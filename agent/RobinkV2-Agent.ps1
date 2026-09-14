<#
.SYNOPSIS
    Robink V2 Ajan - Backend'e baglanir, komutlari alir, calistirir.

.DESCRIPTION
    Bu betik WinToolify.ps1'in fonksiyonlarini kullanarak backend tarafindan
    gonderilen komutlari calistirir ve sonuclari geri gonderir.

    Kullanim:
      Ilk kurulum (cihaz kaydi):
        .\RobinkV2-Agent.ps1 -Server https://robink-v2.com -PairingCode X7K9P2 -DeviceName "Ev PC"

      Sonraki calismalar (cihaz kayitli):
        .\RobinkV2-Agent.ps1 -Server https://robink-v2.com -DeviceId xxx -DeviceToken yyy

.NOTES
    Sunucudan komutlar WinToolify.ps1'dekiyle ayni numaralarla gelir (itemN).
    Ajan WinToolify.ps1'i dot-source eder ve fonksiyonlari kullanir.
    Komut cikti dosyaya yazilir ve geri gonderilir (Write-Host destekli).
#>

param(
    [Parameter(Mandatory=$true)][string]$Server,
    [string]$PairingCode,
    [string]$DeviceId,
    [string]$DeviceToken,
    [string]$DeviceName = "$env:COMPUTERNAME",
    [int]$PollIntervalSeconds = 2,
    [string]$WinToolifyPath
)

# ============================================================
# Robink V2 katalog dosyasi arama mantigi:
#   1) -WinToolifyPath (kullanici verdiyse)
#   2) Ajanin yaninda RobinkV2-Catalog.ps1  (slim, onerilen)
#   3) Ajanin yaninda WinToolify.ps1        (geriye uyumluluk)
#   4) %LOCALAPPDATA%\RobinkV2-Catalog.ps1  (self-bootstrap sonrasi cache)
#   5) Proje kokunde WinToolify.ps1 (agent/../..)
#   6) %LOCALAPPDATA%\WinToolify.ps1 (geriye uyumluluk)
#   7) C:\Robink\WinToolify.ps1 (sabit kurulum)
#   8) Sunucudan indir ($Server/agent/RobinkV2-Catalog.ps1) -> self-bootstrap
# ============================================================

# $PSScriptRoot ve $MyInvocation ayri ayri kontrol et (PS 5.1 uyumu)
$scriptDir = $null
if ($PSScriptRoot) {
    $scriptDir = $PSScriptRoot
} elseif ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $scriptDir) {
    $scriptDir = (Get-Location).Path
}

# Proje koku (agent/../..)
$rootDir = $scriptDir
$parent1 = Split-Path -Parent $scriptDir
if ($parent1) {
    $parent2 = Split-Path -Parent $parent1
    if ($parent2) { $rootDir = $parent2 }
}

$localCandidates = @(
    (Join-Path $scriptDir 'RobinkV2-Catalog.ps1'),
    (Join-Path $scriptDir 'WinToolify.ps1'),
    (Join-Path $env:LOCALAPPDATA 'RobinkV2-Catalog.ps1'),
    (Join-Path $rootDir 'WinToolify.ps1'),
    (Join-Path $env:LOCALAPPDATA 'WinToolify.ps1'),
    'C:\Robink\WinToolify.ps1'
)

$resolvedCatalog = $null
if ($WinToolifyPath -and (Test-Path -LiteralPath $WinToolifyPath)) {
    $resolvedCatalog = $WinToolifyPath
} else {
    foreach ($c in $localCandidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            $resolvedCatalog = $c
            break
        }
    }
}

# 7) Sunucudan indir (self-bootstrap) - sadece -Server verilmisse dene
if (-not $resolvedCatalog -and $Server) {
    Write-Host "  Yerel katalog bulunamadi. Sunucudan indiriliyor: $Server/agent/RobinkV2-Catalog.ps1" -ForegroundColor Yellow
    $catalogUrl = "$Server/agent/RobinkV2-Catalog.ps1"
    $catalogPath = Join-Path $env:LOCALAPPDATA 'RobinkV2-Catalog.ps1'
    try {
        # Eski PS + yeni TLS sunuculari icin TLS 1.2 zorla
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        if (Test-Path -LiteralPath $catalogPath) {
            Remove-Item -LiteralPath $catalogPath -Force -ErrorAction SilentlyContinue
        }
        Invoke-WebRequest -Uri $catalogUrl -OutFile $catalogPath -UseBasicParsing -ErrorAction Stop -TimeoutSec 60
        if (Test-Path -LiteralPath $catalogPath) {
            $size = (Get-Item -LiteralPath $catalogPath).Length
            if ($size -gt 1024) {
                $resolvedCatalog = $catalogPath
                Write-Host "  Katalog sunucudan indirildi ($size byte): $catalogPath" -ForegroundColor Green
            } else {
                Write-Host "  Indirilen dosya cok kucuk ($size byte) - muhtemelen hata sayfasi." -ForegroundColor Red
                Remove-Item -LiteralPath $catalogPath -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Host "  Sunucudan indirilemedi: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if (-not $resolvedCatalog) {
    Write-Host "  Robink V2 katalog dosyasi (WinToolify.ps1) bulunamadi." -ForegroundColor Red
    Write-Host "  Aranan konumlar:" -ForegroundColor Yellow
    foreach ($c in $localCandidates) {
        Write-Host "    - $c" -ForegroundColor Yellow
    }
    if ($Server) {
        Write-Host "    - $Server/agent/WinToolify.ps1 (indirme basarisiz)" -ForegroundColor Yellow
    }
    Write-Host "  Cozumler:" -ForegroundColor Yellow
    Write-Host "    1) -WinToolifyPath 'C:\...\WinToolify.ps1' ile calistir" -ForegroundColor Yellow
    Write-Host "    2) WinToolify.ps1'i elle indirip asagidaki konuma kopyala:" -ForegroundColor Yellow
    Write-Host "       Copy-Item 'C:\...\WinToolify.ps1' '$env:LOCALAPPDATA\RobinkV2-Catalog.ps1'" -ForegroundColor Yellow
    exit 1
}
$WinToolifyPath = $resolvedCatalog
Write-Host "  Katalog: $WinToolifyPath" -ForegroundColor DarkCyan

$ErrorActionPreference = 'Stop'

# WinToolify.ps1'i script basinda yukle (global scope'a) - boylece
# icindeki action scriptblock'lari Get-Translation, New-WtToolRow vs. fonksiyonlarini bulabilir.
if (-not (Test-Path -LiteralPath $WinToolifyPath)) {
    Write-Host "  HATA: Katalog bulunamadi: $WinToolifyPath" -ForegroundColor Red
    exit 1
}
# Global scope'a yuklemek icin scope modifier ile
. $WinToolifyPath
# Fonksiyonlari global scope'a tasimak icin
$globalFuncs = @('Get-Translation','New-WtToolRow','Read-WtSettings','Get-WtInfoToolGroups','Get-WtActionToolGroups','Get-WtWindowsVersionLines','Get-TranslationMap','Set-WtWindowIcon')
foreach ($fn in $globalFuncs) {
    $cmd = Get-Command $fn -ErrorAction SilentlyContinue
    if ($cmd) {
        Set-Item -Path "Function:\Global:$fn" -Value $cmd.ScriptBlock -ErrorAction SilentlyContinue
    }
}

# Renkli cikti icin basit yardimcilar
function Write-RobinkBanner([string]$Text, [string]$Color = 'Cyan') {
    Write-Host ""
    Write-Host "  +---------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  | $Text".PadRight(50) + " |" -ForegroundColor $Color
    Write-Host "  +---------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
}

function Get-WtRowsAndAction {
    param([int]$ItemN)
    # WinToolify.ps1 zaten script basinda global scope'a yuklendi
    $script:WtLanguage = 'TR'
    try {
        $settings = Read-WtSettings
        if (@('EN','TR') -contains $settings.Language) { $script:WtLanguage = $settings.Language }
    } catch {}
    $allGroups = @(
        @{ mode='info'; groups=(Get-WtInfoToolGroups) }
        @{ mode='action'; groups=(Get-WtActionToolGroups) }
    )
    $n = 0
    foreach ($bucket in $allGroups) {
        foreach ($group in $bucket.groups) {
            $rows = & $group.GetRows $group
            foreach ($row in @($rows)) {
                $n++
                if ($n -eq $ItemN) { return $row }
            }
        }
    }
    return $null
}

function Invoke-WtItemWithOutput {
    param($Row)

    if ($null -eq $Row) { return @{ ok=$false; error="Oge bulunamadi" } }
    if ($Row.Data.Power) { return @{ ok=$false; error="Bu oge yeniden baslatma/kapatma icindir" } }

    $startedAt = [DateTime]::UtcNow
    $transcriptPath = Join-Path $env:TEMP "robink-agent-$([Guid]::NewGuid().ToString('N').Substring(0,8)).txt"

    try {
        if ($Row.Data.Native) {
            $fp = [string]$Row.Data.FilePath
            $args = [string]$Row.Data.Arguments
            $outFile = "$transcriptPath.out"
            $errFile = "$transcriptPath.err"
            try {
                $proc = Start-Process -FilePath $fp -ArgumentList $args -NoNewWindow -Wait -PassThru `
                    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
            } catch {
                return @{ ok=$false; error="Process baslatilamadi: $($_.Exception.Message)" }
            }
            $stdout = ''
            $stderr = ''
            if (Test-Path -LiteralPath $outFile) { $stdout = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue; '' | Out-File $outFile -Force }
            if (Test-Path -LiteralPath $errFile) { $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue; '' | Out-File $errFile -Force }
            $output = ($stdout + "`n" + $stderr).TrimEnd()
            return @{
                ok = $true
                output = $output
                exitCode = $proc.ExitCode
                durationMs = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
            }
        }

        # Captured / Inline: Start-Transcript ile yakala
        try { Start-Transcript -Path $transcriptPath -Force -NoClobber -ErrorAction SilentlyContinue | Out-Null } catch {}
        & $Row.Data.Action 2>&1 | Out-Null
        try { Stop-Transcript | Out-Null } catch {}

        $content = ''
        if (Test-Path -LiteralPath $transcriptPath) {
            $raw = Get-Content -LiteralPath $transcriptPath -Raw -ErrorAction SilentlyContinue
            '' | Out-File $transcriptPath -Force
            if ($raw) {
                $lines = $raw -split "`r?`n"
                $starLines = @()
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^\s*\*+\s*$') { $starLines += $i }
                }
                $startIdx = if ($starLines.Count -ge 2) { $starLines[1] + 1 } else { 0 }
                $endIdx = if ($starLines.Count -ge 4) { $starLines[$starLines.Count - 2] - 1 } else { $lines.Count - 1 }
                if ($endIdx -lt $startIdx) { $endIdx = $startIdx }
                $content = ($lines[$startIdx..$endIdx] -join "`n")
            }
        }

        return @{
            ok = $true
            output = $content.TrimEnd()
            durationMs = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }
    catch {
        return @{
            ok = $false
            error = $_.Exception.Message
            durationMs = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }
}

function Send-JsonRequest {
    param([string]$Url, [hashtable]$Body)
    try {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $r = Invoke-WebRequest -Uri $Url -Method POST -ContentType 'application/json' -Body $json -TimeoutSec 30 -UseBasicParsing
        return ($r.Content | ConvertFrom-Json)
    } catch {
        return @{ ok=$false; error=$_.Exception.Message }
    }
}

# ---------- ANA AKIŞ ----------
Write-RobinkBanner "ROBINK V2 AGENT" 'Cyan'

# 1) Eger PairingCode verilmisse, onu kullanarak cihaz kaydi yap
if ($PairingCode) {
    Write-Host "  Cihaz kayit ediliyor: PairingCode=$PairingCode" -ForegroundColor Yellow
    $resp = Send-JsonRequest -Url "$Server/api/agent/pair" -Body @{ code = $PairingCode; name = $DeviceName }
    if (-not $resp.ok) {
        Write-Host "  HATA: $($resp.error)" -ForegroundColor Red
        exit 1
    }
    $DeviceId = $resp.deviceId
    $DeviceToken = $resp.deviceToken
    Write-Host "  Cihaz kayit edildi!" -ForegroundColor Green
    Write-Host "  DeviceId    = $DeviceId" -ForegroundColor Gray
    Write-Host "  DeviceToken = $DeviceToken" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Ileri calismalarda bu kimlikle kullan:" -ForegroundColor Yellow
    Write-Host "    .\RobinkV2-Agent.ps1 -Server $Server -DeviceId $DeviceId -DeviceToken $DeviceToken" -ForegroundColor White
    Write-Host ""

    # Bilgileri yerel kaydet (sonraki kullanim icin)
    $credFile = Join-Path $env:LOCALAPPDATA "robink-agent-$DeviceId.json"
    @{ deviceId = $DeviceId; deviceToken = $DeviceToken; server = $Server } | ConvertTo-Json | Set-Content $credFile -Encoding UTF8
    Write-Host "  Kimlik kaydedildi: $credFile" -ForegroundColor DarkGray
    Write-Host ""
}

if (-not $DeviceId -or -not $DeviceToken) {
    Write-Host "  HATA: DeviceId ve DeviceToken gerekli (ya da -PairingCode ile ilk kayit)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Kullanim:" -ForegroundColor Yellow
    Write-Host "    Ilk kayit:    .\RobinkV2-Agent.ps1 -Server URL -PairingCode XXXXXX -DeviceName 'PC Adi'" -ForegroundColor White
    Write-Host "    Sonraki:      .\RobinkV2-Agent.ps1 -Server URL -DeviceId ID -DeviceToken TOKEN" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "  Server  : $Server" -ForegroundColor Cyan
Write-Host "  Device  : $DeviceId" -ForegroundColor Cyan
Write-Host "  Poll    : ${PollIntervalSeconds}s" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Komut bekleniyor... (kapatmak icin Ctrl+C)" -ForegroundColor DarkGray

# Ctrl+C graceful shutdown
$script:ShouldStop = $false
try {
    [Console]::CancelKeyPress.Add({ $script:ShouldStop = $true })
} catch {}

$PollUrl = "$Server/api/agent/poll"
$ResultUrl = "$Server/api/agent/result"
$consecutiveErrors = 0

while (-not $script:ShouldStop) {
    try {
        # 1) Poll
        $poll = Send-JsonRequest -Url $PollUrl -Body @{ deviceId = $DeviceId; deviceToken = $DeviceToken }

        if (-not $poll.ok) {
            $consecutiveErrors++
            if ($consecutiveErrors -gt 5) {
                Write-Host "  Sunucuya ulasilamiyor ( $($poll.error) )" -ForegroundColor Red
                $consecutiveErrors = 0
            }
            Start-Sleep -Seconds $PollIntervalSeconds
            continue
        }
        $consecutiveErrors = 0

        if ($poll.commands -and $poll.commands.Count -gt 0) {
            foreach ($cmd in $poll.commands) {
                Write-Host ""
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Komut geldi: #$($cmd.itemN) ($($cmd.id.Substring(0,8))...)" -ForegroundColor Cyan
                try {
                    $row = Get-WtRowsAndAction -ItemN $cmd.itemN
                } catch {
                    Write-Host "  WinToolify yuklenemedi: $($_.Exception.Message)" -ForegroundColor Red
                    $row = $null
                }
                $result = Invoke-WtItemWithOutput -Row $row
                $result.deviceId = $DeviceId
                $result.deviceToken = $DeviceToken
                $result.commandId = $cmd.id
                $sendResult = Send-JsonRequest -Url $ResultUrl -Body $result
                if ($sendResult.ok) {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Sonuc gonderildi (ok=$($result.ok), $($result.durationMs)ms)" -ForegroundColor Green
                } else {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Sonuc gonderilemedi: $($sendResult.error)" -ForegroundColor Yellow
                }
            }
        }
    }
    catch {
        Write-Host "  Dongu hatasi: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Start-Sleep -Seconds $PollIntervalSeconds
}

Write-Host ""
Write-Host "  Ajan durduruluyor..." -ForegroundColor DarkGray
Write-Host "  Gule gule." -ForegroundColor Cyan
