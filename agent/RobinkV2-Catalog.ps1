# RobinkV2-Catalog.ps1
# Otomatik uretildi: WinToolify.ps1'den SADECE ajanin ihtiyac duydugu fonksiyonlar
# Tarih: 2026-09-14 20:08
# Hedef: Get-Translation, New-WtToolRow, Read-WtSettings, Get-WtInfoToolGroups, Get-WtActionToolGroups, Get-WtWindowsVersionLines, Set-WtWindowIcon
# Toplam fonksiyon: 324
#
# NOT: Bu dosya ajan (RobinkV2-Agent.ps1) tarafindan dot-source edilir.
# Tum tool tanimlari (New-WtToolRow ile uretilenler) burada yer alir,
# boylece ajan web'den komut geldiginde ayni numarali ogeyi calistirabilir.
# Translation map ve storage fonksiyonlari da dahildir.

#region src/00-core/storage.ps1  (Read-WtSettings ve deps)

# ---- Assert-WtTuiCtrlCInput (lines 5792-5811) ----
function Assert-WtTuiCtrlCInput {
    <#
    .SYNOPSIS
        Puts Ctrl+C back to being a KEY after a captured native command
        (sfc, DISM, winget, a child PowerShell) flips the shared
        console-mode bit back on. Called before every blocking key read
        and on the native runner's tick; returns $true when it changed it.
    #>
    param(
        [scriptblock]$GetConsole = { [Console]::TreatControlCAsInput },
        [scriptblock]$SetConsole = { param($Value) [Console]::TreatControlCAsInput = [bool]$Value }
    )
    if (-not $script:WtTuiCtrlCOwned) { return $false }
    try {
        if ([bool](& $GetConsole)) { return $false }
        & $SetConsole $true
        return $true
    }
    catch { return $false }
}

# ---- Assert-WtWindowMaximized (lines 12120-12142) ----
function Assert-WtWindowMaximized {
    <#
    .SYNOPSIS
        Maximizes the locked window again when something restored or
        minimized it: Win+Down, a caption drag, a programmatic SC_RESTORE
        - none of these check the removed style bits. Called before every
        blocking input wait, next to Assert-WtTuiCtrlCInput; one cheap
        IsZoomed query when nothing changed. No-op without a lock; never
        throws. Returns $true when it had to maximize.
    #>
    param(
        [scriptblock]$IsZoomed = { param($Handle) [bool][WtWindowNative]::IsZoomed($Handle) },
        [scriptblock]$Maximize = { param($Handle) $null = [WtWindowNative]::ShowWindow($Handle, 3); Sync-WtBufferToWindow }
    )
    $state = $script:WtWindowLock
    if ($null -eq $state) { return $false }
    try {
        if ([bool](& $IsZoomed $state.Handle)) { return $false }
        $null = & $Maximize $state.Handle
        return $true
    }
    catch { return $false }
}

# ---- Clear-WtPendingInput (lines 5964-5987) ----
function Clear-WtPendingInput {
    <#
    .SYNOPSIS
        Throws away every key sitting in the console queue and returns how
        many there were. Called after a long action ends and again when
        the nav screen regains control, so a key queued during the action
        (or its auto-repeat) cannot silently replay and repeat the row.
    #>
    param(
        [scriptblock]$KeyAvailable = { [Console]::KeyAvailable },
        [scriptblock]$ReadKey = { [Console]::ReadKey($true) },
        [int]$Cap = 1024
    )
    if ($script:WtInputMode -ne 'Key') { return 0 }
    $drained = 0
    try {
        while ($drained -lt $Cap -and [bool](& $KeyAvailable)) {
            $null = & $ReadKey
            $drained++
        }
    }
    catch { $null = $_ }
    return $drained
}

# ---- Confirm-WtDestructiveAction (lines 6995-7012) ----
function Confirm-WtDestructiveAction {
    <#
    .SYNOPSIS
        Typed-confirmation gate rendered in the panel: the consequence
        (red) plus optional detail lines, then the prompt on the footer
        row. The word the user must type is the localized one (YES in
        English, EVET in Turkish) and the match is case-sensitive.
    #>
    param(
        [Parameter(Mandatory)][string]$Consequence,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [string]$Breadcrumb = '',
        [scriptblock]$ReadAnswer = { param($Lines, $Prompt) Read-WtPanelAnswer -Breadcrumb $(if ($Breadcrumb) { $Breadcrumb } else { $script:WtPanelBreadcrumb }) -Lines $Lines -Prompt $Prompt -Risk 'ADVANCED' }
    )
    $all = @($Consequence) + @($Lines)
    $typed = & $ReadAnswer $all ((Get-Translation 'TypeYesToConfirm') -f (Get-WtTypedWord -Kind 'Yes'))
    return (Test-WtTypedConfirmation -Answer $typed -Kind 'Yes')
}

# ---- ConvertFrom-WtWifiProfileXml (lines 27872-27893) ----
function ConvertFrom-WtWifiProfileXml {
    <#
    .SYNOPSIS
        Parses an exported WLAN profile XML (netsh wlan export profile
        ... key=clear) - locale-independent, unlike scraping the
        localized "Key Content" line from netsh text output. Open
        networks have no sharedKey element and yield Key = $null.
    #>
    param([Parameter(Mandatory)][xml]$ProfileXml)

    $ns = New-Object System.Xml.XmlNamespaceManager($ProfileXml.NameTable)
    $ns.AddNamespace('w', 'http://www.microsoft.com/networking/WLAN/profile/v1')
    $name = $ProfileXml.SelectSingleNode('//w:WLANProfile/w:name', $ns)
    $key = $ProfileXml.SelectSingleNode('//w:sharedKey/w:keyMaterial', $ns)
    $auth = $ProfileXml.SelectSingleNode('//w:authEncryption/w:authentication', $ns)

    return [PSCustomObject]@{
        Name           = if ($name) { $name.InnerText } else { $null }
        Key            = if ($key) { $key.InnerText } else { $null }
        Authentication = if ($auth) { $auth.InnerText } else { $null }
    }
}

# ---- ConvertTo-WtGpoBoolean (lines 15197-15208) ----
function ConvertTo-WtGpoBoolean {
    <#
    .SYNOPSIS
        PURE: a [bool] as the enum name Set-NetFirewallProfile's -Enabled
        parameter accepts ('True'/'False'). A string, not a [GpoBoolean]
        literal: PowerShell cannot cast [bool] to that type directly, and
        the type resolves lazily via the NetSecurity module, so naming it
        here would break parsing on a host without it.
    #>
    param([Parameter(Mandatory)][bool]$Enabled)
    return [string]$Enabled
}

# ---- ConvertTo-WtGridKeyToken (lines 7788-7820) ----
function ConvertTo-WtGridKeyToken {
    <#
    .SYNOPSIS
        The winget store's own key vocabulary: unlike the shared converter,
        keeps case and passes RightArrow/Tab/Delete and any printable
        character through (IsControl, not regex - tr-TR mishandles
        dotted/dotless i under -match).
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][AllowEmptyString()][string]$KeyChar = ''
    )

    switch ($Key) {
        'UpArrow'    { return 'Up' }
        'DownArrow'  { return 'Down' }
        'LeftArrow'  { return 'Left' }
        'RightArrow' { return 'Right' }
        'PageUp'     { return 'PageUp' }
        'PageDown'   { return 'PageDown' }
        'Home'       { return 'Home' }
        'End'        { return 'End' }
        'Tab'        { return 'Tab' }
        'Escape'     { return 'Esc' }
        'Backspace'  { return 'Backspace' }
        'Delete'     { return 'Delete' }
        'Enter'      { return 'Enter' }
        'Spacebar'   { return 'Space' }
    }

    if ($KeyChar.Length -eq 1 -and -not [char]::IsControl($KeyChar[0])) { return 'Char:' + $KeyChar }
    return 'None'
}

# ---- ConvertTo-WtKeyToken (lines 7195-7229) ----
function ConvertTo-WtKeyToken {
    <#
    .SYNOPSIS
        Normalizes one ConsoleKeyInfo (passed as its Key name string +
        KeyChar string so tests never need a real console) into the
        screen-reducer token vocabulary. Unknown keys become 'None' and
        are ignored by the reducer.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [AllowNull()][AllowEmptyString()]
        [string]$KeyChar = ''
    )

    switch ($Key) {
        'UpArrow'   { return 'Up' }
        'DownArrow' { return 'Down' }
        'PageUp'    { return 'PageUp' }
        'PageDown'  { return 'PageDown' }
        'Home'      { return 'Home' }
        'End'       { return 'End' }
        'Spacebar'  { return 'Space' }
        'Enter'     { return 'Enter' }
        'LeftArrow' { return 'Back' }
        'Escape'    { return 'Back' }
        'Backspace' { return 'Back' }
    }

    if ($KeyChar -match '^[0-9]$') { return "Digit:$KeyChar" }
    if ($KeyChar -match '^[A-Za-z]$') { return ('Char:' + $KeyChar.ToLowerInvariant()) }
    if ($KeyChar -eq '/') { return 'Char:/' }
    return 'None'
}

# ---- ConvertTo-WtLineToken (lines 7231-7251) ----
function ConvertTo-WtLineToken {
    <#
    .SYNOPSIS
        The line-input fallback (hosts without ReadKey: ISE, redirected
        stdin) speaks the same token vocabulary: empty line = Enter,
        digits = jump, n/p = paging, b = back, any other word = its
        first letter as a Char token.
    #>
    param(
        [AllowNull()][AllowEmptyString()]
        [string]$Line
    )

    $t = ([string]$Line).Trim()
    if ($t -eq '') { return 'Enter' }
    if ($t -match '^[0-9]+$') { return "Digit:$t" }
    if ($t -match '^[Nn]$') { return 'PageDown' }
    if ($t -match '^[Pp]$') { return 'PageUp' }
    if ($t -match '^[Bb]$') { return 'Back' }
    return ('Char:' + $t.Substring(0, 1).ToLowerInvariant())
}

# ---- ConvertTo-WtOutputLines (lines 9031-9069) ----
function ConvertTo-WtOutputLines {
    <#
    .SYNOPSIS
        One captured pipeline object -> the text lines a panel should
        show: errors and warnings become their message, not a stack
        trace, and other objects go through Out-String. A lone carriage
        return overwrites the current row instead of starting a new one,
        since tools like sfc write their whole progress as one
        CR-separated line.
    #>
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return @() }

    $text = $null
    if ($InputObject -is [string]) { $text = $InputObject }
    elseif ($InputObject -is [System.Management.Automation.InformationRecord]) {
        $data = $InputObject.MessageData
        $text = if ($null -ne $data -and $data.PSObject.Properties.Name -contains 'Message') { [string]$data.Message } else { [string]$data }
    }
    elseif ($InputObject -is [System.Management.Automation.ErrorRecord]) { $text = [string]$InputObject.Exception.Message }
    elseif ($InputObject -is [System.Management.Automation.WarningRecord]) { $text = [string]$InputObject.Message }
    elseif ($InputObject -is [System.Management.Automation.VerboseRecord] -or $InputObject -is [System.Management.Automation.DebugRecord]) { $text = [string]$InputObject.Message }
    else {
        $text = ($InputObject | Out-String).TrimEnd("`r", "`n")
        $text = $text -replace '^(\r?\n)+', ''
    }

    if ($null -eq $text) { return @() }
    $lines = @($text -split '\r?\n')
    if ($lines.Count -eq 1 -and -not $lines[0]) { return @('') }
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line.IndexOf("`r") -lt 0) { $rows.Add($line); continue }
        $segments = @($line -split "`r" | Where-Object { $_ -ne '' })
        $rows.Add($(if ($segments.Count -gt 0) { [string]$segments[-1] } else { '' }))
    }
    return $rows.ToArray()
}

# ---- ConvertTo-WtPanelLines (lines 6495-6520) ----
function ConvertTo-WtPanelLines {
    <#
    .SYNOPSIS
        Panel text wrapped so no row is ever cut with '~'. Every line is
        folded to the room a message row really has at this width; blank
        lines are kept because they are deliberate separators. All lines
        wrap to the FIRST row's room (the one carrying the risk tag), so
        a wrapped paragraph forms a straight block instead of widening on
        later lines.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][int]$Width,
        [string]$Risk = '',
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $probe = New-WtListItem -Kind 'Info' -Name 'Probe' -Label '' -Risk $Risk
    $room = Get-WtListRowLabelRoom -Item $probe -Glyphs $Glyphs -Width $Width
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Lines)) {
        $text = [string]$line
        if (-not $text.Trim()) { $out.Add(''); continue }
        foreach ($piece in @(Split-WtWrappedLines -Text $text -Width $room)) { $out.Add($piece) }
    }
    return [string[]]$out.ToArray()
}

# ---- ConvertTo-WtPsSingleQuoted (lines 42-52) ----
function ConvertTo-WtPsSingleQuoted {
    <#
    .SYNOPSIS
        One value as a PowerShell single-quoted literal, with every
        embedded quote doubled - the only escape a single-quoted string
        needs, keeping a package id from closing its own literal and
        continuing as script in the generated shim.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

# ---- ConvertTo-WtRestorePointTime (lines 34063-34076) ----
function ConvertTo-WtRestorePointTime {
    <#
    .SYNOPSIS
        A restore point's CreationTime as a DateTime. WMI hands it over as
        a DMTF string (yyyymmddHHMMSS.mmmmmm+UUU); the CIM branch may hand
        over a real DateTime. Anything unreadable comes back as $null so
        the caller can print a visibly unknown stamp instead of "today".
    #>
    param([Parameter(Mandatory)][AllowNull()]$CreationTime)
    if ($null -eq $CreationTime) { return $null }
    if ($CreationTime -is [datetime]) { return [datetime]$CreationTime }
    try { return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$CreationTime) }
    catch { return $null }
}

# ---- ConvertTo-WtRowString (lines 7145-7181) ----
function ConvertTo-WtRowString {
    <#
    .SYNOPSIS
        Renders one segment-line into a string that occupies EXACTLY Width
        visible columns: segments are concatenated (styled when Vt),
        truncated at Width, and space-padded (unstyled) to Width. Every
        frame row goes through here, so no stale characters can survive
        a redraw and the right border always lands in the same column.
        Styling goes through the SGR prefix cache rather than calling
        ConvertTo-WtVtText per segment: at 17 segments a store row that
        cost 70-280 ms a frame, the lag behind every cursor move.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Segments,
        [Parameter(Mandatory)][int]$Width,
        [bool]$Vt = $false
    )
    $sb = New-Object System.Text.StringBuilder
    $used = 0
    $cache = $script:WtSgrPrefixCache
    $reset = $script:WtEsc + '[0m'
    foreach ($seg in $Segments) {
        if ($used -ge $Width) { break }
        $text = [string]$seg.T
        if (($used + $text.Length) -gt $Width) { $text = $text.Substring(0, $Width - $used) }
        if ($text.Length -eq 0) { continue }
        if ($Vt) {
            $prefix = $cache[[string]$seg.F + '|' + [string]$seg.B]
            if ($null -eq $prefix) { $prefix = Get-WtSgrPrefix -Fg ([string]$seg.F) -Bg ([string]$seg.B) }
            [void]$sb.Append($prefix).Append($text).Append($reset)
        }
        else { [void]$sb.Append($text) }
        $used += $text.Length
    }
    if ($used -lt $Width) { [void]$sb.Append(' ' * ($Width - $used)) }
    return $sb.ToString()
}

# ---- ConvertTo-WtTaskExitCode (lines 84-99) ----
function ConvertTo-WtTaskExitCode {
    <#
    .SYNOPSIS
        A scheduled task's LastTaskResult as a real exit code, or $null
        while the task has not produced one yet. LastTaskResult doubles as
        a status field before the action finishes (SCHED_S_TASK_RUNNING /
        HAS_NOT_RUN / QUEUED = 267009 / 267011 / 267045), so those three
        values are treated as "still working" rather than as exit codes;
        winget's own codes never collide with them.
    #>
    param([AllowNull()][object]$LastTaskResult)
    if ($null -eq $LastTaskResult) { return $null }
    $value = [int]$LastTaskResult
    if ($value -eq 267009 -or $value -eq 267011 -or $value -eq 267045) { return $null }
    return $value
}

# ---- ConvertTo-WtVcRedistInstalled (lines 28057-28095) ----
function ConvertTo-WtVcRedistInstalled {
    <#
    .SYNOPSIS
        PURE: the Visual C++ runtimes present in a Programs-list snapshot
        (Get-WtInstalledProgramEntries), as @{ Family; Arch; Version;
        DisplayName }. Family comes from DisplayVersion's major, not a year
        in the name (which varies: "2015", "2017", "2015-2022", "v14" all
        mean the same family), falling back to a year match only when
        DisplayVersion is missing or unparsable. The name must start with
        "Microsoft Visual C++" and contain "Redistributable" (excludes the
        "Minimum/Additional Runtime" MSI halves); x64 is a name marker
        (2005 x86 has none), ARM64 rows are ignored.
    #>
    param([AllowNull()][AllowEmptyCollection()][array]$Entries)
    $families = @{ 8 = '2005'; 9 = '2008'; 10 = '2010'; 11 = '2012'; 12 = '2013'; 14 = '2015-2022' }
    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $name = [string]$entry.DisplayName
        if (-not $name.StartsWith('Microsoft Visual C++', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($name.IndexOf('Redistributable', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($name.IndexOf('arm64', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
        $arch = if ([regex]::IsMatch($name, '\bx64\b', $ignoreCase)) { 'x64' } else { 'x86' }
        $version = $null
        $parsed = $null
        if ([version]::TryParse([string]$entry.DisplayVersion, [ref]$parsed)) { $version = $parsed }
        $family = $null
        if ($null -ne $version -and $families.ContainsKey($version.Major)) { $family = $families[$version.Major] }
        if (-not $family) {
            $year = [regex]::Match($name, '\b(2005|2008|2010|2012|2013)\b')
            if ($year.Success) { $family = $year.Groups[1].Value }
            elseif ([regex]::IsMatch($name, '\b(2015|2017|2019|2022|v14)\b', $ignoreCase)) { $family = '2015-2022' }
        }
        if (-not $family) { continue }
        $out.Add(@{ Family = $family; Arch = $arch; Version = $version; DisplayName = $name })
    }
    return $out.ToArray()
}

# ---- ConvertTo-WtVramByteCount (lines 31445-31465) ----
function ConvertTo-WtVramByteCount {
    <#
    .SYNOPSIS
        HardwareInformation.qwMemorySize as a byte count. The value is a
        REG_QWORD (Int64) on most drivers and REG_BINARY (byte[]) on Intel
        and older WDDM stacks; both are decoded here since a plain
        [int64] cast throws on the byte-array form.
    #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return [long]0 }
    if ($Value -is [byte[]]) {
        if ($Value.Length -eq 0) { return [long]0 }
        $buffer = [byte[]]::new(8)
        [System.Array]::Copy($Value, 0, $buffer, 0, [math]::Min(8, $Value.Length))
        return [long][System.BitConverter]::ToInt64($buffer, 0)
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64]) { return [long]$Value }
    $parsed = [long]0
    if ([long]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return [long]0
}

# ---- ConvertTo-WtWingetExitCode (lines 26892-26909) ----
function ConvertTo-WtWingetExitCode {
    <#
    .SYNOPSIS
        winget's documented result codes (0x8A15....) are UNSIGNED, but
        $LASTEXITCODE is a signed Int32, and in Windows PowerShell 5.1 an
        eight-digit hex literal like 0x8A15002B parses as that SAME
        negative Int32 - so casting either straight to [uint32] throws an
        OverflowException instead of producing the documented value. This
        reinterprets $LASTEXITCODE's 32 bits as a UInt32 through
        BitConverter instead, returning $null when no exit code was
        captured. Never cast a 0x8A15.... literal to [uint32] directly;
        go through this function, or [Convert]::ToUInt32(hex, 16).
    #>
    param([Parameter(Mandatory)][AllowNull()][object]$ExitCode)
    if ($null -eq $ExitCode) { return $null }
    $bytes = [System.BitConverter]::GetBytes([int]$ExitCode)
    return [System.BitConverter]::ToUInt32($bytes, 0)
}

# ---- Format-WtBrowserCacheLines (lines 23253-23287) ----
function Format-WtBrowserCacheLines {
    <#
    .SYNOPSIS
        PURE: what the panel shows before anything is deleted - one line
        per browser with its total, one line per profile under it, the
        grand total, and the sentence that says what was NOT touched.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Targets)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'BrowserCacheTitle') + ':')
    $total = 0L

    foreach ($target in @($Targets)) {
        $lines.Add('')
        $lines.Add(('  {0}: {1}' -f $target.DisplayLabel, (Format-WtByteSize -Bytes ([long]$target.Bytes))))
        $seen = New-Object System.Collections.Generic.List[string]
        foreach ($path in @($target.Paths)) {
            $profileName = [string]$path.ProfileName
            if ($seen -ccontains $profileName) { continue }
            $seen.Add($profileName)
            $profileBytes = 0L
            foreach ($candidate in @($target.Paths)) {
                if (([string]$candidate.ProfileName) -ceq $profileName) { $profileBytes += [long]$candidate.Bytes }
            }
            $lines.Add(('      {0} {1}: {2}' -f (Get-Translation 'BrowserCacheProfile'), $profileName, (Format-WtByteSize -Bytes $profileBytes)))
        }
        $total += [long]$target.Bytes
    }

    $lines.Add('')
    $lines.Add(('{0}: {1}' -f (Get-Translation 'BrowserCacheTotal'), (Format-WtByteSize -Bytes $total)))
    $lines.Add((Get-Translation 'BrowserCacheUntouched'))
    return [string[]]$lines.ToArray()
}

# ---- Format-WtBrowserCacheResultLines (lines 23289-23317) ----
function Format-WtBrowserCacheResultLines {
    <#
    .SYNOPSIS
        PURE: the outcome - freed bytes per browser, the reason for every
        browser that was skipped, its errors indented under it, the total,
        and the "nothing else was touched" line repeated where the user
        actually ends up reading it.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Result)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'BrowserCacheTitle') + ':')
    $lines.Add('')

    foreach ($item in @($Result.Results)) {
        if ($item.SkippedReasonKey) {
            $lines.Add(('  {0}: {1}' -f $item.DisplayLabel, (Get-Translation $item.SkippedReasonKey)))
        }
        else {
            $lines.Add(('  {0}: {1} {2}' -f $item.DisplayLabel, (Get-Translation 'FreedSpace'), (Format-WtByteSize -Bytes ([long]$item.FreedBytes))))
        }
        foreach ($err in @($item.Errors)) { $lines.Add('      ' + $err) }
    }

    $lines.Add('')
    $lines.Add(('{0}: {1}' -f (Get-Translation 'FreedSpace'), (Format-WtByteSize -Bytes ([long]$Result.TotalFreedBytes))))
    $lines.Add((Get-Translation 'BrowserCacheUntouched'))
    return [string[]]$lines.ToArray()
}

# ---- Format-WtByteSize (lines 409-436) ----
function Format-WtByteSize {
    <#
    .SYNOPSIS
        Renders a byte count as a 1024-based size with one decimal
        (invariant culture): "512 B", "1.5 KB", "245.3 MB", "1.2 GB",
        "2.0 TB". Used by every report in the bundle so sizes read the same
        everywhere.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [long]$Bytes
    )

    if ($Bytes -lt 1024) {
        return "$Bytes B"
    }

    $units = @('KB', 'MB', 'GB', 'TB', 'PB')
    $value = [double]$Bytes / 1024
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value = $value / 1024
        $unitIndex++
    }

    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.0} {1}', $value, $units[$unitIndex])
}

# ---- Format-WtCleanupPreviewLabel (lines 24050-24067) ----
function Format-WtCleanupPreviewLabel {
    <#
    .SYNOPSIS
        The selector state label for one preview row: "245.3 MB (1,204
        files)" / "245.3 MB (1.204 dosya)" - size via Format-WtByteSize,
        count in invariant culture, the sentence itself localized.
    #>
    param(
        [Parameter(Mandatory)]
        [long]$Bytes,

        [Parameter(Mandatory)]
        [int]$Count
    )

    $countText = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:N0}', $Count)
    return (Get-Translation 'CleanupPreviewLabel') -f (Format-WtByteSize -Bytes $Bytes), $countText
}

# ---- Format-WtCleanupResultLines (lines 24240-24261) ----
function Format-WtCleanupResultLines {
    <#
    .SYNOPSIS
        PURE: the cleanup outcome - a line per category with freed size,
        deleted and skipped counts, each category's errors indented under
        it, then the total.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Result)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'CleanupResultTitle') + ':')
    $lines.Add('')
    foreach ($category in @($Result.Results)) {
        $lines.Add(('  {0}: {1} {2}, {3} {4}, {5} {6}' -f $category.DisplayLabel,
            (Format-WtByteSize -Bytes $category.FreedBytes), (Get-Translation 'FreedSpace'),
            $category.DeletedCount, (Get-Translation 'FilesDeleted'),
            $category.SkippedCount, (Get-Translation 'FilesSkipped')))
        foreach ($err in @($category.Errors)) { $lines.Add('      ' + $err) }
    }
    $lines.Add('')
    $lines.Add(('{0}: {1}' -f (Get-Translation 'FreedSpace'), (Format-WtByteSize -Bytes $Result.TotalFreedBytes)))
    return [string[]]$lines.ToArray()
}

# ---- Format-WtDefenderSignatureAge (lines 32857-32875) ----
function Format-WtDefenderSignatureAge {
    <#
    .SYNOPSIS
        PURE: "N days (timestamp)" for a signature update time. Rounds
        (not floors) to the nearest whole day, away from zero, so a
        signature updated 2 days 23h ago reads "3 days".
    #>
    param(
        [AllowNull()]$LastUpdated,
        [datetime]$Now = (Get-Date)
    )
    if ($null -eq $LastUpdated) { return [string](Get-Translation 'SecStateUnknown') }
    $when = $null
    try { $when = [datetime]$LastUpdated }
    catch { return [string](Get-Translation 'SecStateUnknown') }
    $days = [int][math]::Round(($Now - $when).TotalDays, [MidpointRounding]::AwayFromZero)
    if ($days -lt 0) { $days = 0 }
    return ('{0} ({1})' -f ((Get-Translation 'DefenderSignatureAgeDays') -f $days), $when.ToString('yyyy-MM-dd HH:mm:ss'))
}

# ---- Format-WtDirectionCounts (lines 6522-6537) ----
function Format-WtDirectionCounts {
    <#
    .SYNOPSIS
        PURE: "2 to apply, 1 to remove" - zero parts are omitted, both
        zero gives ''. Used by the list counter, the commit summary and
        the apply prompt so every place words the two directions alike.
    #>
    param(
        [Parameter(Mandatory)][int]$ApplyCount,
        [Parameter(Mandatory)][int]$RemoveCount
    )
    $parts = @()
    if ($ApplyCount -gt 0) { $parts += ((Get-Translation 'MarkSummaryApply') -f $ApplyCount) }
    if ($RemoveCount -gt 0) { $parts += ((Get-Translation 'MarkSummaryRemove') -f $RemoveCount) }
    return ($parts -join ', ')
}

# ---- Format-WtDiskHealthLines (lines 27621-27672) ----
function Format-WtDiskHealthLines {
    <#
    .SYNOPSIS
        Renders the disk half of the System Health Report as plain string
        lines: a heading, then per disk "[Severity] Name (media, bus,
        size)" followed by indented detail lines and one line per flag.
        Plain strings so the menu can color by the [WARNING]/[CRITICAL]
        prefix and Save-WtReport can write them unchanged.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Report
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('=== Disks ===')

    if ($Report.Count -eq 0) {
        $lines.Add('No physical disks reported.')
        return $lines.ToArray()
    }

    foreach ($disk in $Report) {
        $lines.Add("[$($disk.Severity)] $($disk.FriendlyName) ($($disk.MediaType), $($disk.BusType), $(Format-WtByteSize -Bytes $disk.SizeBytes))")
        $lines.Add("    Health: $($disk.HealthStatus) / $($disk.OperationalStatus)")

        $temperatureText = if ($null -ne $disk.TemperatureC) {
            if ($null -ne $disk.TemperatureMaxC) { "$($disk.TemperatureC) C (max $($disk.TemperatureMaxC) C)" } else { "$($disk.TemperatureC) C" }
        }
        else { 'n/a' }
        $lines.Add("    Temperature: $temperatureText")

        $wearText = if ($null -ne $disk.WearPercent) { "$($disk.WearPercent) %" } else { 'n/a' }
        $lines.Add("    Wear: $wearText")

        $hoursText = if ($null -ne $disk.PowerOnHours) { "$($disk.PowerOnHours)" } else { 'n/a' }
        $lines.Add("    Power-on hours: $hoursText")

        $errorText = if ($null -ne $disk.ReadErrorsUncorrected -or $null -ne $disk.WriteErrorsUncorrected) {
            "R $(if ($null -ne $disk.ReadErrorsUncorrected) { $disk.ReadErrorsUncorrected } else { 'n/a' }) / W $(if ($null -ne $disk.WriteErrorsUncorrected) { $disk.WriteErrorsUncorrected } else { 'n/a' })"
        }
        else { 'n/a' }
        $lines.Add("    Uncorrected errors: $errorText")

        foreach ($flag in @($disk.Flags)) {
            $lines.Add("    [$($flag.Severity)] $($flag.Message)")
        }
    }

    return $lines.ToArray()
}

# ---- Format-WtDuplicateReportLines (lines 24551-24592) ----
function Format-WtDuplicateReportLines {
    <#
    .SYNOPSIS
        Renders a Get-WtDuplicateGroups result as plain string lines:
        totals, then the first -MaxGroups groups (all when omitted) with
        one indented path per copy.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Result,

        [int]$MaxGroups = 0
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $groups = @($Result.Groups)
    $lines.Add('=== Duplicate files ===')
    $lines.Add("Files considered: $($Result.FilesConsidered), hashed: $($Result.FilesHashed), duplicates: $($Result.DuplicateFileCount) in $($groups.Count) groups")
    $lines.Add("Total wasted space: $(Format-WtByteSize -Bytes $Result.TotalWastedBytes)")
    if ($Result.UnreadableFiles -gt 0) {
        $lines.Add("Unreadable files skipped: $($Result.UnreadableFiles)")
    }

    if ($groups.Count -eq 0) {
        $lines.Add('No duplicate files found.')
        return $lines.ToArray()
    }

    $limit = if ($MaxGroups -gt 0) { [math]::Min($MaxGroups, $groups.Count) } else { $groups.Count }
    for ($i = 0; $i -lt $limit; $i++) {
        $group = $groups[$i]
        $paths = @($group.Paths)
        $lines.Add(('{0}. {1} copies x {2} - wasted {3}' -f ($i + 1), $paths.Count, (Format-WtByteSize -Bytes $group.Length), (Format-WtByteSize -Bytes $group.WastedBytes)))
        foreach ($path in $paths) { $lines.Add("    $path") }
    }

    if ($limit -lt $groups.Count) {
        $lines.Add("... $($groups.Count - $limit) more groups in the saved report")
    }

    return $lines.ToArray()
}

# ---- Format-WtElapsed (lines 9109-9119) ----
function Format-WtElapsed {
    <#
    .SYNOPSIS
        PURE: seconds -> "mm:ss" for the "still running" footer. Minutes
        keep counting past 60 instead of rolling into hours, so a
        90-minute run reads "90:12" rather than "1:30:12".
    #>
    param([Parameter(Mandatory)][int]$Seconds)
    $s = [Math]::Max(0, $Seconds)
    return ('{0:00}:{1:00}' -f [int][Math]::Floor($s / 60), ($s % 60))
}

# ---- Format-WtExplorerCacheLines (lines 26558-26579) ----
function Format-WtExplorerCacheLines {
    <#
    .SYNOPSIS
        PURE: the icon-cache report - how many databases went, how many
        bytes that freed, and the full path of every file the shell never
        released. The locked list is printed by name: "done" over a file
        that is still there is the one thing this row must not say.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Result)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0}: {1}' -f (Get-Translation 'IconCacheDeleted'), [int]$Result.DeletedCount))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'FreedSpace'), (Format-WtByteSize -Bytes ([long]$Result.FreedBytes))))
    $locked = @($Result.Locked)
    if ($locked.Count -eq 0) {
        $lines.Add((Get-Translation 'IconCacheNoneLocked'))
    }
    else {
        $lines.Add((Get-Translation 'IconCacheStillLocked'))
        foreach ($path in $locked) { $lines.Add('  ' + [string]$path) }
    }
    return [string[]]$lines.ToArray()
}

# ---- Format-WtHungProcessLines (lines 26777-26795) ----
function Format-WtHungProcessLines {
    <#
    .SYNOPSIS
        PURE: what the confirmation gate shows before anything is closed -
        one "name (id) - window title" line per process, so the user can
        recognise the application they are about to lose. A process whose
        title could not be read still gets a line, with a phrase in place
        of the title.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Processes)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($process in @($Processes)) {
        $title = [string]$process.Title
        if (-not $title) { $title = [string](Get-Translation 'HungAppNoTitle') }
        $lines.Add(('  {0} ({1}) - {2}' -f $process.Name, $process.Id, $title))
    }
    if ($lines.Count -eq 0) { $lines.Add([string](Get-Translation 'HungAppNone')) }
    return [string[]]$lines.ToArray()
}

# ---- Format-WtLeftTruncatedPath (lines 438-455) ----
function Format-WtLeftTruncatedPath {
    <#
    .SYNOPSIS
        PURE: a path cut from the LEFT to fit a column. The tail is the
        half that identifies a file, so "C:\Users\..." is what may go -
        cutting from the right would leave every row reading the same.
        A path that already fits comes back untouched.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][int]$Width
    )
    $text = [string]$Path
    if ($Width -le 0) { return '' }
    if ($Width -le 3) { return '...'.Substring(0, $Width) }
    if ($text.Length -le $Width) { return $text }
    return '...' + $text.Substring($text.Length - ($Width - 3))
}

# ---- Format-WtMemoryFlushLines (lines 24894-24919) ----
function Format-WtMemoryFlushLines {
    <#
    .SYNOPSIS
        PURE: the memory-flush report - one line per area, then before /
        after / freed. Split out of the action so the wording is testable
        without touching real memory.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Catalog
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'FreeMemory') + ':')
    $lines.Add('')
    foreach ($item in @($Result.Results)) {
        $entry = $Catalog | Where-Object Name -eq $item.Name | Select-Object -First 1
        $label = if ($entry) { [string]$entry.DisplayLabel } else { [string]$item.Name }
        $status = if ($item.Succeeded) { Get-Translation 'FlushSucceeded' } else { '{0} - {1}' -f (Get-Translation 'FlushFailed'), $item.Error }
        $lines.Add(('  {0}: {1}' -f $label, $status))
    }
    $lines.Add('')
    $lines.Add(('{0}: {1} MB' -f (Get-Translation 'MemoryBefore'), $Result.BeforeMB))
    $lines.Add(('{0}: {1} MB' -f (Get-Translation 'MemoryAfter'), $Result.AfterMB))
    $lines.Add(('{0}: {1} MB' -f (Get-Translation 'MemoryFreed'), $Result.FreedMB))
    return [string[]]$lines.ToArray()
}

# ---- Format-WtOnOffWord (lines 32805-32826) ----
function Format-WtOnOffWord {
    <#
    .SYNOPSIS
        PURE: a boolean-ish value as the active language's On / Off /
        Unknown word. $null or empty is always Unknown, never Off -
        printing Off for "could not read this" is a lie the user acts on.
        String comparison is Ordinal on purpose: a culture-aware compare
        on a tr-TR host folds capital I to the dotless i, so "True" stops
        matching.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return [string](Get-Translation 'SecStateUnknown') }
    if ($Value -is [string]) {
        $text = ([string]$Value).Trim()
        if ($text.Length -eq 0) { return [string](Get-Translation 'SecStateUnknown') }
        if ([string]::Equals($text, 'True', [StringComparison]::Ordinal) -or [string]::Equals($text, '1', [StringComparison]::Ordinal)) { return [string](Get-Translation 'SecStateOn') }
        if ([string]::Equals($text, 'False', [StringComparison]::Ordinal) -or [string]::Equals($text, '0', [StringComparison]::Ordinal)) { return [string](Get-Translation 'SecStateOff') }
        return [string](Get-Translation 'SecStateUnknown')
    }
    if ([bool]$Value) { return [string](Get-Translation 'SecStateOn') }
    return [string](Get-Translation 'SecStateOff')
}

# ---- Format-WtRemoteEndpoint (lines 32405-32423) ----
function Format-WtRemoteEndpoint {
    <#
    .SYNOPSIS
        "address:port" for the connection table, with a long IPv6 literal
        cut to a fixed width so one row can never push the panel into
        wrapping (the cut is visible, '...', never silent). IndexOf takes
        the Ordinal overload, like every text comparison in this file,
        since tr-TR's dotless-I makes culture-aware comparisons unreliable.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Address,
        [Parameter(Mandatory)][int]$Port,
        [int]$MaxAddressLength = 24
    )
    $text = $Address
    if ($text.Length -gt $MaxAddressLength) { $text = $text.Substring(0, [Math]::Max(1, $MaxAddressLength - 3)) + '...' }
    if ($Address.IndexOf(':', [System.StringComparison]::Ordinal) -ge 0) { return ('[{0}]:{1}' -f $text, $Port) }
    return ('{0}:{1}' -f $text, $Port)
}

# ---- Format-WtRestorePointDeleteLines (lines 23748-23792) ----
function Format-WtRestorePointDeleteLines {
    <#
    .SYNOPSIS
        PURE: what the gate shows before anything is deleted - every
        restore point newest first with the newest one marked KEPT, the
        per-drive shadow storage, and the raw vssadmin block underneath.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Points,
        [AllowEmptyCollection()][array]$Storage = @(),
        [AllowEmptyCollection()][string[]]$RawLines = @()
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'RestorePointsHeader') + ':')

    $isNewest = $true
    foreach ($point in @($Points)) {
        $stamp = ''
        if ($point.CreationTime) {
            $stamp = ([datetime]$point.CreationTime).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $mark = if ($isNewest) { '  [' + (Get-Translation 'RestorePointKept') + ']' } else { '' }
        $lines.Add(('  {0}  {1}{2}' -f $stamp, [string]$point.Description, $mark))
        $isNewest = $false
    }

    if (@($Storage).Count -gt 0) {
        $lines.Add('')
        $lines.Add((Get-Translation 'ShadowStorageHeader') + ':')
        foreach ($item in @($Storage)) {
            $lines.Add(('  {0}  {1}: {2}  {3}: {4}' -f [string]$item.DriveLetter,
                (Get-Translation 'ShadowStorageUsed'), (Format-WtByteSize -Bytes ([long]$item.UsedBytes)),
                (Get-Translation 'ShadowStorageAllocated'), (Format-WtByteSize -Bytes ([long]$item.AllocatedBytes))))
        }
    }

    if (@($RawLines).Count -gt 0) {
        $lines.Add('')
        $lines.Add('vssadmin list shadowstorage')
        foreach ($raw in @($RawLines)) { $lines.Add('  ' + $raw) }
    }

    return [string[]]$lines.ToArray()
}

# ---- Format-WtSecurityTimestamp (lines 32840-32855) ----
function Format-WtSecurityTimestamp {
    <#
    .SYNOPSIS
        PURE: a scan/update timestamp as 'yyyy-MM-dd HH:mm:ss', or the
        Never word. Defender hands back $null for a scan that never ran
        and 1601-01-01 (the FILETIME zero) on some platform versions -
        both mean "never", and neither may reach the panel raw.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return [string](Get-Translation 'SecStateNever') }
    $when = $null
    try { $when = [datetime]$Value }
    catch { return [string](Get-Translation 'SecStateUnknown') }
    if ($when.Year -le 1601) { return [string](Get-Translation 'SecStateNever') }
    return $when.ToString('yyyy-MM-dd HH:mm:ss')
}

# ---- Format-WtSecurityValueOrUnknown (lines 32828-32838) ----
function Format-WtSecurityValueOrUnknown {
    <#
    .SYNOPSIS
        PURE: a value as text, or the Unknown word when it is $null or
        blank. Keeps "Firmware type: " out of the panel.
    #>
    param([AllowNull()]$Value)
    $text = if ($null -eq $Value) { '' } else { ([string]$Value).Trim() }
    if ($text.Length -eq 0) { return [string](Get-Translation 'SecStateUnknown') }
    return $text
}

# ---- Format-WtSensorLines (lines 27940-27984) ----
function Format-WtSensorLines {
    <#
    .SYNOPSIS
        Renders the sensor snapshot as plain string lines; every $null
        field prints n/a so a partial snapshot never produces an empty
        line or an error.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Snapshot
    )

    $na = 'n/a'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('=== Sensors ===')
    $lines.Add("[$($Snapshot.Severity)] Sensors")

    $cpu = $Snapshot.Cpu
    $lines.Add("CPU: $(if ($cpu.Name) { $cpu.Name } else { $na })")
    $lines.Add("    Load: $(if ($null -ne $cpu.LoadPercent) { "$($cpu.LoadPercent) %" } else { $na })")
    $lines.Add("    Clock: $(if ($null -ne $cpu.ClockMHz) { "$($cpu.ClockMHz) MHz" } else { $na })")
    $lines.Add("    Cores: $(if ($null -ne $cpu.Cores) { "$($cpu.Cores) / $($cpu.LogicalProcessors) threads" } else { $na })")
    $lines.Add("    Temperature: $(if ($null -ne $cpu.TemperatureC) { "$($cpu.TemperatureC) C" } else { $na })")

    $memory = $Snapshot.Memory
    if ($null -ne $memory.TotalMB) {
        $lines.Add("Memory: $($memory.TotalMB) MB total, $($memory.UsedMB) MB used ($($memory.UsedPercent) %), $($memory.AvailableMB) MB available")
    }
    else {
        $lines.Add("Memory: $na")
    }

    $gpu = $Snapshot.Gpu
    $gpuHeading = if ($gpu.Name) { "$($gpu.Name) (driver $(if ($gpu.DriverVersion) { $gpu.DriverVersion } else { $na }))" } else { $na }
    $lines.Add("GPU: $gpuHeading")
    $lines.Add("    Utilization: $(if ($null -ne $gpu.UtilizationPercent) { "$($gpu.UtilizationPercent) %" } else { $na })")
    $lines.Add("    VRAM in use: $(if ($null -ne $gpu.DedicatedVramUsedMB) { "$($gpu.DedicatedVramUsedMB) MB" } else { $na })")
    $lines.Add("    Temperature: $(if ($null -ne $gpu.TemperatureC) { "$($gpu.TemperatureC) C" } else { $na })")

    foreach ($flag in @($Snapshot.Flags)) {
        $lines.Add("    [$($flag.Severity)] $($flag.Message)")
    }

    return $lines.ToArray()
}

# ---- Format-WtServiceStateLabel (lines 37813-37827) ----
function Format-WtServiceStateLabel {
    <#
    .SYNOPSIS
        PURE: "Status/StartType" for the Services screen with both words
        localized (SvcStatus.<Status> / SvcStart.<StartType>); an unknown
        word is shown as-is.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StartType
    )
    $st = Get-Translation ('SvcStatus.' + $Status); if (-not $st) { $st = $Status }
    $sm = Get-Translation ('SvcStart.' + $StartType); if (-not $sm) { $sm = $StartType }
    return '{0}/{1}' -f $st, $sm
}

# ---- Format-WtSoftwareCell (lines 33204-33229) ----
function Format-WtSoftwareCell {
    <#
    .SYNOPSIS
        PURE: one fixed-width table cell for the Software and startup
        rows. Truncates with '~' - the same mark the panel itself uses -
        and pads with spaces, so a caller can size its columns against
        Get-WtPanelInnerWidth instead of the hard-coded 100 that
        Out-String assumes. CR/LF/TAB are folded to a space first, since
        a Run value or task Execute path may legally contain them and a
        raw newline would break the table into two mis-aligned rows; the
        fold uses -creplace, never -replace, since a culture-aware
        compare matches differently under tr-TR.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )
    if ($Width -lt 1) { return '' }
    $value = if ($null -eq $Text) { '' } else { [string]$Text }
    $value = $value -creplace '[\r\n\t]+', ' '
    if ($value.Length -gt $Width) {
        if ($Width -eq 1) { return '~' }
        return ($value.Substring(0, $Width - 1) + '~')
    }
    return $value.PadRight($Width)
}

# ---- Format-WtUnixDate (lines 34283-34299) ----
function Format-WtUnixDate {
    <#
    .SYNOPSIS
        A registry Unix-seconds stamp as local wall-clock text, or the
        localized "date not recorded" line when missing or zero.
        InstallDate is a REG_DWORD ([int]) and must be widened before
        FromUnixTimeSeconds (which takes [long]) accepts it. Rendered with
        InvariantCulture so the '-' and ':' separators stay the same under
        tr-TR.
    #>
    param([AllowNull()]$UnixSeconds)
    $seconds = [long]0
    if ($null -ne $UnixSeconds -and [long]::TryParse([string]$UnixSeconds, [ref]$seconds) -and $seconds -gt 0) {
        return ([datetimeoffset]::FromUnixTimeSeconds($seconds)).LocalDateTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return (Get-Translation 'UpgradeHistoryDateUnknown')
}

# ---- Format-WtYesNoHint (lines 6880-6891) ----
function Format-WtYesNoHint {
    <#
    .SYNOPSIS
        The tail of a yes-no prompt, written the way the navigation guide
        writes everything else: "E: Evet - H: Hayir" in Turkish,
        "Y: Yes - N: No" in English. Prompt strings never carry this
        themselves, so no translation can drift away from the letters the
        code actually accepts.
    #>
    return '{0}: {1} - {2}: {3}' -f (Get-WtAnswerLetter -Kind 'Yes'), (Get-Translation 'AnswerYes'),
                                    (Get-WtAnswerLetter -Kind 'No'), (Get-Translation 'AnswerNo')
}

# ---- Get-Translation (lines 1480-1482) ----
function Get-Translation($Key) {
    return $script:Translations[$script:Language][$Key]
}

# ---- Get-WtAcceptedTypedWords (lines 6918-6935) ----
function Get-WtAcceptedTypedWords {
    <#
    .SYNOPSIS
        Every spelling a gate accepts: this gate's word in EVERY language
        the build ships, plus the English fallback. A user who switched
        the UI to English but still thinks in Turkish types ONAYLA and it
        works - refusing that only costs them their selection.
    #>
    param([Parameter(Mandatory)][ValidateSet('Yes', 'Confirm')][string]$Kind)
    $key = 'Typed' + $Kind + 'Word'
    $words = New-Object System.Collections.Generic.List[string]
    $words.Add($(if ($Kind -eq 'Yes') { 'YES' } else { 'CONFIRM' }))
    foreach ($lang in @($script:Translations.Keys)) {
        $word = [string]$script:Translations[$lang][$key]
        if ($word -and -not ($words -contains $word)) { $words.Add($word) }
    }
    return [string[]]$words.ToArray()
}

# ---- Get-WtActionToolGroups (lines 16962-17072) ----
function Get-WtActionToolGroups {
    <#
    .SYNOPSIS
        Basic Tools > Actions as seven ordered groups: a header
        translation key plus a delegate returning that group's rows;
        Get-WtToolScreenItems drops a group with nothing to show. sfc.exe
        runs Native, not Captured, since it emits UTF-16LE (OEM decoding
        corrupts it) and prints nothing for minutes at a time.
        CleanComponentStore never passes /ResetBase - that would
        permanently block uninstalling updates already on the machine.
    #>
    return @(
        @{ HeaderKey = 'ActionGroupQuickFixes'; GetRows = {
                @(
                    (New-WtToolRow -Name 'RestartExplorerAction' -Action {
                            $r = Invoke-WtRestartExplorer
                            if ($r.Restarted) { Write-Host (Get-Translation 'RestartExplorerDone') -ForegroundColor Green } else { Write-Host (Get-Translation 'RestartExplorerFailed') -ForegroundColor Red }
                        })
                    (New-WtToolRow -Name 'RepairStartMenu' -Kind 'Captured' -Risk 'CAUTION' -Action { $null = Invoke-WtStartMenuRepair })
                    (New-WtToolRow -Name 'RebuildExplorerCaches' -Kind 'Captured' -Risk 'CAUTION' -Action { $null = Invoke-WtRebuildExplorerCaches })
                    (New-WtToolRow -Name 'RestartAudioServices' -Kind 'Captured' -Risk 'SAFE' -Action { $null = Invoke-WtRestartAudioServices })
                    (New-WtToolRow -Name 'RestartPrinter' -Action { Restart-Service -Name Spooler; Write-Host (Get-Translation 'ActionCompleted') })
                    (New-WtToolRow -Name 'ClearPrintQueue' -Risk 'CAUTION' -Action {
                            Stop-Service -Name Spooler -Force
                            Remove-Item -Path "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
                            Start-Service -Name Spooler
                            Write-Host (Get-Translation 'PrintQueueCleared') -ForegroundColor Green
                        })
                    (New-WtToolRow -Name 'CloseNotRespondingApps' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtCloseNotRespondingAppsAction })
                    (New-WtToolRow -Name 'FreeMemory' -Kind 'Inline' -Action { Invoke-WtFreeMemoryAction })
                )
            }
        }
        @{ HeaderKey = 'ActionGroupWindowsRepair'; GetRows = {
                @(
                    (New-WtToolRow -Name 'RepairWindowsSystemFiles' -Kind 'Native' -FilePath 'sfc.exe' -Arguments '/scannow' -Encoding ([System.Text.Encoding]::Unicode))
                    (New-WtToolRow -Name 'RepairComponentStore' -Kind 'Native' -FilePath 'Dism.exe' -Arguments '/Online /Cleanup-Image /RestoreHealth')
                    (New-WtToolRow -Name 'ResetWindowsUpdateComponents' -Kind 'Captured' -Risk 'ADVANCED' -Action { Invoke-WtResetWindowsUpdateComponentsAction })
                    (New-WtToolRow -Name 'RebuildSearchIndex' -Kind 'Captured' -Risk 'CAUTION' -Action { Invoke-WtRebuildSearchIndexAction })
                    (New-WtToolRow -Name 'RepairWmiRepository' -Kind 'Captured' -Risk 'CAUTION' -Action { Invoke-WtRepairWmiRepositoryAction })
                    (New-WtToolRow -Name 'RestorePowerSchemeDefaults' -Kind 'Captured' -Risk 'CAUTION' -Action { Invoke-WtRestorePowerSchemeDefaultsAction })
                    (New-WtToolRow -Name 'UpdateGroupPolicies' -Action { gpupdate /force })
                )
            }
        }
        @{ HeaderKey = 'ActionGroupNetworkRepair'; GetRows = {
                @(
                    (New-WtToolRow -Name 'FlushDNSCache' -Action { ipconfig /flushdns })
                    (New-WtToolRow -Name 'RenewIpLease' -Action {
                            ipconfig /release
                            ipconfig /renew
                            Write-Host ''
                            foreach ($line in (Get-WtIpConfigSummaryLines)) { Write-Host $line }
                        })
                    (New-WtToolRow -Name 'PingTest' -Kind 'Inline' -Action { Invoke-WtPingTestAction })
                    (New-WtToolRow -Name 'RestartNetworkAdapters' -Kind 'Captured' -Risk 'CAUTION' -Action { Invoke-WtRestartNetworkAdaptersAction })
                    (New-WtToolRow -Name 'ForgetWifiProfile' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtForgetWifiProfileAction })
                    (New-WtToolRow -Name 'ResetWinsock' -Kind 'Captured' -Risk 'CAUTION' -Action { Invoke-WtResetWinsockAction })
                    (New-WtToolRow -Name 'ResetTcpIpStack' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtResetTcpIpStackAction })
                    (New-WtToolRow -Name 'ResetWinHttpProxy' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtResetWinHttpProxyAction })
                    (New-WtToolRow -Name 'ResetHostsFile' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtResetHostsFileAction })
                    (New-WtToolRow -Name 'ResetFirewallRules' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtResetFirewallRulesAction })
                )
            }
        }
        @{ HeaderKey = 'ActionGroupCleanupDisk'; GetRows = {
                @(
                    (New-WtToolRow -Name 'WindowsDiskCleanup' -Risk 'CAUTION' -Action { Invoke-WtDiskCleanupAction })
                    (New-WtToolRow -Name 'CleanUnnecessaryFiles' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtCleanupPreviewAction })
                    (New-WtToolRow -Name 'ClearBrowserCaches' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtClearBrowserCachesAction })
                    (New-WtToolRow -Name 'CleanComponentStore' -Kind 'Captured' -Risk 'CAUTION' -Action {
                        Write-Host (Get-Translation 'ComponentCleanupStarting') -ForegroundColor Cyan
                        Write-Host (Get-Translation 'ComponentCleanupResetBaseNote')
                        DISM /Online /Cleanup-Image /StartComponentCleanup
                    })
                    (New-WtToolRow -Name 'DuplicateFinder' -Kind 'Inline' -Action { Invoke-WtDuplicateFinderAction })
                    (New-WtToolRow -Name 'OptimizeVolumes' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtOptimizeVolumesAction })
                    (New-WtToolRow -Name 'ScheduleDiskRepair' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtScheduleDiskRepairAction })
                    (New-WtToolRow -Name 'DeleteOldRestorePoints' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtDeleteOldRestorePointsAction })
                )
            }
        }
        @{ HeaderKey = 'ActionGroupSoftware'; GetRows = {
                @(
                    (New-WtToolRow -Name 'UpdateWindowsStoreApps' -Action { Invoke-WtStoreUpdatesAction })
                    (New-WtToolRow -Name 'UpdateAllProgramsWithWinGet' -Action { Invoke-WtWingetUpgradeAction } -Encoding ([System.Text.Encoding]::UTF8))
                    (New-WtToolRow -Name 'WingetUpgradeSinglePackage' -Kind 'Inline' -Risk 'SAFE' -Action { Invoke-WtWingetUpgradeSinglePackageAction })
                    (New-WtToolRow -Name 'InstallVCRedist' -Kind 'Captured' -Risk 'SAFE' -Action { Invoke-WtVcRedistAction })
                    (New-WtToolRow -Name 'UninstallProgram' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtUninstallProgramAction })
                    (New-WtToolRow -Name 'ResetStoreCache' -Kind 'Captured' -Risk 'SAFE' -Action { foreach ($line in (Get-WtResetStoreCacheLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'ReRegisterStoreApp' -Kind 'Captured' -Risk 'CAUTION' -Action { foreach ($line in (Get-WtStoreRepairLines)) { Write-Host $line } })
                )
            }
        }
        @{ HeaderKey = 'ActionGroupBackupReports'; GetRows = { @(
            (New-WtToolRow -Name 'BackupRegistry' -Kind 'Captured' -Risk 'SAFE' -Action { Invoke-WtBackupRegistryAction })
            (New-WtToolRow -Name 'ExportDrivers' -Kind 'Captured' -Risk 'SAFE' -Action { Invoke-WtExportDriversAction })
            (New-WtToolRow -Name 'BatteryReport' -Kind 'Captured' -Risk 'SAFE' -Action { Invoke-WtBatteryReportAction })
            (New-WtToolRow -Name 'ExportWifiProfiles' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtExportWifiProfilesAction })
        ) } }
        @{ HeaderKey = 'ActionGroupPowerSession'; GetRows = { @(
            New-WtToolRow -Name 'ShutdownTimer' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtShutdownTimerAction }
            New-WtToolRow -Name 'RestartComputer' -Kind 'Power' -ConsequenceKey 'ConsequenceRestart' -Action { Restart-Computer -Force }
            New-WtToolRow -Name 'ShutdownComputer' -Kind 'Power' -ConsequenceKey 'ConsequenceShutdown' -Action { Stop-Computer -Force }
            New-WtToolRow -Name 'RestartToAdvancedStartup' -Kind 'Power' -ConsequenceKey 'ConsequenceRestartToAdvancedStartup' -Action { Invoke-WtRestartToAdvancedStartup }
            New-WtToolRow -Name 'RestartToFirmwareSettings' -Kind 'Power' -ConsequenceKey 'ConsequenceRestartToFirmwareSettings' -Action { Invoke-WtRestartToFirmwareSettings }
            New-WtToolRow -Name 'RestartInSafeMode' -Kind 'Power' -ConsequenceKey 'ConsequenceSafeMode' -Action { bcdedit /set '{default}' safeboot minimal; Restart-Computer -Force }
            New-WtToolRow -Name 'ExitSafeMode' -Kind 'Power' -ConsequenceKey 'ConsequenceExitSafeMode' -Action { bcdedit /deletevalue '{default}' safeboot }
        ) } }
    )
}

# ---- Get-WtActiveConnectionLines (lines 32425-32492) ----
function Get-WtActiveConnectionLines {
    <#
    .SYNOPSIS
        Which programs have an open connection right now, and where to.
        Summary first - connections per program and distinct remote hosts
        - then a capped detail table, since a raw per-connection dump
        runs to 150-300 rows and answers no question. The PID->name map
        uses an explicit loop, since Group-Object -AsHashTable's
        PSObject collections only index correctly by accident, and rows
        are grouped via .ToArray() rather than @($rows): under tr-TR, @()
        around a List[object] of PSCustomObjects throws "Argument types
        do not match". No reverse DNS is performed, to keep this screen
        local and instant.
    #>
    param(
        [scriptblock]$GetConnections = { Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue },
        [scriptblock]$GetProcesses = { Get-Process -ErrorAction SilentlyContinue | Select-Object Id, ProcessName },
        [int]$MaxDetailRows = 30
    )
    $connections = @()
    try { $connections = @(@(& $GetConnections) | Where-Object { $_ }) }
    catch { $connections = @() }
    if ($connections.Count -eq 0) { return [string[]]@((Get-Translation 'ActiveConnNone')) }

    $names = @{}
    try {
        foreach ($p in @(& $GetProcesses)) {
            if ($null -eq $p) { continue }
            $key = [string]$p.Id
            if (-not $names.ContainsKey($key)) { $names[$key] = [string]$p.ProcessName }
        }
    }
    catch { $names = @{} }

    $unknown = [string](Get-Translation 'ActiveConnUnknownProcess')
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($c in $connections) {
        $key = [string]$c.OwningProcess
        $owner = if ($names.ContainsKey($key) -and $names[$key]) { [string]$names[$key] } else { $unknown }
        $rows.Add([PSCustomObject]@{
            Owner      = $owner
            ProcessId  = $key
            RemoteHost = [string]$c.RemoteAddress
            Endpoint   = (Format-WtRemoteEndpoint -Address ([string]$c.RemoteAddress) -Port ([int]$c.RemotePort))
        })
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'ActiveConnSummaryHeader'))
    $groups = @($rows.ToArray() | Group-Object Owner | Sort-Object @{ Expression = { $_.Count }; Descending = $true }, Name)
    foreach ($g in $groups) {
        $distinct = @(@($g.Group | ForEach-Object { $_.RemoteHost }) | Sort-Object -Unique).Count
        $lines.Add(('  ' + ((Get-Translation 'ActiveConnSummaryLine') -f $g.Name, $g.Count, $distinct)))
    }

    $lines.Add('')
    $shown = @($rows.ToArray() | Select-Object -First $MaxDetailRows)
    $lines.Add(((Get-Translation 'ActiveConnDetailHeader') -f $shown.Count))
    foreach ($r in $shown) {
        $lines.Add(('  {0} ({1}) -> {2}' -f $r.Owner, $r.ProcessId, $r.Endpoint))
    }
    if ($rows.Count -gt $shown.Count) {
        $lines.Add(('  ' + ((Get-Translation 'ActiveConnDetailMore') -f ($rows.Count - $shown.Count))))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'ActiveConnNoReverseDns'))
    return [string[]]$lines.ToArray()
}

# ---- Get-WtAdsiGroupMemberNames (lines 32995-33024) ----
function Get-WtAdsiGroupMemberNames {
    <#
    .SYNOPSIS
        WinNT:// fallback for a local group whose membership
        Get-LocalGroupMember refuses to enumerate. The group is reached
        by translating its well-known SID to this machine's own account
        name, so the localized group name never has to be guessed. Path
        parsing uses -creplace, not -replace: the case-insensitive
        operator is culture-aware and folds the Turkish dotless I.
    #>
    param([Parameter(Mandatory)][string]$GroupSid)

    $sid = New-Object System.Security.Principal.SecurityIdentifier($GroupSid)
    $account = [string]$sid.Translate([System.Security.Principal.NTAccount]).Value
    $groupName = $account.Split([char]'\')[-1]
    $group = [ADSI]("WinNT://./$groupName,group")

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($member in @($group.Invoke('Members'))) {
        $path = [string]$member.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $member, $null)
        $class = [string]$member.GetType().InvokeMember('Class', 'GetProperty', $null, $member, $null)
        $trimmed = $path -creplace '^WinNT://', ''
        $result.Add([PSCustomObject]@{
                Name            = ($trimmed -creplace '/', '\')
                ObjectClass     = $class
                PrincipalSource = ''
            })
    }
    return $result.ToArray()
}

# ---- Get-WtAnswerLetter (lines 6852-6864) ----
function Get-WtAnswerLetter {
    <#
    .SYNOPSIS
        The single upper-case letter the active language expects for
        "yes" / "no" - Y/N in English, E/H (Evet/Hayir) in Turkish. Falls
        back to the English letters if a language ever ships without the
        keys, so a prompt can never end up with no accepted answer.
    #>
    param([Parameter(Mandatory)][ValidateSet('Yes', 'No')][string]$Kind)
    $letter = [string](Get-Translation ($Kind + 'Letter'))
    if (-not $letter) { $letter = if ($Kind -eq 'Yes') { 'Y' } else { 'N' } }
    return $letter.Substring(0, 1).ToUpperInvariant()
}

# ---- Get-WtAudioServiceNames (lines 26663-26672) ----
function Get-WtAudioServiceNames {
    <#
    .SYNOPSIS
        PURE: the two Windows audio services in DEPENDENCY order -
        AudioEndpointBuilder first, Audiosrv second, because Audiosrv
        depends on AudioEndpointBuilder. Starting walks this list as
        written; stopping walks it backwards.
    #>
    return [string[]]@('AudioEndpointBuilder', 'Audiosrv')
}

# ---- Get-WtBannerCreditLines (lines 6205-6212) ----
function Get-WtBannerCreditLines {
    <#
    .SYNOPSIS
        The two lines under the main-screen banner: author credit and the
        project's repository URL. Pure ASCII, language-independent.
    #>
    return @('Created by Burak Arslan', $script:WtRepoUrl)
}

# ---- Get-WtBannerLines (lines 6214-6236) ----
function Get-WtBannerLines {
    <#
    .SYNOPSIS
        The main-screen brand header. The full 9-line block-letter banner
        needs 87 columns plus margin; anything narrower gets the one-line
        brand so the layout never breaks.
    #>
    param([Parameter(Mandatory)][int]$Width)

    if ($Width -lt 89) { return ,@($script:WtBrand) }

    return @(
        '+=====================================================================================+'
        '|##      ## #### ##    ## ########  #######   #######  ##       #### ######## ##    ##|'
        '|##  ##  ##  ##  ###   ##    ##    ##     ## ##     ## ##        ##  ##        ##  ## |'
        '|##  ##  ##  ##  ####  ##    ##    ##     ## ##     ## ##        ##  ##         ####  |'
        '|##  ##  ##  ##  ## ## ##    ##    ##     ## ##     ## ##        ##  ######      ##   |'
        '|##  ##  ##  ##  ##  ####    ##    ##     ## ##     ## ##        ##  ##          ##   |'
        '|##  ##  ##  ##  ##   ###    ##    ##     ## ##     ## ##        ##  ##          ##   |'
        '| ###  ###  #### ##    ##    ##     #######   #######  ######## #### ##          ##   |'
        '+=====================================================================================+'
    )
}

# ---- Get-WtBatteryHealthLines (lines 31581-31639) ----
function Get-WtBatteryHealthLines {
    <#
    .SYNOPSIS
        Design capacity, full-charge capacity, wear percentage, cycle
        count and current charge - Windows ships no UI for any of it.
        Every source is wrapped, so a machine with no battery info says so
        rather than dying behind the capture pipeline. Design and full
        charge capacity come from the powercfg battery report alone,
        since Win32_Battery.DesignCapacity can come back null.
    #>
    param(
        [scriptblock]$GetBatteries = { Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop },
        [scriptblock]$GetBatteryReport = { Get-WtBatteryReportXml }
    )
    $batteries = @()
    try { $batteries = @(& $GetBatteries) } catch { $batteries = @() }
    if ($batteries.Count -eq 0) { return [string[]]@((Get-Translation 'BatteryNotFound')) }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($b in $batteries) {
        if ($null -ne $b.EstimatedChargeRemaining) { $lines.Add(((Get-Translation 'BatteryChargeLine') -f [int]$b.EstimatedChargeRemaining)) }
    }

    $xml = $null
    try { $xml = & $GetBatteryReport } catch { $xml = $null }
    $nodes = @()
    if ($xml) {
        try { $nodes = @($xml.SelectNodes("//*[local-name()='Battery']")) } catch { $nodes = @() }
    }
    if ($nodes.Count -eq 0) {
        $lines.Add((Get-Translation 'BatteryReportUnavailable'))
        return [string[]]$lines.ToArray()
    }

    foreach ($n in $nodes) {
        $id = Get-WtBatteryXmlValue -Node $n -LocalName 'Id'
        if (-not $id) { $id = '-' }
        $lines.Add(((Get-Translation 'BatteryNameLine') -f $id))

        $design = [long]0
        $null = [long]::TryParse((Get-WtBatteryXmlValue -Node $n -LocalName 'DesignCapacity'), [ref]$design)
        $full = [long]0
        $null = [long]::TryParse((Get-WtBatteryXmlValue -Node $n -LocalName 'FullChargeCapacity'), [ref]$full)
        $cycles = [long]0
        $null = [long]::TryParse((Get-WtBatteryXmlValue -Node $n -LocalName 'CycleCount'), [ref]$cycles)

        if ($design -gt 0) { $lines.Add(((Get-Translation 'BatteryDesignLine') -f $design)) }
        if ($full -gt 0) { $lines.Add(((Get-Translation 'BatteryFullChargeLine') -f $full)) }
        if ($design -gt 0 -and $full -gt 0) {
            $wear = [math]::Round((1 - ([double]$full / [double]$design)) * 100, 1)
            if ($wear -lt 0) { $wear = 0 }
            $lines.Add(((Get-Translation 'BatteryWearLine') -f ([double]$wear).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)))
        }
        else { $lines.Add((Get-Translation 'BatteryWearUnknown')) }
        if ($cycles -gt 0) { $lines.Add(((Get-Translation 'BatteryCycleLine') -f $cycles)) }
        else { $lines.Add((Get-Translation 'BatteryCycleUnknown')) }
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtBatteryReportXml (lines 31558-31579) ----
function Get-WtBatteryReportXml {
    <#
    .SYNOPSIS
        Runs powercfg's battery report into %TEMP% as XML, loads it and
        deletes the file again. Returns $null when powercfg produced
        nothing readable. Uses [System.IO.File] rather than Remove-Item /
        New-Item, since the Information screen's files are scanned for
        write verbs.
    #>
    $path = [System.IO.Path]::Combine($env:TEMP, ('wt-batteryreport-{0}.xml' -f [guid]::NewGuid().ToString('N')))
    try {
        $null = & powercfg.exe /batteryreport /XML /OUTPUT $path 2>&1
        if (-not [System.IO.File]::Exists($path)) { return $null }
        $doc = [System.Xml.XmlDocument]::new()
        $doc.Load($path)
        return $doc
    }
    catch { return $null }
    finally {
        try { if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) } } catch { $null = $_ }
    }
}

# ---- Get-WtBatteryXmlValue (lines 31541-31556) ----
function Get-WtBatteryXmlValue {
    <#
    .SYNOPSIS
        The text of one direct child element of a battery-report node,
        found by local name, since the report carries a default namespace
        that a plain name lookup would miss.
    #>
    param(
        [Parameter(Mandatory)][System.Xml.XmlNode]$Node,
        [Parameter(Mandatory)][string]$LocalName
    )
    foreach ($child in $Node.ChildNodes) {
        if ([string]::Equals([string]$child.LocalName, $LocalName, [System.StringComparison]::Ordinal)) { return [string]$child.InnerText }
    }
    return ''
}

# ---- Get-WtBigFileList (lines 33869-33907) ----
function Get-WtBigFileList {
    <#
    .SYNOPSIS
        Every file at or over MinSizeBytes under one subtree, collected
        into a list with an own stack rather than
        "Get-ChildItem -Recurse | Sort-Object" (that pipeline emits
        nothing until the whole walk finishes). A ReparsePoint is skipped
        at every level and an unreadable directory is counted, not thrown.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MinSizeBytes = 104857600,
        [scriptblock]$GetEntries = {
            param($Current)
            $dir = [System.IO.DirectoryInfo]$Current
            return @{ Files = @($dir.GetFiles()); Directories = @($dir.GetDirectories()) }
        }
    )
    $found = [System.Collections.Generic.List[object]]::new()
    $skipped = 0
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $entries = $null
        try { $entries = & $GetEntries $current }
        catch { $skipped++; continue }
        foreach ($f in @($entries.Files)) {
            if ([long]$f.Length -lt $MinSizeBytes) { continue }
            $found.Add([PSCustomObject]@{ Path = [string]$f.FullName; Length = [long]$f.Length })
        }
        foreach ($d in @($entries.Directories)) {
            if (([System.IO.FileAttributes]$d.Attributes -band $reparse) -eq $reparse) { continue }
            $stack.Push([string]$d.FullName)
        }
    }
    return [PSCustomObject]@{ Files = @($found.ToArray()); Skipped = $skipped }
}

# ---- Get-WtBlueScreenHistoryLines (lines 31177-31262) ----
function Get-WtBlueScreenHistoryLines {
    <#
    .SYNOPSIS
        Every stop error, hard power loss, and unexpected shutdown with its
        date, plus the crash dumps still sitting on disk. Three providers,
        not two: WER-SystemErrorReporting 1001 carries the bugcheck,
        Kernel-Power 41 catches a hard hang/power cut with no bugcheck, and
        6008 ("previous shutdown was unexpected") is read here rather than
        by ShutdownHistory, since on a machine with minidumps disabled it
        is often the only trace a crash happened; 6008 gets its own label,
        not the 1001 wording, since it proves only that the shutdown was
        unexpected. Get-WinEvent raises a TERMINATING error when nothing
        matches, so all four sources are wrapped and an empty result
        prints an explicit "none" line.
    #>
    param(
        [scriptblock]$GetBugchecks = {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } -MaxEvents 20 -ErrorAction SilentlyContinue
        },
        [scriptblock]$GetPowerLoss = {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 } -MaxEvents 20 -ErrorAction SilentlyContinue
        },
        [scriptblock]$GetUnexpectedShutdowns = {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6008 } -MaxEvents 20 -ErrorAction SilentlyContinue
        },
        [scriptblock]$GetDumps = {
            Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Minidump') -Filter '*.dmp' -File -ErrorAction SilentlyContinue
        },
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )
    $rows = New-Object System.Collections.Generic.List[object]

    $bugchecks = @()
    try { $bugchecks = @(& $GetBugchecks) } catch { $bugchecks = @() }
    foreach ($e in @($bugchecks | Where-Object { $_ })) {
        $rows.Add([PSCustomObject]@{ When = $e.TimeCreated; Tag = [string](Get-Translation 'BlueScreenTagBugCheck'); Message = [string]$e.Message })
    }

    $powerLoss = @()
    try { $powerLoss = @(& $GetPowerLoss) } catch { $powerLoss = @() }
    foreach ($e in @($powerLoss | Where-Object { $_ })) {
        $rows.Add([PSCustomObject]@{ When = $e.TimeCreated; Tag = [string](Get-Translation 'BlueScreenTagPowerLoss'); Message = [string]$e.Message })
    }

    $unexpected = @()
    try { $unexpected = @(& $GetUnexpectedShutdowns) } catch { $unexpected = @() }
    foreach ($e in @($unexpected | Where-Object { $_ })) {
        $rows.Add([PSCustomObject]@{ When = $e.TimeCreated; Tag = [string](Get-Translation 'BlueScreenTagUnexpectedShutdown'); Message = [string]$e.Message })
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string](Get-Translation 'BlueScreenHistoryHeading'))
    if ($rows.Count -eq 0) {
        $lines.Add('  ' + [string](Get-Translation 'BlueScreenNoneFound'))
    }
    else {
        foreach ($r in @($rows | Sort-Object -Property When -Descending)) {
            $when = ''
            if ($r.When) { $when = ([datetime]$r.When).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
            $parts = @(([string]$r.Message) -csplit "`r`n|`r|`n" | Where-Object { $_.Trim() })
            $msg = if ($parts.Count -gt 0) { $parts[0].Trim() } else { [string](Get-Translation 'EventNoMessage') }
            $msgRoom = [Math]::Max(12, $Width - 16 - 2 - $r.Tag.Length - 2)
            if ($msg.Length -gt $msgRoom) { $msg = $msg.Substring(0, $msgRoom - 1) + '~' }
            $lines.Add((('{0,-16}  {1}  {2}' -f $when, $r.Tag, $msg)).TrimEnd())
        }
    }

    $lines.Add('')
    $lines.Add([string](Get-Translation 'CrashDumpsHeading'))
    $dumps = @()
    try { $dumps = @((& $GetDumps) | Where-Object { $_ }) } catch { $dumps = @() }
    if ($dumps.Count -eq 0) {
        $lines.Add('  ' + [string](Get-Translation 'CrashDumpsNone'))
    }
    else {
        $total = [long]0
        foreach ($d in $dumps) { $total += [long]$d.Length }
        $lines.Add('  ' + ((Get-Translation 'CrashDumpsSummary') -f $dumps.Count, (Format-WtByteSize -Bytes $total)))
        foreach ($d in @($dumps | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 5)) {
            $stamp = ''
            if ($d.LastWriteTime) { $stamp = ([datetime]$d.LastWriteTime).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
            $lines.Add(('  {0,-16}  {1}' -f $stamp, [string]$d.Name))
        }
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtBreadcrumb (lines 37124-37137) ----
function Get-WtBreadcrumb {
    <#
    .SYNOPSIS
        "Main Menu > Category > Screen" from translation keys, with an
        optional literal suffix (e.g. a capability's display label).
    #>
    param(
        [Parameter(Mandatory)][string[]]$Keys,
        [string]$Suffix = ''
    )
    $parts = @($Keys | ForEach-Object { [string](Get-Translation $_) })
    if ($Suffix) { $parts += $Suffix }
    return ($parts -join ' > ')
}

# ---- Get-WtBrowserCacheCatalog (lines 23067-23109) ----
function Get-WtBrowserCacheCatalog {
    <#
    .SYNOPSIS
        The three browsers whose on-disk caches this row clears, in the
        Show-WtSelector catalog shape. Only cache folders are ever named
        here - logins, cookies, history and bookmarks must never appear in
        CacheSubPaths.
    #>
    param(
        [hashtable]$Environment = @{ LOCALAPPDATA = $env:LOCALAPPDATA }
    )

    $localAppData = "$($Environment.LOCALAPPDATA)"
    return @(
        [PSCustomObject]@{
            Name          = 'Edge'
            DisplayLabel  = 'Microsoft Edge'
            Risk          = 'CAUTION'
            Consequence   = $null
            ProcessNames  = @('msedge')
            ProfileRoot   = [System.IO.Path]::Combine($localAppData, 'Microsoft', 'Edge', 'User Data')
            CacheSubPaths = @('Cache\Cache_Data', 'Code Cache', 'GPUCache')
        }
        [PSCustomObject]@{
            Name          = 'Chrome'
            DisplayLabel  = 'Google Chrome'
            Risk          = 'CAUTION'
            Consequence   = $null
            ProcessNames  = @('chrome')
            ProfileRoot   = [System.IO.Path]::Combine($localAppData, 'Google', 'Chrome', 'User Data')
            CacheSubPaths = @('Cache\Cache_Data', 'Code Cache', 'GPUCache')
        }
        [PSCustomObject]@{
            Name          = 'Firefox'
            DisplayLabel  = 'Mozilla Firefox'
            Risk          = 'CAUTION'
            Consequence   = $null
            ProcessNames  = @('firefox')
            ProfileRoot   = [System.IO.Path]::Combine($localAppData, 'Mozilla', 'Firefox', 'Profiles')
            CacheSubPaths = @('cache2')
        }
    )
}

# ---- Get-WtBrowserCacheTargets (lines 23111-23185) ----
function Get-WtBrowserCacheTargets {
    <#
    .SYNOPSIS
        PURE over injected lookups: turns the browser catalog into one
        entry per browser carrying every cache folder that actually holds
        bytes, the measured total, and whether that browser is running
        right now.
    #>
    param(
        [Parameter(Mandatory)][array]$Catalog,

        [scriptblock]$GetProfileNames = {
            param($Entry)
            if (-not (Test-Path -LiteralPath $Entry.ProfileRoot -PathType Container)) { return @() }
            @(Get-ChildItem -LiteralPath $Entry.ProfileRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 } |
                ForEach-Object { $_.Name })
        },

        [scriptblock]$MeasureAction = {
            param($Path)
            $inventory = Get-WtFileInventory -Root $Path -Recurse $true -ReportProgressAction { param($Scanned, $Found) }
            $bytes = 0L
            foreach ($file in @($inventory.Files)) { $bytes += [long]$file.Length }
            [PSCustomObject]@{ Bytes = $bytes; Count = @($inventory.Files).Count }
        },

        [scriptblock]$GetRunningNames = { @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName }) }
    )

    $running = @(& $GetRunningNames)
    $targets = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $Catalog) {
        $isRunning = $false
        foreach ($processName in @($entry.ProcessNames)) {
            foreach ($live in $running) {
                if ([string]::Equals([string]$live, [string]$processName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isRunning = $true
                }
            }
        }

        $paths = New-Object System.Collections.Generic.List[object]
        $bytes = 0L
        $count = 0
        foreach ($profileName in @(& $GetProfileNames $entry)) {
            foreach ($sub in @($entry.CacheSubPaths)) {
                $path = [System.IO.Path]::Combine($entry.ProfileRoot, $profileName, $sub)
                $measured = & $MeasureAction $path
                if (([long]$measured.Bytes -le 0) -and ([int]$measured.Count -le 0)) { continue }
                $bytes += [long]$measured.Bytes
                $count += [int]$measured.Count
                $paths.Add([PSCustomObject]@{
                    ProfileName = [string]$profileName
                    Path        = $path
                    Bytes       = [long]$measured.Bytes
                    Count       = [int]$measured.Count
                })
            }
        }

        $targets.Add([PSCustomObject]@{
            Name         = $entry.Name
            DisplayLabel = $entry.DisplayLabel
            ProcessNames = @($entry.ProcessNames)
            Running      = $isRunning
            Paths        = $paths.ToArray()
            Bytes        = $bytes
            Count        = $count
        })
    }

    return $targets.ToArray()
}

# ---- Get-WtCleanupCatalog (lines 23878-23989) ----
function Get-WtCleanupCatalog {
    <#
    .SYNOPSIS
        The eight cleanup categories: five SAFE entries, then three
        CAUTION ones. Each carries path specs (@{ Path; Recurse; Patterns
        }) and the services to stop around the delete. Every path is
        built from -Environment so the catalog is testable without real
        Windows environment variables. Paths use [System.IO.Path]::Combine
        instead of Join-Path, since Join-Path fails when the drive letter
        does not exist (the dev host, a detached drive).
    #>
    param(
        [hashtable]$Environment = @{
            LOCALAPPDATA = $env:LOCALAPPDATA
            WinDir       = $env:WinDir
            SystemDrive  = $env:SystemDrive
            ProgramData  = $env:ProgramData
        },

        [AllowEmptyCollection()]
        [string[]]$FixedDriveRoots = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object { $_.RootDirectory.FullName })
    )

    $localAppData = "$($Environment.LOCALAPPDATA)"
    $winDir = "$($Environment.WinDir)"
    $systemDrive = "$($Environment.SystemDrive)"
    $programData = "$($Environment.ProgramData)"

    $systemDriveRoot = if ($systemDrive -match '^[A-Za-z]:$') { "$systemDrive\" } else { $systemDrive }

    $werPaths = @(
        ([System.IO.Path]::Combine($programData, 'Microsoft', 'Windows', 'WER')),
        ([System.IO.Path]::Combine($localAppData, 'Microsoft', 'Windows', 'WER'))
    )

    $recycleSpecs = @(foreach ($root in @($FixedDriveRoots)) {
        [PSCustomObject]@{ Path = ([System.IO.Path]::Combine($root, '$Recycle.Bin')); Recurse = $true; Patterns = $null }
    })

    return Resolve-WtCatalogText -KeyPrefix 'Cleanup' -Catalog @(
        [PSCustomObject]@{
            Name           = 'UserTemp'
            DisplayLabel   = 'User temporary files'
            Risk           = 'SAFE'
            Consequence    = $null
            PathSpecs      = @([PSCustomObject]@{ Path = ([System.IO.Path]::Combine($localAppData, 'Temp')); Recurse = $true; Patterns = $null })
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'WindowsTemp'
            DisplayLabel   = 'Windows temporary files'
            Risk           = 'SAFE'
            Consequence    = $null
            PathSpecs      = @([PSCustomObject]@{ Path = ([System.IO.Path]::Combine($winDir, 'Temp')); Recurse = $true; Patterns = $null })
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'SystemDriveLeftovers'
            DisplayLabel   = 'System-drive root leftovers (*.tmp, *.bak, *.old, *.log, *.chk, *.gid, *._mp)'
            Risk           = 'SAFE'
            Consequence    = $null
            PathSpecs      = @([PSCustomObject]@{ Path = $systemDriveRoot; Recurse = $false; Patterns = @('*.tmp', '*.bak', '*.old', '*.log', '*.chk', '*.gid', '*._mp') })
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'CrashDumps'
            DisplayLabel   = 'Crash dumps (MEMORY.DMP, Minidump)'
            Risk           = 'SAFE'
            Consequence    = 'Only needed to debug a past crash'
            PathSpecs      = @(
                [PSCustomObject]@{ Path = $winDir; Recurse = $false; Patterns = @('MEMORY.DMP') }
                [PSCustomObject]@{ Path = ([System.IO.Path]::Combine($winDir, 'Minidump')); Recurse = $false; Patterns = @('*.dmp') }
            )
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'ErrorReports'
            DisplayLabel   = 'Windows Error Reporting queues'
            Risk           = 'SAFE'
            Consequence    = $null
            PathSpecs      = @(foreach ($wer in $werPaths) {
                [PSCustomObject]@{ Path = ([System.IO.Path]::Combine($wer, 'ReportQueue')); Recurse = $true; Patterns = $null }
                [PSCustomObject]@{ Path = ([System.IO.Path]::Combine($wer, 'ReportArchive')); Recurse = $true; Patterns = $null }
            })
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'WindowsUpdateCache'
            DisplayLabel   = 'Windows Update download cache'
            Risk           = 'CAUTION'
            Consequence    = 'Windows Update stops briefly; pending update downloads start over'
            PathSpecs      = @([PSCustomObject]@{ Path = ([System.IO.Path]::Combine($winDir, 'SoftwareDistribution', 'Download')); Recurse = $true; Patterns = $null })
            ServicesToStop = @('wuauserv', 'bits')
        }
        [PSCustomObject]@{
            Name           = 'Prefetch'
            DisplayLabel   = 'Prefetch (*.pf)'
            Risk           = 'CAUTION'
            Consequence    = 'Windows rebuilds it; first launches are slower for a few days'
            PathSpecs      = @([PSCustomObject]@{ Path = ([System.IO.Path]::Combine($winDir, 'Prefetch')); Recurse = $false; Patterns = @('*.pf') })
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'RecycleBin'
            DisplayLabel   = 'Recycle Bin (all users, all fixed drives)'
            Risk           = 'CAUTION'
            Consequence    = 'Permanently deletes recycled files for every user on every fixed drive'
            PathSpecs      = $recycleSpecs
            ServicesToStop = @()
        }
    )
}

# ---- Get-WtCleanupPreview (lines 23991-24048) ----
function Get-WtCleanupPreview {
    <#
    .SYNOPSIS
        Walks every category's path specs up front and reports the exact
        files, byte total, and count per category - the list the delete
        engine acts on verbatim. Catalog metadata (label, risk,
        consequence, services) is copied onto each preview object so
        neither the engine nor the menu needs a second catalog lookup.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Catalog,

        [scriptblock]$InventoryAction = {
            param($Spec)
            if ($Spec.Patterns) {
                Get-WtFileInventory -Root $Spec.Path -Recurse $Spec.Recurse -Patterns $Spec.Patterns
            }
            else {
                Get-WtFileInventory -Root $Spec.Path -Recurse $Spec.Recurse
            }
        }
    )

    $preview = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $Catalog) {
        $files = New-Object System.Collections.Generic.List[object]
        $directories = New-Object System.Collections.Generic.List[string]
        $skipped = 0

        foreach ($spec in @($entry.PathSpecs)) {
            $inventory = & $InventoryAction $spec
            foreach ($file in @($inventory.Files)) { $files.Add($file) }
            if ($spec.Recurse) {
                foreach ($directory in @($inventory.Directories)) { $directories.Add($directory) }
            }
            $skipped += [int]$inventory.SkippedDirectories
        }

        $bytes = 0L
        foreach ($file in $files) { $bytes += [long]$file.Length }

        $preview.Add([PSCustomObject]@{
            Name               = $entry.Name
            DisplayLabel       = $entry.DisplayLabel
            Risk               = $entry.Risk
            Consequence        = $entry.Consequence
            ServicesToStop     = @($entry.ServicesToStop)
            Files              = $files.ToArray()
            Directories        = $directories.ToArray()
            Bytes              = $bytes
            Count              = $files.Count
            SkippedDirectories = $skipped
        })
    }

    return $preview.ToArray()
}

# ---- Get-WtComponentStoreAnalysisLines (lines 34038-34061) ----
function Get-WtComponentStoreAnalysisLines {
    <#
    .SYNOPSIS
        The preamble the component-store row prints before DISM starts:
        Invoke-WtCapturedAction only repaints on output and DISM stays
        silent for its first seconds, so without these lines the panel
        looks frozen. DISM's own answer is streamed verbatim by the row
        and never parsed here: DISM is localized, so grepping its
        "Cleanup Recommended" line would silently report the wrong
        verdict on a Turkish Windows.
    #>
    param(
        [bool]$DismAvailable = (Test-WtDismAvailable),
        [string]$DismPath = (Join-Path $env:SystemRoot 'System32\Dism.exe')
    )
    if (-not $DismAvailable) {
        return [string[]]@(((Get-Translation 'ComponentStoreDismMissing') -f $DismPath))
    }
    return [string[]]@(
        (Get-Translation 'ComponentStoreRunning')
        (Get-Translation 'ComponentStoreReadOnlyNote')
        ''
    )
}

# ---- Get-WtConsoleSize (lines 6020-6034) ----
function Get-WtConsoleSize {
    <#
    .SYNOPSIS
        Current window size as @{ Width; Height }, 100x40 when no console
        exists (redirected host, tests).
    #>
    $w = 100
    $h = 40
    try {
        $s = $Host.UI.RawUI.WindowSize
        if ($s.Width -gt 0 -and $s.Height -gt 0) { $w = [int]$s.Width; $h = [int]$s.Height }
    }
    catch { $null = $_ }
    return @{ Width = $w; Height = $h }
}

# ---- Get-WtConsoleUserSid (lines 18302-18353) ----
function Get-WtConsoleUserSid {
    <#
    .SYNOPSIS
        Resolves the SID of the interactively logged-on console user,
        never $env:USERNAME (which under Start-Process -Verb RunAs can be
        a different administrator's identity than the person actually
        using the machine). Returns $null, never a throw and never a
        fallback to $env:USERNAME, if the console-user lookup is empty,
        the translate step throws, or the resolved SID fails to validate
        against a real ConsentStore hive. The translate step is
        injectable because even the NTAccount constructor - not just
        .Translate() - throws on macOS.
    #>
    param(
        [scriptblock]$GetConsoleUserAction = {
            (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        },

        [scriptblock]$TranslateSidAction = {
            param($account)
            (New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        },

        [scriptblock]$ValidateSidAction = {
            param($sid)
            Test-Path -LiteralPath "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore"
        }
    )

    $consoleUser = & $GetConsoleUserAction
    if ([string]::IsNullOrWhiteSpace($consoleUser)) {
        return $null
    }

    $sid = $null
    try {
        $sid = & $TranslateSidAction $consoleUser
    }
    catch {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($sid)) {
        return $null
    }

    if (-not (& $ValidateSidAction $sid)) {
        return $null
    }

    return $sid
}

# ---- Get-WtDataPath (lines 1134-1169) ----
function Get-WtDataPath {
    <#
    .SYNOPSIS
        Resolves WinToolify's local data root and creates it (and any
        -SubPath beneath it) on demand. -Scope is mandatory, not defaulted:
        an elevated Start-Process -Verb RunAs runs under the admin profile,
        so a wrong scope would hide machine state from the original user.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope,

        [string]$SubPath,

        [string]$TestRootOverride
    )

    if ($TestRootOverride) {
        $root = Join-Path $TestRootOverride $Scope
    }
    elseif ($Scope -eq 'Machine') {
        $root = Join-Path $env:ProgramData 'WinToolify'
    }
    else {
        $root = Join-Path $env:LOCALAPPDATA 'WinToolify'
    }

    $target = if ($SubPath) { Join-Path $root $SubPath } else { $root }

    if (-not (Test-Path -LiteralPath $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }

    return $target
}

# ---- Get-WtDefaultHostsContent (lines 25294-25325) ----
function Get-WtDefaultHostsContent {
    <#
    .SYNOPSIS
        PURE: the Hosts file Windows ships, verbatim, with CRLF endings
        and a trailing newline. Not a translation key on purpose - this
        is file content Windows itself writes in English, not UI text.
    #>
    $lines = @(
        '# Copyright (c) 1993-2009 Microsoft Corp.'
        '#'
        '# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.'
        '#'
        '# This file contains the mappings of IP addresses to host names. Each'
        '# entry should be kept on an individual line. The IP address should'
        '# be placed in the first column followed by the corresponding host name.'
        '# The IP address and the host name should be separated by at least one'
        '# space.'
        '#'
        '# Additionally, comments (such as these) may be inserted on individual'
        '# lines or following the machine name denoted by a ''#'' symbol.'
        '#'
        '# For example:'
        '#'
        '#      102.54.94.97     rhino.acme.com          # source server'
        '#       38.25.63.10     x.acme.com              # x client host'
        ''
        '# localhost name resolution is handled within DNS itself.'
        "#`t127.0.0.1       localhost"
        "#`t::1             localhost"
    )
    return (($lines -join "`r`n") + "`r`n")
}

# ---- Get-WtDefenderStatusLines (lines 32877-32911) ----
function Get-WtDefenderStatusLines {
    <#
    .SYNOPSIS
        PURE: Windows Defender's real-time protection, engine mode,
        signature age and last scans, as printable lines.
        Get-MpComputerStatus is called without a Get-Command guard on
        purpose: the module always resolves, but the CALL throws when
        WinDefend is stopped or another antivirus has taken over -
        exactly the machine this row exists for - and a Get-Command
        guard would report "available" and then blow up in the panel.
    #>
    param(
        [scriptblock]$GetStatus = { Get-MpComputerStatus -ErrorAction Stop },
        [datetime]$Now = (Get-Date)
    )

    $status = $null
    try { $status = & $GetStatus }
    catch { $status = $null }
    if ($null -eq $status) { return [string[]]@([string](Get-Translation 'DefenderStatusUnavailable')) }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderRealTimeProtection'), (Format-WtOnOffWord -Value $status.RealTimeProtectionEnabled)))
    if ($status.PSObject.Properties['AMRunningMode']) {
        $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderRunningMode'), (Format-WtSecurityValueOrUnknown -Value $status.AMRunningMode)))
    }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderAntivirusEnabled'), (Format-WtOnOffWord -Value $status.AntivirusEnabled)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderBehaviorMonitor'), (Format-WtOnOffWord -Value $status.BehaviorMonitorEnabled)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderTamperProtection'), (Format-WtOnOffWord -Value $status.IsTamperProtected)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderSignatureVersion'), (Format-WtSecurityValueOrUnknown -Value $status.AntivirusSignatureVersion)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderSignatureAge'), (Format-WtDefenderSignatureAge -LastUpdated $status.AntispywareSignatureLastUpdated -Now $Now)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderLastQuickScan'), (Format-WtSecurityTimestamp -Value $status.QuickScanEndTime)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderLastFullScan'), (Format-WtSecurityTimestamp -Value $status.FullScanEndTime)))
    return [string[]]$lines.ToArray()
}

# ---- Get-WtDiskAlarmTemperature (lines 27477-27492) ----
function Get-WtDiskAlarmTemperature {
    <#
    .SYNOPSIS
        Temperature at or above which a drive is flagged: 50 C for HDD,
        60 C for everything else - CrystalDiskInfo's defaults.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$MediaType
    )

    if ($MediaType -eq 'HDD') { return 50 }
    return 60
}

# ---- Get-WtDiskErrorEventsLines (lines 31264-31308) ----
function Get-WtDiskErrorEventsLines {
    <#
    .SYNOPSIS
        Controller and file system faults logged on behalf of the drives -
        the warning that arrives long before SMART turns. Level lives
        inside the FilterHashtable, never a later Where-Object, since
        -MaxEvents 40 is spent before any later filter runs - filtering
        afterwards would fetch 40 volmgr/Ntfs information rows and throw
        the real faults away. A provider that does not exist on this
        machine (stornvme on a SATA-only box) is not fatal; Get-WinEvent's
        TERMINATING "no match" error is caught and reported as "none".
    #>
    param(
        [scriptblock]$GetEvents = {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'volmgr', 'storahci', 'stornvme'; Level = 1, 2, 3 } -MaxEvents 40 -ErrorAction SilentlyContinue
        },
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )
    $events = @()
    try { $events = @(& $GetEvents) } catch { $events = @() }
    $events = @($events | Where-Object { $_ })

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string](Get-Translation 'DiskErrorEventsHeading'))
    if ($events.Count -eq 0) {
        $lines.Add('  ' + [string](Get-Translation 'DiskErrorEventsNone'))
        return [string[]]$lines.ToArray()
    }

    $msgRoom = [Math]::Max(12, $Width - 57)
    foreach ($e in @($events | Sort-Object -Property TimeCreated -Descending)) {
        $when = ''
        if ($e.TimeCreated) {
            $when = ([datetime]$e.TimeCreated).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $level = Get-WtEventLevelTag -Level $e.Level
        $provider = [string]$e.ProviderName
        if ($provider.Length -gt 22) { $provider = $provider.Substring(0, 21) + '~' }
        $parts = @(([string]$e.Message) -csplit "`r`n|`r|`n" | Where-Object { $_.Trim() })
        $msg = if ($parts.Count -gt 0) { $parts[0].Trim() } else { [string](Get-Translation 'EventNoMessage') }
        if ($msg.Length -gt $msgRoom) { $msg = $msg.Substring(0, $msgRoom - 1) + '~' }
        $lines.Add((('{0,-16}  {1,-5}  {2,6}  {3,-22}  {4}' -f $when, $level, ([string]$e.Id), $provider, $msg)).TrimEnd())
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtDiskHealthFlags (lines 27494-27538) ----
function Get-WtDiskHealthFlags {
    <#
    .SYNOPSIS
        Pure flag evaluator for one disk report entry: Unhealthy ->
        CRITICAL; Warning status, wear >= 90 %, uncorrected errors, or
        temperature at/above the media alarm -> WARNING. Unreported
        ($null) temperature/wear never flag.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Disk
    )

    $flags = New-Object System.Collections.Generic.List[object]

    if ($Disk.HealthStatus -eq 'Unhealthy') {
        $flags.Add([PSCustomObject]@{ Severity = 'CRITICAL'; Message = 'Windows reports this drive unhealthy' })
    }
    elseif ($Disk.HealthStatus -eq 'Warning') {
        $flags.Add([PSCustomObject]@{ Severity = 'WARNING'; Message = 'Windows reports a health warning for this drive' })
    }

    if ($null -ne $Disk.WearPercent -and [int]$Disk.WearPercent -ge 90) {
        $flags.Add([PSCustomObject]@{ Severity = 'WARNING'; Message = ">= 90 % of rated life used ($($Disk.WearPercent) %)" })
    }

    $readErrors = if ($null -ne $Disk.ReadErrorsUncorrected) { [long]$Disk.ReadErrorsUncorrected } else { 0 }
    $writeErrors = if ($null -ne $Disk.WriteErrorsUncorrected) { [long]$Disk.WriteErrorsUncorrected } else { 0 }
    if ($readErrors -gt 0 -or $writeErrors -gt 0) {
        $flags.Add([PSCustomObject]@{ Severity = 'WARNING'; Message = "Uncorrected read/write errors (R $readErrors / W $writeErrors)" })
    }

    if ($null -ne $Disk.TemperatureC) {
        $alarm = Get-WtDiskAlarmTemperature -MediaType $Disk.MediaType
        if ([int]$Disk.TemperatureC -ge $alarm) {
            $flags.Add([PSCustomObject]@{ Severity = 'WARNING'; Message = "Temperature at or above $alarm C ($($Disk.TemperatureC) C)" })
        }
    }

    $severity = 'OK'
    if (@($flags | Where-Object Severity -eq 'CRITICAL').Count -gt 0) { $severity = 'CRITICAL' }
    elseif ($flags.Count -gt 0) { $severity = 'WARNING' }

    return [PSCustomObject]@{ Flags = $flags.ToArray(); Severity = $severity }
}

# ---- Get-WtDiskHealthReport (lines 27540-27619) ----
function Get-WtDiskHealthReport {
    <#
    .SYNOPSIS
        One entry per physical disk: Get-PhysicalDisk joined with its
        Get-StorageReliabilityCounter row by DeviceId, plus flags. A
        counter row that is missing (USB sticks, some controllers) or a
        counters call that throws leaves the reliability fields $null -
        the report never fails because one source is absent. Both calls
        are injectable since neither cmdlet exists on the macOS dev host.
    #>
    param(
        [scriptblock]$GetPhysicalDisksAction = { Get-PhysicalDisk },

        [scriptblock]$GetReliabilityCountersAction = {
            param($Disks)
            $Disks | Get-StorageReliabilityCounter
        }
    )

    $disks = @(& $GetPhysicalDisksAction)

    $counterById = @{}
    try {
        foreach ($counter in @(& $GetReliabilityCountersAction $disks)) {
            if ($null -ne $counter -and $null -ne $counter.DeviceId) {
                $counterById["$($counter.DeviceId)"] = $counter
            }
        }
    }
    catch {
        Write-Warning "Get-WtDiskHealthReport: reliability counters unavailable - $($_.Exception.Message)"
    }

    $report = New-Object System.Collections.Generic.List[object]
    foreach ($disk in $disks) {
        $counter = $counterById["$($disk.DeviceId)"]

        $temperature = $null
        $temperatureMax = $null
        $wear = $null
        $powerOnHours = $null
        $readErrors = $null
        $writeErrors = $null

        if ($counter) {
            if ($null -ne $counter.Temperature -and [int]$counter.Temperature -gt 0) { $temperature = [int]$counter.Temperature }
            if ($null -ne $counter.TemperatureMax -and [int]$counter.TemperatureMax -gt 0) { $temperatureMax = [int]$counter.TemperatureMax }
            if ($null -ne $counter.Wear -and -not ([int]$counter.Wear -eq 0 -and $disk.MediaType -eq 'HDD')) { $wear = [int]$counter.Wear }
            if ($null -ne $counter.PowerOnHours) { $powerOnHours = [long]$counter.PowerOnHours }
            if ($null -ne $counter.ReadErrorsUncorrected) { $readErrors = [long]$counter.ReadErrorsUncorrected }
            if ($null -ne $counter.WriteErrorsUncorrected) { $writeErrors = [long]$counter.WriteErrorsUncorrected }
        }

        $entry = [PSCustomObject]@{
            DeviceId               = "$($disk.DeviceId)"
            FriendlyName           = $disk.FriendlyName
            SerialNumber           = $disk.SerialNumber
            MediaType              = "$($disk.MediaType)"
            BusType                = "$($disk.BusType)"
            SizeBytes              = [long]$disk.Size
            HealthStatus           = "$($disk.HealthStatus)"
            OperationalStatus      = "$($disk.OperationalStatus)"
            TemperatureC           = $temperature
            TemperatureMaxC        = $temperatureMax
            WearPercent            = $wear
            PowerOnHours           = $powerOnHours
            ReadErrorsUncorrected  = $readErrors
            WriteErrorsUncorrected = $writeErrors
            Flags                  = @()
            Severity               = 'OK'
        }

        $flagResult = Get-WtDiskHealthFlags -Disk $entry
        $entry.Flags = $flagResult.Flags
        $entry.Severity = $flagResult.Severity
        $report.Add($entry)
    }

    return $report.ToArray()
}

# ---- Get-WtDiskPartitionLayoutLines (lines 34145-34230) ----
function Get-WtDiskPartitionLayoutLines {
    <#
    .SYNOPSIS
        Every physical disk with its bus type and GPT/MBR style, and its
        partitions (including the hidden EFI/Reserved/Recovery ones
        Explorer never shows), matched to Get-PhysicalDisk's MediaType /
        FirmwareVersion by Ordinal FriendlyName comparison (tr-TR's
        dotless I makes -eq / -match unreliable here). A 'File Backed
        Virtual' entry can appear in Get-PhysicalDisk but not in
        Get-Disk, so such leftovers are listed separately and labelled
        virtual. A partition's DriveLetter with no letter carries
        [char]0, not '', so it is compared by code point rather than via
        IsNullOrWhiteSpace.
    #>
    param(
        [scriptblock]$GetDisks = { Get-Disk },
        [scriptblock]$GetPartitions = { param($Number) Get-Partition -DiskNumber $Number },
        [scriptblock]$GetPhysicalDisks = { Get-PhysicalDisk }
    )
    $disks = @()
    try { $disks = @(& $GetDisks | Sort-Object -Property Number) }
    catch { $disks = @() }
    $physical = @()
    try { $physical = @(& $GetPhysicalDisks) }
    catch { $physical = @() }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($disks.Count -eq 0) { $lines.Add((Get-Translation 'DiskLayoutNoDisks')) }

    $matchedNames = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $disks) {
        $name = [string]$d.FriendlyName
        $phys = $null
        foreach ($p in $physical) {
            if ([string]::Equals([string]$p.FriendlyName, $name, [System.StringComparison]::Ordinal)) { $phys = $p; break }
        }
        if ($phys) { $matchedNames.Add([string]$phys.FriendlyName) }
        $media = if ($phys -and $phys.MediaType) { [string]$phys.MediaType } else { '-' }
        $firmware = if ($phys -and $phys.FirmwareVersion) { [string]$phys.FirmwareVersion } else { '-' }

        $lines.Add(('#{0}  {1}' -f [string]$d.Number, (Format-WtLeftTruncatedPath -Path $name -Width 44)))
        $lines.Add(('     {0}  {1}  {2}  {3}' -f [string]$d.BusType, [string]$d.PartitionStyle, (Format-WtByteSize -Bytes ([long]$d.Size)), [string]$d.HealthStatus))
        $lines.Add(('     {0}  fw {1}' -f $media, $firmware))

        $parts = $null
        try { $parts = @(& $GetPartitions ([int]$d.Number) | Sort-Object -Property PartitionNumber) }
        catch { $parts = $null }
        if ($null -eq $parts -or $parts.Count -eq 0) {
            $lines.Add('       ' + (Get-Translation 'DiskLayoutPartitionsNone'))
        }
        else {
            foreach ($pt in $parts) {
                $code = 0
                try { $code = [int][char]$pt.DriveLetter }
                catch { $code = 0 }
                $letter = if ($code -gt 32) { ([string][char]$code) + ':' } else { Get-Translation 'DiskLayoutNoLetter' }
                $tags = @()
                if ($pt.IsBoot) { $tags += 'boot' }
                if ($pt.IsSystem) { $tags += 'system' }
                if ($pt.IsHidden) { $tags += (Get-Translation 'DiskLayoutHiddenTag') }
                $tail = if ($tags.Count -gt 0) { '  [' + ($tags -join ', ') + ']' } else { '' }
                $lines.Add(('       {0,-2} {1,-11} {2,-9} {3,10}{4}' -f [string]$pt.PartitionNumber, $letter, [string]$pt.Type, (Format-WtByteSize -Bytes ([long]$pt.Size)), $tail))
            }
        }
        $lines.Add('')
    }

    $extras = @()
    foreach ($p in $physical) {
        $pname = [string]$p.FriendlyName
        $seen = $false
        foreach ($m in $matchedNames) {
            if ([string]::Equals($m, $pname, [System.StringComparison]::Ordinal)) { $seen = $true; break }
        }
        if (-not $seen) { $extras += $p }
    }
    if ($extras.Count -gt 0) {
        $lines.Add((Get-Translation 'DiskLayoutVirtualHeader'))
        foreach ($p in $extras) {
            $bus = [string]$p.BusType
            $tag = if ([string]::Equals($bus, 'File Backed Virtual', [System.StringComparison]::Ordinal)) { Get-Translation 'DiskLayoutVirtualTag' } else { $bus }
            $lines.Add(('  {0}  {1}  {2}' -f (Format-WtLeftTruncatedPath -Path ([string]$p.FriendlyName) -Width 22), (Format-WtByteSize -Bytes ([long]$p.Size)), $tag))
        }
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtDiskRepairCatalog (lines 23504-23543) ----
function Get-WtDiskRepairCatalog {
    <#
    .SYNOPSIS
        The fixed NTFS/ReFS volumes a boot-time repair can be scheduled
        for, in the Show-WtSelector catalog shape, each carrying its
        Get-WtDiskRepairPlan.
    #>
    param(
        [scriptblock]$GetVolumes = { Get-Volume -ErrorAction SilentlyContinue },
        [string]$SystemDrive = "$env:SystemDrive"
    )

    $systemLetter = ''
    if ($SystemDrive -and $SystemDrive.Length -ge 1) { $systemLetter = $SystemDrive.Substring(0, 1).ToUpperInvariant() }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($volume in @(& $GetVolumes)) {
        if (-not $volume.DriveLetter) { continue }
        if (([string]$volume.DriveType) -cne 'Fixed') { continue }
        $fileSystem = [string]$volume.FileSystem
        if (-not $fileSystem) { $fileSystem = [string]$volume.FileSystemType }
        if (($fileSystem -cne 'NTFS') -and ($fileSystem -cne 'ReFS')) { continue }

        $letter = ([string]$volume.DriveLetter).Substring(0, 1).ToUpperInvariant()
        $isSystem = ($letter -ceq $systemLetter)
        $plan = Get-WtDiskRepairPlan -DriveLetter $letter -IsSystemDrive $isSystem

        $entries.Add([PSCustomObject]@{
            Name          = $letter
            DisplayLabel  = ('{0}: {1} ({2})' -f $letter, ([string]$volume.FileSystemLabel), $fileSystem)
            Risk          = 'ADVANCED'
            Consequence   = (Get-Translation $plan.NoteKey)
            DriveLetter   = $letter
            IsSystemDrive = $isSystem
            Plan          = $plan
        })
    }

    return $entries.ToArray()
}

# ---- Get-WtDiskRepairPlan (lines 23479-23502) ----
function Get-WtDiskRepairPlan {
    <#
    .SYNOPSIS
        PURE: how a chkdsk /f repair is scheduled for one drive letter, and
        the command that cancels it. The system drive sets the dirty bit
        directly, since chkdsk's own next-boot prompt is a localized
        yes/no a captured run cannot answer; any other volume uses
        Repair-Volume -OfflineScanAndFix.
    #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][bool]$IsSystemDrive
    )

    $letter = ([string]$DriveLetter).Substring(0, 1).ToUpperInvariant()

    return [PSCustomObject]@{
        DriveLetter   = $letter
        Method        = $(if ($IsSystemDrive) { 'DirtyBit' } else { 'OfflineScanAndFix' })
        ScheduleText  = $(if ($IsSystemDrive) { "fsutil dirty set ${letter}:" } else { "Repair-Volume -DriveLetter $letter -OfflineScanAndFix" })
        CancelCommand = "chkntfs /x ${letter}:"
        NoteKey       = $(if ($IsSystemDrive) { 'DiskRepairSystemDrive' } else { 'DiskRepairOfflineScan' })
    }
}

# ---- Get-WtDnsAnswerAddresses (lines 32651-32670) ----
function Get-WtDnsAnswerAddresses {
    <#
    .SYNOPSIS
        The A-record addresses out of one Resolve-DnsName answer,
        de-duplicated and ordinally sorted so two servers that return the
        same addresses in a different order still compare equal.
    #>
    param([AllowEmptyCollection()][array]$Records = @())
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        if (-not ($record.PSObject.Properties.Name -contains 'IPAddress')) { continue }
        $value = [string]$record.IPAddress
        if (-not $value) { continue }
        if (-not $out.Contains($value)) { $out.Add($value) }
    }
    $sorted = $out.ToArray()
    [array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return [string[]]$sorted
}

# ---- Get-WtDnsTestPlanLines (lines 32672-32693) ----
function Get-WtDnsTestPlanLines {
    <#
    .SYNOPSIS
        The three servers the name will be asked of, printed BEFORE the
        first query - same disclosure discipline as the connectivity test.
        Pure: no data source parameter, so nothing is queried by printing.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$PublicServers = @('8.8.8.8', '1.1.1.1')
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(((Get-Translation 'DnsTestServersHeader') -f $Name))
    $lines.Add(('  - ' + (Get-Translation 'DnsTestServerAdapter')))
    foreach ($server in $PublicServers) {
        $lines.Add(('  - ' + ((Get-Translation 'DnsTestServerLine') -f $server)))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'DnsTestCacheNote'))
    $lines.Add('')
    return [string[]]$lines.ToArray()
}

# ---- Get-WtDnsTestResultLines (lines 32695-32740) ----
function Get-WtDnsTestResultLines {
    <#
    .SYNOPSIS
        Resolves one name against the adapter's own DNS server and
        against 8.8.8.8 and 1.1.1.1, puts the three answer sets side by
        side and says plainly when they differ - a hijacked or blocking
        resolver shows up as a different answer. Every query uses
        -Type A -DnsOnly, since without -DnsOnly the local DNS cache
        answers first and hides exactly the difference this row exists
        to expose. A server that fails is written as "no answer", never
        a blank; signatures are built via .ToArray(), never @($answers):
        under tr-TR, @() around a List[object] of PSCustomObjects throws
        "Argument types do not match".
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$PublicServers = @('8.8.8.8', '1.1.1.1'),
        [scriptblock]$ResolveWithAdapter = { param($HostName) Resolve-DnsName -Name $HostName -Type A -DnsOnly -ErrorAction Stop },
        [scriptblock]$ResolveWithServer = { param($HostName, $Server) Resolve-DnsName -Name $HostName -Type A -DnsOnly -Server $Server -ErrorAction Stop }
    )
    $answers = New-Object System.Collections.Generic.List[object]

    $adapter = @()
    try { $adapter = @(Get-WtDnsAnswerAddresses -Records @(& $ResolveWithAdapter $Name)) }
    catch { $adapter = @() }
    $answers.Add([PSCustomObject]@{ Label = [string](Get-Translation 'DnsTestAdapterLabel'); Addresses = $adapter })

    foreach ($server in $PublicServers) {
        $set = @()
        try { $set = @(Get-WtDnsAnswerAddresses -Records @(& $ResolveWithServer $Name $server)) }
        catch { $set = @() }
        $answers.Add([PSCustomObject]@{ Label = [string]$server; Addresses = $set })
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($answer in $answers) {
        $text = if (@($answer.Addresses).Count -eq 0) { [string](Get-Translation 'DnsTestNoAnswer') } else { (@($answer.Addresses) -join ', ') }
        $lines.Add(('  {0}: {1}' -f $answer.Label, $text))
    }
    $lines.Add('')
    $signatures = @($answers.ToArray() | ForEach-Object { (@($_.Addresses) -join ',') })
    $distinct = @(@($signatures) | Sort-Object -Unique)
    if ($distinct.Count -le 1) { $lines.Add((Get-Translation 'DnsTestSame')) }
    else { $lines.Add((Get-Translation 'DnsTestDifferent')) }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtDuplicateGroups (lines 24414-24519) ----
function Get-WtDuplicateGroups {
    <#
    .SYNOPSIS
        Hash-based duplicate grouping: group by size, prehash the
        collisions, full-hash the survivors, keep only groups of two or
        more byte-identical files. A file whose hash throws (locked,
        vanished) is dropped from its group and counted, never fatal.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Files,

        [scriptblock]$PrehashAction = { param($Path) Get-WtFilePrehash -Path $Path },

        [scriptblock]$FullHashAction = { param($Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash },

        [scriptblock]$ReportProgressAction = {
            param($Done, $Total)
            Write-Progress -Activity 'Hashing' -Status "$Done of $Total files" -PercentComplete ([math]::Min(100, [int](100 * $Done / [math]::Max(1, $Total))))
        }
    )

    $unreadable = 0
    $hashed = 0

    $bySize = @{}
    foreach ($file in $Files) {
        $key = [string][long]$file.Length
        if (-not $bySize.ContainsKey($key)) { $bySize[$key] = New-Object System.Collections.Generic.List[object] }
        $bySize[$key].Add($file)
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($group in $bySize.Values) {
        if ($group.Count -ge 2) { foreach ($file in $group) { $candidates.Add($file) } }
    }

    $byPrehash = @{}
    $done = 0
    foreach ($file in $candidates) {
        try {
            $prehash = & $PrehashAction $file.Path
            $key = '{0}|{1}' -f [long]$file.Length, $prehash
            if (-not $byPrehash.ContainsKey($key)) { $byPrehash[$key] = New-Object System.Collections.Generic.List[object] }
            $byPrehash[$key].Add($file)
        }
        catch {
            $unreadable++
        }
        $done++
        if (($done % 50) -eq 0) { & $ReportProgressAction $done $candidates.Count }
    }

    $byHash = @{}
    $survivors = New-Object System.Collections.Generic.List[object]
    foreach ($group in $byPrehash.Values) {
        if ($group.Count -ge 2) { foreach ($file in $group) { $survivors.Add($file) } }
    }
    $done = 0
    foreach ($file in $survivors) {
        try {
            $hash = & $FullHashAction $file.Path
            $hashed++
            $key = '{0}|{1}' -f [long]$file.Length, $hash
            if (-not $byHash.ContainsKey($key)) { $byHash[$key] = New-Object System.Collections.Generic.List[object] }
            $byHash[$key].Add($file)
        }
        catch {
            $unreadable++
        }
        $done++
        if (($done % 50) -eq 0) { & $ReportProgressAction $done $survivors.Count }
    }
    Write-Progress -Activity 'Hashing' -Completed

    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($key in $byHash.Keys) {
        $group = $byHash[$key]
        if ($group.Count -lt 2) { continue }
        $length = [long]$group[0].Length
        $groups.Add([PSCustomObject]@{
            Hash        = ($key -split '\|', 2)[1]
            Length      = $length
            Paths       = @($group | ForEach-Object { $_.Path })
            WastedBytes = ($group.Count - 1) * $length
        })
    }

    $sorted = @($groups.ToArray() | Sort-Object -Property WastedBytes -Descending)
    $totalWasted = 0L
    $duplicateCount = 0
    foreach ($group in $sorted) {
        $totalWasted += [long]$group.WastedBytes
        $duplicateCount += @($group.Paths).Count
    }

    return [PSCustomObject]@{
        Groups             = $sorted
        TotalWastedBytes   = $totalWasted
        FilesConsidered    = @($Files).Count
        FilesHashed        = $hashed
        DuplicateFileCount = $duplicateCount
        UnreadableFiles    = $unreadable
    }
}

# ---- Get-WtDuplicateScanRootCatalog (lines 24521-24549) ----
function Get-WtDuplicateScanRootCatalog {
    <#
    .SYNOPSIS
        The known user folders offered as duplicate-scan roots, in the
        Show-WtSelector catalog shape (Name/DisplayLabel/Risk/Consequence)
        plus Path. A folder that does not exist on this machine is still
        listed - the menu marks it unselectable.
    #>
    $downloads = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Downloads' } else { '' }
    $entries = @(
        @{ Name = 'Desktop'; Path = [Environment]::GetFolderPath('Desktop') }
        @{ Name = 'Documents'; Path = [Environment]::GetFolderPath('MyDocuments') }
        @{ Name = 'Downloads'; Path = $downloads }
        @{ Name = 'Pictures'; Path = [Environment]::GetFolderPath('MyPictures') }
        @{ Name = 'Videos'; Path = [Environment]::GetFolderPath('MyVideos') }
        @{ Name = 'Music'; Path = [Environment]::GetFolderPath('MyMusic') }
    )

    return Resolve-WtCatalogText -KeyPrefix 'DuplicateScanRoot' -Catalog @($entries | ForEach-Object {
        [PSCustomObject]@{
            Name         = $_.Name
            DisplayLabel = '{0} ({1})' -f $_.Name, $_.Path
            LabelArgs    = @($_.Path)
            Risk         = 'SAFE'
            Consequence  = $null
            Path         = $_.Path
        }
    })
}

# ---- Get-WtErrorLogPath (lines 329-343) ----
function Get-WtErrorLogPath {
    <#
    .SYNOPSIS
        <User data root>\errors.log. User scope on purpose: the log is
        for the person in front of the console, like settings.json.
        $script:WtErrorLogPath, when set, overrides it (tests point it
        at a temp file so a deliberately thrown test error never lands
        in the real log).
    #>
    param([string]$TestRootOverride)
    if ($script:WtErrorLogPath) { return [string]$script:WtErrorLogPath }
    $dataPathArgs = @{ Scope = 'User' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    return Join-Path (Get-WtDataPath @dataPathArgs) 'errors.log'
}

# ---- Get-WtEventLevelTag (lines 31116-31133) ----
function Get-WtEventLevelTag {
    <#
    .SYNOPSIS
        PURE: the short, localized word for a Windows event Level number -
        1 Critical, 2 Error, 3 Warning. Anything else (Information,
        Verbose, or a null Level on a record built by hand) yields '', so
        the column keeps its width instead of printing a raw digit.
    #>
    param([AllowNull()][object]$Level)
    $n = 0
    if ($null -ne $Level) { $n = [int]$Level }
    switch ($n) {
        1 { return [string](Get-Translation 'EventLevelCritical') }
        2 { return [string](Get-Translation 'EventLevelError') }
        3 { return [string](Get-Translation 'EventLevelWarning') }
        default { return '' }
    }
}

# ---- Get-WtExplorerCacheTargets (lines 26540-26556) ----
function Get-WtExplorerCacheTargets {
    <#
    .SYNOPSIS
        PURE: the icon / thumbnail cache database globs, as directory +
        wildcard pairs, composed from an injected LOCALAPPDATA so the shape
        is testable. Two locations, not one: iconcache_*.db /
        thumbcache_*.db live under ...\Explorer, the legacy IconCache.db
        directly in LOCALAPPDATA; missing either leaves stale icons.
    #>
    param([string]$LocalAppData = $env:LOCALAPPDATA)
    $explorer = Join-Path $LocalAppData 'Microsoft\Windows\Explorer'
    return @(
        [PSCustomObject]@{ Directory = $explorer; Filter = 'iconcache*.db' }
        [PSCustomObject]@{ Directory = $explorer; Filter = 'thumbcache*.db' }
        [PSCustomObject]@{ Directory = $LocalAppData; Filter = 'IconCache.db' }
    )
}

# ---- Get-WtFileInventory (lines 24275-24383) ----
function Get-WtFileInventory {
    <#
    .SYNOPSIS
        Iterative directory walk shared by the duplicate finder and the
        cleanup preview. Skips ReparsePoint directories (junctions, symlinks
        - Get-ChildItem -Recurse follows them on 5.1) and skips files that
        are reparse points, Offline, or OneDrive online-only placeholders
        (RECALL_ON_DATA_ACCESS/RECALL_ON_OPEN bits - hashing them would
        download them); a directory it cannot enumerate is counted, not
        thrown. Returns
        @{ Files = @(@{ Path; Length; LastWriteTime }); Directories = @(...);
        SkippedDirectories; SkippedFiles }.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [bool]$Recurse = $true,

        [string[]]$Patterns,

        [long]$MinSizeBytes = 0,

        [scriptblock]$ReportProgressAction = {
            param($DirectoriesScanned, $FilesFound)
            Write-Progress -Activity 'Scanning' -Status "$FilesFound files in $DirectoriesScanned folders"
        }
    )

    $files = New-Object System.Collections.Generic.List[object]
    $directories = New-Object System.Collections.Generic.List[string]
    $skippedDirectories = 0
    $skippedFiles = 0
    $scanned = 0

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [PSCustomObject]@{ Files = @(); Directories = @(); SkippedDirectories = 0; SkippedFiles = 0 }
    }

    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $offline = [System.IO.FileAttributes]::Offline
    $recallBits = 0x400000 -bor 0x40000

    $rootInfo = [System.IO.DirectoryInfo]$Root
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push($rootInfo)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $scanned++

        try {
            $entries = @($dir.EnumerateFileSystemInfos())
        }
        catch {
            $skippedDirectories++
            continue
        }

        if ($dir.FullName -ne $rootInfo.FullName) {
            $directories.Add($dir.FullName)
        }

        foreach ($entry in $entries) {
            $attributes = $entry.Attributes
            if ($entry -is [System.IO.DirectoryInfo]) {
                if ($Recurse -and (($attributes -band $reparse) -eq 0)) {
                    $stack.Push($entry)
                }
                continue
            }

            if ((($attributes -band $reparse) -ne 0) -or (($attributes -band $offline) -ne 0) -or (([int]$attributes -band $recallBits) -ne 0)) {
                $skippedFiles++
                continue
            }

            if ($entry.Length -lt $MinSizeBytes) { continue }

            if ($Patterns) {
                $matched = $false
                foreach ($pattern in $Patterns) {
                    if ($entry.Name -like $pattern) { $matched = $true; break }
                }
                if (-not $matched) { continue }
            }

            $files.Add([PSCustomObject]@{
                Path          = $entry.FullName
                Length        = [long]$entry.Length
                LastWriteTime = $entry.LastWriteTime
            })
        }

        if (($scanned % 200) -eq 0) {
            & $ReportProgressAction $scanned $files.Count
        }
    }

    & $ReportProgressAction $scanned $files.Count
    Write-Progress -Activity 'Scanning' -Completed

    return [PSCustomObject]@{
        Files              = $files.ToArray()
        Directories        = $directories.ToArray()
        SkippedDirectories = $skippedDirectories
        SkippedFiles       = $skippedFiles
    }
}

# ---- Get-WtFilePrehash (lines 24385-24412) ----
function Get-WtFilePrehash {
    <#
    .SYNOPSIS
        SHA-256 of a file's first $script:WtDuplicatePrehashBytes bytes -
        the cheap discriminator between same-size files before the full
        hash (czkawka's prehash stage).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] $script:WtDuplicatePrehashBytes
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($buffer, 0, $read)) -replace '-', '')
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

# ---- Get-WtFirewallActionText (lines 32334-32356) ----
function Get-WtFirewallActionText {
    <#
    .SYNOPSIS
        DefaultInboundAction / DefaultOutboundAction in words.
        'NotConfigured' must not reach the panel raw: a factory-default
        machine reports it for both directions, which a home user would
        read as "nothing is blocked" when the effective Windows defaults
        are block inbound / allow outbound. Comparisons are -ceq, since
        tr-TR's dotless-I makes a case-insensitive match on
        'NotConfigured'/'Block' culture-dependent.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Inbound', 'Outbound')][string]$Direction
    )
    if ($Action -ceq 'Allow') { return [string](Get-Translation 'FirewallActionAllow') }
    if ($Action -ceq 'Block') { return [string](Get-Translation 'FirewallActionBlock') }
    if ((-not $Action) -or ($Action -ceq 'NotConfigured')) {
        $effective = if ($Direction -ceq 'Inbound') { Get-Translation 'FirewallActionBlock' } else { Get-Translation 'FirewallActionAllow' }
        return [string]((Get-Translation 'FirewallActionNotConfigured') -f $effective)
    }
    return $Action
}

# ---- Get-WtFirewallRuleCounts (lines 25396-25418) ----
function Get-WtFirewallRuleCounts {
    <#
    .SYNOPSIS
        How many rules "netsh advfirewall reset" is about to drop: this
        tool's own blocklist rules (Group 'WinToolify') and the custom
        rules that belong to no group at all. Windows' built-in rules
        carry their own resource group and are counted in neither, since
        they come back with the default set regardless. Returns zeroes,
        not nothing, when the firewall service cannot be queried.
    #>
    param([scriptblock]$GetRules = { Get-NetFirewallRule -ErrorAction SilentlyContinue })
    $rules = @()
    try { $rules = @(& $GetRules) }
    catch { $rules = @() }
    $ownCount = 0
    $customCount = 0
    foreach ($rule in $rules) {
        $group = [string]$rule.Group
        if ([string]::Equals($group, 'WinToolify', [System.StringComparison]::Ordinal)) { $ownCount++ }
        elseif (-not $group.Trim()) { $customCount++ }
    }
    return [PSCustomObject]@{ WinToolify = $ownCount; Custom = $customCount }
}

# ---- Get-WtFocusableCount (lines 8552-8557) ----
function Get-WtFocusableCount {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Items)
    $n = 0
    foreach ($item in $Items) { if (Test-WtItemFocusable -Item $item) { $n++ } }
    return $n
}

# ---- Get-WtFolderUsage (lines 33703-33743) ----
function Get-WtFolderUsage {
    <#
    .SYNOPSIS
        Total bytes and file count under one folder, walked with an own
        stack rather than Get-ChildItem -Recurse: an unreadable directory
        is COUNTED, not thrown, and a ReparsePoint is skipped at every
        level (PS 5.1's -Recurse does not follow junctions, but this walk
        does not depend on that). Uses ::new() rather than New-Object
        throughout: the information screens must stay clear of every
        New-/Set-/Remove- verb, which a denylist test greps for.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$GetEntries = {
            param($Current)
            $dir = [System.IO.DirectoryInfo]$Current
            return @{ Files = @($dir.GetFiles()); Directories = @($dir.GetDirectories()) }
        }
    )
    $bytes = 0L
    $files = 0
    $skipped = 0
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $entries = $null
        try { $entries = & $GetEntries $current }
        catch { $skipped++; continue }
        foreach ($f in @($entries.Files)) {
            $bytes += [long]$f.Length
            $files++
        }
        foreach ($d in @($entries.Directories)) {
            if (([System.IO.FileAttributes]$d.Attributes -band $reparse) -eq $reparse) { continue }
            $stack.Push([string]$d.FullName)
        }
    }
    return [PSCustomObject]@{ Bytes = $bytes; Files = $files; Skipped = $skipped }
}

# ---- Get-WtFrameChromeHeight (lines 5896-5915) ----
function Get-WtFrameChromeHeight {
    <#
    .SYNOPSIS
        Rows the frame spends outside the content viewport: header
        (banner rows + 4) plus 6 for a default box (borders, path,
        separators, footer) or 4 in banner mode (no path row). The
        layout (Full / Compact) does not change the count.
    #>
    param(
        [Parameter(Mandatory)][int]$Width,
        [bool]$ShowBanner = $false,
        [bool]$Searchable = $false,
        [int]$DescriptionRows = 0
    )
    $header = @(Get-WtBannerLines -Width $Width).Count + 4
    $search = $(if ($Searchable) { 2 } else { 0 })
    $desc = $(if ($DescriptionRows -gt 0) { $DescriptionRows + 1 } else { 0 })
    if ($ShowBanner) { return $header + 4 + $search + $desc }
    return $header + 6 + $search + $desc
}

# ---- Get-WtFrameDescriptionLines (lines 6592-6628) ----
function Get-WtFrameDescriptionLines {
    <#
    .SYNOPSIS
        PURE: the text of the description band for the row the cursor is
        on - the row's Desc word-wrapped to Width, ALWAYS exactly Rows
        lines, padded with empty ones. Fixed height is the whole point:
        the box must not change shape as the cursor walks the menu, so a
        row with no description (a rule, a spacer, a screen that never
        set one) yields blank lines rather than a shorter band. A
        description too long for the band ends its last line with '~'
        instead of being cut off in silence.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][int]$CursorIndex,
        [Parameter(Mandatory)][int]$Width,
        [int]$Rows = 2
    )
    $count = [Math]::Max(0, $Rows)
    $w = [Math]::Max(8, $Width)
    $text = ''
    if ($CursorIndex -ge 0 -and $CursorIndex -lt $Items.Count) {
        $item = $Items[$CursorIndex]
        if ($null -ne $item) { $text = [string]$item.Desc }
    }
    $wrapped = @(Split-WtWrappedLines -Text $text -Width $w)
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $count; $i++) {
        $line = $(if ($i -lt $wrapped.Count) { [string]$wrapped[$i] } else { '' })
        if ($i -eq ($count - 1) -and $wrapped.Count -gt $count) {
            if ($line.Length -ge $w) { $line = $line.Substring(0, $w - 1) }
            $line = $line.TrimEnd() + '~'
        }
        $out.Add($line)
    }
    return $out.ToArray()
}

# ---- Get-WtFrameDiff (lines 5989-6006) ----
function Get-WtFrameDiff {
    <#
    .SYNOPSIS
        Indexes of the rows that differ from the previous frame (or every
        index when forced / the previous frame is shorter). Case-sensitive
        ordinal compare: the rows carry SGR payloads.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Rows,
        [AllowEmptyCollection()][string[]]$PrevRows = @(),
        [bool]$Force = $false
    )
    $changed = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        if ($Force -or $i -ge $PrevRows.Count -or -not [string]::Equals($Rows[$i], $PrevRows[$i], [System.StringComparison]::Ordinal)) { $changed.Add($i) }
    }
    return [int[]]$changed.ToArray()
}

# ---- Get-WtFrameFooterCell (lines 9201-9220) ----
function Get-WtFrameFooterCell {
    <#
    .SYNOPSIS
        PURE: the footer row of a painted frame - the last box row before
        the bottom border - and the column just inside its left border.
        Full layout: (Height-2, 2); Compact: wherever the box ends.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$FrameLines,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs
    )
    $row = [Math]::Max(0, $FrameLines.Count - 2)
    $col = 2
    for ($i = $FrameLines.Count - 1; $i -ge 0; $i--) {
        $text = (@($FrameLines[$i]) | ForEach-Object T) -join ''
        $lead = $text.Length - $text.TrimStart().Length
        if ($text.TrimStart().StartsWith($Glyphs.V)) { $row = $i; $col = $lead + 2; break }
    }
    return @{ Row = $row; Col = $col }
}

# ---- Get-WtFrameRows (lines 6630-6845) ----
function Get-WtFrameRows {
    <#
    .SYNOPSIS
        Composes one complete screen as an array of segment-lines that
        owns EVERY console row (Count == Height); pure, the painter only
        prints what this returns. Every row is exactly Width-1 columns so
        the last console column is never written and nothing can wrap or
        scroll. Layout 'Full' spans the console with a path row, content
        viewport, footer and border; 'Compact' menus/panels size to their
        rows and center horizontally, always sized by the worst case
        (full unfiltered list, longest footer guide) so a live filter or
        swapped footer never resizes it mid-interaction. Row segments are
        collected without wrapping calls in @(), which would re-box an
        already-array result instead of flattening it.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs,
        [string]$CounterText = '',
        [string]$FooterText = '',
        [bool]$LineMode = $false,
        [bool]$ShowBanner = $false,
        [ValidateSet('Full', 'Compact')][string]$Layout = 'Full',
        [hashtable]$CycleLabels = @{},
        [hashtable]$Search = $null,
        [AllowNull()][array]$SizeItems = $null,
        [string]$FooterSizeText = '',
        [int]$DescriptionRows = 0
    )
    $w = Get-WtFrameWidth -Width $Width
    $h = $Glyphs.H
    $v = $Glyphs.V
    $measureItems = $Items
    if ($null -ne $SizeItems) { $measureItems = $SizeItems }
    $stateWidth = 0
    foreach ($item in $measureItems) { if ($item.StateLabel) { $stateWidth = [Math]::Max($stateWidth, ([string]$item.StateLabel).Length) } }
    $rows = New-Object System.Collections.Generic.List[object]
    $blankRow = { ,@(New-WtSeg -Text (' ' * $w) -Fg 'Gray') }
    $centered = { param([string]$Text, [string]$Fg)
        if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w) }
        $pad = [Math]::Max(0, [Math]::Floor(($w - $Text.Length) / 2))
        ,@(New-WtSeg -Text ((' ' * $pad) + $Text + (' ' * ($w - $pad - $Text.Length))) -Fg $Fg)
    }

    $headerKey = [string]$Width + 'x' + [string]$w
    $header = $script:WtFrameHeaderCache[$headerKey]
    if ($null -eq $header) {
        $header = New-Object System.Collections.Generic.List[object]
        foreach ($b in (Get-WtBannerLines -Width $Width)) { $header.Add((& $centered $b 'Cyan')) }
        $header.Add((& $blankRow))
        $credit = @(Get-WtBannerCreditLines)
        $header.Add((& $centered ([string]$credit[0]) 'Gray'))
        $header.Add((& $centered ([string]$credit[1]) 'DarkGray'))
        $header.Add((& $blankRow))
        $script:WtFrameHeaderCache[$headerKey] = $header
    }
    foreach ($hr in $header) { $rows.Add($hr) }

    $searchable = ($null -ne $Search)
    $chromeCount = Get-WtFrameChromeHeight -Width $Width -ShowBanner $ShowBanner -Searchable $searchable -DescriptionRows $DescriptionRows
    $viewHeight = [Math]::Max(1, $Height - $chromeCount)
    if ($Layout -eq 'Compact') { $viewHeight = [Math]::Max(1, [Math]::Min($viewHeight, $measureItems.Count)) }
    $window = Get-WtViewportWindow -ItemCount $Items.Count -CursorIndex ([int]$State.CursorIndex) -ViewHeight $viewHeight -WindowStart ([int]$State.WindowStart)
    $listNumbers = 0
    foreach ($item in $measureItems) {
        $kind = [string]$item.Kind
        if ($kind -eq 'Check' -or $kind -eq 'Link' -or $kind -eq 'Action' -or $kind -eq 'Radio') { $listNumbers++ }
    }
    $numberWidth = [Math]::Max(1, ([string][Math]::Max(1, $listNumbers)).Length)
    $rangeText = ''
    if ($Items.Count -gt $viewHeight) {
        $rangeText = '{0}-{1}/{2}' -f ($window + 1), ([Math]::Min($window + $viewHeight, $Items.Count)), $Items.Count
    }
    $right = (@($CounterText, $rangeText) | Where-Object { $_ }) -join '  '
    $showPath = -not $ShowBanner
    $footerStatus = [string]$(if ($ShowBanner) { $rangeText })

    $bw = $w
    if ($Layout -eq 'Compact') {
        $needKey = [string][System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($measureItems) + '|' + $measureItems.Count + '|' + $stateWidth + '|' + $numberWidth + '|' + $DescriptionRows + '|' + [string]$script:Language
        if ($script:WtCompactNeedKey -eq $needKey) { $need = [int]$script:WtCompactNeedValue }
        else {
            $need = 0
            foreach ($item in $measureItems) { $need = [Math]::Max($need, (Get-WtListRowNaturalWidth -Item $item -Glyphs $Glyphs -StateWidth $stateWidth -NumberWidth $numberWidth)) }
            if ($DescriptionRows -gt 0) {
                $longestDesc = 0
                foreach ($item in $measureItems) { $longestDesc = [Math]::Max($longestDesc, ([string]$item.Desc).Length) }
                if ($longestDesc -gt 0) { $need = [Math]::Max($need, [int][Math]::Ceiling($longestDesc / [double]$DescriptionRows) + 4) }
            }
            $script:WtCompactNeedKey = $needKey
            $script:WtCompactNeedValue = $need
        }
        if ($showPath) {
            $sizeRange = ''
            if ($measureItems.Count -gt $viewHeight) { $sizeRange = '{0}-{1}/{2}' -f ($measureItems.Count - $viewHeight + 1), $measureItems.Count, $measureItems.Count }
            $sizeRight = (@($CounterText, $sizeRange) | Where-Object { $_ }) -join '  '
            $need = [Math]::Max($need, ([string]$Breadcrumb).Length + [Math]::Max($right.Length, $sizeRight.Length) + 2)
        }
        if ($searchable) {
            $sLabel = (Get-Translation 'ListSearchLabel') + ': '
            $sValue = ([string](Get-Translation 'ListSearchPlaceholder')).Length
            $sTotal = Get-WtFocusableCount -Items $measureItems
            $sCount = ((Get-Translation 'ListSearchCount') -f $sTotal, $sTotal) + ' - ' + (Get-Translation 'ListSearchClearHint')
            $need = [Math]::Max($need, $sLabel.Length + $sValue + 2 + $sCount.Length)
        }
        $footerNeed = [Math]::Max(([string]$FooterText).Length, ([string]$FooterSizeText).Length)
        if ($footerStatus) { $footerNeed += 2 + $footerStatus.Length }
        $need = [Math]::Max($need, $footerNeed)
        $bw = [Math]::Min($w, [Math]::Max(40, $need + 2 + 4))
    }
    $inner = $bw - 4
    $lead = [Math]::Max(0, [Math]::Floor(($w - $bw) / 2))
    $trail = [Math]::Max(0, $w - $bw - $lead)
    $boxRow = { param([array]$Segs)
        $out = @()
        if ($lead -gt 0) { $out += @(New-WtSeg -Text (' ' * $lead) -Fg 'Gray') }
        $out += @($Segs)
        if ($trail -gt 0) { $out += @(New-WtSeg -Text (' ' * $trail) -Fg 'Gray') }
        ,$out
    }
    $hline = { param([string]$L, [string]$R) ,@(New-WtSeg -Text ($L + ($h * ($bw - 2)) + $R) -Fg 'Cyan') }

    $rows.Add((& $boxRow (& $hline $Glyphs.TL $Glyphs.TR)))

    if ($showPath) {
        $crumb = [string]$Breadcrumb
        $gap = $inner - $crumb.Length - $right.Length
        if ($gap -lt 1) {
            $room = [Math]::Max(0, $inner - $right.Length - 2)
            $crumb = $crumb.Substring(0, $room) + '~'
            $gap = 1
        }
        $rows.Add((& $boxRow @(
            New-WtSeg -Text ($v + ' ') -Fg 'Cyan'
            New-WtSeg -Text $crumb -Fg 'White'
            New-WtSeg -Text ((' ' * $gap) + $right) -Fg 'DarkGray'
            New-WtSeg -Text (' ' + $v) -Fg 'Cyan'
        )))
        $rows.Add((& $boxRow (& $hline $Glyphs.LT $Glyphs.RT)))
    }

    if ($searchable) {
        $searchSegs = @(Get-WtStoreSearchRowSegments -State $Search -Inner $inner -CountText ([string]$Search.CountText) `
            -Label (Get-Translation 'ListSearchLabel') -Placeholder (Get-Translation 'ListSearchPlaceholder'))
        $rows.Add((& $boxRow (@(New-WtSeg -Text ($v + ' ') -Fg 'Cyan') + $searchSegs + @(New-WtSeg -Text (' ' + $v) -Fg 'Cyan'))))
        $rows.Add((& $boxRow (& $hline $Glyphs.LT $Glyphs.RT)))
    }

    $rowNumber = 0
    for ($i = 0; $i -lt $window; $i++) {
        $kind = [string]$Items[$i].Kind
        if ($kind -eq 'Check' -or $kind -eq 'Link' -or $kind -eq 'Action' -or $kind -eq 'Radio') { $rowNumber++ }
    }
    $limit = [Math]::Min($window + $viewHeight, $Items.Count)
    for ($i = $window; $i -lt $limit; $i++) {
        $item = $Items[$i]
        $num = 0
        $kind = [string]$item.Kind
        if ($kind -eq 'Check' -or $kind -eq 'Link' -or $kind -eq 'Action' -or $kind -eq 'Radio') { $rowNumber++; $num = $rowNumber }
        $isCursor = ($i -eq [int]$State.CursorIndex)
        $pending = ''
        if ($State.ContainsKey('Cycle') -and $null -ne $State.Cycle -and $State.Cycle.ContainsKey([string]$item.Name)) {
            $target = [string]$State.Cycle[[string]$item.Name]
            $pending = $(if ($CycleLabels.ContainsKey($target)) { [string]$CycleLabels[$target] } else { $target })
        }
        $segs = Get-WtListRowSegments -Item $item -IsCursor $isCursor -Selected ($State.Selection.Contains($item.Name)) -Glyphs $Glyphs -Width $inner -VisibleNumber $num -StateWidth $stateWidth -NumberWidth $numberWidth -PendingLabel $pending
        $segLen = 0
        foreach ($s in $segs) { $segLen += ([string]$s.T).Length }
        if ($segLen -lt $inner) {
            $padSeg = if ($isCursor) { [PSCustomObject]@{ T = (' ' * ($inner - $segLen)); F = 'Black'; B = 'DarkCyan' } } else { [PSCustomObject]@{ T = (' ' * ($inner - $segLen)); F = 'Gray'; B = '' } }
            $segs = @($segs) + @($padSeg)
        }
        $rows.Add((& $boxRow (@([PSCustomObject]@{ T = ($v + ' '); F = 'Cyan'; B = '' }) + $segs + @([PSCustomObject]@{ T = (' ' + $v); F = 'Cyan'; B = '' }))))
    }
    for ($i = ($limit - $window); $i -lt $viewHeight; $i++) {
        $rows.Add((& $boxRow @(New-WtSeg -Text ($v + (' ' * ($bw - 2)) + $v) -Fg 'Cyan')))
    }

    if ($DescriptionRows -gt 0) {
        $rows.Add((& $boxRow (& $hline $Glyphs.LT $Glyphs.RT)))
        foreach ($line in (Get-WtFrameDescriptionLines -Items $Items -CursorIndex ([int]$State.CursorIndex) -Width $inner -Rows $DescriptionRows)) {
            $text = [string]$line
            if ($text.Length -gt $inner) { $text = $text.Substring(0, $inner) }
            $rows.Add((& $boxRow @(
                New-WtSeg -Text ($v + ' ') -Fg 'Cyan'
                New-WtSeg -Text ($text + (' ' * ($inner - $text.Length))) -Fg 'Gray'
                New-WtSeg -Text (' ' + $v) -Fg 'Cyan'
            )))
        }
    }

    $rows.Add((& $boxRow (& $hline $Glyphs.LT $Glyphs.RT)))
    $footer = [string]$FooterText
    $statusPart = ''
    if ($footerStatus) {
        if ($footerStatus.Length -gt $inner) { $footerStatus = $footerStatus.Substring(0, $inner) }
        $statusRoom = [Math]::Max(0, $inner - $footerStatus.Length - 2)
        if ($footer.Length -gt $statusRoom) { $footer = $(if ($statusRoom -gt 1) { $footer.Substring(0, $statusRoom - 1) + '~' } else { $footer.Substring(0, $statusRoom) }) }
        $statusPart = (' ' * [Math]::Max(0, $inner - $footer.Length - $footerStatus.Length)) + $footerStatus
    }
    elseif ($footer.Length -gt $inner) { $footer = $(if ($inner -gt 1) { $footer.Substring(0, $inner - 1) + '~' } else { $footer.Substring(0, $inner) }) }
    $rows.Add((& $boxRow @(
        New-WtSeg -Text ($v + ' ') -Fg 'Cyan'
        New-WtSeg -Text $footer -Fg 'Yellow'
        New-WtSeg -Text $statusPart -Fg 'Yellow'
        New-WtSeg -Text ((' ' * [Math]::Max(0, $inner - $footer.Length - $statusPart.Length)) + ' ' + $v) -Fg 'Cyan'
    )))
    $rows.Add((& $boxRow (& $hline $Glyphs.BL $Glyphs.BR)))

    while ($rows.Count -lt $Height) { $rows.Add((& $blankRow)) }
    return $rows.ToArray()
}

# ---- Get-WtFrameWidth (lines 6036-6054) ----
function Get-WtFrameWidth {
    <#
    .SYNOPSIS
        PURE: how many columns a framed screen may draw into. Rows stop
        one column short of the console by default: filling the last cell
        of a row leaves the console in its pending-wrap state and the next
        character written would push the frame down a line. With VT on
        every row Write-WtFrame paints is preceded by an absolute cursor
        move, which clears that state before anything else is written, so
        there the frame can have the whole width. VT is only ever set in
        Key mode, so this is also what keeps the Line-mode path - where
        each row is written with its own newline - one column short.
    #>
    param(
        [Parameter(Mandatory)][int]$Width,
        [bool]$Vt = $script:WtVt
    )
    return [Math]::Max(20, $(if ($Vt) { $Width } else { $Width - 1 }))
}

# ---- Get-WtGpuDriverLines (lines 31491-31539) ----
function Get-WtGpuDriverLines {
    <#
    .SYNOPSIS
        One block per display adapter: real VRAM, driver version, driver
        date and the active display mode. AdapterRAM is not used since it
        saturates at 4 GB; a null CurrentHorizontalResolution means the
        adapter is present but drives no display, not an error, so the
        row says "not active" rather than "0x0".
    #>
    param(
        [scriptblock]$GetControllers = { Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop },
        [scriptblock]$GetVramEntries = { Get-WtGpuVramEntries }
    )
    $controllers = @()
    try { $controllers = @(& $GetControllers) } catch { $controllers = @() }
    if ($controllers.Count -eq 0) { return [string[]]@((Get-Translation 'GpuDriverNotAvailable')) }
    $vram = @()
    try { $vram = @(& $GetVramEntries) } catch { $vram = @() }

    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $controllers.Count; $i++) {
        $c = $controllers[$i]
        $name = [string]$c.Name
        if (-not $name) { $name = [string]$c.Description }
        if (-not $name) { $name = '-' }
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add(((Get-Translation 'GpuDriverNameLine') -f $name))

        $bytes = [long]0
        foreach ($e in $vram) {
            if ([string]::Equals([string]$e.DriverDesc, $name, [System.StringComparison]::Ordinal)) { $bytes = [long]$e.Bytes; break }
        }
        if ($bytes -le 0 -and $i -lt $vram.Count -and $vram[$i]) { $bytes = [long]$vram[$i].Bytes }
        $vramText = if ($bytes -gt 0) { Format-WtByteSize -Bytes $bytes } else { Get-Translation 'GpuDriverVramUnknown' }
        $lines.Add(((Get-Translation 'GpuDriverVramLine') -f $vramText))

        $dateText = Get-Translation 'GpuDriverDateUnknown'
        if ($c.DriverDate) { $dateText = ([datetime]$c.DriverDate).ToString('yyyy-MM-dd') }
        $version = [string]$c.DriverVersion
        if (-not $version) { $version = '-' }
        $lines.Add(((Get-Translation 'GpuDriverVersionLine') -f $version, $dateText))

        if ($c.CurrentHorizontalResolution) {
            $lines.Add(((Get-Translation 'GpuDriverModeLine') -f [int]$c.CurrentHorizontalResolution, [int]$c.CurrentVerticalResolution, [int]$c.CurrentRefreshRate))
        }
        else { $lines.Add((Get-Translation 'GpuDriverModeInactive')) }
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtGpuUtilizationFromEngines (lines 27678-27706) ----
function Get-WtGpuUtilizationFromEngines {
    <#
    .SYNOPSIS
        Task Manager's "GPU %" convention over the GPUEngine formatted
        perf class: sum UtilizationPercentage per engine type (the
        engtype_<Type> suffix of Name), report the busiest type. $null
        when no instance carries an engine type.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Engines
    )

    $byType = @{}
    foreach ($engine in $Engines) {
        if ("$($engine.Name)" -match 'engtype_(\w+)$') {
            $type = $Matches[1]
            if (-not $byType.ContainsKey($type)) { $byType[$type] = 0.0 }
            $byType[$type] += [double]$engine.UtilizationPercentage
        }
    }

    if ($byType.Count -eq 0) { return $null }

    $max = 0.0
    foreach ($value in $byType.Values) { if ($value -gt $max) { $max = $value } }
    return [int][math]::Round($max)
}

# ---- Get-WtGpuVramEntries (lines 31467-31489) ----
function Get-WtGpuVramEntries {
    <#
    .SYNOPSIS
        The display-adapter class key's VRAM values, one object per
        adapter subkey: DriverDesc + the decoded byte count. Kept apart
        from Get-WtGpuDriverLines so the formatter is testable with
        fixtures. Only the four-digit subkeys are adapters - the class key
        also carries 'Configuration' and 'Properties' siblings.
    #>
    $root = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $entries = New-Object System.Collections.Generic.List[psobject]
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        if ([string]$key.PSChildName -cnotmatch '^\d{4}$') { continue }
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { continue }
        if (-not $props) { continue }
        $entries.Add([PSCustomObject]@{
                DriverDesc = [string]$props.DriverDesc
                Bytes      = (ConvertTo-WtVramByteCount -Value $props.'HardwareInformation.qwMemorySize')
            })
    }
    return $entries.ToArray()
}

# ---- Get-WtHostsFileLines (lines 32494-32544) ----
function Get-WtHostsFileLines {
    <#
    .SYNOPSIS
        The active hosts entries with their count, the file size and the
        last-changed time - the read-back the blocklist feature never had.
        Read via [System.IO.File]::ReadAllLines(..., UTF8), matching the
        blocklist apply step's own encoding, since Get-Content's PS 5.1
        default (the ANSI code page) would decode the same file
        differently. The missing-file case is checked before .Length is
        touched, since Format-WtByteSize takes a [long] and dies on
        $null. Capped at 150 entries, since a blocklist can add thousands
        of lines.
    #>
    param(
        [string]$Path = (Join-Path $env:WinDir 'System32\drivers\etc\hosts'),
        [scriptblock]$GetFileInfo = { param($P) Get-Item -LiteralPath $P -ErrorAction SilentlyContinue },
        [scriptblock]$ReadLines = { param($P) [System.IO.File]::ReadAllLines($P, [System.Text.Encoding]::UTF8) },
        [int]$MaxEntries = 150
    )
    $info = $null
    try { $info = & $GetFileInfo $Path }
    catch { $info = $null }
    if ($null -eq $info) { return [string[]]@(((Get-Translation 'HostsFileMissing') -f $Path)) }

    $raw = @()
    try { $raw = @(& $ReadLines $Path) }
    catch { return [string[]]@(((Get-Translation 'HostsFileMissing') -f $Path)) }

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($line in $raw) {
        $text = ([string]$line).Trim()
        if (-not $text) { continue }
        if ($text.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
        $entries.Add($text)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(((Get-Translation 'HostsFileHeader') -f $Path))
    $lines.Add(((Get-Translation 'HostsFileStats') -f $entries.Count, (Format-WtByteSize -Bytes ([long]$info.Length)), ([string]$info.LastWriteTime)))
    $lines.Add('')
    if ($entries.Count -eq 0) {
        $lines.Add((Get-Translation 'HostsFileNoEntries'))
        return [string[]]$lines.ToArray()
    }
    $shown = [Math]::Min($entries.Count, $MaxEntries)
    for ($i = 0; $i -lt $shown; $i++) { $lines.Add('  ' + $entries[$i]) }
    if ($entries.Count -gt $shown) {
        $lines.Add(('  ' + ((Get-Translation 'HostsFileTruncated') -f $shown, ($entries.Count - $shown))))
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtHostsFileSummary (lines 25257-25277) ----
function Get-WtHostsFileSummary {
    <#
    .SYNOPSIS
        PURE: how many active entries the Hosts file holds (a non-empty
        line that does not start with '#') and how many of those carry
        this tool's blocklist marker, appended by Get-WtHostsLinesToAdd as
        "<line><tab># WinToolify (<tier>)".
    #>
    param([AllowEmptyString()][string]$Content = '')
    $active = 0
    $marked = 0
    foreach ($raw in ([string]$Content -split "`r?`n")) {
        $line = [string]$raw
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
        $active++
        if ($line.Contains('# WinToolify (')) { $marked++ }
    }
    return [PSCustomObject]@{ Active = $active; Marked = $marked }
}

# ---- Get-WtHostsResetPreviewLines (lines 25279-25292) ----
function Get-WtHostsResetPreviewLines {
    <#
    .SYNOPSIS
        PURE: the two lines the confirmation gate shows before the Hosts
        file is rewritten - what is in there now, and how much of it this
        tool put there.
    #>
    param([AllowEmptyString()][string]$Content = '')
    $summary = Get-WtHostsFileSummary -Content $Content
    return [string[]]@(
        ((Get-Translation 'HostsActiveEntries') -f $summary.Active)
        ((Get-Translation 'HostsWinToolifyEntries') -f $summary.Marked)
    )
}

# ---- Get-WtHungProcessSample (lines 26720-26750) ----
function Get-WtHungProcessSample {
    <#
    .SYNOPSIS
        One sample of the windowed processes not answering their message
        loop: Id, Name and window title. Every .Responding /
        .MainWindowTitle read is guarded - a protected or just-exited
        process raises a Win32Exception, and one unhandled throw would
        silently empty the whole list.
    #>
    param(
        [scriptblock]$GetProcesses = { @(Get-Process -ErrorAction SilentlyContinue) },
        [scriptblock]$ReadResponding = { param($Process) [bool]$Process.Responding },
        [scriptblock]$ReadTitle = { param($Process) [string]$Process.MainWindowTitle }
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(& $GetProcesses)) {
        if (-not $process) { continue }
        $handle = [int64]0
        try { $handle = [int64]$process.MainWindowHandle } catch { continue }
        if ($handle -eq 0) { continue }
        $responding = $true
        try { $responding = [bool](& $ReadResponding $process) } catch { continue }
        if ($responding) { continue }
        $title = ''
        try { $title = [string](& $ReadTitle $process) } catch { $title = '' }
        $id = 0
        try { $id = [int]$process.Id } catch { continue }
        $result.Add([PSCustomObject]@{ Id = $id; Name = [string]$process.Name; Title = $title })
    }
    return @($result.ToArray())
}

# ---- Get-WtInfoToolGroups (lines 17074-17209) ----
function Get-WtInfoToolGroups {
    <#
    .SYNOPSIS
        Basic Tools > Information as seven ordered groups. Every row is
        read-only except the two Inline rows that ask the user first
        (Wi-Fi profile name, save-the-report). DISM's component-store
        verdict prints verbatim since it is localized text; only
        InternetConnectivityTest and DnsResolutionTest contact the
        internet, and the former must print its host list before running
        its queries.
    #>
    return @(
        @{ HeaderKey = 'InfoGroupSystemSummary'; GetRows = {
                @(
                    (New-WtToolRow -Name 'ShowComputerAndUserName' -Action {
                            Write-Host ('{0}: {1}' -f (Get-Translation 'ComputerName'), $env:COMPUTERNAME) -ForegroundColor Green
                            Write-Host ('{0}: {1}' -f (Get-Translation 'ActiveUser'), $env:USERNAME) -ForegroundColor Green
                        })
                    (New-WtToolRow -Name 'ShowWindowsVersion' -Action { foreach ($l in (Get-WtWindowsVersionLines)) { Write-Host $l -ForegroundColor Green }; Start-Process -FilePath 'winver.exe' })
                    (New-WtToolRow -Name 'WindowsUpgradeHistory' -Kind 'Captured' -Action { foreach ($l in (Get-WtWindowsUpgradeHistoryLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'GetSystemInformation' -Action { systeminfo })
                    (New-WtToolRow -Name 'ShowWindowsLicenseStatus' -Action {
                            cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /xpr
                            Write-Host ''
                            cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /dlv
                        })
                    (New-WtToolRow -Name 'PendingRebootCheck' -Kind 'Captured' -Action { foreach ($l in (Get-WtPendingRebootLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'ShowTimeSyncStatus' -Kind 'Captured' -Action { foreach ($l in (Get-WtTimeSyncLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'ShutdownHistory' -Kind 'Captured' -Action { foreach ($l in (Get-WtShutdownHistoryLines)) { Write-Host $l } })
                )
            }
        }
        @{ HeaderKey = 'InfoGroupHardware'; GetRows = {
                @(
                    (New-WtToolRow -Name 'HardwareSummary' -Action {
                            foreach ($l in (Get-WtSystemIdentityLines)) { Write-Host $l -ForegroundColor Green }
                            foreach ($l in (Format-WtSensorLines -Snapshot (Get-WtSensorSnapshot))) { Write-Host $l }
                        })
                    (New-WtToolRow -Name 'ShowRAMUsage' -Action {
                            $os = Get-CimInstance -ClassName Win32_OperatingSystem
                            Write-Host ((Get-Translation 'RamUsageLine') -f [math]::Round($os.FreePhysicalMemory / 1024), [math]::Round($os.TotalVisibleMemorySize / 1024)) -ForegroundColor Green
                        })
                    (New-WtToolRow -Name 'MemoryModuleReport' -Kind 'Captured' -Action { foreach ($l in (Get-WtMemoryModuleLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'MotherboardBiosInfo' -Action { foreach ($line in (Get-WtMotherboardBiosLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'ShowCPUInfo' -Action { Get-CimInstance -ClassName Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed | Format-List | Out-String | Write-Host })
                    (New-WtToolRow -Name 'GpuDriverDetails' -Kind 'Captured' -Action { foreach ($l in (Get-WtGpuDriverLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'BatteryHealthReport' -Kind 'Captured' -Action {
                            Write-Host (Get-Translation 'BatteryReportRunning')
                            foreach ($l in (Get-WtBatteryHealthLines)) { Write-Host $l }
                        })
                    (New-WtToolRow -Name 'ProblemDeviceReport' -Kind 'Captured' -Action { foreach ($l in (Get-WtProblemDeviceLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'ShowPrinterStatus' -Action { Get-Printer | Format-Table Name, PrinterStatus, DriverName, PortName -AutoSize | Out-String | Write-Host })
                )
            }
        }
        @{ HeaderKey = 'InfoGroupStorage'; GetRows = {
                @(
                    (New-WtToolRow -Name 'ShowStorageStatus' -Action { foreach ($l in (Get-WtStorageLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'CheckDiskStatus' -Action { Get-PhysicalDisk | Format-Table FriendlyName, MediaType, HealthStatus, OperationalStatus, @{ Name = 'Size'; Expression = { Format-WtByteSize -Bytes ([long]$_.Size) } } -AutoSize | Out-String | Write-Host })
                    (New-WtToolRow -Name 'LargestFoldersReport' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtLargestFoldersReportAction })
                    (New-WtToolRow -Name 'LargestFilesReport' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtLargestFilesReportAction })
                    (New-WtToolRow -Name 'ComponentStoreAnalysis' -Kind 'Captured' -Risk 'CAUTION' -Action {
                        $available = Test-WtDismAvailable
                        foreach ($l in (Get-WtComponentStoreAnalysisLines -DismAvailable $available)) { Write-Host $l }
                        if (-not $available) { return }
                        DISM /Online /Cleanup-Image /AnalyzeComponentStore
                    })
                    (New-WtToolRow -Name 'RestorePointShadowStorage' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtRestorePointShadowStorageLines)) { Write-Host $l }
                        vssadmin list shadowstorage
                    })
                    (New-WtToolRow -Name 'DiskPartitionLayout' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtDiskPartitionLayoutLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'ScanHardDisk' -Action { chkdsk $env:SystemDrive /scan })
                )
            }
        }
        @{ HeaderKey = 'InfoGroupNetwork'; GetRows = {
                @(
                    (New-WtToolRow -Name 'ShowIPConfigSummary' -Action { foreach ($line in (Get-WtIpConfigSummaryLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'ShowNetworkAdapters' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtNetworkAdapterLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'ShowWifiLinkDetails' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtWifiLinkLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'ShowWifiPassword' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtWifiPasswordAction })
                    (New-WtToolRow -Name 'ShowNetworkProfileState' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtNetworkProfileLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'ShowListeningPorts' -Action { foreach ($line in (Get-WtListeningPortLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'ShowActiveConnections' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtActiveConnectionLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'ShowHostsFile' -Kind 'Captured' -Risk 'CAUTION' -Action {
                        foreach ($l in (Get-WtHostsFileLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'InternetConnectivityTest' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtInternetTestPlanLines)) { Write-Host $l }
                        foreach ($l in (Get-WtInternetTestResultLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'DnsResolutionTest' -Kind 'Inline' -Action { Invoke-WtDnsResolutionTestAction })
                    (New-WtToolRow -Name 'ShowFullIPConfig' -Action { ipconfig /all })
                )
            }
        }
        @{ HeaderKey = 'InfoGroupSoftwareStartup'; GetRows = { @(
                    (New-WtToolRow -Name 'InstalledProgramsList' -Kind 'Captured' -Action { foreach ($line in (Get-WtInstalledProgramsLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'StartupProgramsList' -Kind 'Captured' -Action { foreach ($line in (Get-WtStartupProgramsLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'NonMicrosoftScheduledTasks' -Kind 'Captured' -Action { foreach ($line in (Get-WtNonMicrosoftTaskLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'InstalledUpdatesList' -Kind 'Captured' -Action { foreach ($line in (Get-WtInstalledUpdatesLines)) { Write-Host $line } })
                ) }
        }
        @{ HeaderKey = 'InfoGroupSecurity'; GetRows = {
                @(
                    (New-WtToolRow -Name 'DefenderStatusInfo' -Kind 'Captured' -Action { foreach ($line in (Get-WtDefenderStatusLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'SecureBootTpmStatus' -Kind 'Captured' -Action { foreach ($line in (Get-WtSecureBootTpmLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'LocalAdministrators' -Kind 'Captured' -Action { foreach ($line in (Get-WtLocalAdministratorsLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'ListUserAccounts' -Action { Get-WtLocalUserTable | Format-Table -AutoSize | Out-String | Write-Host })
                    (New-WtToolRow -Name 'SecurityPostureInfo' -Kind 'Captured' -Action { foreach ($line in (Get-WtSecurityPostureLines)) { Write-Host $line } })
                )
            }
        }
        @{ HeaderKey = 'InfoGroupEventsDiagnostics'; GetRows = {
                @(
                    (New-WtToolRow -Name 'SystemHealthReport' -Kind 'Inline' -Action { Invoke-WtSystemHealthAction })
                    (New-WtToolRow -Name 'RecentSystemErrors' -Kind 'Captured' -Action { foreach ($l in (Get-WtRecentSystemErrorsLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'BlueScreenHistory' -Kind 'Captured' -Action { foreach ($l in (Get-WtBlueScreenHistoryLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'DiskErrorEvents' -Kind 'Captured' -Action { foreach ($l in (Get-WtDiskErrorEventsLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'TopProcessesByMemory' -Kind 'Captured' -Action { foreach ($l in (Get-WtTopProcessesByMemoryLines)) { Write-Host $l } })
                )
            }
        }
    )
}

# ---- Get-WtInstalledProgramEntries (lines 27125-27186) ----
function Get-WtInstalledProgramEntries {
    <#
    .SYNOPSIS
        The classic Win32 "Add or remove programs" list, read straight
        from the registry. NEVER Win32_Product: querying that class makes
        Windows Installer RECONFIGURE every MSI product on the machine -
        minutes of disk churn and a real chance of breaking an install.
        Keyed on PSChildName, since two vendors can ship the same
        DisplayName, deduplicated with an Ordinal comparer since tr-TR
        would otherwise fold I/i and collapse two distinct keys into one.
    #>
    param(
        [scriptblock]$GetRoots = { Get-WtUninstallRegistryRoots },
        [scriptblock]$GetEntries = {
            param($Path)
            if (-not (Test-Path -LiteralPath $Path)) { return @() }
            Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            }
        }
    )
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $out = New-Object 'System.Collections.Generic.List[object]'
    $skipReleaseTypes = @('Security Update', 'Update', 'Hotfix', 'ServicePack')
    foreach ($root in @(& $GetRoots)) {
        $raws = @()
        try { $raws = @(& $GetEntries $root.Path) }
        catch { $raws = @() }
        foreach ($raw in $raws) {
            if (-not $raw) { continue }
            $key = [string]$raw.PSChildName
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $name = [string]$raw.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($raw.SystemComponent -eq 1) { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.ParentKeyName)) { continue }

            $releaseType = [string]$raw.ReleaseType
            $isUpdate = $false
            foreach ($skip in $skipReleaseTypes) {
                if ([string]::Equals($releaseType, $skip, [System.StringComparison]::OrdinalIgnoreCase)) { $isUpdate = $true; break }
            }
            if ($isUpdate) { continue }

            $uninstallString = [string]$raw.UninstallString
            $quietString = [string]$raw.QuietUninstallString
            if ([string]::IsNullOrWhiteSpace($uninstallString) -and [string]::IsNullOrWhiteSpace($quietString)) { continue }

            if (-not $seen.Add($key)) { continue }
            $out.Add([PSCustomObject]@{
                Key                  = $key
                DisplayName          = $name.Trim()
                DisplayVersion       = [string]$raw.DisplayVersion
                Publisher            = [string]$raw.Publisher
                UninstallString      = $uninstallString
                QuietUninstallString = $quietString
                ScopeKey             = [string]$root.ScopeKey
            })
        }
    }
    return @($out.ToArray() | Sort-Object -Property DisplayName)
}

# ---- Get-WtInstalledProgramsLines (lines 33231-33325) ----
function Get-WtInstalledProgramsLines {
    <#
    .SYNOPSIS
        PURE-FRONTED: the classic desktop program inventory, over the three
        Uninstall roots Get-WtUninstallRegistryRoots owns - HKLM,
        HKLM\WOW6432Node and Registry::HKEY_USERS\<SID>. The MSI
        product-enumeration API is never used, since enumerating it makes
        Windows Installer reconfigure every installed package, and the
        retired WMI cmdlet is banned (absent in PowerShell 7). Under
        elevation HKCU is the ADMIN's hive, so the interactive user's
        entries come via Get-WtConsoleUserSid; with no SID the row says so
        rather than quietly showing a short list. Injected results are
        captured as @($raw), never @(& $Action), which would double-wrap a
        comma-protected array.
    #>
    param(
        [scriptblock]$GetUninstallEntries = {
            param($Path)
            $out = New-Object System.Collections.Generic.List[object]
            foreach ($k in @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue)) {
                $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if ($props) { $out.Add($props) }
            }
            return , $out.ToArray()
        },
        [scriptblock]$GetUserSid = { Get-WtConsoleUserSid },
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $roots = @()
    try { $roots = @(Get-WtUninstallRegistryRoots -GetUserSid $GetUserSid) } catch { $roots = @() }
    $hasUserHive = $false
    foreach ($root in $roots) {
        if ([string]::Equals([string]$root.ScopeKey, 'UninstallScopeUser', [System.StringComparison]::Ordinal)) { $hasUserHive = $true; break }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $skipReleaseTypes = @('Security Update', 'Update', 'Hotfix', 'ServicePack')
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($root in $roots) {
        $entries = @()
        try {
            $raw = & $GetUninstallEntries $root.Path
            $entries = if ($null -eq $raw) { @() } else { @($raw) }
        }
        catch { $entries = @() }
        foreach ($entry in $entries) {
            if (-not $entry) { continue }
            $name = [string]$entry.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (('' + $entry.SystemComponent) -ceq '1') { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.ParentKeyName)) { continue }
            $release = [string]$entry.ReleaseType
            $isUpdate = $false
            foreach ($type in $skipReleaseTypes) {
                if ([string]::Equals($type, $release, [System.StringComparison]::OrdinalIgnoreCase)) { $isUpdate = $true; break }
            }
            if ($isUpdate) { continue }
            $version = [string]$entry.DisplayVersion
            if (-not $seen.Add($name + '|' + $version)) { continue }
            $rows.Add([PSCustomObject]@{
                    SortKey   = $name.ToUpperInvariant()
                    Name      = $name
                    Version   = $version
                    Publisher = [string]$entry.Publisher
                })
        }
    }

    if ($rows.Count -eq 0) {
        $lines.Add((Get-Translation 'InstalledProgramsNone'))
        if (-not $hasUserHive) { $lines.Add((Get-Translation 'InstalledProgramsNoUserHive')) }
        return [string[]]$lines.ToArray()
    }

    $verWidth = 14
    $pubWidth = 24
    $nameWidth = [Math]::Max(20, $Width - $verWidth - $pubWidth - 2)
    $total = $nameWidth + $verWidth + $pubWidth + 2

    $lines.Add(((Get-Translation 'InstalledProgramsCount') -f $rows.Count))
    if (-not $hasUserHive) { $lines.Add((Get-Translation 'InstalledProgramsNoUserHive')) }
    $lines.Add('')
    $lines.Add((((Format-WtSoftwareCell -Text 'Name' -Width $nameWidth) + ' ' + (Format-WtSoftwareCell -Text 'Version' -Width $verWidth) + ' ' + (Format-WtSoftwareCell -Text 'Publisher' -Width $pubWidth)).TrimEnd()))
    $lines.Add('-' * [Math]::Min($total, [Math]::Max(20, $Width)))
    foreach ($row in ($rows | Sort-Object -Property SortKey)) {
        $lines.Add((((Format-WtSoftwareCell -Text $row.Name -Width $nameWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Version -Width $verWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Publisher -Width $pubWidth)).TrimEnd()))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'InstalledProgramsFootnote'))
    return [string[]]$lines.ToArray()
}

# ---- Get-WtInstalledUpdatesLines (lines 33614-33675) ----
function Get-WtInstalledUpdatesLines {
    <#
    .SYNOPSIS
        PURE-FRONTED: which KB updates are installed and when - the first
        thing to look at when a problem "started after an update". An
        empty or unparsable InstalledOn sorts last rather than throwing.
        Store apps and driver updates are not in this source at all; the
        footnote says so. The table is a fixed ~69 columns, so unlike the
        program and startup tables it needs no width measurement.
    #>
    param(
        [scriptblock]$GetHotFixes = { Get-HotFix -ErrorAction Stop }
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $items = @()
    try {
        $raw = & $GetHotFixes
        $items = if ($null -eq $raw) { @() } else { @($raw) }
    }
    catch {
        $lines.Add((Get-Translation 'InstalledUpdatesNotAvailable'))
        return [string[]]$lines.ToArray()
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if (-not $item) { continue }
        $installed = $null
        if ($item.InstalledOn -is [datetime]) { $installed = [datetime]$item.InstalledOn }
        $rows.Add([PSCustomObject]@{
                SortStamp   = $(if ($installed) { $installed } else { [datetime]::MinValue })
                HotFixID    = [string]$item.HotFixID
                Description = [string]$item.Description
                Installed   = $(if ($installed) { $installed.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } else { '-' })
                InstalledBy = [string]$item.InstalledBy
            })
    }

    if ($rows.Count -eq 0) {
        $lines.Add((Get-Translation 'InstalledUpdatesNone'))
        $lines.Add((Get-Translation 'InstalledUpdatesFootnote'))
        return [string[]]$lines.ToArray()
    }

    $idWidth = 12
    $descWidth = 20
    $dateWidth = 12
    $byWidth = 22

    $lines.Add(((Get-Translation 'InstalledUpdatesCount') -f $rows.Count))
    $lines.Add('')
    $lines.Add((((Format-WtSoftwareCell -Text 'HotFixID' -Width $idWidth) + ' ' + (Format-WtSoftwareCell -Text 'Type' -Width $descWidth) + ' ' + (Format-WtSoftwareCell -Text 'Installed' -Width $dateWidth) + ' ' + (Format-WtSoftwareCell -Text 'Installed by' -Width $byWidth)).TrimEnd()))
    $lines.Add('-' * ($idWidth + $descWidth + $dateWidth + $byWidth + 3))
    foreach ($row in ($rows | Sort-Object -Property SortStamp -Descending)) {
        $lines.Add((((Format-WtSoftwareCell -Text $row.HotFixID -Width $idWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Description -Width $descWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Installed -Width $dateWidth) + ' ' + (Format-WtSoftwareCell -Text $row.InstalledBy -Width $byWidth)).TrimEnd()))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'InstalledUpdatesFootnote'))
    return [string[]]$lines.ToArray()
}

# ---- Get-WtInteractiveUserName (lines 21-40) ----
function Get-WtInteractiveUserName {
    <#
    .SYNOPSIS
        The owner of the console session as DOMAIN\User, or '' when it
        cannot be read. Win32_ComputerSystem.UserName reports who is
        sitting at the machine regardless of what identity this process
        runs as, unlike $env:USERNAME under Start-Process -Verb RunAs.
        Never throws.
    #>
    param(
        [scriptblock]$GetConsoleUser = {
            (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        }
    )
    $owner = $null
    try { $owner = & $GetConsoleUser }
    catch { return '' }
    if ([string]::IsNullOrWhiteSpace([string]$owner)) { return '' }
    return ([string]$owner).Trim()
}

# ---- Get-WtInteractiveUserTaskApi (lines 130-170) ----
function Get-WtInteractiveUserTaskApi {
    <#
    .SYNOPSIS
        The five Task Scheduler calls the runner needs, in one place, so
        every test can replace them together. Register-ScheduledTask with
        -LogonType Interactive and -RunLevel Limited builds the token from
        the principal rather than from whoever registered the task, so a
        task registered by an elevated process still runs at medium
        integrity in the user's own session, without needing a password.
    #>
    return @{
        Register = {
            param($Context)
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Context.ShimPath + '"')
            $principal = New-ScheduledTaskPrincipal -UserId $Context.UserName `
                -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::FromSeconds([Math]::Max(60, $Context.TimeoutSeconds)))
            $null = Register-ScheduledTask -TaskName $Context.TaskName -Action $action `
                -Principal $principal -Settings $settings -Force
        }
        Start    = { param($Context) Start-ScheduledTask -TaskName $Context.TaskName }
        State    = {
            param($Context)
            $task = Get-ScheduledTask -TaskName $Context.TaskName -ErrorAction SilentlyContinue
            if ($null -eq $task) { return '' }
            return [string]$task.State
        }
        Result   = {
            param($Context)
            $info = Get-ScheduledTaskInfo -TaskName $Context.TaskName -ErrorAction SilentlyContinue
            if ($null -eq $info) { return $null }
            return $info.LastTaskResult
        }
        Remove   = {
            param($Context)
            Unregister-ScheduledTask -TaskName $Context.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

# ---- Get-WtInternetTestPlanLines (lines 32546-32572) ----
function Get-WtInternetTestPlanLines {
    <#
    .SYNOPSIS
        The disclosure this row ships on: the complete list of hosts the
        connectivity test is about to contact, written before anything is
        contacted. Deliberately pure and source-free - no data source
        parameter, since taking none is what guarantees this can print
        first. DNS and ICMP only; no HTTP request, no payload about this
        machine, and the ISP name is never looked up (that would need an
        HTTP-based whois service).
    #>
    param(
        [string]$ResolverHost = 'resolver1.opendns.com',
        [string[]]$PingTargets = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'InternetTestDisclosure'))
    $lines.Add('')
    $lines.Add(('  - ' + ((Get-Translation 'InternetTestHostResolver') -f $ResolverHost)))
    foreach ($target in $PingTargets) {
        $lines.Add(('  - ' + ((Get-Translation 'InternetTestHostPing') -f $target)))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'InternetTestNoHttp'))
    $lines.Add('')
    return [string[]]$lines.ToArray()
}

# ---- Get-WtInternetTestResultLines (lines 32574-32632) ----
function Get-WtInternetTestResultLines {
    <#
    .SYNOPSIS
        The public IP address and the round-trip latency to three public
        resolvers - is the line up, and how does this machine look from
        outside. The public IP comes from one DNS query (myip.opendns.com
        against resolver1.opendns.com), not an HTTP request, so nothing
        about this machine is uploaded; the ISP name is never attempted
        for the same reason. Every failure is written as a failure, never
        an empty line. Windows PowerShell 5.1 returns Win32_PingStatus
        (StatusCode/ResponseTime); PowerShell 7 returns a wrapper with
        Latency - both shapes are read.
    #>
    param(
        [scriptblock]$GetPublicIp = { Resolve-DnsName -Name 'myip.opendns.com' -Server 'resolver1.opendns.com' -Type A -ErrorAction Stop },
        [scriptblock]$PingTarget = { param($Target) Test-Connection -ComputerName $Target -Count 4 -ErrorAction SilentlyContinue },
        [string[]]$PingTargets = @('1.1.1.1', '8.8.8.8', '9.9.9.9'),
        [int]$PingCount = 4
    )
    $lines = New-Object System.Collections.Generic.List[string]

    $publicIp = ''
    try {
        foreach ($record in @(& $GetPublicIp)) {
            if ($null -eq $record) { continue }
            if (-not ($record.PSObject.Properties.Name -contains 'IPAddress')) { continue }
            if ([string]$record.IPAddress) { $publicIp = [string]$record.IPAddress; break }
        }
    }
    catch { $publicIp = '' }
    if ($publicIp) { $lines.Add(('{0}: {1}' -f (Get-Translation 'InternetTestPublicIpLabel'), $publicIp)) }
    else { $lines.Add((Get-Translation 'InternetTestPublicIpFailed')) }

    $lines.Add('')
    $lines.Add((Get-Translation 'InternetTestLatencyHeader'))
    foreach ($target in $PingTargets) {
        $replies = @()
        try { $replies = @(@(& $PingTarget $target) | Where-Object { $_ }) }
        catch { $replies = @() }
        $times = New-Object System.Collections.Generic.List[double]
        foreach ($reply in $replies) {
            $props = $reply.PSObject.Properties.Name
            if (($props -contains 'StatusCode') -and ($null -ne $reply.StatusCode) -and ([int]$reply.StatusCode -ne 0)) { continue }
            $value = $null
            if (($props -contains 'ResponseTime') -and ($null -ne $reply.ResponseTime)) { $value = [double]$reply.ResponseTime }
            elseif (($props -contains 'Latency') -and ($null -ne $reply.Latency)) { $value = [double]$reply.Latency }
            if ($null -ne $value) { $times.Add($value) }
        }
        if ($times.Count -eq 0) {
            $lines.Add(('  ' + ((Get-Translation 'InternetTestLatencyFailed') -f $target)))
            continue
        }
        $sum = 0.0
        foreach ($t in $times) { $sum += $t }
        $average = [math]::Round($sum / $times.Count)
        $lines.Add(('  ' + ((Get-Translation 'InternetTestLatencyLine') -f $target, $times.Count, $PingCount, $average)))
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtIpConfigSummaryLines (lines 32184-32222) ----
function Get-WtIpConfigSummaryLines {
    <#
    .SYNOPSIS
        One block per live adapter: IPv4 address with prefix, default
        gateway, DNS servers. Replaces the bare ipconfig row - the same
        answer, narrow enough to read in the panel without truncation;
        the verbose ipconfig /all row stays as the fallback. DNSServer
        holds one record per address family, so an IPv6-only resolver
        set is called out rather than shown as an empty cell.
    #>
    param(
        [scriptblock]$GetConfiguration = { Get-NetIPConfiguration -ErrorAction SilentlyContinue }
    )
    $configs = @()
    try { $configs = @(& $GetConfiguration) } catch { $configs = @() }
    if ($configs.Count -eq 0) { return [string[]]@((Get-Translation 'NoNetworkAdapterFound')) }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($config in $configs) {
        $lines.Add([string]$config.InterfaceAlias)

        $v4 = @($config.IPv4Address)
        $address = if ($v4.Count -gt 0) { (@($v4 | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })) -join ', ' } else { '-' }

        $gw = @($config.IPv4DefaultGateway)
        $gateway = if ($gw.Count -gt 0) { (@($gw | ForEach-Object { [string]$_.NextHop })) -join ', ' } else { '-' }

        $v4Dns = @($config.DNSServer | Where-Object { $_.AddressFamily -eq 2 })
        $dns = if ($v4Dns.Count -gt 0 -and @($v4Dns[0].ServerAddresses).Count -gt 0) { (@($v4Dns[0].ServerAddresses)) -join ', ' }
        elseif (@($config.DNSServer).Count -gt 0) { Get-Translation 'DnsIpv6Only' }
        else { '-' }

        $lines.Add(('  IPv4    : {0}' -f $address))
        $lines.Add(('  Gateway : {0}' -f $gateway))
        $lines.Add(('  DNS     : {0}' -f $dns))
        $lines.Add('')
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtItemGroup (lines 8727-8731) ----
function Get-WtItemGroup {
    param([Parameter(Mandatory)][PSCustomObject]$Item)
    if ($Item.PSObject.Properties.Name -contains 'Group' -and $Item.Group) { return [string]$Item.Group }
    return ''
}

# ---- Get-WtLargestFilesReportLines (lines 33909-33985) ----
function Get-WtLargestFilesReportLines {
    <#
    .SYNOPSIS
        The forgotten ISO or VM disk the folder view hides: files over
        100 MB under one path, biggest first. Top-level directories are
        walked one by one with a heartbeat per subtree, since a single
        "Get-ChildItem -Recurse | Sort-Object" pipeline emits nothing
        until it finishes. ReparsePoint entries are skipped so a
        junction cannot list the same file twice; long paths are cut
        from the LEFT.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$Top = 25,
        [long]$MinSizeBytes = 104857600,
        [scriptblock]$TestRoot = { param($Path) Test-Path -LiteralPath $Path -PathType Container },
        [scriptblock]$GetTopLevel = {
            param($Path)
            $dir = [System.IO.DirectoryInfo]$Path
            return @{ Directories = @($dir.GetDirectories()); Files = @($dir.GetFiles()) }
        },
        [scriptblock]$GetBigFiles = { param($Path, $MinBytes) Get-WtBigFileList -Path $Path -MinSizeBytes $MinBytes },
        [scriptblock]$WriteLine = { param($Text) Write-Host $Text }
    )
    if (-not (& $TestRoot $Root)) {
        return [string[]]@(('{0}: {1}' -f (Get-Translation 'FolderNotFound'), $Root))
    }

    & $WriteLine ((Get-Translation 'LargestFilesHeader') -f $Root)
    & $WriteLine (Get-Translation 'ScanResultsBelow')
    & $WriteLine ''

    $entries = $null
    try { $entries = & $GetTopLevel $Root }
    catch { $entries = $null }
    if ($null -eq $entries) {
        return [string[]]@((Get-Translation 'LargestFilesNone'))
    }

    $found = [System.Collections.Generic.List[object]]::new()
    $unreadable = 0
    foreach ($f in @($entries.Files)) {
        if ([long]$f.Length -lt $MinSizeBytes) { continue }
        $found.Add([PSCustomObject]@{ Path = [string]$f.FullName; Length = [long]$f.Length })
    }

    $reparse = [System.IO.FileAttributes]::ReparsePoint
    foreach ($d in @($entries.Directories)) {
        if (([System.IO.FileAttributes]$d.Attributes -band $reparse) -eq $reparse) { continue }
        $result = & $GetBigFiles ([string]$d.FullName) $MinSizeBytes
        $unreadable += [int]$result.Skipped
        foreach ($hit in @($result.Files)) {
            $found.Add([PSCustomObject]@{ Path = [string]$hit.Path; Length = [long]$hit.Length })
        }
        & $WriteLine ('  ' + (((Get-Translation 'ScanningFolder') -f [string]$d.Name)) + '  ' + @($result.Files).Count)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('')
    $lines.Add(((Get-Translation 'LargestFilesHeader') -f $Root))
    $lines.Add('')
    if ($found.Count -eq 0) {
        $lines.Add((Get-Translation 'LargestFilesNone'))
    }
    else {
        $rank = 0
        foreach ($hit in @(@($found.ToArray()) | Sort-Object -Property Length -Descending | Select-Object -First $Top)) {
            $rank++
            $lines.Add(('{0,2}. {1,10}  {2}' -f $rank, (Format-WtByteSize -Bytes ([long]$hit.Length)), (Format-WtLeftTruncatedPath -Path ([string]$hit.Path) -Width 54)))
        }
    }
    if ($unreadable -gt 0) {
        $lines.Add('')
        $lines.Add(((Get-Translation 'ScanSkippedFolders') -f $unreadable))
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtLargestFoldersReportLines (lines 33745-33829) ----
function Get-WtLargestFoldersReportLines {
    <#
    .SYNOPSIS
        "What ate my C: drive": the top-level folders under one path,
        biggest first, streamed with a heartbeat per folder before the
        ranking (Invoke-WtCapturedAction only repaints on output, and the
        ranking prints last, which is why the header says to press End).
        The result list is deliberately not named the same as the
        caller's own collector: the injected -MeasureFolder / -WriteLine
        scriptblocks are dynamically scoped, so a same-named local here
        would silently swallow the caller's own Adds. Top-level
        ReparsePoint entries are skipped so a profile's junctions do not
        double-count bytes.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$Top = 20,
        [scriptblock]$TestRoot = { param($Path) Test-Path -LiteralPath $Path -PathType Container },
        [scriptblock]$GetTopLevel = {
            param($Path)
            $dir = [System.IO.DirectoryInfo]$Path
            return @{ Directories = @($dir.GetDirectories()); Files = @($dir.GetFiles()) }
        },
        [scriptblock]$MeasureFolder = { param($Path) Get-WtFolderUsage -Path $Path },
        [scriptblock]$WriteLine = { param($Text) Write-Host $Text }
    )
    if (-not (& $TestRoot $Root)) {
        return [string[]]@(('{0}: {1}' -f (Get-Translation 'FolderNotFound'), $Root))
    }

    & $WriteLine ((Get-Translation 'LargestFoldersHeader') -f $Root)
    & $WriteLine (Get-Translation 'ScanResultsBelow')
    & $WriteLine ''

    $entries = $null
    try { $entries = & $GetTopLevel $Root }
    catch { $entries = $null }
    if ($null -eq $entries) {
        return [string[]]@((Get-Translation 'LargestFoldersNone'))
    }

    $rootBytes = 0L
    $rootFiles = 0
    foreach ($f in @($entries.Files)) {
        $rootBytes += [long]$f.Length
        $rootFiles++
    }

    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $folderTotals = [System.Collections.Generic.List[object]]::new()
    $unreadable = 0
    foreach ($d in @($entries.Directories)) {
        if (([System.IO.FileAttributes]$d.Attributes -band $reparse) -eq $reparse) { continue }
        $usage = & $MeasureFolder ([string]$d.FullName)
        $unreadable += [int]$usage.Skipped
        $folderTotals.Add([PSCustomObject]@{ Name = [string]$d.Name; Bytes = [long]$usage.Bytes; Files = [int]$usage.Files })
        & $WriteLine ('  ' + (((Get-Translation 'ScanningFolder') -f [string]$d.Name)) + '  ' + (Format-WtByteSize -Bytes ([long]$usage.Bytes)))
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('')
    $lines.Add(((Get-Translation 'LargestFoldersHeader') -f $Root))
    $lines.Add('')
    if ($folderTotals.Count -eq 0 -and $rootFiles -eq 0) {
        $lines.Add((Get-Translation 'LargestFoldersNone'))
        return [string[]]$lines.ToArray()
    }
    $rank = 0
    foreach ($m in @(@($folderTotals.ToArray()) | Sort-Object -Property Bytes -Descending | Select-Object -First $Top)) {
        $rank++
        $lines.Add(('{0,2}. {1,10}  {2}' -f $rank, (Format-WtByteSize -Bytes $m.Bytes), (Format-WtLeftTruncatedPath -Path $m.Name -Width 54)))
    }
    $totalBytes = $rootBytes
    foreach ($m in @($folderTotals.ToArray())) { $totalBytes += [long]$m.Bytes }
    if ($rootFiles -gt 0) {
        $lines.Add('')
        $lines.Add(('  {0} ({1}): {2}' -f (Get-Translation 'ScanRootFiles'), $rootFiles, (Format-WtByteSize -Bytes $rootBytes)))
    }
    $lines.Add('')
    $lines.Add(((Get-Translation 'ScanTotalMeasured') -f (Format-WtByteSize -Bytes $totalBytes), $folderTotals.Count))
    if ($unreadable -gt 0) {
        $lines.Add(((Get-Translation 'ScanSkippedFolders') -f $unreadable))
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtLicenseInfoLines (lines 27920-27938) ----
function Get-WtLicenseInfoLines {
    <#
    .SYNOPSIS
        Windows activation summary (/xpr) and detailed license info (/dlv)
        as console lines via cscript //nologo - slmgr under wscript pops a
        GUI dialog per call, which a terminal tool must never do.
    #>
    param(
        [scriptblock]$RunSlmgrAction = { param($Switch) cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" $Switch }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($switch in '/xpr', '/dlv') {
        foreach ($line in @(& $RunSlmgrAction $switch)) {
            if ($null -ne $line -and ([string]$line).Trim()) { $lines.Add([string]$line) }
        }
        $lines.Add('')
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtListeningPortLines (lines 32224-32259) ----
function Get-WtListeningPortLines {
    <#
    .SYNOPSIS
        Every TCP port this machine listens on, joined to the program that
        owns it. Replaces the netstat -an row outright: netstat prints the
        ports with no owning process, which is the one column that makes
        the output actionable. The PID->name map uses an explicit loop,
        since Group-Object -AsHashTable's PSObject collections only index
        correctly by accident; a listener reported once per address
        family is deduplicated to one row per port+PID.
    #>
    param(
        [scriptblock]$GetListeners = { Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue },
        [scriptblock]$GetProcesses = { Get-Process -ErrorAction SilentlyContinue }
    )
    $listeners = @()
    try { $listeners = @(& $GetListeners) } catch { $listeners = @() }
    if ($listeners.Count -eq 0) { return [string[]]@((Get-Translation 'NoListeningPort')) }

    $processes = @()
    try { $processes = @(& $GetProcesses) } catch { $processes = @() }
    $names = @{}
    foreach ($process in $processes) { $names[[int]$process.Id] = [string]$process.ProcessName }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0,-7} {1,-8} {2}' -f 'Port', 'PID', 'Process'))
    foreach ($listener in @($listeners | Sort-Object LocalPort)) {
        $key = '{0}|{1}' -f $listener.LocalPort, $listener.OwningProcess
        if (-not $seen.Add($key)) { continue }
        $pidValue = [int]$listener.OwningProcess
        $name = if ($names.ContainsKey($pidValue)) { $names[$pidValue] } else { Get-Translation 'UnknownProcess' }
        $lines.Add(('{0,-7} {1,-8} {2}' -f $listener.LocalPort, $pidValue, $name))
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtListRowLabelRoom (lines 6471-6493) ----
function Get-WtListRowLabelRoom {
    <#
    .SYNOPSIS
        PURE: how many characters this row's label may use at the given
        inner width - the same arithmetic Get-WtListRowSegments lays the
        row out with, exposed so callers can WRAP text to fit instead of
        letting the renderer cut it with '~'.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs,
        [Parameter(Mandatory)][int]$Width,
        [int]$VisibleNumber = 0,
        [int]$StateWidth = 0,
        [int]$NumberWidth = 1
    )
    $marker = if ($Item.Kind -eq 'Check' -or $Item.Kind -eq 'Radio') { 3 } else { 0 }
    $number = if ($VisibleNumber -gt 0) { [Math]::Max(1, $NumberWidth) + 2 } else { 0 }
    $right = (Get-WtListRowRightParts -Item $Item -StateWidth $StateWidth).Text
    $room = $Width - $Glyphs.Cursor.Length - $number - $marker - 1 - $right.Length - 2
    if ($room -lt 4) { $room = 4 }
    return $room
}

# ---- Get-WtListRowNaturalWidth (lines 6567-6590) ----
function Get-WtListRowNaturalWidth {
    <#
    .SYNOPSIS
        Columns one row needs so Get-WtListRowSegments shows its label
        untruncated: cursor + the right-aligned number column + marker +
        space + label + two spaces + risk/state. Mirrors that function's
        layout math (same NumberWidth); the compact box is sized from the
        widest row.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs,
        [int]$StateWidth = 0,
        [int]$NumberWidth = 1
    )
    $label = [string]$Item.Label
    if ($Item.Kind -eq 'Spacer') { return 0 }
    if ($Item.Kind -eq 'Header') { return 2 + $label.Length }
    if ($Item.Kind -eq 'Rule') { return 5 + $label.Length + 4 }
    $marker = if ($Item.Kind -eq 'Check' -or $Item.Kind -eq 'Radio') { 3 } else { 0 }
    $right = (Get-WtListRowRightParts -Item $Item -StateWidth $StateWidth).Text
    $gap = if ($right) { 2 } else { 0 }
    return $Glyphs.Cursor.Length + [Math]::Max(1, $NumberWidth) + 2 + $marker + 1 + $label.Length + $gap + $right.Length
}

# ---- Get-WtListRowRightParts (lines 6427-6469) ----
function Get-WtListRowRightParts {
    <#
    .SYNOPSIS
        PURE: builds the right-hand part of a list row as two
        fixed-width columns so rows line up - the risk tag right-aligned
        to the widest localized tag, then the state left-aligned and
        padded to the wider of the Applied/NotApplied labels. A row
        missing risk or state still reserves that column, unless no row
        on the screen has a state column at all (StateWidth 0), in which
        case nothing is reserved. PendingVerbKey lets a marked row show
        its own pending action (e.g. "Kaldirilacak") without touching
        Applied, which still decides direction and markability.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [int]$StateWidth = 0,
        [bool]$Selected = $false,
        [string]$PendingLabel = ''
    )
    $metrics = $script:WtRowColumnCache[[string]$script:Language]
    if ($null -eq $metrics) { $metrics = Get-WtRowColumnMetrics }
    $showTag = (-not ($Item.PSObject.Properties.Name -contains 'RiskTag')) -or [bool]$Item.RiskTag
    $riskRaw = ''
    if ($Item.Risk -and $showTag) {
        $riskKey = [string]$Item.Risk
        $riskText = $(if ($metrics.RiskLabels.ContainsKey($riskKey)) { [string]$metrics.RiskLabels[$riskKey] } else { [string](Get-WtRiskLabel -Risk $riskKey) })
        $riskRaw = '[' + $riskText + ']'
    }
    $stateRaw = [string]$Item.StateLabel
    if ($Selected -and $Item.Kind -eq 'Check' -and $PendingLabel) { $stateRaw = '-> ' + $PendingLabel }
    elseif ($Selected -and $Item.Kind -eq 'Check' -and $stateRaw) {
        $applied = ($Item.PSObject.Properties.Name -contains 'Applied') -and [bool]$Item.Applied
        $verbKey = if (($Item.PSObject.Properties.Name -contains 'PendingVerbKey') -and $Item.PendingVerbKey) { [string]$Item.PendingVerbKey }
                   elseif ($applied) { 'WillRemove' } else { 'WillApply' }
        $stateRaw = Get-Translation $verbKey
    }
    if (-not $riskRaw -and -not $stateRaw) { return @{ Risk = ''; State = ''; Text = '' } }
    $risk = $riskRaw.PadLeft([int]$metrics.RiskWidth)
    if (-not $stateRaw -and $StateWidth -le 0) { return @{ Risk = $risk; State = ''; Text = $risk } }
    $stateWidth = [Math]::Max($StateWidth, [int]$metrics.StateFloor)
    $state = $stateRaw.PadRight($stateWidth)
    return @{ Risk = $risk; State = $state; Text = ($risk + '  ' + $state) }
}

# ---- Get-WtListRowSegments (lines 6329-6425) ----
function Get-WtListRowSegments {
    <#
    .SYNOPSIS
        Renders one list row into colored segments:
        "{cursor}{number}{marker} {label}  [{risk}]  {state}", truncated
        to fit Width. A marked row shows [x], its pending verb
        (WillApply/WillRemove) instead of the live state, and its state
        column as one solid yellow block instead of vocabulary-coloured.
        Get-WtListRowLabelRoom mirrors this layout arithmetic for callers
        that wrap instead of truncate. NumberWidth right-aligns the row
        number so numbering past 9 still keeps markers and columns
        aligned; unnumbered callers leave it at its 1-digit default.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [Parameter(Mandatory)][bool]$IsCursor,
        [Parameter(Mandatory)][bool]$Selected,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs,
        [Parameter(Mandatory)][int]$Width,
        [int]$VisibleNumber = 0,
        [int]$StateWidth = 0,
        [int]$NumberWidth = 1,
        [string]$PendingLabel = ''
    )

    if ($Item.Kind -eq 'Spacer') { return ,@([PSCustomObject]@{ T = ''; F = 'Gray'; B = '' }) }

    if ($Item.Kind -eq 'Header') {
        $text = '  ' + $Item.Label
        if ($text.Length -gt $Width) { $text = $text.Substring(0, $Width) }
        return ,@([PSCustomObject]@{ T = $text; F = 'Cyan'; B = '' })
    }

    if ($Item.Kind -eq 'Rule') {
        $rule = [string]$Glyphs.Rule
        $lead = '  ' + ($rule * 2) + ' '
        $title = [string]$Item.Label
        $room = $Width - $lead.Length - 2
        if ($title.Length -gt $room -and $room -gt 1) { $title = $title.Substring(0, $room - 1) + '~' }
        $tail = ' ' + ($rule * [Math]::Max(0, $Width - $lead.Length - $title.Length - 1))
        return @(([PSCustomObject]@{ T = $lead; F = 'DarkGray'; B = '' }), ([PSCustomObject]@{ T = $title; F = 'Cyan'; B = '' }), ([PSCustomObject]@{ T = $tail; F = 'DarkGray'; B = '' }))
    }

    $marker = ''
    $applied = ($Item.PSObject.Properties.Name -contains 'Applied') -and [bool]$Item.Applied
    if ($Item.Kind -eq 'Check') { $marker = if ($Selected) { $Glyphs.CheckOn } else { $Glyphs.CheckOff } }
    elseif ($Item.Kind -eq 'Radio') { $marker = if ($Selected) { $Glyphs.RadioOn } else { $Glyphs.RadioOff } }

    $cursorMark = if ($IsCursor) { $Glyphs.Cursor } else { ' ' * $Glyphs.Cursor.Length }
    $numberText = if ($VisibleNumber -gt 0) { ('{0}.' -f $VisibleNumber).PadLeft([Math]::Max(1, $NumberWidth) + 1) + ' ' } else { '' }

    $parts = Get-WtListRowRightParts -Item $Item -StateWidth $StateWidth -Selected $Selected -PendingLabel $PendingLabel
    $riskText = $parts.Risk
    $stateText = $parts.State

    $rightText = $parts.Text
    $leftFixed = $cursorMark + $numberText + $marker + ' '
    $labelRoom = $Width - $leftFixed.Length - $rightText.Length - 2
    $label = [string]$Item.Label
    if ($labelRoom -lt $label.Length -and $rightText) {
        $riskText = $riskText.TrimStart()
        $rightText = ($riskText + '  ' + $stateText).Trim()
        $labelRoom = $Width - $leftFixed.Length - $rightText.Length - 2
    }
    if ($labelRoom -lt 4) { $labelRoom = 4 }
    if ($label.Length -gt $labelRoom) { $label = $label.Substring(0, $labelRoom - 1) + '~' }
    $label = $label.PadRight($labelRoom)

    $rowFg = switch ($Item.Risk) { 'ADVANCED' { 'Red' } 'CAUTION' { 'Yellow' } default { 'White' } }
    if ($Item.Kind -eq 'Info' -and -not $Item.Risk) { $rowFg = 'Gray' }

    if ($IsCursor) {
        $text = $leftFixed + $label + '  ' + $rightText
        if ($text.Length -gt $Width) { $text = $text.Substring(0, $Width) }
        if ($text.Length -lt $Width) { $text = $text.PadRight($Width) }
        return ,@([PSCustomObject]@{ T = $text; F = 'Black'; B = 'DarkCyan' })
    }

    $pending = ($Selected -and $Item.Kind -eq 'Check' -and $stateText.Trim())
    $stateFg = if ($pending) { 'Yellow' } elseif ($applied) { 'Green' } else { 'DarkGray' }
    $stateOnly = $rightText.Substring($riskText.Length)
    $stateSegs = if ($pending) { @([PSCustomObject]@{ T = $stateOnly; F = $stateFg; B = '' }) }
                 else { @(Get-WtStateSegmentsCached -Text $stateOnly -DefaultFg $stateFg) }
    if ($stateSegs.Count -eq 0) { $stateSegs = @([PSCustomObject]@{ T = $stateOnly; F = $stateFg; B = '' }) }
    $segs = @(
        [PSCustomObject]@{ T = ($leftFixed + $label + '  '); F = $rowFg; B = '' }
        [PSCustomObject]@{ T = $riskText; F = $rowFg; B = '' }
    ) + $stateSegs
    $totalLength = 0
    foreach ($s in $segs) { $totalLength += ([string]$s.T).Length }
    if ($totalLength -gt $Width) {
        $total = ''
        foreach ($s in $segs) { $total += [string]$s.T }
        return ,@([PSCustomObject]@{ T = $total.Substring(0, $Width); F = $rowFg; B = '' })
    }
    return $segs
}

# ---- Get-WtListSearchEmptyItem (lines 8633-8655) ----
function Get-WtListSearchEmptyItem {
    <#
    .SYNOPSIS
        The one Info row a filter that matched nothing shows. The shape is
        New-WtListItem's, spelled out here so the TUI layer does not call
        up into the screens layer for it.
    #>
    return [PSCustomObject]@{
        Kind           = 'Info'
        Name           = 'ListSearchEmpty'
        Label          = [string](Get-Translation 'ListSearchEmpty')
        Risk           = $null
        StateLabel     = ''
        PendingVerbKey = ''
        Selectable     = $false
        Data           = $null
        Group          = ''
        Applied        = $false
        Removable      = $false
        RiskTag        = $true
        CycleTargets   = [string[]]@()
    }
}

# ---- Get-WtLocalAdministratorsLines (lines 33026-33075) ----
function Get-WtLocalAdministratorsLines {
    <#
    .SYNOPSIS
        PURE: exactly who holds administrator rights on this machine,
        Microsoft and domain accounts included. The group is addressed
        by its well-known SID, so the localized group name never
        matters. A documented Windows PowerShell 5.1 defect makes
        Get-LocalGroupMember throw instead of listing the rest when one
        member's SID no longer resolves (a deleted domain account); this
        falls back to the ADSI WinNT:// enumeration and the row says so.
    #>
    param(
        [scriptblock]$GetMembers = { Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop },
        [scriptblock]$GetFallbackMembers = { Get-WtAdsiGroupMemberNames -GroupSid 'S-1-5-32-544' }
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string](Get-Translation 'LocalAdminGroupHeader'))

    $members = $null
    $usedFallback = $false
    try { $members = @(& $GetMembers) }
    catch {
        $usedFallback = $true
        try { $members = @(& $GetFallbackMembers) }
        catch { $members = $null }
    }

    if ($null -eq $members -or $members.Count -eq 0) {
        if ($usedFallback) { $lines.Add([string](Get-Translation 'LocalAdminUnavailable')) }
        else { $lines.Add([string](Get-Translation 'LocalAdminNone')) }
        return [string[]]$lines.ToArray()
    }

    foreach ($member in $members) {
        $name = Format-WtSecurityValueOrUnknown -Value $member.Name
        $class = [string]$member.ObjectClass
        $source = [string]$member.PrincipalSource
        $classText = [string](Get-Translation ('LocalAdminObject.' + $class))
        if (-not $classText) { $classText = $class }
        $sourceText = [string](Get-Translation ('LocalAdminSource.' + $source))
        if (-not $sourceText) { $sourceText = $source }
        $tags = @(@($classText, $sourceText) | Where-Object { $_ })
        if ($tags.Count -gt 0) { $lines.Add(('  {0}  [{1}]' -f $name, ($tags -join ', '))) }
        else { $lines.Add(('  {0}' -f $name)) }
    }

    if ($usedFallback) { $lines.Add([string](Get-Translation 'LocalAdminFallbackNote')) }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtLocalUserTable (lines 32790-32801) ----
function Get-WtLocalUserTable {
    <#
    .SYNOPSIS
        Local accounts: Get-LocalUser when available (Windows PowerShell),
        the CIM Win32_UserAccount fallback under PowerShell 7 where the
        LocalAccounts module is not shipped.
    #>
    if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
        return Get-LocalUser | Select-Object Name, Enabled, LastLogon
    }
    return Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' | Select-Object Name, @{ Name = 'Enabled'; Expression = { -not $_.Disabled } }, SID
}

# ---- Get-WtMarkSummary (lines 6539-6565) ----
function Get-WtMarkSummary {
    <#
    .SYNOPSIS
        PURE: how many marked rows will be applied and how many removed
        (a marked row whose Applied flag is set is a removal), plus the
        formatted counter text. Raw rows (no Applied property on any
        Item at all - the non-apply multi-select pickers such as the DNS
        flush / duplicate finder / cleanup screens) have no direction to
        speak of, so the counter just says how many are marked.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Selection
    )
    $apply = 0
    $remove = 0
    $hasAppliedProperty = $false
    foreach ($item in $Items) {
        if ($item.PSObject.Properties.Name -contains 'Applied') { $hasAppliedProperty = $true }
        if (-not $Selection.Contains([string]$item.Name)) { continue }
        if (($item.PSObject.Properties.Name -contains 'Applied') -and [bool]$item.Applied) { $remove++ } else { $apply++ }
    }
    if (-not $hasAppliedProperty) {
        return @{ ApplyCount = $apply; RemoveCount = $remove; Text = ((Get-Translation 'MarkedCount') -f $Selection.Count) }
    }
    return @{ ApplyCount = $apply; RemoveCount = $remove; Text = (Format-WtDirectionCounts -ApplyCount $apply -RemoveCount $remove) }
}

# ---- Get-WtMemoryFlushCatalog (lines 24747-24794) ----
function Get-WtMemoryFlushCatalog {
    <#
    .SYNOPSIS
        The four individually-selectable Free Memory operations: three
        NtSetSystemInformation memory-list commands plus registry
        reconciliation. Working sets is CAUTION - emptying every process's
        working set makes applications stall briefly while pages fault
        back; the other three are transparent to running apps.
    #>
    return Resolve-WtCatalogText -KeyPrefix 'MemoryFlush' -Catalog @(
        [PSCustomObject]@{
            Name         = 'WorkingSets'
            DisplayLabel = 'Working sets (all processes)'
            Risk         = 'CAUTION'
            Consequence  = 'Applications may stall briefly while their pages reload'
            Operation    = 'MemoryList'
            Command      = 2
            Privilege    = 'SeProfileSingleProcessPrivilege'
        }
        [PSCustomObject]@{
            Name         = 'StandbyList'
            DisplayLabel = 'Standby list'
            Risk         = 'SAFE'
            Consequence  = $null
            Operation    = 'MemoryList'
            Command      = 4
            Privilege    = 'SeProfileSingleProcessPrivilege'
        }
        [PSCustomObject]@{
            Name         = 'ModifiedPageList'
            DisplayLabel = 'Modified page list'
            Risk         = 'SAFE'
            Consequence  = $null
            Operation    = 'MemoryList'
            Command      = 3
            Privilege    = 'SeProfileSingleProcessPrivilege'
        }
        [PSCustomObject]@{
            Name         = 'RegistryCache'
            DisplayLabel = 'Registry cache'
            Risk         = 'SAFE'
            Consequence  = $null
            Operation    = 'RegistryReconcile'
            Command      = $null
            Privilege    = $null
        }
    )
}

# ---- Get-WtMemoryModuleLines (lines 31391-31443) ----
function Get-WtMemoryModuleLines {
    <#
    .SYNOPSIS
        One line per physical memory stick (bank, capacity, DDR
        generation, speed, part number) plus free slots and the board's
        max capacity. The installed total sums Capacity, not
        Win32_ComputerSystem.TotalPhysicalMemory, which is the usable
        figure and would hide the firmware reservation. Sticks are told
        apart by BankLabel, since DeviceLocator can read 'DIMM 0' for both
        sticks on the same board.
    #>
    param(
        [scriptblock]$GetModules = { Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop },
        [scriptblock]$GetArrays = { Get-CimInstance -ClassName Win32_PhysicalMemoryArray -ErrorAction Stop }
    )
    $modules = @()
    try { $modules = @(& $GetModules) } catch { $modules = @() }
    if ($modules.Count -eq 0) { return [string[]]@((Get-Translation 'MemoryModuleNotAvailable')) }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'MemoryModuleHeader'))
    $installed = [long]0
    foreach ($m in $modules) {
        $capacity = [long]0
        if ($m.Capacity) { $capacity = [long]$m.Capacity }
        $installed += $capacity
        $slot = [string]$m.BankLabel
        if (-not $slot) { $slot = [string]$m.DeviceLocator }
        if (-not $slot) { $slot = '-' }
        $speedText = if ($m.Speed) { '{0} MHz' -f [int]$m.Speed } else { Get-Translation 'MemoryModuleSpeedUnknown' }
        $part = ([string]$m.PartNumber).Trim()
        if (-not $part) { $part = '-' }
        $lines.Add(('  {0}: {1} {2} {3} ({4})' -f $slot, (Format-WtByteSize -Bytes $capacity), (Get-WtMemoryTypeName -Module $m), $speedText, $part))
    }
    $lines.Add(((Get-Translation 'MemoryModuleTotalLine') -f (Format-WtByteSize -Bytes $installed), $modules.Count))

    $arrays = @()
    try { $arrays = @(& $GetArrays) } catch { $arrays = @() }
    $slots = 0
    $maxCapacityKb = [long]0
    foreach ($a in $arrays) {
        if ($a.MemoryDevices) { $slots += [int]$a.MemoryDevices }
        if ($a.MaxCapacityEx) { $maxCapacityKb += [long]$a.MaxCapacityEx }
    }
    if ($slots -gt 0) {
        $free = $slots - $modules.Count
        if ($free -lt 0) { $free = 0 }
        $lines.Add(((Get-Translation 'MemoryModuleSlotsLine') -f $slots, $free))
    }
    else { $lines.Add((Get-Translation 'MemoryModuleSlotsUnknown')) }
    if ($maxCapacityKb -gt 0) { $lines.Add(((Get-Translation 'MemoryModuleMaxLine') -f (Format-WtByteSize -Bytes ($maxCapacityKb * 1024)))) }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtMemoryTypeName (lines 31363-31389) ----
function Get-WtMemoryTypeName {
    <#
    .SYNOPSIS
        The DDR generation of one Win32_PhysicalMemory instance.
        SMBIOSMemoryType is authoritative; MemoryType is the fallback when
        firmware leaves SMBIOS at 0. An unrecognised number is printed raw
        rather than guessed.
    #>
    param([Parameter(Mandatory)][AllowNull()][object]$Module)
    $code = 0
    if ($Module.SMBIOSMemoryType) { $code = [int]$Module.SMBIOSMemoryType }
    elseif ($Module.MemoryType) { $code = [int]$Module.MemoryType }
    switch ($code) {
        20 { return 'DDR' }
        21 { return 'DDR2' }
        22 { return 'DDR2 FB-DIMM' }
        24 { return 'DDR3' }
        26 { return 'DDR4' }
        27 { return 'LPDDR' }
        28 { return 'LPDDR2' }
        29 { return 'LPDDR3' }
        30 { return 'LPDDR4' }
        34 { return 'DDR5' }
        35 { return 'LPDDR5' }
        default { return ((Get-Translation 'MemoryModuleTypeUnknown') -f $code) }
    }
}

# ---- Get-WtMotherboardBiosLines (lines 31691-31738) ----
function Get-WtMotherboardBiosLines {
    <#
    .SYNOPSIS
        Board maker, model, revision and serial, BIOS vendor / version /
        date, and the chassis type - what you need in front of you before
        a BIOS update. Win32_BIOS.SerialNumber is printed as the system
        serial.
    #>
    param(
        [scriptblock]$GetBoard = { Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1 },
        [scriptblock]$GetBios = { Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1 },
        [scriptblock]$GetEnclosure = { Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1 }
    )
    $board = $null
    try { $board = & $GetBoard } catch { $board = $null }
    $bios = $null
    try { $bios = & $GetBios } catch { $bios = $null }
    if (-not $board -and -not $bios) { return [string[]]@((Get-Translation 'BiosInfoUnavailable')) }

    $clean = { param($Value) ([string]$Value).Trim() }

    $lines = New-Object System.Collections.Generic.List[string]
    if ($board) {
        $lines.Add(('Board        : {0} {1}' -f (& $clean $board.Manufacturer), (& $clean $board.Product)))
        if (& $clean $board.Version) { $lines.Add(('Board Rev    : {0}' -f (& $clean $board.Version))) }
        if (& $clean $board.SerialNumber) { $lines.Add(('Board Serial : {0}' -f (& $clean $board.SerialNumber))) }
    }
    if ($bios) {
        $lines.Add(('BIOS         : {0} {1}' -f (& $clean $bios.Manufacturer), (& $clean $bios.SMBIOSBIOSVersion)))
        if ($bios.ReleaseDate) { $lines.Add(('BIOS Date    : {0}' -f ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd'))) }
        if (& $clean $bios.SerialNumber) { $lines.Add(('System Serial: {0}' -f (& $clean $bios.SerialNumber))) }
    }

    $enclosure = $null
    try { $enclosure = & $GetEnclosure } catch { $enclosure = $null }
    if ($enclosure -and @($enclosure.ChassisTypes).Count -gt 0) {
        $code = [int](@($enclosure.ChassisTypes)[0])
        $chassisNames = @{
            3 = 'Desktop'; 4 = 'Low Profile Desktop'; 5 = 'Pizza Box'; 6 = 'Mini Tower'; 7 = 'Tower'
            8 = 'Portable'; 9 = 'Laptop'; 10 = 'Notebook'; 11 = 'Hand Held'; 13 = 'All in One'
            14 = 'Sub Notebook'; 15 = 'Space-saving'; 16 = 'Lunch Box'; 17 = 'Main System Chassis'
            23 = 'Rack Mount Chassis'; 30 = 'Tablet'; 31 = 'Convertible'; 32 = 'Detachable'
        }
        $chassis = if ($chassisNames.ContainsKey($code)) { $chassisNames[$code] } else { "Chassis type $code" }
        $lines.Add(('Chassis      : {0}' -f $chassis))
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtNativeOutputEncoding (lines 37162-37182) ----
function Get-WtNativeOutputEncoding {
    <#
    .SYNOPSIS
        The encoding a captured native command's stdout must be decoded
        with: the console's REAL OEM code page, not what chcp reports.
        Nothing decoded anything while output went straight to the
        console, so this never mattered before; captured, a Turkish
        machine's ipconfig writes cp857 and decoding it as UTF-8 turns
        "Yerel Ag Baglantisi" into mojibake. Legacy console tools
        (ipconfig, systeminfo, chkdsk, netstat, sfc) write OEM bytes even
        when the console itself is on UTF-8; tools that really emit
        UTF-8 (winget and friends) get an explicit -Encoding from their
        caller instead of being guessed at here.
    #>
    param(
        [int]$OemCodePage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
    )
    try { return [System.Text.Encoding]::GetEncoding($OemCodePage) }
    catch { $null = $_ }
    return [Console]::OutputEncoding
}

# ---- Get-WtNetworkAdapterLines (lines 32262-32299) ----
function Get-WtNetworkAdapterLines {
    <#
    .SYNOPSIS
        One row per network adapter: status, negotiated link speed, MAC and
        media type - the answer to "is this cable running at 1 Gbps, or did
        it fall back to 100". Sorted Up-first (plain Status sort would put
        'Disconnected' first); the compare is -cne, since tr-TR's dotless-I
        rules make a case-insensitive match on 'Up' unreliable. Property
        names stay native English - no localized table headers. A
        Hyper-V virtual switch adapter's made-up 10 Gbps link is called
        out, not shown as a real interface speed.
    #>
    param(
        [scriptblock]$GetAdapters = { Get-NetAdapter -ErrorAction SilentlyContinue }
    )
    $adapters = @()
    try { $adapters = @(@(& $GetAdapters) | Where-Object { $_ }) }
    catch { $adapters = @() }
    if ($adapters.Count -eq 0) { return [string[]]@((Get-Translation 'NetAdapterNoneFound')) }

    $ordered = @($adapters | Sort-Object @{ Expression = { [int]([string]$_.Status -cne 'Up') } }, @{ Expression = { [string]$_.Name } })
    $lines = New-Object System.Collections.Generic.List[string]
    $table = ($ordered | Format-Table -Property Name, Status, LinkSpeed, MacAddress, MediaType -AutoSize | Out-String -Width 110)
    foreach ($row in ($table -split "`r?`n")) {
        if (([string]$row).Trim()) { $lines.Add(([string]$row).TrimEnd()) }
    }

    $hasVirtual = $false
    foreach ($a in $ordered) {
        $name = [string]$a.Name
        if ($name -and $name.IndexOf('vEthernet', [System.StringComparison]::Ordinal) -ge 0) { $hasVirtual = $true }
    }
    if ($hasVirtual) {
        $lines.Add('')
        $lines.Add((Get-Translation 'NetAdapterVirtualNote'))
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtNetworkProfileLines (lines 32358-32403) ----
function Get-WtNetworkProfileLines {
    <#
    .SYNOPSIS
        Is this network Public or Private, does Windows really see the
        internet, and which firewall profiles are on - the connection
        profile and the firewall profile folded into one row.
    #>
    param(
        [scriptblock]$GetConnectionProfiles = { Get-NetConnectionProfile -ErrorAction SilentlyContinue },
        [scriptblock]$GetFirewallProfiles = { Get-NetFirewallProfile -Profile Domain, Private, Public -ErrorAction SilentlyContinue }
    )
    $lines = New-Object System.Collections.Generic.List[string]

    $profiles = @()
    try { $profiles = @(@(& $GetConnectionProfiles) | Where-Object { $_ }) }
    catch { $profiles = @() }
    if ($profiles.Count -eq 0) {
        $lines.Add((Get-Translation 'NetProfileNoneFound'))
    }
    else {
        foreach ($p in $profiles) {
            $lines.Add(('{0}: {1} ({2})' -f (Get-Translation 'NetProfileNameLabel'), [string]$p.Name, [string]$p.InterfaceAlias))
            $lines.Add(('  {0}: {1}' -f (Get-Translation 'NetProfileCategoryLabel'), [string]$p.NetworkCategory))
            $lines.Add(('  {0}: {1}' -f (Get-Translation 'NetProfileIPv4Label'), [string]$p.IPv4Connectivity))
            $lines.Add(('  {0}: {1}' -f (Get-Translation 'NetProfileIPv6Label'), [string]$p.IPv6Connectivity))
        }
    }

    $lines.Add('')
    $lines.Add((Get-Translation 'FirewallProfilesHeader'))
    $firewall = @()
    try { $firewall = @(@(& $GetFirewallProfiles) | Where-Object { $_ }) }
    catch { $firewall = @() }
    if ($firewall.Count -eq 0) {
        $lines.Add(('  ' + (Get-Translation 'FirewallProfilesNotAvailable')))
    }
    else {
        foreach ($f in $firewall) {
            $state = if ([bool]$f.Enabled) { Get-Translation 'FirewallProfileOn' } else { Get-Translation 'FirewallProfileOff' }
            $lines.Add(('  {0}: {1}' -f [string]$f.Name, $state))
            $lines.Add(('    {0}: {1}' -f (Get-Translation 'FirewallInboundLabel'), (Get-WtFirewallActionText -Action ([string]$f.DefaultInboundAction) -Direction 'Inbound')))
            $lines.Add(('    {0}: {1}' -f (Get-Translation 'FirewallOutboundLabel'), (Get-WtFirewallActionText -Action ([string]$f.DefaultOutboundAction) -Direction 'Outbound')))
        }
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtNetworkResetPreviewLines (lines 25101-25131) ----
function Get-WtNetworkResetPreviewLines {
    <#
    .SYNOPSIS
        PURE: what the TCP/IP reset is about to erase - the static IPv4
        addresses and the DNS servers configured right now, shown before
        the confirmation gate. When a source is missing or throws, the
        "there is none" line is printed rather than an empty section.
    #>
    param(
        [scriptblock]$GetAddresses = { Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue },
        [scriptblock]$GetDnsServers = { Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'NetResetStaticHeader'))
    $statics = @()
    try { $statics = @(& $GetAddresses | Where-Object { [string]$_.PrefixOrigin -ceq 'Manual' }) }
    catch { $statics = @() }
    if ($statics.Count -eq 0) { $lines.Add('  ' + (Get-Translation 'NetResetNoStatic')) }
    else {
        foreach ($address in $statics) { $lines.Add(('  {0}: {1}/{2}' -f $address.InterfaceAlias, $address.IPAddress, $address.PrefixLength)) }
    }
    $lines.Add((Get-Translation 'NetResetDnsHeader'))
    $servers = @()
    try { $servers = @(& $GetDnsServers | Where-Object { @($_.ServerAddresses).Count -gt 0 }) }
    catch { $servers = @() }
    if ($servers.Count -eq 0) { $lines.Add('  ' + (Get-Translation 'NetResetNoDns')) }
    else {
        foreach ($entry in $servers) { $lines.Add(('  {0}: {1}' -f $entry.InterfaceAlias, (@($entry.ServerAddresses) -join ', '))) }
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtNextFocusableIndex (lines 8531-8550) ----
function Get-WtNextFocusableIndex {
    <#
    .SYNOPSIS
        The next focusable row index in the given direction (+1/-1),
        skipping Header/Info rows. Returns FromIndex unchanged when no
        focusable row exists in that direction (no wrap-around).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][int]$FromIndex,
        [Parameter(Mandatory)][ValidateSet(-1, 1)][int]$Direction
    )

    $i = $FromIndex + $Direction
    while ($i -ge 0 -and $i -lt $Items.Count) {
        if (Test-WtItemFocusable -Item $Items[$i]) { return $i }
        $i += $Direction
    }
    return $FromIndex
}

# ---- Get-WtNonMicrosoftTaskLines (lines 33519-33612) ----
function Get-WtNonMicrosoftTaskLines {
    <#
    .SYNOPSIS
        PURE-FRONTED: the scheduled tasks that did not ship with Windows -
        where updaters and adware live once the Startup list is clean.
        Actions[0].Execute is guarded, not assumed, since it comes back
        $null for ComHandler and SendEmail actions. LastRunTime of
        1899-11-30 means "never ran" - Task Scheduler's sentinel for no
        run - so only a year past 1900 counts as a real timestamp.
    #>
    param(
        [scriptblock]$GetTasks = { Get-ScheduledTask -ErrorAction Stop },
        [scriptblock]$GetTaskInfo = { param($Task) Get-ScheduledTaskInfo -InputObject $Task -ErrorAction SilentlyContinue },
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $all = @()
    try {
        $raw = & $GetTasks
        $all = if ($null -eq $raw) { @() } else { @($raw) }
    }
    catch {
        $lines.Add((Get-Translation 'ScheduledTasksNotAvailable'))
        return [string[]]$lines.ToArray()
    }

    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($task in $all) {
        if (-not $task) { continue }
        $taskPath = [string]$task.TaskPath
        if ($taskPath.StartsWith('\Microsoft\', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $tasks.Add($task)
    }

    if ($tasks.Count -eq 0) {
        $lines.Add((Get-Translation 'ScheduledTasksNone'))
        $lines.Add((Get-Translation 'ScheduledTasksFootnote'))
        return [string[]]$lines.ToArray()
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($task in $tasks) {
        $full = ([string]$task.TaskPath) + ([string]$task.TaskName)

        $program = ''
        $actions = @($task.Actions)
        if ($actions.Count -gt 0 -and $actions[0] -and ($actions[0].PSObject.Properties.Name -contains 'Execute')) {
            $program = [string]$actions[0].Execute
        }
        if ([string]::IsNullOrWhiteSpace($program)) { $program = '-' }

        $lastRun = '-'
        $info = $null
        try { $info = & $GetTaskInfo $task }
        catch { $info = $null }
        if ($info -and ($info.LastRunTime -is [datetime])) {
            if ($info.LastRunTime.Year -gt 1900) {
                $lastRun = $info.LastRunTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            }
        }

        $rows.Add([PSCustomObject]@{
                SortKey = $full.ToUpperInvariant()
                Path    = $full
                State   = [string]$task.State
                LastRun = $lastRun
                Program = $program
            })
    }

    $disabledCount = 0
    foreach ($row in $rows) {
        if ([string]::Equals($row.State, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase)) { $disabledCount++ }
    }
    $lines.Add(((Get-Translation 'ScheduledTasksCount') -f $rows.Count, ($rows.Count - $disabledCount), $disabledCount))
    $lines.Add('')

    $pathWidth = 34
    $stateWidth = 9
    $runWidth = 16
    $progWidth = [Math]::Max(16, $Width - $pathWidth - $stateWidth - $runWidth - 3)
    $total = $pathWidth + $stateWidth + $runWidth + $progWidth + 3

    $lines.Add((((Format-WtSoftwareCell -Text 'Task' -Width $pathWidth) + ' ' + (Format-WtSoftwareCell -Text 'State' -Width $stateWidth) + ' ' + (Format-WtSoftwareCell -Text 'Last run' -Width $runWidth) + ' ' + (Format-WtSoftwareCell -Text 'Program' -Width $progWidth)).TrimEnd()))
    $lines.Add('-' * [Math]::Min($total, [Math]::Max(20, $Width)))
    foreach ($row in ($rows | Sort-Object -Property SortKey)) {
        $lines.Add((((Format-WtSoftwareCell -Text $row.Path -Width $pathWidth) + ' ' + (Format-WtSoftwareCell -Text $row.State -Width $stateWidth) + ' ' + (Format-WtSoftwareCell -Text $row.LastRun -Width $runWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Program -Width $progWidth)).TrimEnd()))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'ScheduledTasksFootnote'))
    return [string[]]$lines.ToArray()
}

# ---- Get-WtNvidiaSmiTemperature (lines 27708-27746) ----
function Get-WtNvidiaSmiTemperature {
    <#
    .SYNOPSIS
        GPU temperature via nvidia-smi when the NVIDIA driver already ships
        it (never downloaded). $null when the tool is absent, the query
        fails, or the first line is not an integer - the report shows n/a.
    #>
    param(
        [scriptblock]$ResolveAction = {
            $command = Get-Command nvidia-smi -ErrorAction SilentlyContinue
            if ($command) { return $command.Source }
            $legacy = Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
            if ($env:ProgramFiles -and (Test-Path -LiteralPath $legacy)) { return $legacy }
            return $null
        },

        [scriptblock]$QueryAction = {
            param($Path)
            $output = & $Path --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -ne 0) { throw "nvidia-smi exit code $LASTEXITCODE" }
            return @($output)
        }
    )

    try {
        $path = & $ResolveAction
        if (-not $path) { return $null }

        $lines = @(& $QueryAction $path)
        if ($lines.Count -eq 0) { return $null }

        $first = "$($lines[0])".Trim()
        if ($first -match '^\d+$') { return [int]$first }
        return $null
    }
    catch {
        return $null
    }
}

# ---- Get-WtOptimizeVolumeCatalog (lines 23368-23419) ----
function Get-WtOptimizeVolumeCatalog {
    <#
    .SYNOPSIS
        Every fixed NTFS/ReFS volume that has a drive letter, in the
        Show-WtSelector catalog shape, carrying the media type Windows
        reports and the switch it earns.
    #>
    param(
        [scriptblock]$GetVolumes = { Get-Volume -ErrorAction SilentlyContinue },

        [scriptblock]$GetMediaType = {
            param($DriveLetter)
            try {
                $physical = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop |
                    Get-Disk -ErrorAction Stop |
                    Get-PhysicalDisk -ErrorAction Stop |
                    Select-Object -First 1
                if ($physical) { return [string]$physical.MediaType }
            }
            catch { return '' }
            return ''
        }
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($volume in @(& $GetVolumes)) {
        if (-not $volume.DriveLetter) { continue }
        if (([string]$volume.DriveType) -cne 'Fixed') { continue }
        $fileSystem = [string]$volume.FileSystem
        if (-not $fileSystem) { $fileSystem = [string]$volume.FileSystemType }
        if (($fileSystem -cne 'NTFS') -and ($fileSystem -cne 'ReFS')) { continue }

        $letter = ([string]$volume.DriveLetter).Substring(0, 1).ToUpperInvariant()
        $mediaType = [string](& $GetMediaType $letter)
        $mode = Get-WtVolumeOptimizeMode -MediaType $mediaType
        $modeLabel = if ($mode -ceq 'Defrag') { Get-Translation 'OptimizeModeDefrag' } else { Get-Translation 'OptimizeModeReTrim' }
        $mediaLabel = if ($mediaType) { $mediaType } else { Get-Translation 'StateUnknown' }

        $entries.Add([PSCustomObject]@{
            Name         = $letter
            DisplayLabel = ('{0}: {1} [{2}]' -f $letter, ([string]$volume.FileSystemLabel), $mediaLabel)
            Risk         = 'CAUTION'
            Consequence  = $null
            DriveLetter  = $letter
            MediaType    = $mediaType
            Mode         = $mode
            ModeLabel    = $modeLabel
        })
    }

    return $entries.ToArray()
}

# ---- Get-WtOutputTail (lines 37144-37160) ----
function Get-WtOutputTail {
    <#
    .SYNOPSIS
        PURE: the last Count lines, for the live progress panel. A
        running command's newest output is the interesting end, and
        Show-WtPanelMessage paints from the top with no scrolling, so
        the caller hands it a tail that fits instead of the whole log.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][int]$Count
    )
    $all = @($Lines)
    $take = [Math]::Max(1, $Count)
    if ($all.Count -le $take) { return $all }
    return @($all[($all.Count - $take)..($all.Count - 1)])
}

# ---- Get-WtPanelInnerWidth (lines 9151-9160) ----
function Get-WtPanelInnerWidth {
    <#
    .SYNOPSIS
        PURE: the widest inner area a box can offer on this console. A
        Compact box is never wider, so wrapping to this fits both
        layouts.
    #>
    param([Parameter(Mandatory)][int]$Width)
    return [Math]::Max(20, (Get-WtFrameWidth -Width $Width) - 4)
}

# ---- Get-WtPanelItems (lines 9010-9029) ----
function Get-WtPanelItems {
    <#
    .SYNOPSIS
        Plain text lines as non-focusable Info rows (one per line), with
        an optional risk so notices render red/yellow. Only the first
        line carries the risk tag, since a message wrapped over several
        rows is one message, not one per row.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [string]$Risk = ''
    )
    $items = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($l in @($Lines)) {
        $n++
        $items.Add((New-WtListItem -Kind 'Info' -Name ('Line:' + $n) -Label ([string]$l) -Risk $Risk -RiskTag ($n -eq 1)))
    }
    return $items.ToArray()
}

# ---- Get-WtPanelPromptFit (lines 9299-9316) ----
function Get-WtPanelPromptFit {
    <#
    .SYNOPSIS
        PURE: cuts a Read-Host prompt so prompt + ': ' still fits between
        the panel's footer column and the right border. Read-Host retypes
        the prompt at the footer column; an unfit prompt once wrapped onto
        the bottom border and the answering Enter scrolled the alt buffer.
        Budget: Width minus the footer column, border/pad, and the ': '
        Read-Host appends, floored at 10; overflow is cut and marked '~'.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Prompt,
        [Parameter(Mandatory)][int]$Width
    )
    $budget = [Math]::Max(10, $Width - 8)
    if ($Prompt.Length -le $budget) { return $Prompt }
    return ($Prompt.Substring(0, $budget - 1) + '~')
}

# ---- Get-WtPendingRebootLines (lines 34375-34429) ----
function Get-WtPendingRebootLines {
    <#
    .SYNOPSIS
        Whether Windows is waiting for a restart, and WHICH component is
        asking for it - also explains why sfc and DISM keep failing on a
        machine that never got restarted. Three flags decide:
        CBS\RebootPending, Windows Update's RebootRequired, and an
        ActiveComputerName that no longer matches ComputerName (compared
        Ordinal-ignore-case, since tr-TR folds 'I' differently).
        PendingFileRenameOperations is REPORTED as a count but never
        decides: it is populated on almost every machine, so letting it
        decide would make the row cry wolf.
    #>
    param(
        [scriptblock]$GetCbsRebootPending = { Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' },
        [scriptblock]$GetWindowsUpdateRebootRequired = { Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' },
        [scriptblock]$GetActiveComputerName = { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName },
        [scriptblock]$GetPendingComputerName = { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName },
        [scriptblock]$GetPendingFileRenames = { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations }
    )
    $reasons = New-Object System.Collections.Generic.List[string]

    $cbs = try { [bool](& $GetCbsRebootPending) } catch { $false }
    if ($cbs) { $reasons.Add((Get-Translation 'PendingRebootReasonCbs')) }

    $wu = try { [bool](& $GetWindowsUpdateRebootRequired) } catch { $false }
    if ($wu) { $reasons.Add((Get-Translation 'PendingRebootReasonWindowsUpdate')) }

    $activeName = try { [string](& $GetActiveComputerName) } catch { '' }
    $pendingName = try { [string](& $GetPendingComputerName) } catch { '' }
    if ($activeName -and $pendingName -and -not [string]::Equals($activeName, $pendingName, [System.StringComparison]::OrdinalIgnoreCase)) {
        $reasons.Add(((Get-Translation 'PendingRebootReasonComputerName') -f $activeName, $pendingName))
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $answer = if ($reasons.Count -gt 0) { Get-Translation 'AnswerYes' } else { Get-Translation 'AnswerNo' }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PendingRebootHeader'), $answer))
    if ($reasons.Count -eq 0) {
        $lines.Add('  ' + (Get-Translation 'PendingRebootNoFlags'))
    }
    else {
        foreach ($r in $reasons) { $lines.Add('  - ' + $r) }
    }

    $lines.Add('')
    try {
        $renames = @(& $GetPendingFileRenames)
        $renameCount = @($renames | Where-Object { $_ -is [string] -and $_.Trim().Length -gt 0 }).Count
        $lines.Add(((Get-Translation 'PendingRebootFileRenameLine') -f $renameCount))
    }
    catch {
        $lines.Add((Get-Translation 'PendingRebootFileRenameUnavailable'))
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtProblemDeviceCodeText (lines 31641-31653) ----
function Get-WtProblemDeviceCodeText {
    <#
    .SYNOPSIS
        One CM_PROB_* error code in plain language. A code the dictionary
        has no wording for falls back to the number itself - a device
        Windows flagged is never dropped from the report just because its
        code is unusual.
    #>
    param([Parameter(Mandatory)][int]$Code)
    $text = [string](Get-Translation ('ProblemDeviceCode' + $Code))
    if ($text) { return $text }
    return ((Get-Translation 'ProblemDeviceCodeUnknown') -f $Code)
}

# ---- Get-WtProblemDeviceLines (lines 31655-31688) ----
function Get-WtProblemDeviceLines {
    <#
    .SYNOPSIS
        Every device Device Manager would flag, with its CM_PROB error
        code translated into plain language, the device name and the
        instance path. The filter is WQL syntax ('<>', not PowerShell's
        '-ne'), filtered inside the query rather than over every PnP
        entity so the row stays instant.
    #>
    param([scriptblock]$GetDevices = { Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction Stop })
    $devices = @()
    try { $devices = @(& $GetDevices) } catch { return [string[]]@((Get-Translation 'ProblemDeviceNotAvailable')) }
    if ($devices.Count -eq 0) { return [string[]]@((Get-Translation 'ProblemDeviceNone')) }

    $room = 95 - 4
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(((Get-Translation 'ProblemDeviceCountLine') -f $devices.Count))
    $ordered = @($devices | Sort-Object -Property @{ Expression = { [int]$_.ConfigManagerErrorCode } }, @{ Expression = { [string]$_.Name } })
    foreach ($d in $ordered) {
        $code = [int]$d.ConfigManagerErrorCode
        $lines.Add(('  {0} - {1}' -f $code, (Get-WtProblemDeviceCodeText -Code $code)))
        $name = [string]$d.Name
        if (-not $name) { $name = [string]$d.Caption }
        if (-not $name) { $name = '-' }
        if ($name.Length -gt $room) { $name = $name.Substring(0, $room - 1) + '~' }
        $lines.Add('    ' + $name)
        $id = [string]$d.DeviceID
        if ($id) {
            if ($id.Length -gt $room) { $id = $id.Substring(0, $room - 1) + '~' }
            $lines.Add('    ' + $id)
        }
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtRecentSystemErrorsLines (lines 31135-31175) ----
function Get-WtRecentSystemErrorsLines {
    <#
    .SYNOPSIS
        The last week of Critical and Error records from the System log, one
        readable row each: time, level, event id, provider, and the first
        line of the message. Get-WinEvent raises a TERMINATING error when a
        filter matches nothing - even with -ErrorAction SilentlyContinue on
        some builds - so the call is wrapped in try/catch and an empty
        result prints "no matching events" rather than nothing at all.
        Message is cast to string before being split, since it is $null
        whenever the provider's resource DLL is missing.
    #>
    param(
        [scriptblock]$GetEvents = {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 40 -ErrorAction SilentlyContinue
        },
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )
    $events = @()
    try { $events = @(& $GetEvents) } catch { $events = @() }
    $events = @($events | Where-Object { $_ })
    if ($events.Count -eq 0) { return [string[]]@([string](Get-Translation 'EventsNoneFound')) }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string](Get-Translation 'RecentSystemErrorsHeading'))
    $msgRoom = [Math]::Max(12, $Width - 57)
    foreach ($e in $events) {
        $when = ''
        if ($e.TimeCreated) {
            $when = ([datetime]$e.TimeCreated).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $level = Get-WtEventLevelTag -Level $e.Level
        $provider = [string]$e.ProviderName
        if ($provider.Length -gt 22) { $provider = $provider.Substring(0, 21) + '~' }
        $parts = @(([string]$e.Message) -csplit "`r`n|`r|`n" | Where-Object { $_.Trim() })
        $msg = if ($parts.Count -gt 0) { $parts[0].Trim() } else { [string](Get-Translation 'EventNoMessage') }
        if ($msg.Length -gt $msgRoom) { $msg = $msg.Substring(0, $msgRoom - 1) + '~' }
        $lines.Add((('{0,-16}  {1,-5}  {2,6}  {3,-22}  {4}' -f $when, $level, ([string]$e.Id), $provider, $msg)).TrimEnd())
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtRegistryBackupTargets (lines 22689-22707) ----
function Get-WtRegistryBackupTargets {
    <#
    .SYNOPSIS
        PURE: the hives BackupRegistry exports, in export order. SYSTEM
        is marked Reimportable=$false (merging it back into a running
        Windows can leave the machine unbootable). The user hive is
        addressed as HKU\<SID>, never HKCU, since under elevation HKCU is
        the ADMIN's hive; a $null SID exports only the machine hives.
    #>
    param([AllowNull()][string]$UserSid)

    $targets = New-Object System.Collections.Generic.List[object]
    $targets.Add([PSCustomObject]@{ Key = 'HKLM\SOFTWARE'; FileName = 'HKLM-SOFTWARE.reg'; Reimportable = $true })
    $targets.Add([PSCustomObject]@{ Key = 'HKLM\SYSTEM'; FileName = 'HKLM-SYSTEM.reg'; Reimportable = $false })
    if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
        $targets.Add([PSCustomObject]@{ Key = ('HKU\' + $UserSid); FileName = 'HKU-CurrentUser.reg'; Reimportable = $true })
    }
    return $targets.ToArray()
}

# ---- Get-WtResetStoreCacheLines (lines 27373-27406) ----
function Get-WtResetStoreCacheLines {
    <#
    .SYNOPSIS
        Clears the Microsoft Store cache - the fix for a Store that shows
        a blank page or loops on "Try again". WSReset.exe is started
        WITHOUT -Wait on purpose: it keeps its own window open until the
        Store front-end comes up, so -Wait would hold the panel hostage
        for as long as that window stays on screen; this row returns in
        milliseconds and SAYS it started something in the background
        rather than pretending to have finished. The Store package is
        probed first, since this application's own bloatware screen can
        have removed it.
    #>
    param(
        [scriptblock]$GetStorePackage = { Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction SilentlyContinue },
        [string]$WsResetPath = '',
        [scriptblock]$TestWsReset = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf },
        [scriptblock]$StartWsReset = { param($Path) Start-Process -FilePath $Path | Out-Null }
    )
    if ([string]::IsNullOrWhiteSpace($WsResetPath)) {
        $WsResetPath = Join-Path $env:SystemRoot 'System32\WSReset.exe'
    }
    $store = $null
    try { $store = & $GetStorePackage }
    catch { $store = $null }
    if (-not $store) { return [string[]]@((Get-Translation 'StoreCacheNoStore')) }
    if (-not (& $TestWsReset $WsResetPath)) { return [string[]]@((Get-Translation 'StoreCacheNoWsReset')) }
    try { & $StartWsReset $WsResetPath }
    catch { return [string[]]@(((Get-Translation 'StoreCacheStartFailed') -f $_.Exception.Message)) }
    return [string[]]@(
        (Get-Translation 'StoreCacheStarted')
        (Get-Translation 'StoreCacheAccountNote')
    )
}

# ---- Get-WtRestorePointEntries (lines 23613-23654) ----
function Get-WtRestorePointEntries {
    <#
    .SYNOPSIS
        The machine's restore points, newest first, normalized to
        SequenceNumber / Description / CreationTime. Returns an empty
        array when System Protection is off, never reported as a
        successful delete.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Get-ComputerRestorePoint only executes in the PS5.1 branch, guarded by Test-WtUsesCimRestorePointApi; PSScriptAnalyzer cannot see the runtime version guard.')]
    param(
        [scriptblock]$GetPoints = {
            if (Test-WtUsesCimRestorePointApi -PSMajorVersion $PSVersionTable.PSVersion.Major) {
                Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction SilentlyContinue
            }
            else {
                Get-ComputerRestorePoint -ErrorAction SilentlyContinue
            }
        }
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($point in @(& $GetPoints)) {
        if (-not $point) { continue }
        $created = $null
        $raw = $point.CreationTime
        if ($raw -is [datetime]) {
            $created = [datetime]$raw
        }
        elseif ($raw) {
            try { $created = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$raw) }
            catch { $created = $null }
        }
        $entries.Add([PSCustomObject]@{
            SequenceNumber = [int]$point.SequenceNumber
            Description    = [string]$point.Description
            CreationTime   = $created
        })
    }

    return @($entries.ToArray() | Sort-Object -Property @{ Expression = { if ($_.CreationTime) { $_.CreationTime } else { [datetime]::MinValue } } } -Descending)
}

# ---- Get-WtRestorePointRecords (lines 1016-1039) ----
function Get-WtRestorePointRecords {
    <#
    .SYNOPSIS
        Every restore point, with the read outcome kept separate from the
        result (Succeeded/Points/Error), since an unelevated session makes
        Get-ComputerRestorePoint throw rather than return nothing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Get-ComputerRestorePoint only executes in the PS5.1 branch, guarded by Test-WtUsesCimRestorePointApi; PSScriptAnalyzer cannot see the runtime version guard.')]
    param()

    try {
        if (Test-WtUsesCimRestorePointApi -PSMajorVersion $PSVersionTable.PSVersion.Major) {
            $points = @(Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction Stop)
        }
        else {
            $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
        }
        return [PSCustomObject]@{ Succeeded = $true; Points = @($points); Error = '' }
    }
    catch {
        return [PSCustomObject]@{ Succeeded = $false; Points = @(); Error = [string]$_.Exception.Message }
    }
}

# ---- Get-WtRestorePointShadowStorageLines (lines 34107-34143) ----
function Get-WtRestorePointShadowStorageLines {
    <#
    .SYNOPSIS
        Which restore points exist, when they were made, and what kind
        they are, then the header under which the row prints
        "vssadmin list shadowstorage" verbatim. A read failure is
        reported as unavailable, never as zero restore points - that
        would call a protected machine unprotected. The vssadmin output
        itself is streamed straight into the panel with no -Encoding:
        OEM decoding is what vssadmin needs, and UTF8 there turns its box
        characters into mojibake.
    #>
    param(
        [PSCustomObject]$Result = (Get-WtRestorePointRecords),
        [int]$Top = 20
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Get-Translation 'RestorePointListHeader'))
    if (-not $Result.Succeeded) {
        $lines.Add('  ' + ((Get-Translation 'RestorePointsUnavailable') -f [string]$Result.Error))
        $lines.Add('  ' + (Get-Translation 'RestorePointsUnknownWarning'))
    }
    elseif (@($Result.Points).Count -eq 0) {
        $lines.Add('  ' + (Get-Translation 'RestorePointListNone'))
    }
    else {
        foreach ($p in @(@($Result.Points) | Sort-Object -Property SequenceNumber -Descending | Select-Object -First $Top)) {
            $when = ConvertTo-WtRestorePointTime -CreationTime $p.CreationTime
            $stamp = if ($when) { $when.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } else { '????-??-?? --:--' }
            $lines.Add(('  {0,4}  {1}  {2}' -f [string]$p.SequenceNumber, $stamp, [string]$p.Description))
            $lines.Add(('        {0}' -f (Get-WtRestorePointTypeLabel -Type $p.RestorePointType)))
        }
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'ShadowStorageReportHeader'))
    return [string[]]$lines.ToArray()
}

# ---- Get-WtRestorePointTypeLabel (lines 34078-34105) ----
function Get-WtRestorePointTypeLabel {
    <#
    .SYNOPSIS
        RestorePointType resolved to words, from the SRRestorePtAPI.h
        table (0 APPLICATION_INSTALL, 1 APPLICATION_UNINSTALL, 6 RESTORE,
        7 CHECKPOINT, 10 DEVICE_DRIVER_INSTALL, 12 MODIFY_SETTINGS,
        13 CANCELLED_OPERATION). A missing value must NOT fall through to
        0 - [int]$null is 0 in PowerShell, which would label every point
        with no type as an application install.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Type)
    if ($null -eq $Type -or ([string]$Type) -eq '') {
        return ((Get-Translation 'RestorePointTypeOther') -f '?')
    }
    $number = $null
    try { $number = [int]$Type }
    catch { return ((Get-Translation 'RestorePointTypeOther') -f ([string]$Type)) }
    switch ($number) {
        0 { return (Get-Translation 'RestorePointTypeAppInstall') }
        1 { return (Get-Translation 'RestorePointTypeAppUninstall') }
        6 { return (Get-Translation 'RestorePointTypeRestore') }
        7 { return (Get-Translation 'RestorePointTypeCheckpoint') }
        10 { return (Get-Translation 'RestorePointTypeDriverInstall') }
        12 { return (Get-Translation 'RestorePointTypeModifySettings') }
        13 { return (Get-Translation 'RestorePointTypeCancelled') }
    }
    return ((Get-Translation 'RestorePointTypeOther') -f $number)
}

# ---- Get-WtRetryReasonKey (lines 256-269) ----
function Get-WtRetryReasonKey {
    <#
    .SYNOPSIS
        The translation key that explains why a de-elevated retry never
        ran. An unknown reason falls back to the general failure line
        rather than to a blank.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Reason)
    switch ($Reason) {
        'NoInteractiveUser' { return 'WsRetryNoUser' }
        'Timeout'           { return 'WsRetryTimeout' }
    }
    return 'WsRetryFailed'
}

# ---- Get-WtRiskLabel (lines 36464-36476) ----
function Get-WtRiskLabel {
    <#
    .SYNOPSIS
        Localized text for a SAFE / CAUTION / ADVANCED risk tag. The risk
        value itself stays the English constant everywhere else (catalog
        matching, colors, guards) - only what the row prints changes.
    #>
    param([AllowEmptyString()][string]$Risk = '')
    if (-not $Risk) { return '' }
    $label = Get-Translation ('Risk' + $Risk)
    if ($label) { return [string]$label }
    return $Risk
}

# ---- Get-WtRowColumnMetrics (lines 6140-6163) ----
function Get-WtRowColumnMetrics {
    <#
    .SYNOPSIS
        @{ RiskWidth; StateFloor; RiskLabels } for the active language,
        computed once per language: RiskWidth is the widest "[label]"
        of SAFE / CAUTION / ADVANCED, StateFloor the widest of the four
        state words a marked row can show, RiskLabels the three labels.
    #>
    $lang = [string]$script:Language
    $hit = $script:WtRowColumnCache[$lang]
    if ($null -ne $hit) { return $hit }
    $labels = @{}
    $riskWidth = 0
    foreach ($r in 'SAFE', 'CAUTION', 'ADVANCED') {
        $text = [string](Get-WtRiskLabel -Risk $r)
        $labels[$r] = $text
        $riskWidth = [Math]::Max($riskWidth, $text.Length + 2)
    }
    $floor = 0
    foreach ($k in 'Applied', 'NotApplied', 'WillApply', 'WillRemove') { $floor = [Math]::Max($floor, ([string](Get-Translation $k)).Length) }
    $metrics = @{ RiskWidth = $riskWidth; StateFloor = $floor; RiskLabels = $labels }
    $script:WtRowColumnCache[$lang] = $metrics
    return $metrics
}

# ---- Get-WtSearchableFooter (lines 8615-8631) ----
function Get-WtSearchableFooter {
    <#
    .SYNOPSIS
        PURE: a screen's navigation guide with the search key added: "/: ara"
        goes in front of the Esc item, so the guide reads doing-to-leaving. A
        footer without an Esc item is not a guide and comes back untouched.
        Ordinal IndexOf, never -replace, to avoid tr-TR casefolding.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Footer,
        [Parameter(Mandatory)][string]$Hint
    )
    $text = [string]$Footer
    $at = $text.IndexOf(' - Esc:', [System.StringComparison]::Ordinal)
    if ($at -lt 0) { return $text }
    return $text.Substring(0, $at) + ' - ' + $Hint + $text.Substring($at)
}

# ---- Get-WtSecureBootTpmLines (lines 32913-32993) ----
function Get-WtSecureBootTpmLines {
    <#
    .SYNOPSIS
        PURE: firmware type, Secure Boot, TPM presence + version and the
        system disk's partition style - the Windows 11 eligibility
        question in four lines. Confirm-SecureBootUEFI throws a different
        exception type depending on cause (legacy BIOS vs a non-elevated
        shell); the EXCEPTION TYPE decides which note is printed, never
        the message, since Windows localizes it. Every probe falls back
        to a WMI/registry read on failure, and an empty result prints
        Unknown rather than nothing.
    #>
    param(
        [scriptblock]$GetFirmwareType = { $env:firmware_type },
        [scriptblock]$GetSecureBoot = { Confirm-SecureBootUEFI -ErrorAction Stop },
        [scriptblock]$GetSecureBootRegistry = { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop).UEFISecureBootEnabled },
        [scriptblock]$GetTpm = { Get-Tpm -ErrorAction Stop },
        [scriptblock]$GetTpmCim = { Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName Win32_Tpm -ErrorAction Stop },
        [scriptblock]$GetSystemDisk = { Get-Disk -ErrorAction Stop | Where-Object { $_.IsSystem } }
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $firmware = ''
    try { $firmware = [string](& $GetFirmwareType) }
    catch { $firmware = '' }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'SecureBootFirmwareType'), (Format-WtSecurityValueOrUnknown -Value $firmware)))

    $secureWord = $null
    $secureNote = $null
    try {
        $secureWord = Format-WtOnOffWord -Value (& $GetSecureBoot)
    }
    catch {
        $ex = $_.Exception
        if ($ex -is [System.PlatformNotSupportedException]) { $secureNote = [string](Get-Translation 'SecureBootNotSupported') }
        elseif ($ex -is [System.UnauthorizedAccessException]) { $secureNote = [string](Get-Translation 'SecureBootAccessDenied') }
        else { $secureNote = [string](Get-Translation 'SecureBootQueryFailed') }
        try {
            $raw = & $GetSecureBootRegistry
            if ($null -ne $raw) { $secureWord = Format-WtOnOffWord -Value ([int]$raw) }
        }
        catch { $null = $_ }
    }
    if ($secureWord -and $secureNote) { $lines.Add(('{0}: {1} ({2})' -f (Get-Translation 'SecureBootState'), $secureWord, $secureNote)) }
    elseif ($secureWord) { $lines.Add(('{0}: {1}' -f (Get-Translation 'SecureBootState'), $secureWord)) }
    else { $lines.Add(('{0}: {1}' -f (Get-Translation 'SecureBootState'), $secureNote)) }

    $tpmWord = $null
    try {
        $tpm = & $GetTpm
        if ($null -ne $tpm -and $null -ne $tpm.TpmPresent) {
            if ([bool]$tpm.TpmPresent) { $tpmWord = Format-WtOnOffWord -Value $tpm.TpmEnabled }
            else { $tpmWord = [string](Get-Translation 'TpmNotPresent') }
        }
    }
    catch { $tpmWord = $null }

    $tpmVersion = $null
    $cim = @()
    try { $cim = @(& $GetTpmCim) }
    catch { $cim = @() }
    if ($cim.Count -gt 0) {
        if ($null -eq $tpmWord) { $tpmWord = Format-WtOnOffWord -Value $cim[0].IsEnabled_InitialValue }
        $spec = [string]$cim[0].SpecVersion
        if ($spec) { $tpmVersion = $spec.Split(',')[0].Trim() }
    }
    if ($null -eq $tpmWord) { $tpmWord = [string](Get-Translation 'TpmNotAvailable') }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'TpmStatusLabel'), $tpmWord))
    if ($tpmVersion) { $lines.Add(('{0}: {1}' -f (Get-Translation 'TpmVersionLabel'), $tpmVersion)) }

    $style = $null
    try {
        $disks = @(& $GetSystemDisk)
        if ($disks.Count -gt 0) { $style = [string]$disks[0].PartitionStyle }
    }
    catch { $style = $null }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'SystemDiskPartitionStyle'), (Format-WtSecurityValueOrUnknown -Value $style)))

    return [string[]]$lines.ToArray()
}

# ---- Get-WtSecurityPostureLines (lines 33112-33195) ----
function Get-WtSecurityPostureLines {
    <#
    .SYNOPSIS
        PURE: one answer to "how open is this machine" - UAC in words,
        Remote Desktop, WinRM and the local password policy. Every source
        is separately guarded since each one can be missing on a real
        machine. net accounts is printed verbatim and must NOT get an
        explicit -Encoding: it already arrives OEM-decoded through
        Invoke-WtCapturedAction, and forcing UTF-8 here turns Turkish
        text into question marks.
    #>
    param(
        [scriptblock]$GetUacPolicy = { Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop },
        [scriptblock]$GetTerminalServerPolicy = { Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction Stop },
        [scriptblock]$GetRdpTcpPolicy = { Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction Stop },
        [scriptblock]$GetRemoteDesktopUsers = { Get-LocalGroupMember -SID 'S-1-5-32-555' -ErrorAction Stop },
        [scriptblock]$GetWinrmService = { Get-Service -Name 'WinRM' -ErrorAction Stop },
        [scriptblock]$GetWinrmListeners = { Get-ChildItem -Path 'WSMan:\localhost\Listener' -ErrorAction Stop },
        [scriptblock]$GetPasswordPolicy = { net accounts }
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add([string](Get-Translation 'PostureSectionUac'))
    $uac = $null
    try { $uac = & $GetUacPolicy }
    catch { $uac = $null }
    $uacKey = if ($null -eq $uac) { 'SecStateUnknown' } else { Get-WtUacLevelKey -EnableLua $uac.EnableLUA -ConsentPromptBehaviorAdmin $uac.ConsentPromptBehaviorAdmin -PromptOnSecureDesktop $uac.PromptOnSecureDesktop }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureUacLevel'), (Get-Translation $uacKey)))

    $lines.Add([string](Get-Translation 'PostureSectionRemote'))
    $deny = $null
    try { $deny = (& $GetTerminalServerPolicy).fDenyTSConnections }
    catch { $deny = $null }
    $rdpWord = if ($null -eq $deny) { [string](Get-Translation 'SecStateUnknown') }
    elseif ([int]$deny -eq 0) { [string](Get-Translation 'SecStateOn') }
    else { [string](Get-Translation 'SecStateOff') }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureRdpLabel'), $rdpWord))

    $nla = $null
    try { $nla = (& $GetRdpTcpPolicy).UserAuthentication }
    catch { $nla = $null }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureRdpNla'), (Format-WtOnOffWord -Value $nla)))

    $rdpUsers = $null
    try { $rdpUsers = @(& $GetRemoteDesktopUsers) }
    catch { $rdpUsers = $null }
    $rdpUsersText = if ($null -eq $rdpUsers) { [string](Get-Translation 'SecStateUnknown') }
    elseif ($rdpUsers.Count -eq 0) { [string](Get-Translation 'PostureRdpUsersEmpty') }
    else { (@($rdpUsers | ForEach-Object { [string]$_.Name }) -join ', ') }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureRdpUsersLabel'), $rdpUsersText))

    $winrm = $null
    try { $winrm = & $GetWinrmService }
    catch { $winrm = $null }
    $winrmText = if ($null -eq $winrm) { [string](Get-Translation 'SecStateUnknown') } else { Format-WtServiceStateLabel -Status ([string]$winrm.Status) -StartType ([string]$winrm.StartType) }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureWinrmLabel'), $winrmText))

    $listeners = $null
    try { $listeners = @(& $GetWinrmListeners) }
    catch { $listeners = $null }
    if ($null -eq $listeners -or $listeners.Count -eq 0) {
        $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureWinrmListeners'), (Get-Translation 'PostureWinrmNoListener')))
    }
    else {
        $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureWinrmListeners'), $listeners.Count))
        foreach ($listener in $listeners) {
            $keys = @(@($listener.Keys) | Where-Object { $_ })
            if ($keys.Count -gt 0) { $lines.Add(('  {0}' -f ($keys -join ', '))) }
            else { $lines.Add(('  {0}' -f (Format-WtSecurityValueOrUnknown -Value $listener.Name))) }
        }
    }

    $lines.Add([string](Get-Translation 'PostureSectionPasswordPolicy'))
    $policy = $null
    try { $policy = @(& $GetPasswordPolicy) }
    catch { $policy = $null }
    $policyLines = @()
    if ($null -ne $policy) { $policyLines = @($policy | ForEach-Object { ([string]$_).TrimEnd() } | Where-Object { $_.Length -gt 0 }) }
    if ($policyLines.Count -eq 0) { $lines.Add([string](Get-Translation 'PosturePasswordPolicyUnavailable')) }
    else { foreach ($policyLine in $policyLines) { $lines.Add($policyLine) } }

    return [string[]]$lines.ToArray()
}

# ---- Get-WtSelectorDisplayLabel (lines 11880-11898) ----
function Get-WtSelectorDisplayLabel {
    <#
    .SYNOPSIS
        What Show-WtSelector should render for one catalog entry: its own
        DisplayLabel when the catalog supplies a non-empty one, falling
        back to Name otherwise. The existing Services/Packages catalogs
        supply no DisplayLabel and render exactly as before this function
        existed - purely additive.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry
    )

    if ($Entry.PSObject.Properties.Name -contains 'DisplayLabel' -and $Entry.DisplayLabel) {
        return $Entry.DisplayLabel
    }
    return $Entry.Name
}

# ---- Get-WtSensorFlags (lines 27748-27767) ----
function Get-WtSensorFlags {
    <#
    .SYNOPSIS
        Pure flag evaluator for the sensor snapshot: memory used >= 90 %
        -> WARNING "High memory pressure".
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Snapshot
    )

    $flags = New-Object System.Collections.Generic.List[object]

    if ($null -ne $Snapshot.Memory.UsedPercent -and [int]$Snapshot.Memory.UsedPercent -ge 90) {
        $flags.Add([PSCustomObject]@{ Severity = 'WARNING'; Message = "High memory pressure ($($Snapshot.Memory.UsedPercent) % used)" })
    }

    $severity = if ($flags.Count -gt 0) { 'WARNING' } else { 'OK' }
    return [PSCustomObject]@{ Flags = $flags.ToArray(); Severity = $severity }
}

# ---- Get-WtSensorSnapshot (lines 27769-27870) ----
function Get-WtSensorSnapshot {
    <#
    .SYNOPSIS
        One-shot CPU / memory / GPU snapshot from CIM (Get-CimInstance is
        injectable since there is no CIM on the macOS dev host). Each
        query runs in its own try/catch so a missing class (VM, old
        driver) or an unsupported thermal zone leaves that section $null
        and the rest of the report intact. Never touches Get-Counter -
        counter paths are localized.
    #>
    param(
        [scriptblock]$CimQueryAction = {
            param($Namespace, $ClassName)
            Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop
        },

        [scriptblock]$GpuTemperatureAction = { Get-WtNvidiaSmiTemperature }
    )

    $cpu = [PSCustomObject]@{ Name = $null; LoadPercent = $null; ClockMHz = $null; Cores = $null; LogicalProcessors = $null; TemperatureC = $null }
    $memory = [PSCustomObject]@{ TotalMB = $null; UsedMB = $null; AvailableMB = $null; UsedPercent = $null }
    $gpu = [PSCustomObject]@{ Name = $null; DriverVersion = $null; UtilizationPercent = $null; DedicatedVramUsedMB = $null; TemperatureC = $null }

    try {
        $processors = @(& $CimQueryAction 'root/cimv2' 'Win32_Processor')
        if ($processors.Count -gt 0) {
            $cpu.Name = "$($processors[0].Name)".Trim()
            $loads = @($processors | ForEach-Object { [double]$_.LoadPercentage })
            $cpu.LoadPercent = [int][math]::Round(($loads | Measure-Object -Average).Average)
            $cpu.ClockMHz = [int]$processors[0].CurrentClockSpeed
            $cpu.Cores = [int](($processors | Measure-Object -Property NumberOfCores -Sum).Sum)
            $cpu.LogicalProcessors = [int](($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        }
    }
    catch { }

    try {
        $zones = @(& $CimQueryAction 'root/wmi' 'MSAcpi_ThermalZoneTemperature')
        $hottest = $null
        foreach ($zone in $zones) {
            $celsius = ([double]$zone.CurrentTemperature / 10) - 273.15
            if ($null -eq $hottest -or $celsius -gt $hottest) { $hottest = $celsius }
        }
        if ($null -ne $hottest) { $cpu.TemperatureC = [int][math]::Round($hottest) }
    }
    catch { }

    try {
        $os = @(& $CimQueryAction 'root/cimv2' 'Win32_OperatingSystem')
        if ($os.Count -gt 0 -and [double]$os[0].TotalVisibleMemorySize -gt 0) {
            $totalKB = [double]$os[0].TotalVisibleMemorySize
            $freeKB = [double]$os[0].FreePhysicalMemory
            $memory.TotalMB = [int][math]::Round($totalKB / 1024)
            $memory.AvailableMB = [int][math]::Round($freeKB / 1024)
            $memory.UsedMB = [int][math]::Round(($totalKB - $freeKB) / 1024)
            $memory.UsedPercent = [int][math]::Round((($totalKB - $freeKB) / $totalKB) * 100)
        }
    }
    catch { }

    try {
        $controllers = @(& $CimQueryAction 'root/cimv2' 'Win32_VideoController')
        if ($controllers.Count -gt 0) {
            $gpu.Name = "$($controllers[0].Name)".Trim()
            $gpu.DriverVersion = "$($controllers[0].DriverVersion)"
        }
    }
    catch { }

    try {
        $engines = @(& $CimQueryAction 'root/cimv2' 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine')
        $gpu.UtilizationPercent = Get-WtGpuUtilizationFromEngines -Engines $engines
    }
    catch { }

    try {
        $adapterMemory = @(& $CimQueryAction 'root/cimv2' 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory')
        if ($adapterMemory.Count -gt 0) {
            $dedicated = ($adapterMemory | ForEach-Object { [double]$_.DedicatedUsage } | Measure-Object -Sum).Sum
            $gpu.DedicatedVramUsedMB = [int][math]::Round($dedicated / 1MB)
        }
    }
    catch { }

    try {
        $gpu.TemperatureC = & $GpuTemperatureAction
    }
    catch { }

    $snapshot = [PSCustomObject]@{
        Cpu      = $cpu
        Memory   = $memory
        Gpu      = $gpu
        Flags    = @()
        Severity = 'OK'
    }

    $flagResult = Get-WtSensorFlags -Snapshot $snapshot
    $snapshot.Flags = $flagResult.Flags
    $snapshot.Severity = $flagResult.Severity
    return $snapshot
}

# ---- Get-WtSettingsFilePath (lines 1246-1257) ----
function Get-WtSettingsFilePath {
    <#
    .SYNOPSIS
        <User data root>\settings.json - the per-user preferences file
        (language choice). User scope on purpose: the language is a
        personal preference, not machine state.
    #>
    param([string]$TestRootOverride)
    $dataPathArgs = @{ Scope = 'User' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    return Join-Path (Get-WtDataPath @dataPathArgs) 'settings.json'
}

# ---- Get-WtSgrPrefix (lines 7108-7128) ----
function Get-WtSgrPrefix {
    <#
    .SYNOPSIS
        The SGR prefix for one colour pair, from the cache after the first
        time. An unknown or empty foreground is 37 (Gray), as before; an
        unknown background adds nothing.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Fg,
        [AllowNull()][AllowEmptyString()][string]$Bg
    )
    $key = [string]$Fg + '|' + [string]$Bg
    $hit = $script:WtSgrPrefixCache[$key]
    if ($null -ne $hit) { return $hit }
    $codes = '37'
    if ($Fg -and $script:WtSgrMap.ContainsKey($Fg)) { $codes = [string]$script:WtSgrMap[$Fg] }
    if ($Bg -and $script:WtSgrMap.ContainsKey($Bg)) { $codes += ';' + ([int]$script:WtSgrMap[$Bg] + 10) }
    $prefix = $script:WtEsc + '[' + $codes + 'm'
    $script:WtSgrPrefixCache[$key] = $prefix
    return $prefix
}

# ---- Get-WtShadowCopyCount (lines 23691-23718) ----
function Get-WtShadowCopyCount {
    <#
    .SYNOPSIS
        How many shadow copies live on one drive letter, counted through
        CIM (Win32_ShadowCopy joined to Win32_Volume) instead of counting
        rows in localized vssadmin output. This is the number the
        oldest-first delete loop stops at.
    #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [scriptblock]$GetCopies = { Get-CimInstance -ClassName 'Win32_ShadowCopy' -ErrorAction SilentlyContinue },
        [scriptblock]$GetVolumes = { Get-CimInstance -ClassName 'Win32_Volume' -ErrorAction SilentlyContinue }
    )

    $letter = ([string]$DriveLetter).Substring(0, 1).ToUpperInvariant()
    $deviceIds = New-Object System.Collections.Generic.List[string]
    foreach ($volume in @(& $GetVolumes)) {
        $volumeLetter = [string]$volume.DriveLetter
        if (-not $volumeLetter) { continue }
        if ($volumeLetter.Substring(0, 1).ToUpperInvariant() -ceq $letter) { $deviceIds.Add([string]$volume.DeviceID) }
    }

    $count = 0
    foreach ($copy in @(& $GetCopies)) {
        if ($deviceIds -ccontains ([string]$copy.VolumeName)) { $count++ }
    }
    return $count
}

# ---- Get-WtShadowStorageEntries (lines 23656-23689) ----
function Get-WtShadowStorageEntries {
    <#
    .SYNOPSIS
        Shadow-copy storage per drive: used and allocated bytes, read
        through CIM rather than parsed from "vssadmin list shadowstorage"
        text - that text is localized (Turkish decimal commas), so a byte
        figure taken from it would be wrong on exactly the machines this
        ships for.
    #>
    param(
        [scriptblock]$GetStorage = { Get-CimInstance -ClassName 'Win32_ShadowStorage' -ErrorAction SilentlyContinue },
        [scriptblock]$GetVolumes = { Get-CimInstance -ClassName 'Win32_Volume' -ErrorAction SilentlyContinue }
    )

    $letterByDevice = @{}
    foreach ($volume in @(& $GetVolumes)) {
        if ($volume.DeviceID) { $letterByDevice[[string]$volume.DeviceID] = [string]$volume.DriveLetter }
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($storage in @(& $GetStorage)) {
        $deviceId = ''
        if ($storage.Volume) { $deviceId = [string]$storage.Volume.DeviceID }
        $letter = [string]$letterByDevice[$deviceId]
        if (-not $letter) { $letter = Get-Translation 'StateUnknown' }
        $entries.Add([PSCustomObject]@{
            DriveLetter    = $letter
            UsedBytes      = [long]$storage.UsedSpace
            AllocatedBytes = [long]$storage.AllocatedSpace
        })
    }

    return $entries.ToArray()
}

# ---- Get-WtSharedTextLines (lines 101-128) ----
function Get-WtSharedTextLines {
    <#
    .SYNOPSIS
        A text file's lines, read while something else still has it open
        for writing. Opens with FileShare::ReadWrite so a partial read is
        the worst case, never an exception - a plain Get-Content's share
        mode can lose that race. A file that is not there yet is zero
        lines.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return , [string[]]@() }
    $stream = $null
    $reader = $null
    $text = ''
    try {
        $stream = New-Object System.IO.FileStream(
            $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        $text = $reader.ReadToEnd()
    }
    catch { return , [string[]]@() }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
    if ($text -eq '') { return , [string[]]@() }
    return , [string[]]@($text -split "`r?`n")
}

# ---- Get-WtShutdownCancelLines (lines 25583-25597) ----
function Get-WtShutdownCancelLines {
    <#
    .SYNOPSIS
        PURE: what "shutdown /a" actually answered, in the user's
        language. 1116 is ERROR_NO_SHUTDOWN_IN_PROGRESS - shutdown.exe
        writes that to stderr in the OS language ("Unable to abort the
        system shutdown because no shutdown was in progress.(1116)"),
        which is not an error here at all, just "there was nothing to
        cancel". The raw text never reaches the panel; this line does.
    #>
    param([Parameter(Mandatory)][int]$ExitCode)
    if ($ExitCode -eq 0) { return [string[]]@((Get-Translation 'ShutdownTimerCancelled')) }
    if ($ExitCode -eq 1116) { return [string[]]@((Get-Translation 'ShutdownTimerNonePending')) }
    return [string[]]@(((Get-Translation 'ShutdownTimerCancelFailed') -f $ExitCode))
}

# ---- Get-WtShutdownEventText (lines 34491-34518) ----
function Get-WtShutdownEventText {
    <#
    .SYNOPSIS
        One history row for a 1074 / 6005 / 6006 System event. 1074 carries
        the process, user and reason in the FIRST LINE of Message, never by
        property order (it differs between shutdown initiators). The first
        line is taken by splitting on LF and trimming a trailing CR, not a
        "`r`n" regex anchor - a PS 5.1 trap this project has already paid
        for once. A missing message resource says so instead of printing a
        blank.
    #>
    param([Parameter(Mandatory)][AllowNull()]$EventRecord)
    if ($null -eq $EventRecord) { return (Get-Translation 'ShutdownMessageUnavailable') }
    $id = 0
    if ($null -ne $EventRecord.Id) { $id = [int]$EventRecord.Id }
    $label = switch ($id) {
        1074 { Get-Translation 'ShutdownEventRequested' }
        6005 { Get-Translation 'ShutdownEventLogStarted' }
        6006 { Get-Translation 'ShutdownEventLogStopped' }
        default { (Get-Translation 'ShutdownEventOther') -f $id }
    }
    if ($id -ne 1074) { return $label }
    $message = [string]$EventRecord.Message
    if (-not $message.Trim()) { return ('{0} - {1}' -f $label, (Get-Translation 'ShutdownMessageUnavailable')) }
    $first = $message.Split([char]10)[0].TrimEnd([char]13).Trim()
    if (-not $first) { return ('{0} - {1}' -f $label, (Get-Translation 'ShutdownMessageUnavailable')) }
    return ('{0} - {1}' -f $label, $first)
}

# ---- Get-WtShutdownHistoryLines (lines 34520-34576) ----
function Get-WtShutdownHistoryLines {
    <#
    .SYNOPSIS
        How long the machine has been up, and when and why it was last shut
        down or restarted. The header is LastBootUpTime with a Fast Startup
        footnote: with Fast Startup on, a shutdown hibernates the kernel
        session, so that value does not move and can be far older than the
        last power-off. Reads 1074/6005/6006 only - 6008 and 41 belong to
        the blue screen history row instead, noted so the omission never
        reads as a gap. Get-WinEvent throws on no match, which is exactly a
        trimmed/cleared log, so the catch prints "no record left".
    #>
    param(
        [scriptblock]$GetOs = { Get-CimInstance -ClassName Win32_OperatingSystem },
        [scriptblock]$GetNow = { Get-Date },
        [scriptblock]$GetEvents = { Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074, 6005, 6006 } -MaxEvents 40 -ErrorAction Stop },
        [int]$MaxRows = 8
    )
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $lines = New-Object System.Collections.Generic.List[string]

    $os = try { & $GetOs } catch { $null }
    $boot = $null
    if ($null -ne $os -and $null -ne $os.LastBootUpTime) {
        $boot = try { [datetime]$os.LastBootUpTime } catch { $null }
    }
    if ($null -eq $boot) {
        $lines.Add((Get-Translation 'ShutdownBootTimeUnavailable'))
    }
    else {
        $now = try { [datetime](& $GetNow) } catch { [datetime]::Now }
        $span = $now - $boot
        if ($span.Ticks -lt 0) { $span = [timespan]::Zero }
        $lines.Add(('{0}: {1}' -f (Get-Translation 'ShutdownLastBoot'), $boot.ToString('yyyy-MM-dd HH:mm:ss', $invariant)))
        $lines.Add(('{0}: {1}' -f (Get-Translation 'ShutdownUptime'), ((Get-Translation 'ShutdownUptimeValue') -f $span.Days, $span.Hours, $span.Minutes)))
        $lines.Add((Get-Translation 'ShutdownFastStartupNote'))
    }

    $lines.Add('')
    $lines.Add(((Get-Translation 'ShutdownHistoryHeader') + ':'))
    $events = @()
    try { $events = @(& $GetEvents | Where-Object { $null -ne $_ }) } catch { $events = @() }
    if ($events.Count -eq 0) {
        $lines.Add('  ' + (Get-Translation 'ShutdownHistoryNone'))
    }
    else {
        $ordered = @($events | Sort-Object -Property @{ Expression = { [datetime]$_.TimeCreated }; Descending = $true })
        foreach ($e in @($ordered | Select-Object -First $MaxRows)) {
            $stamp = try { ([datetime]$e.TimeCreated).ToString('yyyy-MM-dd HH:mm:ss', $invariant) } catch { '' }
            $lines.Add(('  {0}  {1}' -f $stamp, (Get-WtShutdownEventText -EventRecord $e)))
        }
    }

    $lines.Add('')
    $lines.Add((Get-Translation 'ShutdownBugcheckElsewhere'))
    return [string[]]$lines.ToArray()
}

# ---- Get-WtShutdownScheduleLines (lines 25599-25622) ----
function Get-WtShutdownScheduleLines {
    <#
    .SYNOPSIS
        PURE: what "shutdown /s /t <seconds>" answered. The wall-clock
        echo is the whole point of the row - the user has to be able to
        verify WHEN the machine goes down - so it is formatted with
        InvariantCulture: a culture-formatted date renders differently
        per host and the row would stop being checkable.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Plan,
        [Parameter(Mandatory)][int]$ExitCode
    )
    $rows = New-Object System.Collections.Generic.List[string]
    if ($Plan.Capped) { $rows.Add((Get-Translation 'ShutdownTimerCapped')) }
    if ($ExitCode -ne 0) {
        $rows.Add(((Get-Translation 'ShutdownTimerScheduleFailed') -f $ExitCode))
        return [string[]]$rows.ToArray()
    }
    $stamp = ([datetime]$Plan.At).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    $rows.Add(((Get-Translation 'ShutdownTimerScheduled') -f $Plan.Minutes, $stamp))
    $rows.Add((Get-Translation 'ShutdownTimerCancelHint'))
    return [string[]]$rows.ToArray()
}

# ---- Get-WtShutdownTimerPlan (lines 25548-25581) ----
function Get-WtShutdownTimerPlan {
    <#
    .SYNOPSIS
        PURE: turns the panel answer into a plan. Mode is 'Cancel' (empty
        or zero), 'Schedule' (a whole number of minutes) or 'Invalid'
        (anything else); Invalid is refused in the panel and NEVER
        handed to shutdown.exe. The ceiling is two days - a bigger
        number is clamped, and the clamp is REPORTED by the caller,
        never applied silently. Matched with -cnotmatch against
        '^\d+\z', not -notmatch/'$': under tr-TR a case-insensitive
        match is culture-sensitive (dotless I), and .NET's '$' also
        matches before a trailing newline.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Answer,
        [datetime]$Now = (Get-Date)
    )
    $maxMinutes = 2880
    $text = ([string]$Answer).Trim()
    if (-not $text) { return [PSCustomObject]@{ Mode = 'Cancel'; Minutes = 0; Seconds = 0; Capped = $false; At = $Now } }
    if ($text -cnotmatch '^\d+\z') { return [PSCustomObject]@{ Mode = 'Invalid'; Minutes = 0; Seconds = 0; Capped = $false; At = $Now } }
    $parsed = [long]0
    if (-not [long]::TryParse($text, [ref]$parsed)) { $parsed = [long]::MaxValue }
    if ($parsed -le 0) { return [PSCustomObject]@{ Mode = 'Cancel'; Minutes = 0; Seconds = 0; Capped = $false; At = $Now } }
    $capped = ($parsed -gt [long]$maxMinutes)
    $minutes = [int][Math]::Min($parsed, [long]$maxMinutes)
    return [PSCustomObject]@{
        Mode    = 'Schedule'
        Minutes = $minutes
        Seconds = ($minutes * 60)
        Capped  = $capped
        At      = $Now.AddMinutes($minutes)
    }
}

# ---- Get-WtStartMenuPackageNames (lines 26398-26413) ----
function Get-WtStartMenuPackageNames {
    <#
    .SYNOPSIS
        PURE: the Appx packages that make up the Start menu and its search
        surface - the documented repair for a Start button that does
        nothing. The whole package set is deliberately NOT re-registered:
        that takes minutes and touches apps unrelated to the fault.
    #>
    return [string[]]@(
        'Microsoft.Windows.ShellExperienceHost'
        'Microsoft.Windows.StartMenuExperienceHost'
        'Microsoft.Windows.Search'
        'Microsoft.Windows.Cortana'
        'Microsoft.UI.Xaml.CBS'
    )
}

# ---- Get-WtStartupProgramsLines (lines 33347-33517) ----
function Get-WtStartupProgramsLines {
    <#
    .SYNOPSIS
        PURE-FRONTED: everything that starts at sign-in, from all eight
        locations - Run and RunOnce under HKLM, under HKLM\WOW6432Node and
        under the INTERACTIVE user's hive, plus the common and the
        per-user Startup folder - with its command line and whether it is
        disabled. StartupApproved is merged from both hives with the
        user's copy added last, so a per-user entry the user disabled
        wins. Under elevation HKCU is the ADMIN's hive, so the
        interactive user's keys and Startup folder are reached via the
        console SID, never [Environment]::GetFolderPath('Startup'),
        which would return the admin's folder.
    #>
    param(
        [scriptblock]$GetValueMap = {
            param($Path)
            $map = [ordered]@{}
            $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            if ($key) {
                foreach ($valueName in $key.GetValueNames()) {
                    if ([string]::IsNullOrEmpty($valueName)) { continue }
                    $map[$valueName] = [string]$key.GetValue($valueName)
                }
            }
            return $map
        },
        [scriptblock]$GetApprovalMap = {
            param($Path)
            $map = @{}
            $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            if ($key) {
                foreach ($valueName in $key.GetValueNames()) {
                    if ([string]::IsNullOrEmpty($valueName)) { continue }
                    $map[$valueName] = $key.GetValue($valueName)
                }
            }
            return $map
        },
        [scriptblock]$GetFolderEntries = {
            param($Path)
            $out = New-Object System.Collections.Generic.List[object]
            if ($Path -and (Test-Path -LiteralPath $Path)) {
                foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue)) {
                    if ([string]::Equals($file.Name, 'desktop.ini', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    $out.Add([PSCustomObject]@{ Name = $file.Name; Command = $file.FullName })
                }
            }
            return , $out.ToArray()
        },
        [scriptblock]$GetUserSid = { Get-WtConsoleUserSid },
        [scriptblock]$GetUserProfilePath = {
            param($Sid)
            if (-not $Sid) { return $null }
            $profileKey = Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $Sid) -ErrorAction SilentlyContinue
            if (-not $profileKey -or -not $profileKey.ProfileImagePath) { return $null }
            return [Environment]::ExpandEnvironmentVariables([string]$profileKey.ProfileImagePath)
        },
        [string]$CommonStartup = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'),
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $sid = $null
    try { $sid = & $GetUserSid } catch { $sid = $null }
    $userRoot = if ($sid) { 'Registry::HKEY_USERS\' + $sid } else { $null }

    $approved = @{ 'Run' = @{}; 'Run32' = @{}; 'StartupFolder' = @{} }
    $approvalRoots = New-Object System.Collections.Generic.List[string]
    $approvalRoots.Add('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved')
    if ($userRoot) { $approvalRoots.Add($userRoot + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved') }
    foreach ($root in $approvalRoots) {
        foreach ($kind in 'Run', 'Run32', 'StartupFolder') {
            $map = $null
            try { $map = & $GetApprovalMap ($root + '\' + $kind) }
            catch { $map = $null }
            if (-not $map) { continue }
            foreach ($valueName in @($map.Keys)) { $approved[$kind][[string]$valueName] = $map[$valueName] }
        }
    }

    $sources = New-Object System.Collections.Generic.List[object]
    $sources.Add([PSCustomObject]@{ Label = 'HKLM Run'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approval = 'Run' })
    $sources.Add([PSCustomObject]@{ Label = 'HKLM RunOnce'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Approval = '' })
    $sources.Add([PSCustomObject]@{ Label = 'HKLM32 Run'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approval = 'Run32' })
    $sources.Add([PSCustomObject]@{ Label = 'HKLM32 RunOnce'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Approval = '' })
    if ($userRoot) {
        $sources.Add([PSCustomObject]@{ Label = 'HKU Run'; Path = $userRoot + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approval = 'Run' })
        $sources.Add([PSCustomObject]@{ Label = 'HKU RunOnce'; Path = $userRoot + '\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Approval = '' })
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($source in $sources) {
        $map = $null
        try { $map = & $GetValueMap $source.Path }
        catch { $map = $null }
        if (-not $map) { continue }
        foreach ($valueName in @($map.Keys)) {
            $name = [string]$valueName
            $approval = $null
            if ($source.Approval -and $approved[$source.Approval].ContainsKey($name)) { $approval = $approved[$source.Approval][$name] }
            $rows.Add([PSCustomObject]@{
                    SortKey  = $name.ToUpperInvariant()
                    Name     = $name
                    Location = $source.Label
                    Command  = [string]$map[$valueName]
                    Enabled  = (Test-WtStartupEntryEnabled -ApprovalValue $approval)
                })
        }
    }

    $folders = New-Object System.Collections.Generic.List[object]
    $folders.Add([PSCustomObject]@{ Label = 'Startup (all)'; Path = $CommonStartup })
    $profilePath = $null
    if ($sid) {
        try { $profilePath = & $GetUserProfilePath $sid }
        catch { $profilePath = $null }
    }
    if ($profilePath) {
        $folders.Add([PSCustomObject]@{ Label = 'Startup (user)'; Path = (Join-Path $profilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup') })
    }
    foreach ($folder in $folders) {
        $entries = @()
        try {
            $raw = & $GetFolderEntries $folder.Path
            $entries = if ($null -eq $raw) { @() } else { @($raw) }
        }
        catch { $entries = @() }
        foreach ($entry in $entries) {
            if (-not $entry) { continue }
            $name = [string]$entry.Name
            $approval = $null
            if ($approved['StartupFolder'].ContainsKey($name)) { $approval = $approved['StartupFolder'][$name] }
            $rows.Add([PSCustomObject]@{
                    SortKey  = $name.ToUpperInvariant()
                    Name     = $name
                    Location = $folder.Label
                    Command  = [string]$entry.Command
                    Enabled  = (Test-WtStartupEntryEnabled -ApprovalValue $approval)
                })
        }
    }

    if ($rows.Count -eq 0) {
        $lines.Add((Get-Translation 'StartupProgramsNone'))
        if (-not $sid) { $lines.Add((Get-Translation 'StartupProgramsNoUserHive')) }
        return [string[]]$lines.ToArray()
    }

    $enabledCount = @($rows | Where-Object { $_.Enabled }).Count
    $lines.Add(((Get-Translation 'StartupProgramsCount') -f $rows.Count, $enabledCount, ($rows.Count - $enabledCount)))
    if (-not $sid) { $lines.Add((Get-Translation 'StartupProgramsNoUserHive')) }
    $lines.Add('')

    $nameWidth = 24
    $stateWidth = 11
    $locWidth = 14
    $cmdWidth = [Math]::Max(20, $Width - $nameWidth - $stateWidth - $locWidth - 3)
    $total = $nameWidth + $stateWidth + $locWidth + $cmdWidth + 3

    $lines.Add((((Format-WtSoftwareCell -Text 'Name' -Width $nameWidth) + ' ' + (Format-WtSoftwareCell -Text 'State' -Width $stateWidth) + ' ' + (Format-WtSoftwareCell -Text 'Location' -Width $locWidth) + ' ' + (Format-WtSoftwareCell -Text 'Command' -Width $cmdWidth)).TrimEnd()))
    $lines.Add('-' * [Math]::Min($total, [Math]::Max(20, $Width)))
    foreach ($row in ($rows | Sort-Object -Property Location, SortKey)) {
        $state = if ($row.Enabled) { Get-Translation 'StartupStateEnabled' } else { Get-Translation 'StartupStateDisabled' }
        $lines.Add((((Format-WtSoftwareCell -Text $row.Name -Width $nameWidth) + ' ' + (Format-WtSoftwareCell -Text $state -Width $stateWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Location -Width $locWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Command -Width $cmdWidth)).TrimEnd()))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'StartupProgramsFootnote'))
    return [string[]]$lines.ToArray()
}

# ---- Get-WtStateColorMap (lines 6240-6286) ----
function Get-WtStateColorMap {
    <#
    .SYNOPSIS
        The state column's vocabulary: the localized word the app itself
        printed -> the colour that word means. Built from translation
        KEYS, never from literals, so a word and its colour cannot drift
        apart when a translation changes, and TR gets the same colours as
        EN for free. Sorted longest-first, because "currently: off" must
        match before anything shorter that lives inside it.
    #>
    param([string]$Language = $script:Language)
    if ($script:WtStateColorCache.ContainsKey($Language)) { return $script:WtStateColorCache[$Language] }
    $byKey = [ordered]@{
        'FirewallCurrentlyOff' = 'Red'
        'FirewallCurrentlyOn'  = 'Green'
        'NotSupportedWddm'     = 'DarkGray'
        'StateNotPresent'      = 'DarkGray'
        'SvcStart.Automatic'   = 'Green'
        'SvcStart.Disabled'    = 'Red'
        'SvcStart.Manual'      = 'Yellow'
        'SvcStatus.Running'    = 'Green'
        'SvcStatus.Stopped'    = 'Gray'
        'SvcStatus.Paused'     = 'Yellow'
        'SvcStatus.StartPending'    = 'Yellow'
        'SvcStatus.StopPending'     = 'Yellow'
        'SvcStatus.PausePending'    = 'Yellow'
        'SvcStatus.ContinuePending' = 'Yellow'
        'SvcStart.Boot'        = 'Green'
        'SvcStart.System'      = 'Green'
        'FlushAvailable'       = 'Green'
        'StateInstalled'       = 'Green'
        'StateRemoved'         = 'DarkGray'
        'StateUnknown'         = 'DarkGray'
        'FolderNotFound'       = 'DarkGray'
        'Applied'              = 'Green'
        'NotApplied'           = 'DarkGray'
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($key in $byKey.Keys) {
        $word = [string]$script:Translations[$Language][$key]
        if (-not $word) { continue }
        $pairs.Add([PSCustomObject]@{ Word = $word; Fg = [string]$byKey[$key] })
    }
    $map = @($pairs | Sort-Object -Property @{ Expression = { $_.Word.Length }; Descending = $true }, Word)
    $script:WtStateColorCache[$Language] = $map
    return $map
}

# ---- Get-WtStateSegmentsCached (lines 6167-6184) ----
function Get-WtStateSegmentsCached {
    <#
    .SYNOPSIS
        Cached wrapper around Split-WtStateSegments, keyed by
        language|colour|text. Returned segments are shared across rows
        and frames, so callers must never mutate one in place.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$DefaultFg = 'DarkGray'
    )
    $key = [string]$script:Language + '|' + $DefaultFg + '|' + $Text
    $hit = $script:WtStateSegmentCache[$key]
    if ($null -ne $hit) { return $hit }
    $segs = @(Split-WtStateSegments -Text $Text -DefaultFg $DefaultFg)
    $script:WtStateSegmentCache[$key] = $segs
    return $segs
}

# ---- Get-WtStorageLines (lines 33684-33701) ----
function Get-WtStorageLines {
    <#
    .SYNOPSIS
        V1's "Show Storage Status" (Get-PSDrive) upgraded to Get-Volume:
        one line per lettered volume with free / total / percent free.
    #>
    param([scriptblock]$GetVolumes = { Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter })
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($v in @(& $GetVolumes)) {
        $size = [double]$v.Size
        $free = [double]$v.SizeRemaining
        $pct = if ($size -gt 0) { [math]::Round(($free / $size) * 100) } else { 0 }
        $label = if ($v.FileSystemLabel) { [string]$v.FileSystemLabel } else { '-' }
        $lines.Add(('{0}: {1} {2} {3} {4} {5} ({6}%)' -f $v.DriveLetter, $label, $v.FileSystem, (Format-WtByteSize -Bytes ([long]$free)), (Get-Translation 'FreeOf'), (Format-WtByteSize -Bytes ([long]$size)), $pct))
    }
    if ($lines.Count -eq 0) { $lines.Add((Get-Translation 'StorageNotAvailable')) }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtStoreRepairLines (lines 27420-27466) ----
function Get-WtStoreRepairLines {
    <#
    .SYNOPSIS
        Re-registers the Store and App Installer packages - the fix for
        a vanished Store icon or a winget that stopped working. One OK /
        FAIL / not-installed line per PackageFullName; success is never
        reported silently. -AllUsers returns ONE OBJECT PER USER PROFILE
        for the same package, so results are de-duplicated on
        PackageFullName with an ordinal set before anything is
        registered.
    #>
    param(
        [scriptblock]$GetPackages = { param($Name) Get-AppxPackage -Name $Name -AllUsers -ErrorAction SilentlyContinue },
        [scriptblock]$RegisterPackage = { param($ManifestPath) Add-AppxPackage -DisableDevelopmentMode -Register $ManifestPath -ErrorAction Stop }
    )
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add((Get-Translation 'StoreRepairHeader'))
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($name in (Get-WtStoreRepairPackageNames)) {
        $packages = @()
        try { $packages = @(& $GetPackages $name | Where-Object { $_ }) }
        catch { $packages = @() }
        if ($packages.Count -eq 0) {
            $lines.Add(((Get-Translation 'StoreRepairMissing') -f $name))
            continue
        }
        foreach ($package in $packages) {
            $full = [string]$package.PackageFullName
            if ([string]::IsNullOrWhiteSpace($full)) { continue }
            if (-not $seen.Add($full)) { continue }
            $location = [string]$package.InstallLocation
            if ([string]::IsNullOrWhiteSpace($location)) {
                $lines.Add(((Get-Translation 'StoreRepairFail') -f $full, (Get-Translation 'StoreRepairNoLocation')))
                continue
            }
            $manifest = Join-Path $location 'AppXManifest.xml'
            try {
                & $RegisterPackage $manifest
                $lines.Add(((Get-Translation 'StoreRepairOk') -f $full))
            }
            catch {
                $lines.Add(((Get-Translation 'StoreRepairFail') -f $full, $_.Exception.Message))
            }
        }
    }
    return [string[]]@($lines.ToArray())
}

# ---- Get-WtStoreRepairPackageNames (lines 27408-27418) ----
function Get-WtStoreRepairPackageNames {
    <#
    .SYNOPSIS
        EXACTLY two packages. The classic internet fix -
        "Get-AppxPackage -AllUsers | Add-AppxPackage -Register" over every
        package on the machine - is FORBIDDEN here: it would reinstate
        every bloatware package this application's own debloat screen
        removed.
    #>
    return [string[]]@('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller')
}

# ---- Get-WtStoreSearchRowSegments (lines 7375-7417) ----
function Get-WtStoreSearchRowSegments {
    <#
    .SYNOPSIS
        PURE: the store's permanent search row - label, typed query with
        a caret only while focused, and the caller's right-aligned count -
        sized to exactly Inner columns so both store composers (grid and
        table) draw byte-for-byte the same row.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$Inner,
        [string]$CountText = '',
        [string]$Label = '',
        [string]$Placeholder = ''
    )
    $focused = ([string]$State.Focus -eq 'Input')
    $label = $(if ($Label) { $Label } else { Get-Translation 'WsSearchLabel' }) + ': '
    $query = [string]$State.Query
    $valueFg = if ($focused) { 'Yellow' } else { 'Gray' }
    if ($focused) { $query += '_' }
    elseif ($query -eq '' -and $Placeholder) { $query = $Placeholder; $valueFg = 'DarkGray' }
    $countText = [string]$CountText
    $used = $label.Length + $query.Length + $countText.Length
    $gap = [Math]::Max(1, $Inner - $used)
    $segs = New-Object System.Collections.Generic.List[object]
    $segs.Add((New-WtSeg -Text $label -Fg 'Cyan'))
    $segs.Add((New-WtSeg -Text $query -Fg $valueFg))
    $segs.Add((New-WtSeg -Text ((' ' * $gap) + $countText) -Fg 'DarkGray'))
    $total = 0
    foreach ($s in $segs) { $total += ([string]$s.T).Length }
    if ($total -gt $Inner) {
        $over = $total - $Inner
        for ($i = $segs.Count - 1; $i -ge 0 -and $over -gt 0; $i--) {
            $t = [string]$segs[$i].T
            if ($t.Length -le $over) { $over -= $t.Length; $segs.RemoveAt($i) }
            else { $segs[$i] = New-WtSeg -Text $t.Substring(0, $t.Length - $over) -Fg $segs[$i].F -Bg $segs[$i].B; $over = 0 }
        }
    }
    elseif ($total -lt $Inner) {
        $segs.Add((New-WtSeg -Text (' ' * ($Inner - $total)) -Fg 'DarkGray'))
    }
    return $segs.ToArray()
}

# ---- Get-WtSystemIdentityLines (lines 34237-34260) ----
function Get-WtSystemIdentityLines {
    <#
    .SYNOPSIS
        The merged "System Identity" leaf: computer + user name, BIOS
        serial, and the Windows license summary (cscript slmgr, no GUI)
        - one list of console lines. Sources are injected so the shape
        is unit-tested without CIM.
    #>
    param(
        [scriptblock]$GetSerial = { (Get-CimInstance -ClassName Win32_BIOS).SerialNumber },
        [scriptblock]$GetLicenseLines = { Get-WtLicenseInfoLines },
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$UserName = $env:USERNAME
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0}: {1}' -f (Get-Translation 'ComputerName'), $ComputerName))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'ActiveUser'), $UserName))
    $serial = try { [string](& $GetSerial) } catch { $null }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'SerialNumber'), $(if ($serial) { $serial } else { 'n/a' })))
    $lines.Add('')
    $lines.Add(((Get-Translation 'LicenseInfo') + ':'))
    foreach ($l in @(& $GetLicenseLines)) { $lines.Add('  ' + [string]$l) }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtTimeSyncLines (lines 34431-34489) ----
function Get-WtTimeSyncLines {
    <#
    .SYNOPSIS
        The clock, the time zone, the sync source, the last successful sync
        and the current offset - a drifted clock breaks HTTPS everywhere at
        once. w32tm /query calls run ONLY while W32Time is running, since a
        stopped service fails both with 0x80070426 and localized noise. The
        w32tm output is printed verbatim, never parsed, since its field
        names are localized and would silently match nothing in another
        language. /resync is an action, not information, and stays off this
        screen.
    #>
    param(
        [scriptblock]$GetNow = { Get-Date },
        [scriptblock]$GetTimeZoneName = { [System.TimeZoneInfo]::Local.DisplayName },
        [scriptblock]$GetTimeService = { Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue },
        [scriptblock]$GetTimeSource = { & w32tm /query /source 2>&1 },
        [scriptblock]$GetTimeStatus = { & w32tm /query /status 2>&1 }
    )
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $lines = New-Object System.Collections.Generic.List[string]

    $now = try { [datetime](& $GetNow) } catch { [datetime]::Now }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'TimeSyncLocalTime'), $now.ToString('yyyy-MM-dd HH:mm:ss', $invariant)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'TimeSyncUtcTime'), $now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', $invariant)))
    $zone = try { [string](& $GetTimeZoneName) } catch { '' }
    if (-not $zone) { $zone = Get-Translation 'TimeSyncZoneUnknown' }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'TimeSyncTimeZone'), $zone))

    $service = try { & $GetTimeService } catch { $null }
    if ($null -eq $service) {
        $lines.Add('')
        $lines.Add((Get-Translation 'TimeSyncServiceMissing'))
        return [string[]]$lines.ToArray()
    }
    if (-not [string]::Equals([string]$service.Status, 'Running', [System.StringComparison]::OrdinalIgnoreCase)) {
        $lines.Add('')
        $lines.Add((Get-Translation 'TimeSyncServiceStopped'))
        return [string[]]$lines.ToArray()
    }

    $lines.Add('')
    $source = try { @(& $GetTimeSource) } catch { @() }
    $sourceText = (@($source | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ' ')
    if (-not $sourceText) { $sourceText = Get-Translation 'TimeSyncNotAvailable' }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'TimeSyncSourceHeader'), $sourceText))

    $lines.Add('')
    $lines.Add(((Get-Translation 'TimeSyncStatusHeader') + ':'))
    $status = try { @(& $GetTimeStatus) } catch { @() }
    $statusLines = @($status | ForEach-Object { ([string]$_).TrimEnd() } | Where-Object { $_.Trim() })
    if ($statusLines.Count -eq 0) {
        $lines.Add('  ' + (Get-Translation 'TimeSyncNotAvailable'))
    }
    else {
        foreach ($l in $statusLines) { $lines.Add('  ' + $l) }
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtTopProcessesByMemoryLines (lines 31310-31356) ----
function Get-WtTopProcessesByMemoryLines {
    <#
    .SYNOPSIS
        The programs holding the most RAM right now, every instance of one
        name added together - so "my memory is full" gets a name.
        Group-Object -AsHashTable hands back PSObject collections on
        PowerShell 5.1, so the name -> total map is built with an explicit
        loop over an OrderedDictionary instead, which conveniently compares
        keys ordinally (what tr-TR's dotless-I rule needs too). No CPU
        column on purpose: Get-Process exposes CPU as lifetime seconds,
        which answers no question a user is asking, and reading it throws
        Access Denied on a protected process, unlike WorkingSet64.
    #>
    param(
        [scriptblock]$GetProcesses = { Get-Process -ErrorAction SilentlyContinue },
        [int]$Top = 15
    )
    $procs = @()
    try { $procs = @((& $GetProcesses) | Where-Object { $_ }) } catch { $procs = @() }
    if ($procs.Count -eq 0) { return [string[]]@([string](Get-Translation 'TopProcessesNoneFound')) }

    $totals = New-Object System.Collections.Specialized.OrderedDictionary
    $grand = [long]0
    foreach ($p in $procs) {
        $name = [string]$p.ProcessName
        if (-not $name) { $name = '(unknown)' }
        if (-not $totals.Contains($name)) {
            $totals[$name] = [PSCustomObject]@{ Name = $name; Count = 0; Bytes = [long]0 }
        }
        $entry = $totals[$name]
        $entry.Count = $entry.Count + 1
        $entry.Bytes = $entry.Bytes + [long]$p.WorkingSet64
        $grand = $grand + [long]$p.WorkingSet64
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string](Get-Translation 'TopProcessesHeading'))
    $lines.Add((('{0,-28}  {1,5}  {2,12}' -f [string](Get-Translation 'ColumnProcess'), [string](Get-Translation 'ColumnInstances'), [string](Get-Translation 'ColumnMemory'))).TrimEnd())
    foreach ($row in @(@($totals.Values) | Sort-Object -Property Bytes -Descending | Select-Object -First $Top)) {
        $name = [string]$row.Name
        if ($name.Length -gt 28) { $name = $name.Substring(0, 27) + '~' }
        $lines.Add((('{0,-28}  {1,5}  {2,12}' -f $name, $row.Count, (Format-WtByteSize -Bytes ([long]$row.Bytes)))).TrimEnd())
    }
    $lines.Add('')
    $lines.Add([string]((Get-Translation 'TopProcessesTotalLine') -f $procs.Count, $totals.Count, (Format-WtByteSize -Bytes $grand)))
    return [string[]]$lines.ToArray()
}

# ---- Get-WtTypedWord (lines 6904-6916) ----
function Get-WtTypedWord {
    <#
    .SYNOPSIS
        The word a destructive gate asks the user to type out in full -
        YES / CONFIRM in English, EVET / ONAYLA in Turkish. Upper-case in
        the prompt; what the user types is matched case-insensitively
        (see Test-WtTypedConfirmation).
    #>
    param([Parameter(Mandatory)][ValidateSet('Yes', 'Confirm')][string]$Kind)
    $word = [string](Get-Translation ('Typed' + $Kind + 'Word'))
    if (-not $word) { $word = if ($Kind -eq 'Yes') { 'YES' } else { 'CONFIRM' } }
    return $word
}

# ---- Get-WtUacLevelKey (lines 33077-33110) ----
function Get-WtUacLevelKey {
    <#
    .SYNOPSIS
        PURE: the translation key naming the UAC slider position that
        EnableLUA + ConsentPromptBehaviorAdmin describe.
        PromptOnSecureDesktop only distinguishes the two middle slider
        positions (splitting Default from Do not dim) and is otherwise
        unused. A missing or unrecognised value returns SecStateUnknown
        rather than a guess, since the user reads this line to judge
        exposure.
    #>
    param(
        [AllowNull()]$EnableLua,
        [AllowNull()]$ConsentPromptBehaviorAdmin,
        [AllowNull()]$PromptOnSecureDesktop
    )

    if ($null -eq $EnableLua -or $null -eq $ConsentPromptBehaviorAdmin) { return 'SecStateUnknown' }
    if ([int]$EnableLua -eq 0) { return 'PostureUacDisabled' }

    $secureDesktop = if ($null -eq $PromptOnSecureDesktop) { 1 } else { [int]$PromptOnSecureDesktop }
    switch ([int]$ConsentPromptBehaviorAdmin) {
        0 { return 'PostureUacNeverNotify' }
        1 { return 'PostureUacCredentials' }
        2 { return 'PostureUacAlwaysNotify' }
        3 { return 'PostureUacCredentials' }
        4 { return 'PostureUacConsent' }
        5 {
            if ($secureDesktop -eq 0) { return 'PostureUacNoDim' }
            return 'PostureUacDefault'
        }
    }
    return 'SecStateUnknown'
}

# ---- Get-WtUndoEntries (lines 12757-12789) ----
function Get-WtUndoEntries {
    <#
    .SYNOPSIS
        Reads both the Machine- and User-scoped undo\ directories and
        returns the merged set newest first, ordered by the recorded
        Timestamp field, not filename or mtime. A corrupt entry is skipped,
        not fatal, with Read-WtJson's warning captured (-WarningVariable)
        rather than printed, since this runs behind a painted frame.
    #>
    param(
        [string]$TestRootOverride
    )

    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($scope in @('Machine', 'User')) {
        $dataPathArgs = @{ Scope = $scope; SubPath = 'undo' }
        if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
        $undoDir = Get-WtDataPath @dataPathArgs

        $files = Get-ChildItem -LiteralPath $undoDir -Filter '*.json' -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $entry = Read-WtJson -Path $file.FullName -WarningAction SilentlyContinue
            if ($null -eq $entry) {
                continue
            }
            $entry | Add-Member -NotePropertyName 'Path' -NotePropertyValue $file.FullName -Force
            $entries.Add($entry)
        }
    }

    return @($entries | Sort-Object -Property { [datetime]$_.Timestamp } -Descending)
}

# ---- Get-WtUninstallCommand (lines 27188-27236) ----
function Get-WtUninstallCommand {
    <#
    .SYNOPSIS
        Turns one Add/Remove entry into a runnable, NON-interactive
        uninstall command: a product-GUID key becomes msiexec /x <guid>
        /qn /norestart, a QuietUninstallString is split into executable +
        arguments, and anything else returns Kind 'None' rather than the
        vendor's own uninstaller, which would open a UI this panel can
        neither show nor close. The GUID test uses -cmatch with both
        letter cases written into the character class, since a
        case-insensitive match folds I/i under tr-TR and could
        misclassify a key.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Entry)
    $key = [string]$Entry.Key
    if ($key -cmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
        return @{ Kind = 'Msi'; FilePath = 'msiexec.exe'; Arguments = "/x $key /qn /norestart" }
    }
    $quiet = [string]$Entry.QuietUninstallString
    if (-not [string]::IsNullOrWhiteSpace($quiet)) {
        $quiet = $quiet.Trim()
        if ($quiet.StartsWith('"', [System.StringComparison]::Ordinal)) {
            $close = $quiet.IndexOf('"', 1)
            if ($close -gt 0) {
                return @{
                    Kind      = 'Quiet'
                    FilePath  = $quiet.Substring(1, $close - 1)
                    Arguments = $quiet.Substring($close + 1).Trim()
                }
            }
        }
        $exeAt = $quiet.IndexOf('.exe', [System.StringComparison]::OrdinalIgnoreCase)
        if ($exeAt -ge 0) {
            return @{
                Kind      = 'Quiet'
                FilePath  = $quiet.Substring(0, $exeAt + 4)
                Arguments = $quiet.Substring($exeAt + 4).Trim()
            }
        }
        $space = $quiet.IndexOf(' ')
        if ($space -lt 0) { return @{ Kind = 'Quiet'; FilePath = $quiet; Arguments = '' } }
        return @{
            Kind      = 'Quiet'
            FilePath  = $quiet.Substring(0, $space)
            Arguments = $quiet.Substring($space + 1).Trim()
        }
    }
    return @{ Kind = 'None'; FilePath = ''; Arguments = '' }
}

# ---- Get-WtUninstallProgramCatalog (lines 27238-27262) ----
function Get-WtUninstallProgramCatalog {
    <#
    .SYNOPSIS
        The Show-WtSelector catalog for the uninstall picker. Name is the
        PSChildName - DisplayName is not unique, two builds of the same
        product sit next to each other and only the key tells them apart.
        Risk is left empty on purpose: the selector's own ADVANCED gate
        would ask a second, vaguer question; the single gate for this row
        is the Confirm-WtDestructiveAction that names the chosen program.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries)
    $catalog = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $Entries) {
        $label = [string]$entry.DisplayName
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.DisplayVersion)) { $label = $label + ' ' + [string]$entry.DisplayVersion }
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Publisher)) { $label = $label + ' - ' + [string]$entry.Publisher }
        $catalog.Add([PSCustomObject]@{
            Name         = [string]$entry.Key
            DisplayLabel = $label
            Risk         = ''
            Consequence  = ((Get-Translation 'UninstallConsequence') -f [string]$entry.DisplayName)
        })
    }
    return @($catalog.ToArray())
}

# ---- Get-WtUninstallProgramStateItems (lines 27264-27285) ----
function Get-WtUninstallProgramStateItems {
    <#
    .SYNOPSIS
        The live-state column for the uninstall picker: which hive the
        program lives in, and whether it can be removed without a UI.
        A program with no silent command is shown but NOT selectable -
        listing it and then failing would be worse than saying up front
        that this panel cannot drive its uninstaller.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries)
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $Entries) {
        $command = Get-WtUninstallCommand -Entry $entry
        $silent = -not [string]::Equals([string]$command.Kind, 'None', [System.StringComparison]::Ordinal)
        $items.Add([PSCustomObject]@{
            Name       = [string]$entry.Key
            Selectable = $silent
            StateLabel = $(if ($silent) { Get-Translation ([string]$entry.ScopeKey) } else { Get-Translation 'UninstallNoSilentState' })
        })
    }
    return @($items.ToArray())
}

# ---- Get-WtUninstallRegistryRoots (lines 27070-27109) ----
function Get-WtUninstallRegistryRoots {
    <#
    .SYNOPSIS
        Every registry container that holds "Add or remove programs"
        entries: the 64-bit HKLM view, the 32-bit WOW6432Node view, and
        the INTERACTIVE user's two per-user containers reached through
        Registry::HKEY_USERS\<SID>. HKCU is deliberately NOT used, since
        under Start-Process -Verb RunAs it is the ELEVATING
        administrator's hive, not the hive of the person sitting at the
        machine whose per-user installs this row exists to find.
    #>
    param(
        [scriptblock]$GetUserSid = {
            $consoleUser = $null
            try { $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName }
            catch { return $null }
            if ([string]::IsNullOrWhiteSpace($consoleUser)) { return $null }

            $resolvedSid = $null
            try {
                $resolvedSid = (New-Object System.Security.Principal.NTAccount($consoleUser)).Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
            }
            catch { return $null }
            if ([string]::IsNullOrWhiteSpace($resolvedSid)) { return $null }

            if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$resolvedSid")) { return $null }
            return $resolvedSid
        }
    )
    $roots = New-Object 'System.Collections.Generic.List[object]'
    $roots.Add(@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; ScopeKey = 'UninstallScopeMachine' })
    $roots.Add(@{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; ScopeKey = 'UninstallScopeMachine' })
    $sid = & $GetUserSid
    if (-not [string]::IsNullOrWhiteSpace([string]$sid)) {
        $roots.Add(@{ Path = "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; ScopeKey = 'UninstallScopeUser' })
        $roots.Add(@{ Path = "Registry::HKEY_USERS\$sid\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"; ScopeKey = 'UninstallScopeUser' })
    }
    return @($roots.ToArray())
}

# ---- Get-WtValidListCursor (lines 8559-8574) ----
function Get-WtValidListCursor {
    <#
    .SYNOPSIS
        PURE: the cursor a list can actually show - the given index when it
        lands on a focusable row, else the first focusable row, else -1
        (nothing to focus: a read-only page, or a filter that matched
        nothing). Keeps the highlight on a real row as the search box changes.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [int]$CursorIndex = -1
    )
    if ($CursorIndex -ge 0 -and $CursorIndex -lt $Items.Count -and (Test-WtItemFocusable -Item $Items[$CursorIndex])) { return $CursorIndex }
    for ($i = 0; $i -lt $Items.Count; $i++) { if (Test-WtItemFocusable -Item $Items[$i]) { return $i } }
    return -1
}

# ---- Get-WtVcRedistCatalog (lines 28008-28034) ----
function Get-WtVcRedistCatalog {
    <#
    .SYNOPSIS
        The twelve installers the repo bundles under
        Visual-C-Runtimes-WinToolify, pure data, in the old install_all.bat's
        order. Size guards against a truncated download. MinVersion is set
        only on the 2015-2022 family, which upgrades in place (an old 14.0
        build is what "VCRUNTIME140_1.dll is missing" comes from); 2005-2013
        are frozen lines where "present" is enough. Major is the
        DisplayVersion major the Programs list carries per family.
    #>
    $passive = '/passive /norestart'
    return @(
        @{ Id = '2005-x86'; Family = '2005'; Arch = 'x86'; Major = 8; File = 'vcredist2005_x86.exe'; Size = 2707352; Args = '/q'; MinVersion = $null }
        @{ Id = '2005-x64'; Family = '2005'; Arch = 'x64'; Major = 8; File = 'vcredist2005_x64.exe'; Size = 3175832; Args = '/q'; MinVersion = $null }
        @{ Id = '2008-x86'; Family = '2008'; Arch = 'x86'; Major = 9; File = 'vcredist2008_x86.exe'; Size = 4479832; Args = '/qb'; MinVersion = $null }
        @{ Id = '2008-x64'; Family = '2008'; Arch = 'x64'; Major = 9; File = 'vcredist2008_x64.exe'; Size = 5207896; Args = '/qb'; MinVersion = $null }
        @{ Id = '2010-x86'; Family = '2010'; Arch = 'x86'; Major = 10; File = 'vcredist2010_x86.exe'; Size = 8990552; Args = $passive; MinVersion = $null }
        @{ Id = '2010-x64'; Family = '2010'; Arch = 'x64'; Major = 10; File = 'vcredist2010_x64.exe'; Size = 10274136; Args = $passive; MinVersion = $null }
        @{ Id = '2012-x86'; Family = '2012'; Arch = 'x86'; Major = 11; File = 'vcredist2012_x86.exe'; Size = 6554576; Args = $passive; MinVersion = $null }
        @{ Id = '2012-x64'; Family = '2012'; Arch = 'x64'; Major = 11; File = 'vcredist2012_x64.exe'; Size = 7186992; Args = $passive; MinVersion = $null }
        @{ Id = '2013-x86'; Family = '2013'; Arch = 'x86'; Major = 12; File = 'vcredist2013_x86.exe'; Size = 6510136; Args = $passive; MinVersion = $null }
        @{ Id = '2013-x64'; Family = '2013'; Arch = 'x64'; Major = 12; File = 'vcredist2013_x64.exe'; Size = 7200744; Args = $passive; MinVersion = $null }
        @{ Id = '2015-2022-x86'; Family = '2015-2022'; Arch = 'x86'; Major = 14; File = 'vcredist2015_2017_2019_2022_x86.exe'; Size = 13957544; Args = $passive; MinVersion = '14.42.34433' }
        @{ Id = '2015-2022-x64'; Family = '2015-2022'; Arch = 'x64'; Major = 14; File = 'vcredist2015_2017_2019_2022_x64.exe'; Size = 25640112; Args = $passive; MinVersion = '14.42.34433' }
    )
}

# ---- Get-WtVcRedistLocalDirs (lines 28153-28178) ----
function Get-WtVcRedistLocalDirs {
    <#
    .SYNOPSIS
        Where a bundled copy of the installers might already sit: the repo
        folder next to the script or one level up (a development checkout
        runs dist\WinToolify.ps1). Only directories that exist come back;
        the released single file has none and downloads. -LaunchHome is
        the fallback the elevated relaunch hands down in
        $env:WINTOOLIFY_HOME: that child is built from script TEXT, so it
        has no $PSScriptRoot of its own and would otherwise re-download
        120 MB a development checkout already has on disk.
    #>
    param(
        [string]$ScriptRoot = $PSScriptRoot,
        [string]$LaunchHome = $env:WINTOOLIFY_HOME
    )
    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = $LaunchHome }
    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { return @() }
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($base in @($ScriptRoot, (Split-Path -Parent $ScriptRoot))) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $candidate = Join-Path $base 'Visual-C-Runtimes-WinToolify'
        if (Test-Path -LiteralPath $candidate -PathType Container) { $dirs.Add($candidate) }
    }
    return $dirs.ToArray()
}

# ---- Get-WtVcRedistPackageFile (lines 28233-28278) ----
function Get-WtVcRedistPackageFile {
    <#
    .SYNOPSIS
        The installer file for one package, as @{ Path; Source =
        'Local'|'Cache'|'Download' }: a bundled local copy if there is one
        of the right size, else the cached file of the right size, else a
        fresh download into <CacheDir>\<file>.part, renamed only once its
        length matches the catalog. A short download is deleted and
        reported; a .part left by a killed run is never trusted. Throws
        when the file cannot be obtained.
    #>
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$CacheDir,
        [AllowNull()][AllowEmptyCollection()][string[]]$LocalDirs = @(),
        [scriptblock]$Download = { param($Url, $Path, $OnProgress) Invoke-WtVcRedistDownload -Url $Url -Path $Path -OnProgress $OnProgress },
        [scriptblock]$OnProgress = { param($Percent) }
    )
    $file = [string]$Package.File
    $size = [long]$Package.Size
    foreach ($dir in @($LocalDirs)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $local = Join-Path $dir $file
        if (Test-WtVcRedistFileComplete -Path $local -Size $size) { return @{ Path = $local; Source = 'Local' } }
    }
    if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    $target = Join-Path $CacheDir $file
    if (Test-WtVcRedistFileComplete -Path $target -Size $size) { return @{ Path = $target; Source = 'Cache' } }
    $part = $target + '.part'
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    $url = Get-WtVcRedistUrl -File $file
    try { $null = & $Download $url $part $OnProgress }
    catch {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw
    }
    if (-not (Test-WtVcRedistFileComplete -Path $part -Size $size)) {
        $got = [long]0
        try { if (Test-Path -LiteralPath $part) { $got = (Get-Item -LiteralPath $part).Length } } catch { $got = 0 }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw ('size mismatch: expected {0} bytes, got {1}' -f $size, $got)
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
    Move-Item -LiteralPath $part -Destination $target -Force
    return @{ Path = $target; Source = 'Download' }
}

# ---- Get-WtVcRedistPackageLabel (lines 28047-28055) ----
function Get-WtVcRedistPackageLabel {
    <#
    .SYNOPSIS
        "Visual C++ 2015-2022 (x64)" - the same in both languages, so the
        narration lines only translate the verb around it.
    #>
    param([Parameter(Mandatory)]$Package)
    return 'Visual C++ ' + [string]$Package.Family + ' (' + [string]$Package.Arch + ')'
}

# ---- Get-WtVcRedistPlan (lines 28097-28136) ----
function Get-WtVcRedistPlan {
    <#
    .SYNOPSIS
        PURE: one row per catalog package this machine can take -
        @{ Package; Action = 'Install'|'Update'|'Skip'; InstalledVersion;
        DisplayName } - in catalog order. Present is Skip, unless MinVersion
        says the installed build is older (then Update, upgrading in place);
        an unreadable installed version still counts as present, since
        reinstalling over an unknown build is the wrong default. x64
        packages are dropped entirely on 32-bit Windows; when two rows match
        one family, the higher version wins.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Catalog,
        [AllowNull()][AllowEmptyCollection()][array]$Installed,
        [bool]$Is64Bit = $true
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($package in @($Catalog)) {
        if ([string]$package.Arch -eq 'x64' -and -not $Is64Bit) { continue }
        $hit = $null
        foreach ($item in @($Installed)) {
            if ($null -eq $item) { continue }
            if ([string]$item.Family -ne [string]$package.Family -or [string]$item.Arch -ne [string]$package.Arch) { continue }
            if ($null -eq $hit) { $hit = $item; continue }
            if ($null -ne $item.Version -and ($null -eq $hit.Version -or [version]$item.Version -gt [version]$hit.Version)) { $hit = $item }
        }
        if ($null -eq $hit) {
            $rows.Add(@{ Package = $package; Action = 'Install'; InstalledVersion = ''; DisplayName = '' })
            continue
        }
        $action = 'Skip'
        $installedVersion = if ($null -ne $hit.Version) { [string]$hit.Version } else { '' }
        if ($package.MinVersion -and $null -ne $hit.Version) {
            if ([version]$hit.Version -lt [version]$package.MinVersion) { $action = 'Update' }
        }
        $rows.Add(@{ Package = $package; Action = $action; InstalledVersion = $installedVersion; DisplayName = [string]$hit.DisplayName })
    }
    return $rows.ToArray()
}

# ---- Get-WtVcRedistUrl (lines 28036-28045) ----
function Get-WtVcRedistUrl {
    <#
    .SYNOPSIS
        Where one bundled installer is fetched from: the raw GitHub path
        of the repo folder. One file at a time - the old action pulled the
        whole repository as a 120 MB zip for every run.
    #>
    param([Parameter(Mandatory)][string]$File)
    return 'https://raw.githubusercontent.com/burakarslan0110/WinToolify/main/Visual-C-Runtimes-WinToolify/' + $File
}

# ---- Get-WtViewportWindow (lines 8501-8524) ----
function Get-WtViewportWindow {
    <#
    .SYNOPSIS
        Scroll-window math: given the cursor and previous window start,
        returns the new start so the cursor stays visible and the window
        never runs past either end. A negative CursorIndex means "no
        cursor" (read-only view): the window is honoured as-is, clamped.
    #>
    param(
        [Parameter(Mandatory)][int]$ItemCount,
        [Parameter(Mandatory)][int]$CursorIndex,
        [Parameter(Mandatory)][int]$ViewHeight,
        [Parameter(Mandatory)][int]$WindowStart
    )

    if ($ItemCount -le $ViewHeight) { return 0 }
    if ($CursorIndex -lt 0) { return [Math]::Max(0, [Math]::Min($WindowStart, $ItemCount - $ViewHeight)) }

    $start = $WindowStart
    if ($CursorIndex -lt $start) { $start = $CursorIndex }
    elseif ($CursorIndex -ge ($start + $ViewHeight)) { $start = $CursorIndex - $ViewHeight + 1 }

    return [Math]::Max(0, [Math]::Min($start, $ItemCount - $ViewHeight))
}

# ---- Get-WtVolumeOptimizeMode (lines 23355-23366) ----
function Get-WtVolumeOptimizeMode {
    <#
    .SYNOPSIS
        PURE: which Optimize-Volume switch a media type earns. 'Defrag' is
        returned only when Windows reports HDD; everything else (SSD, SCM,
        Unspecified, unreadable) gets 'ReTrim'.
    #>
    param([AllowNull()][AllowEmptyString()][string]$MediaType)

    if (([string]$MediaType) -ceq 'HDD') { return 'Defrag' }
    return 'ReTrim'
}

# ---- Get-WtWifiLinkLines (lines 32301-32332) ----
function Get-WtWifiLinkLines {
    <#
    .SYNOPSIS
        The connected wireless network with signal percentage, channel,
        radio type and TX/RX rate - "why is Wi-Fi slow" in one screen.
        netsh runs only behind a 'WlanSvc Running' guard (compared -cne,
        since tr-TR's dotless-I makes a case-insensitive match on
        'Running' unreliable), or a desktop with no wireless adapter
        shows a raw, localized netsh error; the report itself is passed
        through verbatim, since parsing Windows' own localized output
        would break on every non-English install.
    #>
    param(
        [scriptblock]$GetWlanServiceStatus = { (Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue).Status },
        [scriptblock]$GetInterfaceOutput = { netsh wlan show interfaces 2>&1 }
    )
    $status = ''
    try { $status = [string](& $GetWlanServiceStatus) }
    catch { $status = '' }
    if ($status -cne 'Running') { return [string[]]@((Get-Translation 'WifiServiceNotRunning')) }

    $raw = @()
    try { $raw = @(& $GetInterfaceOutput) }
    catch { $raw = @() }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $raw) {
        $text = ([string]$item).TrimEnd()
        if ($text.Trim()) { $lines.Add($text) }
    }
    if ($lines.Count -eq 0) { return [string[]]@((Get-Translation 'WifiLinkNoOutput')) }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtWifiPasswordLines (lines 24928-24946) ----
function Get-WtWifiPasswordLines {
    <#
    .SYNOPSIS
        PURE formatter: the lines a looked-up Wi-Fi profile should show.
        Separated from the panel flow so the wording is testable without
        a console or a real wireless profile.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result
    )
    if (-not $Result.Found) { return @((Get-Translation 'WiFiProfileNotFound')) }
    $lines = @(
        ('{0}: {1}' -f (Get-Translation 'WiFiName'), $Result.Name)
        ('{0}: {1}' -f (Get-Translation 'WiFiAuthentication'), $Result.Authentication)
    )
    if ($Result.Key) { $lines += ('{0}: {1}' -f (Get-Translation 'WiFiPassword'), $Result.Key) }
    else { $lines += (Get-Translation 'NoPasswordFound') }
    return $lines
}

# ---- Get-WtWifiProfileKey (lines 27895-27918) ----
function Get-WtWifiProfileKey {
    <#
    .SYNOPSIS
        Exports one WLAN profile with its key in clear text into a
        private temp folder, parses it, and ALWAYS deletes the export
        again - the XML holds the passphrase in plain text.
    #>
    param(
        [Parameter(Mandatory)][string]$ProfileName,
        [scriptblock]$ExportAction = { param($Name, $Folder) netsh wlan export profile name="$Name" key=clear folder="$Folder" }
    )
    $folder = Join-Path $env:TEMP ("wt-wlan-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    try {
        & $ExportAction $ProfileName $folder | Out-Null
        $file = Get-ChildItem -Path $folder -Filter '*.xml' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $file) { return [PSCustomObject]@{ Found = $false; Name = $ProfileName; Key = $null; Authentication = $null } }
        $parsed = ConvertFrom-WtWifiProfileXml -ProfileXml ([xml](Get-Content -Raw -Path $file.FullName))
        return [PSCustomObject]@{ Found = $true; Name = $parsed.Name; Key = $parsed.Key; Authentication = $parsed.Authentication }
    }
    finally {
        Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---- Get-WtWifiProfileNames (lines 25022-25043) ----
function Get-WtWifiProfileNames {
    <#
    .SYNOPSIS
        PURE: the saved profile names out of "netsh wlan show profiles".
        Splits on the first colon only, since an SSID may itself contain
        one, and never matches the line's label text, which is translated
        on a Turkish Windows.
    #>
    param([AllowEmptyCollection()][string[]]$Output = @())
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($raw in @($Output)) {
        $line = [string]$raw
        if (-not $line) { continue }
        if ($line -cnotmatch '^\s') { continue }
        $colon = $line.IndexOf(':', [System.StringComparison]::Ordinal)
        if ($colon -lt 0) { continue }
        $name = $line.Substring($colon + 1).Trim()
        if (-not $name) { continue }
        if (-not $names.Contains($name)) { $names.Add($name) }
    }
    return [string[]]$names.ToArray()
}

# ---- Get-WtWindowsBuildText (lines 34301-34326) ----
function Get-WtWindowsBuildText {
    <#
    .SYNOPSIS
        "Windows 10 Pro - 21H2 - Build 19044.4291" from a
        CurrentVersion-shaped property bag. Older keys carry ReleaseId
        instead of DisplayVersion, CurrentBuildNumber instead of
        CurrentBuild, and a 'Source OS' key can carry neither; an entry
        with nothing usable returns '' so the caller can print the key
        name instead of a row of dashes.
    #>
    param([AllowNull()]$Entry)
    if ($null -eq $Entry) { return '' }
    $name = [string]$Entry.ProductName
    $display = [string]$Entry.DisplayVersion
    if (-not $display) { $display = [string]$Entry.ReleaseId }
    $build = [string]$Entry.CurrentBuild
    if (-not $build) { $build = [string]$Entry.CurrentBuildNumber }
    $ubr = [string]$Entry.UBR
    if ($build -and $ubr) { $build = '{0}.{1}' -f $build, $ubr }
    $parts = New-Object System.Collections.Generic.List[string]
    if ($name) { $parts.Add($name) }
    if ($display) { $parts.Add($display) }
    if ($build) { $parts.Add(('{0} {1}' -f (Get-Translation 'BuildLabel'), $build)) }
    if ($parts.Count -eq 0) { return '' }
    return ($parts -join ' - ')
}

# ---- Get-WtWindowsUpdateServicePlan (lines 28403-28439) ----
function Get-WtWindowsUpdateServicePlan {
    <#
    .SYNOPSIS
        PURE: the five services a Windows Update reset has to stop, each
        resolved to StartMode / State through an injectable Win32_Service
        lookup. The returned order is the STOP order; the caller walks it
        backwards to restart, so CryptSvc (catroot2's owner) is up again
        before wuauserv asks it to verify a catalog signature. msiserver
        is deliberately excluded: only UsoSvc and DoSvc actually hold
        handles inside SoftwareDistribution.
    #>
    param(
        [string[]]$Names = @('wuauserv', 'UsoSvc', 'BITS', 'DoSvc', 'CryptSvc'),

        [scriptblock]$GetServiceInfo = {
            param($Name)
            Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction SilentlyContinue
        }
    )
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($name in $Names) {
        $info = $null
        try { $info = & $GetServiceInfo $name }
        catch { $info = $null }
        $startMode = if ($info) { [string]$info.StartMode } else { '' }
        $state = if ($info) { [string]$info.State } else { '' }
        $plan.Add([PSCustomObject]@{
                Name      = [string]$name
                StartMode = $startMode
                State     = $state
                Missing   = ($null -eq $info)
                Disabled  = [string]::Equals($startMode, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase)
                Running   = [string]::Equals($state, 'Running', [System.StringComparison]::OrdinalIgnoreCase)
            })
    }
    return $plan.ToArray()
}

# ---- Get-WtWindowsUpgradeHistoryLines (lines 34328-34373) ----
function Get-WtWindowsUpgradeHistoryLines {
    <#
    .SYNOPSIS
        When this Windows was installed, what it is running now, and every
        build it was upgraded through - the honest answer to the question
        systeminfo's single "Original Install Date" muddles, since a feature
        upgrade rewrites that date. Rows come from HKLM:\SYSTEM\Setup
        subkeys named 'Source OS*', matched Ordinal (tr-TR folds I/i
        differently). No such keys is the common case, not a failure, so
        the row prints one flat sentence instead of an empty block.
    #>
    param(
        [scriptblock]$GetCurrentVersion = { Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue },
        [scriptblock]$GetSourceOsEntries = {
            Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName.StartsWith('Source OS', [System.StringComparison]::OrdinalIgnoreCase) } |
                ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue }
        }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $cv = try { & $GetCurrentVersion } catch { $null }
    if ($null -eq $cv) {
        $lines.Add((Get-Translation 'UpgradeHistoryNotAvailable'))
        return [string[]]$lines.ToArray()
    }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'UpgradeHistoryInstalledOn'), (Format-WtUnixDate -UnixSeconds $cv.InstallDate)))
    $current = Get-WtWindowsBuildText -Entry $cv
    if (-not $current) { $current = (Get-Translation 'UpgradeHistoryDateUnknown') }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'UpgradeHistoryCurrent'), $current))

    $entries = @()
    try { $entries = @(& $GetSourceOsEntries | Where-Object { $null -ne $_ }) } catch { $entries = @() }
    if ($entries.Count -eq 0) {
        $lines.Add((Get-Translation 'UpgradeHistoryNone'))
        return [string[]]$lines.ToArray()
    }
    $lines.Add('')
    $lines.Add(((Get-Translation 'UpgradeHistoryPrevious') + ':'))
    $sorted = @($entries | Sort-Object -Property @{ Expression = { if ($null -eq $_.InstallDate) { [long]0 } else { [long]$_.InstallDate } } })
    foreach ($e in $sorted) {
        $text = Get-WtWindowsBuildText -Entry $e
        if (-not $text) { $text = [string]$e.PSChildName }
        $lines.Add(('  {0}  {1}' -f (Format-WtUnixDate -UnixSeconds $e.InstallDate), $text))
    }
    return [string[]]$lines.ToArray()
}

# ---- Get-WtWindowsVersionLines (lines 34263-34281) ----
function Get-WtWindowsVersionLines {
    <#
    .SYNOPSIS
        V1's "Show Windows Version", now with a console summary before
        winver opens: caption, DisplayVersion + build, architecture.
    #>
    param(
        [scriptblock]$GetOs = { Get-CimInstance -ClassName Win32_OperatingSystem },
        [scriptblock]$GetDisplayVersion = { (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion }
    )
    $os = & $GetOs
    $display = [string](& $GetDisplayVersion)
    $version = if ($display) { '{0} (Build {1})' -f $display, $os.BuildNumber } else { 'Build {0}' -f $os.BuildNumber }
    return [string[]]@(
        ('{0}: {1}' -f (Get-Translation 'WindowsEdition'), $os.Caption)
        ('{0}: {1}' -f (Get-Translation 'WindowsVersionLabel'), $version)
        ('{0}: {1}' -f (Get-Translation 'Architecture'), $os.OSArchitecture)
    )
}

# ---- Get-WtWingetUpgradeArguments (lines 26911-26944) ----
function Get-WtWingetUpgradeArguments {
    <#
    .SYNOPSIS
        The winget argument list for a SINGLE package upgrade, built as an
        array so nothing the user typed is ever re-parsed as script.
        --silent and --disable-interactivity are required, not optional:
        without them an installer UI or a source-agreement question
        blocks forever inside Invoke-WtCapturedAction, which has no
        cancel key, and the two --accept-* flags turn an unaccepted
        agreement into a hard failure instead of a prompt. The retry pass
        uses --name and deliberately drops --exact.
    #>
    param(
        [Parameter(Mandatory)][string]$Package,
        [switch]$ByName
    )
    $list = New-Object 'System.Collections.Generic.List[string]'
    $list.Add('upgrade')
    if ($ByName) {
        $list.Add('--name')
        $list.Add($Package)
    }
    else {
        $list.Add('--id')
        $list.Add($Package)
        $list.Add('--exact')
    }
    $list.Add('--include-unknown')
    $list.Add('--silent')
    $list.Add('--disable-interactivity')
    $list.Add('--accept-source-agreements')
    $list.Add('--accept-package-agreements')
    return [string[]]$list.ToArray()
}

# ---- Get-WtWingetUpgradeResultLines (lines 26961-26991) ----
function Get-WtWingetUpgradeResultLines {
    <#
    .SYNOPSIS
        The one-line verdict for a single-package winget run. Pure, so
        the signed/unsigned exit-code handling is testable without
        winget. 0x8A15002B = already current, 0x8A150014 = no match;
        anything else prints as the UNSIGNED hex code, since a negative
        decimal cannot be looked up in Microsoft's table.
    #>
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][AllowNull()][object]$ExitCode
    )
    $code = ConvertTo-WtWingetExitCode -ExitCode $ExitCode
    if ($null -eq $code) {
        return [string[]]@((Get-Translation 'WingetSingleFailed') -f $Package, '????????')
    }
    if ($code -eq [uint32]0) {
        return [string[]]@((Get-Translation 'WingetSingleDone') -f $Package)
    }
    if ($code -eq [Convert]::ToUInt32('8A15002B', 16)) {
        return [string[]]@((Get-Translation 'WingetSingleUpToDate') -f $Package)
    }
    if ($code -eq [Convert]::ToUInt32('8A150014', 16)) {
        return [string[]]@((Get-Translation 'WingetSingleNotFound') -f $Package)
    }
    if ($code -eq [Convert]::ToUInt32('8A15007D', 16)) {
        return [string[]]@((Get-Translation 'WsResultAdminContext') -f $Package)
    }
    return [string[]]@((Get-Translation 'WingetSingleFailed') -f $Package, ('{0:X8}' -f $code))
}

# ---- Get-WtWinToolifyLogoBase64 (lines 517-528) ----
function Get-WtWinToolifyLogoBase64 {
    <#
    .SYNOPSIS
        site/assets/logo-160.png as base64, the one copy the script
        carries. The OAuth callback page wraps it in a data URI and the
        console window turns it into a window icon; both of those sit
        above this layer, so the bytes live here rather than in either
        of them. Kept byte-identical to the shipped asset - a test
        compares the two, so a new logo cannot leave a stale one behind.
    #>
    return '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'
}

# ---- Get-WtWmiRepositoryVerdict (lines 28621-28641) ----
function Get-WtWmiRepositoryVerdict {
    <#
    .SYNOPSIS
        PURE: winmgmt /verifyrepository's exit code plus its output ->
        one of 'Consistent' / 'Inconsistent' / 'CheckFailed'. Exit code 1
        is ambiguous - inconsistent OR the check itself could not run (a
        denied WMI connect also returns 1, with 0x80041003 in the text) -
        so the verdict is decided by matching that hex token with
        -cmatch, never a culture-aware match tr-TR could bend.
    #>
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Output = @()
    )
    if ($ExitCode -eq 0) { return 'Consistent' }
    foreach ($line in @($Output)) {
        if ([string]$line -cmatch '0x[0-9A-Fa-f]{8}') { return 'CheckFailed' }
    }
    if ($ExitCode -ne 1) { return 'CheckFailed' }
    return 'Inconsistent'
}

# ---- Get-WtYesNoPrompt (lines 6893-6902) ----
function Get-WtYesNoPrompt {
    <#
    .SYNOPSIS
        A prompt sentence plus its localized yes-no hint.
    #>
    param(
        [Parameter(Mandatory)][string]$Text
    )
    return ($Text.TrimEnd() + ' ' + (Format-WtYesNoHint))
}

# ---- Initialize-WtNativeMemory (lines 24728-24745) ----
function Initialize-WtNativeMemory {
    <#
    .SYNOPSIS
        Compiles the WinToolify.NativeMemory P/Invoke type once per
        session (Add-Type refuses to redefine a loaded type), called
        lazily by the Free Memory flush action so a user who never opens
        it never pays for the compile. The C# source targets C# 5 only,
        since Windows PowerShell 5.1's Add-Type compiles with the old
        CodeDOM compiler: no string interpolation, expression-bodied
        members, nameof, out var, or null-conditional operators. The
        second ntdll import binds the same export under a distinct name
        via EntryPoint, so no ref-int/IntPtr overload resolution is ever
        involved.
    #>
    if (-not ([System.Management.Automation.PSTypeName]'WinToolify.NativeMemory').Type) {
        Add-Type -TypeDefinition $script:WtNativeMemorySource -ErrorAction Stop
    }
}

# ---- Invoke-WtBackupRegistryAction (lines 22709-22793) ----
function Invoke-WtBackupRegistryAction {
    <#
    .SYNOPSIS
        Writes importable .reg exports of the main hives into a
        machine-scope folder - the safety net to take before any tweak
        screen. Machine scope on purpose: a User-scope path would land in
        the ADMIN's profile under RunAs. Each export line prints before it
        runs, since HKLM\SOFTWARE alone can take about a minute and the
        panel only repaints on output. reg.exe's own output is swallowed
        and only its exit code trusted, since the success sentence is
        localized and would not parse on Turkish Windows. The folder ends
        up holding cleartext secrets (the admin's HKCU, a manual-autologon
        password), so its ACL inheritance is broken first and narrowed to
        Administrators/SYSTEM by well-known SID.
    #>
    param(
        [scriptblock]$GetUserSid = { Get-WtConsoleUserSid },
        [scriptblock]$GetFolder = { Get-WtDataPath -Scope Machine -SubPath ('RegistryBackup\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) },
        [scriptblock]$HardenFolderAcl = {
            param($Folder)
            $acl = Get-Acl -LiteralPath $Folder
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($wellKnown in @('S-1-5-32-544', 'S-1-5-18')) {
                $sid = New-Object System.Security.Principal.SecurityIdentifier $wellKnown
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule ($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            }
            Set-Acl -LiteralPath $Folder -AclObject $acl
        },
        [scriptblock]$ExportAction = {
            param($Key, $File)
            reg.exe export $Key $File /y | Out-Null
            return ($LASTEXITCODE -eq 0)
        },
        [scriptblock]$GetFileSize = { param($File) (Get-Item -LiteralPath $File -ErrorAction SilentlyContinue).Length }
    )

    $sid = $null
    try { $sid = [string](& $GetUserSid) } catch { $sid = $null }

    $folder = [string](& $GetFolder)
    Write-Host ((Get-Translation 'BackupRegistryFolder') -f $folder) -ForegroundColor Cyan

    $aclHardened = $false
    try {
        & $HardenFolderAcl $folder
        $aclHardened = $true
    }
    catch {
        $aclHardened = $false
    }
    if ($aclHardened) {
        Write-Host (Get-Translation 'BackupRegistryAclHardened') -ForegroundColor Yellow
    }
    else {
        Write-Host (Get-Translation 'BackupRegistryAclFailed') -ForegroundColor Red
    }

    if ([string]::IsNullOrWhiteSpace($sid)) {
        Write-Host (Get-Translation 'BackupRegistryNoUserHive') -ForegroundColor Yellow
    }

    $targets = @(Get-WtRegistryBackupTargets -UserSid $sid)
    $ok = 0
    foreach ($t in $targets) {
        $file = Join-Path $folder $t.FileName
        Write-Host ((Get-Translation 'BackupRegistryExporting') -f $t.Key) -ForegroundColor Cyan
        $done = $false
        try { $done = [bool](& $ExportAction $t.Key $file) } catch { $done = $false }
        if ($done) {
            $ok++
            $size = 0
            try { $size = [long](& $GetFileSize $file) } catch { $size = 0 }
            Write-Host ('  ' + $t.FileName + '  ' + (Format-WtByteSize -Bytes ([long]$size))) -ForegroundColor Green
            if (-not $t.Reimportable) {
                Write-Host ('  ' + (Get-Translation 'BackupRegistrySystemWarning')) -ForegroundColor Yellow
            }
        }
        else {
            Write-Host ('  ' + ((Get-Translation 'BackupRegistryFailed') -f $t.Key)) -ForegroundColor Red
        }
    }

    Write-Host ((Get-Translation 'BackupRegistryDone') -f $ok, $targets.Count) -ForegroundColor Green
    Write-Host ((Get-Translation 'BackupRegistryRestoreHint') -f $folder)
}

# ---- Invoke-WtBatteryReportAction (lines 22881-22924) ----
function Invoke-WtBatteryReportAction {
    <#
    .SYNOPSIS
        Produces Windows' full battery history report - every charge cycle
        and the capacity trend - and hands it to File Explorer. The file
        goes to explorer.exe, never Start-Process on the .html itself:
        that opens the default browser ELEVATED (Chrome refuses to run as
        administrator, Edge opens the admin's profile instead of the
        user's); explorer.exe hands off to the already-running,
        non-elevated shell. The report file name uses digits-only date
        formatting so tr-TR cannot reshape it.
    #>
    param(
        [scriptblock]$GetBattery = { Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue },
        [scriptblock]$GetFolder = { Get-WtDataPath -Scope Machine -SubPath 'Reports' },
        [scriptblock]$RunPowercfg = { param($File) powercfg /batteryreport /output $File },
        [scriptblock]$TestReport = { param($File) Test-Path -LiteralPath $File },
        [scriptblock]$OpenReport = { param($File) Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $File + '"') }
    )

    $batteries = @()
    try { $batteries = @(& $GetBattery) } catch { $batteries = @() }
    if ($batteries.Count -eq 0) {
        Write-Host (Get-Translation 'BatteryReportNoBattery') -ForegroundColor Yellow
        return
    }
    foreach ($b in $batteries) {
        Write-Host ((Get-Translation 'BatteryReportBattery') -f [string]$b.Name)
    }

    $folder = [string](& $GetFolder)
    $file = Join-Path $folder ('battery-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.html')
    Write-Host ((Get-Translation 'BatteryReportFile') -f $file) -ForegroundColor Cyan

    & $RunPowercfg $file

    if (-not (& $TestReport $file)) {
        Write-Host (Get-Translation 'BatteryReportFailed') -ForegroundColor Red
        return
    }
    Write-Host (Get-Translation 'BatteryReportDone') -ForegroundColor Green
    & $OpenReport $file
    Write-Host (Get-Translation 'BatteryReportOpened')
}

# ---- Invoke-WtBrowserCacheClear (lines 23187-23251) ----
function Invoke-WtBrowserCacheClear {
    <#
    .SYNOPSIS
        Deletes the measured cache folders of the browsers it is given and
        reports what each one freed. A browser still running after the
        close attempt is skipped, not refused, since Edge keeps msedge.exe
        alive after its last window closes.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Targets,

        [AllowEmptyCollection()][string[]]$CloseNames = @(),

        [scriptblock]$StopAction = {
            param($ProcessNames)
            foreach ($processName in @($ProcessNames)) { Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 1500
        },

        [scriptblock]$IsRunningAction = {
            param($ProcessNames)
            [bool](@(Get-Process -Name @($ProcessNames) -ErrorAction SilentlyContinue).Count -gt 0)
        },

        [scriptblock]$RemoveAction = { param($Path) Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
    )

    $results = New-Object System.Collections.Generic.List[object]
    $totalFreed = 0L

    foreach ($target in @($Targets)) {
        $errors = New-Object System.Collections.Generic.List[string]
        $freed = 0L
        $skippedKey = ''
        $askedToClose = (@($CloseNames) -ccontains [string]$target.Name)

        if ($askedToClose) { & $StopAction @($target.ProcessNames) }

        if ([bool](& $IsRunningAction @($target.ProcessNames))) {
            $skippedKey = if ($askedToClose) { 'BrowserCacheCloseFailed' } else { 'BrowserCacheSkipped' }
        }
        else {
            foreach ($path in @($target.Paths)) {
                try {
                    & $RemoveAction $path.Path
                    $freed += [long]$path.Bytes
                }
                catch {
                    $errors.Add(('{0}: {1}' -f $path.Path, $_.Exception.Message))
                }
            }
        }

        $totalFreed += $freed
        $results.Add([PSCustomObject]@{
            Name             = $target.Name
            DisplayLabel     = $target.DisplayLabel
            FreedBytes       = $freed
            SkippedReasonKey = $skippedKey
            Errors           = $errors.ToArray()
        })
    }

    return [PSCustomObject]@{ Results = $results.ToArray(); TotalFreedBytes = $totalFreed }
}

# ---- Invoke-WtCapturedAction (lines 37220-37292) ----
function Invoke-WtCapturedAction {
    <#
    .SYNOPSIS
        Runs an action with every output stream captured and rendered
        INSIDE the box, repainting at most every RefreshMs so a long
        sfc /scannow still visibly progresses; the same output then opens
        in a scrollable Show-WtOutputScreen when the command finishes.
        *>&1 merges every stream into one pipeline, so the action must
        NOT call Read-Host - ask for input in the panel before calling
        this. There is no cancel key while the command runs, matching
        the old console mode: reading the keyboard mid-pipeline would
        need a second runspace, and killing a half-finished sfc/DISM is
        worse than letting it end. Around each repaint, the console's
        encoding is swapped back to the UI encoding and then back to the
        native one, so a box-drawing glyph is never painted under a
        foreign code page.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Title = '',
        [string]$Breadcrumb = '',
        [scriptblock]$ShowProgress = {
            param($Lines, $Footer)
            $size = Get-WtConsoleSize
            $view = [Math]::Max(1, $size.Height - (Get-WtFrameChromeHeight -Width $size.Width))
            Show-WtPanelMessage -Breadcrumb $script:WtPanelBreadcrumb -Lines (Get-WtOutputTail -Lines $Lines -Count $view) -FooterText $Footer | Out-Null
        },
        [scriptblock]$ShowResult = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines },
        [int]$RefreshMs = 120,
        [AllowNull()][System.Text.Encoding]$Encoding = $null,
        [bool]$UseNativeEncoding = $true
    )
    $script:WtPanelBreadcrumb = $(if ($Breadcrumb) { $Breadcrumb } elseif ($Title) { $Title } else { '' })
    $lines = New-Object System.Collections.Generic.List[string]
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPaint = [long]-1000
    $footer = { (Get-Translation 'OutputRunning') -f (Format-WtElapsed -Seconds ([int]$watch.Elapsed.TotalSeconds)) }
    & $ShowProgress @() (& $footer)

    $uiEncoding = $null
    $nativeEncoding = $null
    if ($UseNativeEncoding) {
        try {
            $uiEncoding = [Console]::OutputEncoding
            $nativeEncoding = if ($Encoding) { $Encoding } else { Get-WtNativeOutputEncoding }
            if ($nativeEncoding.CodePage -ne $uiEncoding.CodePage) { [Console]::OutputEncoding = $nativeEncoding }
            else { $uiEncoding = $null }
        }
        catch { $uiEncoding = $null }
    }
    $paint = {
        param($Rows, $Foot)
        if ($uiEncoding) { try { [Console]::OutputEncoding = $uiEncoding } catch { $null = $_ } }
        & $ShowProgress $Rows $Foot
        if ($uiEncoding) { try { [Console]::OutputEncoding = $nativeEncoding } catch { $null = $_ } }
    }
    try {
        & $Action *>&1 | ForEach-Object {
            foreach ($line in (ConvertTo-WtOutputLines -InputObject $_)) { $lines.Add([string]$line) }
            if (($watch.ElapsedMilliseconds - $lastPaint) -ge $RefreshMs) {
                $lastPaint = $watch.ElapsedMilliseconds
                & $paint $lines.ToArray() (& $footer)
            }
        }
    }
    catch { $lines.Add([string]$_.Exception.Message) }
    finally {
        if ($uiEncoding) { try { [Console]::OutputEncoding = $uiEncoding } catch { $null = $_ } }
    }
    $watch.Stop()
    $null = Clear-WtPendingInput
    & $ShowResult $lines.ToArray()
}

# ---- Invoke-WtCleanup (lines 24069-24194) ----
function Invoke-WtCleanup {
    <#
    .SYNOPSIS
        Deletes exactly the files the preview captured for each selected
        category - per file, -LiteralPath, never -Recurse (on PS 5.1,
        Remove-Item -Recurse through a junction deletes the target's
        contents). A file that cannot be removed counts as skipped, not
        freed. Empty subdirectories the walk entered are pruned
        afterwards; the category root stays. The Windows Update category
        stops wuauserv/bits first and restarts, in a finally block, only
        the services it found running.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Preview,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedNames,

        [scriptblock]$RemoveFileAction = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop },

        [scriptblock]$RemoveDirectoryAction = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop },

        [scriptblock]$StopServiceAction = {
            param($Name)
            $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') {
                Stop-Service -Name $Name -Force -ErrorAction Stop
                return $true
            }
            return $false
        },

        [scriptblock]$StartServiceAction = { param($Name) Start-Service -Name $Name -ErrorAction Stop },

        [scriptblock]$ReportProgressAction = {
            param($Category, $Done, $Total)
            Write-Progress -Activity "Cleaning $Category" -Status "$Done of $Total files" -PercentComplete ([math]::Min(100, [int](100 * $Done / [math]::Max(1, $Total))))
        }
    )

    $results = New-Object System.Collections.Generic.List[object]
    $selected = @($Preview | Where-Object { $SelectedNames -contains $_.Name })

    foreach ($category in $selected) {
        $freed = 0L
        $deleted = 0
        $skipped = 0
        $errors = New-Object System.Collections.Generic.List[string]
        $stopped = New-Object System.Collections.Generic.List[string]

        foreach ($serviceName in @($category.ServicesToStop)) {
            try {
                if (& $StopServiceAction $serviceName) { $stopped.Add($serviceName) }
            }
            catch {
                if ($errors.Count -lt 5) { $errors.Add("Stop $serviceName - $($_.Exception.Message)") }
            }
        }

        try {
            $files = @($category.Files)
            $done = 0
            foreach ($file in $files) {
                try {
                    & $RemoveFileAction $file.Path
                    $freed += [long]$file.Length
                    $deleted++
                }
                catch {
                    $skipped++
                    if ($errors.Count -lt 5) { $errors.Add("$($file.Path) - $($_.Exception.Message)") }
                }
                $done++
                if (($done % 100) -eq 0) { & $ReportProgressAction $category.DisplayLabel $done $files.Count }
            }

            $directories = @($category.Directories | Sort-Object -Property { $_.Length } -Descending)
            foreach ($directory in $directories) {
                try {
                    if ((Test-Path -LiteralPath $directory -PathType Container) -and @([System.IO.Directory]::EnumerateFileSystemEntries($directory)).Count -eq 0) {
                        & $RemoveDirectoryAction $directory
                    }
                }
                catch { }
            }
        }
        finally {
            foreach ($serviceName in $stopped) {
                try {
                    & $StartServiceAction $serviceName
                }
                catch {
                    if ($errors.Count -lt 5) { $errors.Add("Start $serviceName - $($_.Exception.Message)") }
                }
            }
        }

        $results.Add([PSCustomObject]@{
            Name         = $category.Name
            DisplayLabel = $category.DisplayLabel
            FreedBytes   = $freed
            DeletedCount = $deleted
            SkippedCount = $skipped
            Errors       = $errors.ToArray()
        })
    }
    Write-Progress -Activity 'Cleaning' -Completed

    $totalFreed = 0L
    $totalDeleted = 0
    $totalSkipped = 0
    foreach ($result in $results) {
        $totalFreed += $result.FreedBytes
        $totalDeleted += $result.DeletedCount
        $totalSkipped += $result.SkippedCount
    }

    return [PSCustomObject]@{
        Results           = $results.ToArray()
        TotalFreedBytes   = $totalFreed
        TotalDeletedCount = $totalDeleted
        TotalSkippedCount = $totalSkipped
    }
}

# ---- Invoke-WtCleanupPreviewAction (lines 24197-24238) ----
function Invoke-WtCleanupPreviewAction {
    <#
    .SYNOPSIS
        Cleanup Preview screen: shows sizes, requires the typed
        confirmation gate, then deletes exactly the previewed files. Not
        a guarded change - nothing deleted here is restorable, so there
        is no undo entry.
    #>
    $cleanupCatalog = @(Get-WtCleanupCatalog)
    $cleanupPreview = @(Get-WtCleanupPreview -Catalog $cleanupCatalog)
    $cleanupStateItems = foreach ($previewEntry in $cleanupPreview) {
        [PSCustomObject]@{
            Name       = $previewEntry.Name
            Selectable = ($previewEntry.Count -gt 0)
            StateLabel = Format-WtCleanupPreviewLabel -Bytes $previewEntry.Bytes -Count $previewEntry.Count
        }
    }
    if (@($cleanupPreview | Where-Object { $_.Count -gt 0 }).Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'NothingToClean'))
        return
    }
    $selectedCleanup = @(Show-WtSelector -Catalog $cleanupCatalog -StateItems $cleanupStateItems -Title (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'CleanUnnecessaryFiles') -UnselectableNote '')
    if ($selectedCleanup.Count -eq 0) { return }
    $selectedPreview = @($cleanupPreview | Where-Object { $selectedCleanup -contains $_.Name })
    $reclaimable = 0L
    $detail = New-Object System.Collections.Generic.List[string]
    foreach ($previewEntry in $selectedPreview) {
        $reclaimable += [long]$previewEntry.Bytes
        $detail.Add("  $($previewEntry.DisplayLabel) [$(Get-WtRiskLabel -Risk ([string]$previewEntry.Risk))]: $(Format-WtCleanupPreviewLabel -Bytes $previewEntry.Bytes -Count $previewEntry.Count)")
        if ($previewEntry.Consequence) { $detail.Add("      $($previewEntry.Consequence)") }
    }
    $detail.Add('')
    $detail.Add("$(Get-Translation 'ReclaimableTotal'): $(Format-WtByteSize -Bytes $reclaimable)")
    if (Confirm-WtDestructiveAction -Consequence (Get-Translation 'CleanupConfirmConsequence') -Lines $detail.ToArray() -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'CleanUnnecessaryFiles')) {
        $cleanupResult = Invoke-WtCleanup -Preview $cleanupPreview -SelectedNames $selectedCleanup
        Show-WtOutputScreen -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'CleanUnnecessaryFiles') `
            -Lines (Format-WtCleanupResultLines -Result $cleanupResult) | Out-Null
    }
    else {
        Wait-WtEnter -Lines @((Get-Translation 'ActionCancelled'))
    }
}

# ---- Invoke-WtClearBrowserCachesAction (lines 23319-23353) ----
function Invoke-WtClearBrowserCachesAction {
    <#
    .SYNOPSIS
        The inline flow behind the ClearBrowserCaches row: measure first,
        ask about every running browser, then delete only the folders that
        were measured. Uses a plain scriptblock rather than GetNewClosure(),
        which loses access to this file's functions once the script runs
        standalone.
    #>
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'ClearBrowserCaches'
    $script:WtPanelBreadcrumb = $crumb

    Show-WtPanelMessage -Breadcrumb $crumb -Lines @((Get-Translation 'BrowserCacheMeasuring')) `
        -FooterText ((Get-Translation 'OutputRunning') -f (Format-WtElapsed -Seconds 0)) | Out-Null

    $found = @(Get-WtBrowserCacheTargets -Catalog (Get-WtBrowserCacheCatalog) | Where-Object { [long]$_.Bytes -gt 0 })
    if ($found.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'BrowserCacheNothing'))
        return
    }

    $measuredLines = @(Format-WtBrowserCacheLines -Targets $found)
    $closeNames = New-Object System.Collections.Generic.List[string]
    foreach ($target in $found) {
        if (-not $target.Running) { continue }
        $answer = Read-WtPanelAnswer -Breadcrumb $crumb -Lines $measuredLines -Risk 'CAUTION' `
            -Prompt (Get-WtYesNoPrompt -Text ((Get-Translation 'BrowserCacheRunningPrompt') -f $target.DisplayLabel))
        if (Test-WtAffirmativeAnswer -Answer $answer) { $closeNames.Add([string]$target.Name) }
    }

    Invoke-WtCapturedAction -Title (Get-Translation 'ClearBrowserCaches') -Breadcrumb $crumb -Action {
        $clearResult = Invoke-WtBrowserCacheClear -Targets $found -CloseNames $closeNames.ToArray()
        foreach ($line in (Format-WtBrowserCacheResultLines -Result $clearResult)) { Write-Host $line }
    }
}

# ---- Invoke-WtCloseHungProcesses (lines 26797-26826) ----
function Invoke-WtCloseHungProcesses {
    <#
    .SYNOPSIS
        Force-closes the processes the user confirmed, one line per
        process, then a closed / failed summary. Runs INSIDE
        Invoke-WtCapturedAction, so it asks nothing: the gate was already
        answered before the capture started.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Processes,
        [scriptblock]$StopProcess = { param($Id) Stop-Process -Id $Id -Force -ErrorAction Stop },
        [scriptblock]$Write = { param($Line, $Color) if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line } }
    )
    & $Write (Get-Translation 'HungAppClosing') 'Cyan'
    $closed = 0
    $failed = 0
    foreach ($process in @($Processes)) {
        try {
            & $StopProcess ([int]$process.Id) | Out-Null
            $closed++
            & $Write ('  {0} ({1}): {2}' -f $process.Name, $process.Id, (Get-Translation 'HungAppClosed')) 'Green'
        }
        catch {
            $failed++
            & $Write ('  {0} ({1}): {2}' -f $process.Name, $process.Id, $_.Exception.Message) 'Red'
        }
    }
    & $Write ((Get-Translation 'HungAppSummary') -f $closed, $failed) $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
    return [PSCustomObject]@{ Closed = $closed; Failed = $failed }
}

# ---- Invoke-WtCloseNotRespondingAppsAction (lines 26828-26870) ----
function Invoke-WtCloseNotRespondingAppsAction {
    <#
    .SYNOPSIS
        The panel flow behind "Close not-responding apps": sample, wait
        three seconds, sample again, keep only what was hung BOTH times,
        and force-close only what the typed gate confirmed - asked BEFORE
        Invoke-WtCapturedAction starts, since Read-Host inside a capture
        deadlocks. Reads $Processes from the enclosing scope, not
        GetNewClosure(), which misbehaves once the built script runs.
    #>
    param(
        [string]$Breadcrumb = (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'CloseNotRespondingApps'),
        [scriptblock]$Sample = { Get-WtHungProcessSample },
        [scriptblock]$Announce = { Show-WtPanelMessage -Breadcrumb $Breadcrumb -Lines @((Get-Translation 'HungAppScanning')) | Out-Null },
        [scriptblock]$Wait = { Start-Sleep -Seconds 3 },
        [scriptblock]$ConfirmGate = { param($Lines) Confirm-WtDestructiveAction -Consequence (Get-Translation 'HungAppConsequence') -Lines $Lines -Breadcrumb $Breadcrumb },
        [scriptblock]$Notify = { param($Lines) Wait-WtEnter -Lines $Lines },
        [scriptblock]$Close = {
            param($Processes)
            Invoke-WtCapturedAction -Title (Get-Translation 'CloseNotRespondingApps') -Breadcrumb $Breadcrumb -Action {
                $null = Invoke-WtCloseHungProcesses -Processes $Processes
            }
        }
    )
    $first = @(& $Sample)
    if ($first.Count -eq 0) {
        & $Notify @([string](Get-Translation 'HungAppNone'))
        return
    }
    & $Announce | Out-Null
    & $Wait | Out-Null
    $second = @(& $Sample)
    $hung = @(Select-WtStillHungProcesses -First $first -Second $second)
    if ($hung.Count -eq 0) {
        & $Notify @([string](Get-Translation 'HungAppRecovered'))
        return
    }
    if (-not (& $ConfirmGate (Format-WtHungProcessLines -Processes $hung))) {
        & $Notify @([string](Get-Translation 'ActionCancelled'))
        return
    }
    & $Close $hung
}

# ---- Invoke-WtDeleteOldRestorePointsAction (lines 23794-23867) ----
function Invoke-WtDeleteOldRestorePointsAction {
    <#
    .SYNOPSIS
        Frees the 10-20 GB the shadow store holds while always keeping the
        newest restore point: lists the points and the per-drive shadow
        storage first, gates on the typed word, then deletes oldest-first
        in a loop that stops at one.
    #>
    param(
        [scriptblock]$GetPoints = { Get-WtRestorePointEntries },
        [scriptblock]$GetStorage = { Get-WtShadowStorageEntries },
        [scriptblock]$GetRawShadowStorageLines = {
            try { @(& vssadmin.exe list shadowstorage | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) }
            catch { @() }
        },
        [scriptblock]$Confirm = { param($ConsequenceText, $Lines, $Crumb) Confirm-WtDestructiveAction -Consequence $ConsequenceText -Lines $Lines -Breadcrumb $Crumb },
        [scriptblock]$DeleteShadow = { param($DriveLetter) & vssadmin.exe delete shadows ('/for={0}:' -f $DriveLetter) /oldest /quiet },
        [scriptblock]$ShowCancelled = { param($Lines) Wait-WtEnter -Lines $Lines }
    )
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'DeleteOldRestorePoints'
    $script:WtPanelBreadcrumb = $crumb

    $points = @(& $GetPoints)
    if ($points.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'RestorePointsNone'))
        return
    }
    if ($points.Count -eq 1) {
        Wait-WtEnter -Lines @((Get-Translation 'RestorePointsOnlyOne'))
        return
    }

    $storageBefore = @(& $GetStorage)
    $rawLines = @(& $GetRawShadowStorageLines)

    $newest = $points[0]
    $newestStamp = ''
    if ($newest.CreationTime) {
        $newestStamp = ([datetime]$newest.CreationTime).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $keptText = '{0} ({1})' -f [string]$newest.Description, $newestStamp
    $consequence = (Get-Translation 'ConsequenceDeleteRestorePoints') -f ($points.Count - 1), $keptText

    if (-not (& $Confirm $consequence (Format-WtRestorePointDeleteLines -Points $points -Storage $storageBefore -RawLines $rawLines) $crumb)) {
        & $ShowCancelled @((Get-Translation 'ActionCancelled'))
        return
    }

    $driveLetters = @($storageBefore | ForEach-Object { [string]$_.DriveLetter } |
        Where-Object { $_ -cmatch '^[A-Za-z]:' } | ForEach-Object { $_.Substring(0, 1) })
    if ($driveLetters.Count -eq 0) { $driveLetters = @(([string]$env:SystemDrive).Substring(0, 1)) }

    Invoke-WtCapturedAction -Title (Get-Translation 'DeleteOldRestorePoints') -Breadcrumb $crumb -Action {
        $deletedTotal = 0
        $remainingTotal = 0
        foreach ($letter in $driveLetters) {
            Write-Host ((Get-Translation 'RestorePointsDeleting') -f ($letter + ':')) -ForegroundColor Cyan
            $loop = Invoke-WtShadowOldestLoop -DriveLetter $letter `
                -CountAction { param($Drive) Get-WtShadowCopyCount -DriveLetter $Drive } `
                -DeleteAction { param($Drive) & $DeleteShadow $Drive }
            $deletedTotal += [int]$loop.Deleted
            $remainingTotal += [int]$loop.Remaining
        }
        Write-Host ((Get-Translation 'RestorePointsDeleted') -f $deletedTotal, $remainingTotal) -ForegroundColor Green

        $usedBefore = 0L
        foreach ($item in @($storageBefore)) { $usedBefore += [long]$item.UsedBytes }
        $usedAfter = 0L
        foreach ($item in @(& $GetStorage)) { $usedAfter += [long]$item.UsedBytes }
        $reclaimed = $usedBefore - $usedAfter
        if ($reclaimed -lt 0) { $reclaimed = 0L }
        Write-Host ('{0}: {1}' -f (Get-Translation 'RestorePointsReclaimed'), (Format-WtByteSize -Bytes $reclaimed)) -ForegroundColor Green
    }
}

# ---- Invoke-WtDiskCleanupAction (lines 23051-23064) ----
function Invoke-WtDiskCleanupAction {
    <#
    .SYNOPSIS
        Disk Cleanup: the first run opens cleanmgr's category picker
        (/sageset:65) so the user decides once; every run after that
        executes the saved profile (/sagerun:65).
    #>
    if (-not (Test-WtDiskCleanupConfigured)) {
        Write-Host (Get-Translation 'DiskCleanupFirstRun') -ForegroundColor Yellow
        Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sageset:65' -Wait
    }
    Write-Host (Get-Translation 'DiskCleanupRunning') -ForegroundColor Cyan
    Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:65' -Wait
}

# ---- Invoke-WtDnsResolutionTestAction (lines 32742-32783) ----
function Invoke-WtDnsResolutionTestAction {
    <#
    .SYNOPSIS
        Inline row: the host name is asked for in the panel, validated,
        and only then are the three servers printed and queried.
        Read-WtPanelAnswer runs before Invoke-WtCapturedAction on
        purpose - an interactive prompt inside a captured action would
        deadlock, since output capture blocks the direct keyboard read
        the prompt needs. $Run resolves $target through the scope chain
        rather than via GetNewClosure, which breaks when the bundle runs
        as a script rather than dot-sourced.
    #>
    param(
        [string]$DefaultName = 'www.microsoft.com',
        [scriptblock]$AskName = {
            param($Crumb, $Default)
            Read-WtPanelAnswer -Breadcrumb $Crumb -Lines @() -Prompt ((Get-Translation 'DnsTestPrompt') -f $Default) -Layout 'Compact'
        },
        [scriptblock]$Run = {
            param($HostName, $Crumb)
            $target = $HostName
            Invoke-WtCapturedAction -Title (Get-Translation 'DnsResolutionTest') -Breadcrumb $Crumb -Action {
                foreach ($l in (Get-WtDnsTestPlanLines -Name $target)) { Write-Host $l }
                foreach ($l in (Get-WtDnsTestResultLines -Name $target)) { Write-Host $l }
            }
        },
        [scriptblock]$ShowInvalid = {
            param($Crumb, $Text)
            $null = Read-WtPanelAnswer -Breadcrumb $Crumb -Lines @(((Get-Translation 'DnsTestInvalidHost') -f $Text)) -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
        }
    )
    $crumb = if ($script:WtPanelBreadcrumb) { $script:WtPanelBreadcrumb } else { [string](Get-Translation 'DnsResolutionTest') }
    $answer = & $AskName $crumb $DefaultName
    if ($null -eq $answer) { return }
    $entered = ([string]$answer).Trim()
    if (-not $entered) { $entered = $DefaultName }
    if (-not (Test-WtHostName -Name $entered)) {
        & $ShowInvalid $crumb $entered
        return
    }
    & $Run $entered $crumb
}

# ---- Invoke-WtDuplicateFinderAction (lines 24595-24630) ----
function Invoke-WtDuplicateFinderAction {
    <#
    .SYNOPSIS
        Duplicate File Finder: report only, never deletes.
    #>
    $scanRoots = @(Get-WtDuplicateScanRootCatalog)
    $scanStateItems = foreach ($entry in $scanRoots) {
        $exists = [bool]($entry.Path -and (Test-Path -LiteralPath $entry.Path -PathType Container))
        [PSCustomObject]@{
            Name       = $entry.Name
            Selectable = $exists
            StateLabel = if ($exists) { $entry.Path } else { Get-Translation 'FolderNotFound' }
        }
    }
    $selectedRoots = @(Show-WtSelector -Catalog $scanRoots -StateItems $scanStateItems -Title (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'DuplicateFinder') -UnselectableNote '')
    $rootPaths = @($scanRoots | Where-Object { $selectedRoots -contains $_.Name } | ForEach-Object { $_.Path })
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'DuplicateFinder'
    $script:WtPanelBreadcrumb = $crumb
    $extraFolder = ([string](Read-WtPanelAnswer -Breadcrumb $crumb -Lines @() -Prompt (Get-Translation 'ExtraFolderPrompt') -Layout 'Compact')).Trim()
    if ($extraFolder) {
        if (Test-Path -LiteralPath $extraFolder -PathType Container) { $rootPaths += $extraFolder }
        else { Wait-WtEnter -Lines @('{0}: {1}' -f (Get-Translation 'FolderNotFound'), $extraFolder) }
    }
    if ($rootPaths.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'NoScanRoots'))
        return
    }
    Show-WtPanelMessage -Breadcrumb $crumb -Lines @((Get-Translation 'DuplicateFinder')) -FooterText ((Get-Translation 'OutputRunning') -f (Format-WtElapsed -Seconds 0)) | Out-Null
    $scanFiles = @(foreach ($rootPath in $rootPaths) {
        (Get-WtFileInventory -Root $rootPath -MinSizeBytes $script:WtDuplicateMinSizeBytes).Files
    })
    $duplicateResult = Get-WtDuplicateGroups -Files $scanFiles
    Show-WtSavableReport -Breadcrumb $crumb -ReportName 'duplicates' `
        -Lines (@((Get-Translation 'DuplicateFinder'), '') + @(Format-WtDuplicateReportLines -Result $duplicateResult -MaxGroups 25)) `
        -SaveAction { param($Name, $Rows) Save-WtReport -Name $Name -Lines @(Format-WtDuplicateReportLines -Result $duplicateResult) }
}

# ---- Invoke-WtExportDriversAction (lines 22826-22879) ----
function Invoke-WtExportDriversAction {
    <#
    .SYNOPSIS
        Copies every third-party driver package into a machine-scope
        folder, so a clean install needs no hunt through OEM sites.
        Machine scope for the same RunAs reason as the registry backup.
        Packages are consumed via ForEach-Object, one line per package:
        collecting the pipeline into @() first would print nothing until
        the whole 1-5 GB export finished.
    #>
    param(
        [scriptblock]$GetFolder = { Get-WtDataPath -Scope Machine -SubPath ('DriverBackup\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) },
        [scriptblock]$CheckSpace = { param($Folder) Test-WtDriverExportSpace -Path $Folder },
        [scriptblock]$ExportAction = { param($Folder) Export-WindowsDriver -Online -Destination $Folder },
        [scriptblock]$GetFolderSize = {
            param($Folder)
            (Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        }
    )

    $folder = [string](& $GetFolder)
    Write-Host ((Get-Translation 'ExportDriversFolder') -f $folder) -ForegroundColor Cyan

    $space = & $CheckSpace $folder
    Write-Host ((Get-Translation 'ExportDriversFreeSpace') -f $space.Root, (Format-WtByteSize -Bytes ([long]$space.FreeBytes)), (Format-WtByteSize -Bytes ([long]$space.RequiredBytes)))
    if (-not $space.Sufficient) {
        Write-Host (Get-Translation 'ExportDriversNoSpace') -ForegroundColor Red
        return
    }

    Write-Host (Get-Translation 'ExportDriversRunning') -ForegroundColor Cyan
    $exported = New-Object System.Collections.Generic.List[string]
    try {
        & $ExportAction $folder | ForEach-Object {
            $name = [string]$_.OriginalFileName
            $exported.Add($name)
            Write-Host ('  ' + $name)
        }
    }
    catch {
        Write-Host ((Get-Translation 'ExportDriversFailed') -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    if ($exported.Count -eq 0) {
        Write-Host (Get-Translation 'ExportDriversNone') -ForegroundColor Yellow
        return
    }

    $size = 0
    try { $size = [long](& $GetFolderSize $folder) } catch { $size = 0 }
    Write-Host ((Get-Translation 'ExportDriversDone') -f $exported.Count, (Format-WtByteSize -Bytes ([long]$size))) -ForegroundColor Green
    Write-Host ((Get-Translation 'ExportDriversRestoreHint') -f $folder)
}

# ---- Invoke-WtExportWifiProfilesAction (lines 22975-23023) ----
function Invoke-WtExportWifiProfilesAction {
    <#
    .SYNOPSIS
        Inline flow for the Wi-Fi profile export: asks for the target
        folder in the panel, puts up the typed-confirmation gate, and only
        then runs the export inside the captured panel. The folder prompt
        happens BEFORE Invoke-WtCapturedAction because a Read-Host inside
        a captured action deadlocks behind the capture.
    #>
    param(
        [scriptblock]$GetDefaultFolder = { Join-Path $env:USERPROFILE 'Desktop\WinToolify-WiFi' },
        [scriptblock]$AskFolder = {
            param($Default)
            Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @(((Get-Translation 'ExportWifiProfilesFolderHint') -f $Default)) -Prompt (Get-Translation 'ExportWifiProfilesFolderPrompt') -Risk 'ADVANCED'
        },
        [scriptblock]$Confirm = {
            param($Consequence, $Lines)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines -Breadcrumb $script:WtPanelBreadcrumb
        },
        [scriptblock]$Notify = {
            param($Lines)
            $null = Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
        },
        [scriptblock]$Run = {
            param($Folder, $Crumb)
            $target = $Folder
            Invoke-WtCapturedAction -Title (Get-Translation 'ExportWifiProfiles') -Breadcrumb $Crumb -Action { Invoke-WtWifiProfileExport -Folder $target }
        }
    )

    $default = [string](& $GetDefaultFolder)
    $answer = & $AskFolder $default
    if ($null -eq $answer) { return }

    $folder = ([string]$answer).Trim().Trim('"').Trim()
    if (-not $folder) { $folder = $default }

    $lines = @(
        ((Get-Translation 'ExportWifiProfilesTargetLine') -f $folder)
        (Get-Translation 'ExportWifiProfilesClearTextLine')
        (Get-Translation 'ExportWifiProfilesStaysOnDiskLine')
    )
    if (-not (& $Confirm (Get-Translation 'ExportWifiProfilesConsequence') $lines)) {
        & $Notify @((Get-Translation 'ExportWifiProfilesCancelled'))
        return
    }

    & $Run $folder $script:WtPanelBreadcrumb
}

# ---- Invoke-WtForgetWifiProfileAction (lines 25045-25083) ----
function Invoke-WtForgetWifiProfileAction {
    <#
    .SYNOPSIS
        Panel flow: list the saved wireless profiles, ask for a number in
        the panel, then delete exactly that one profile with netsh. The
        chosen SSID is passed as ONE quoted argument ("name=<ssid>"), so
        an SSID with spaces is not re-split by the native command line and
        nothing the user typed is ever re-parsed as script.
    #>
    param(
        [scriptblock]$ListProfiles = { netsh wlan show profiles },
        [scriptblock]$AskChoice = { param($Lines) Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -Prompt (Get-Translation 'WifiProfilePickPrompt') -Risk 'CAUTION' },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$Run = {
            param($ProfileName, $Crumb)
            $target = $ProfileName
            Invoke-WtCapturedAction -Title (Get-Translation 'ForgetWifiProfile') -Breadcrumb $Crumb -Action {
                Write-Host ((Get-Translation 'WifiProfileDeleting') -f $target)
                netsh wlan delete profile "name=$target"
            }
        }
    )
    $names = @(Get-WtWifiProfileNames -Output @(& $ListProfiles | ForEach-Object { [string]$_ }))
    if ($names.Count -eq 0) {
        & $ShowMessage @((Get-Translation 'WifiProfilesNone'))
        return
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'WifiProfilePickHeader'))
    for ($i = 0; $i -lt $names.Count; $i++) { $lines.Add(('  [{0}] {1}' -f ($i + 1), $names[$i])) }
    $answer = ([string](& $AskChoice $lines.ToArray())).Trim()
    if (-not $answer) { return }
    $index = 0
    if (-not [int]::TryParse($answer, [ref]$index) -or $index -lt 1 -or $index -gt $names.Count) {
        & $ShowMessage @((Get-Translation 'WifiProfileInvalidChoice'))
        return
    }
    & $Run $names[$index - 1] $script:WtPanelBreadcrumb
}

# ---- Invoke-WtFreeMemoryAction (lines 24870-24892) ----
function Invoke-WtFreeMemoryAction {
    <#
    .SYNOPSIS
        Transient (never staged): the memory-flush selector with the live
        RAM figure on the same screen, then the flush and its report.
    #>
    $flushCatalog = @(Get-WtMemoryFlushCatalog)
    $flushStateItems = foreach ($entry in $flushCatalog) {
        [PSCustomObject]@{ Name = $entry.Name; Selectable = $true; StateLabel = (Get-Translation 'FlushAvailable') }
    }
    $ramLine = ''
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $ramLine = (Get-Translation 'RamUsageLine') -f [math]::Round($os.FreePhysicalMemory / 1024), [math]::Round($os.TotalVisibleMemorySize / 1024)
    }
    catch { $ramLine = '' }
    $selectorArgs = @{ Catalog = $flushCatalog; StateItems = $flushStateItems; Title = (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'FreeMemory') }
    if ($ramLine) { $selectorArgs['InfoLines'] = @($ramLine) }
    $selectedFlush = @(Show-WtSelector @selectorArgs)
    if ($selectedFlush.Count -eq 0) { return }
    $flushResult = Invoke-WtMemoryFlush -SelectedNames $selectedFlush
    Show-WtOutputScreen -Breadcrumb (Get-Translation 'FreeMemory') -Lines (Format-WtMemoryFlushLines -Result $flushResult -Catalog $flushCatalog) | Out-Null
}

# ---- Invoke-WtLargestFilesReportAction (lines 33987-34021) ----
function Invoke-WtLargestFilesReportAction {
    <#
    .SYNOPSIS
        Inline row: the path is asked for IN THE PANEL first (empty means
        the profile folder, never the whole drive), then the walk is
        handed to Invoke-WtCapturedAction - a Read-Host inside a captured
        action deadlocks behind the capture, so the question cannot live
        in the scriptblock.
    #>
    param(
        [string]$DefaultRoot = $env:USERPROFILE,
        [scriptblock]$AskPath = {
            param($Crumb, $Lines, $Prompt)
            Read-WtPanelAnswer -Breadcrumb $Crumb -Lines $Lines -Prompt $Prompt -Risk 'CAUTION' -Layout 'Compact'
        },
        [scriptblock]$TestRoot = { param($Path) Test-Path -LiteralPath $Path -PathType Container },
        [scriptblock]$Run = {
            param($Root, $Crumb)
            $target = $Root
            Invoke-WtCapturedAction -Title (Get-Translation 'LargestFilesReport') -Breadcrumb $Crumb -Action {
                foreach ($l in (Get-WtLargestFilesReportLines -Root $target)) { Write-Host $l }
            }
        }
    )
    $crumb = if ($script:WtPanelBreadcrumb) { $script:WtPanelBreadcrumb } else { Get-Translation 'LargestFilesReport' }
    $answer = & $AskPath $crumb @(((Get-Translation 'ScanPathDefaultHint') -f $DefaultRoot)) (Get-Translation 'ScanPathPrompt')
    if ($null -eq $answer) { return }
    $root = ([string]$answer).Trim().Trim('"')
    if (-not $root) { $root = $DefaultRoot }
    if (-not (& $TestRoot $root)) {
        Wait-WtEnter -Lines @(('{0}: {1}' -f (Get-Translation 'FolderNotFound'), $root))
        return
    }
    & $Run $root $crumb
}

# ---- Invoke-WtLargestFoldersReportAction (lines 33831-33867) ----
function Invoke-WtLargestFoldersReportAction {
    <#
    .SYNOPSIS
        Inline row: the path is asked for IN THE PANEL first (empty means
        the profile folder, never the whole drive), then the walk is
        handed to Invoke-WtCapturedAction - a Read-Host inside a captured
        action deadlocks behind the capture, so the question cannot live
        in the scriptblock. $target is captured by the inner
        scriptblock's defining scope rather than via GetNewClosure,
        which breaks once WinToolify.ps1 is run rather than dot-sourced.
    #>
    param(
        [string]$DefaultRoot = $env:USERPROFILE,
        [scriptblock]$AskPath = {
            param($Crumb, $Lines, $Prompt)
            Read-WtPanelAnswer -Breadcrumb $Crumb -Lines $Lines -Prompt $Prompt -Risk 'CAUTION' -Layout 'Compact'
        },
        [scriptblock]$TestRoot = { param($Path) Test-Path -LiteralPath $Path -PathType Container },
        [scriptblock]$Run = {
            param($Root, $Crumb)
            $target = $Root
            Invoke-WtCapturedAction -Title (Get-Translation 'LargestFoldersReport') -Breadcrumb $Crumb -Action {
                foreach ($l in (Get-WtLargestFoldersReportLines -Root $target)) { Write-Host $l }
            }
        }
    )
    $crumb = if ($script:WtPanelBreadcrumb) { $script:WtPanelBreadcrumb } else { Get-Translation 'LargestFoldersReport' }
    $answer = & $AskPath $crumb @(((Get-Translation 'ScanPathDefaultHint') -f $DefaultRoot)) (Get-Translation 'ScanPathPrompt')
    if ($null -eq $answer) { return }
    $root = ([string]$answer).Trim().Trim('"')
    if (-not $root) { $root = $DefaultRoot }
    if (-not (& $TestRoot $root)) {
        Wait-WtEnter -Lines @(('{0}: {1}' -f (Get-Translation 'FolderNotFound'), $root))
        return
    }
    & $Run $root $crumb
}

# ---- Invoke-WtListMarkToggle (lines 8765-8800) ----
function Invoke-WtListMarkToggle {
    <#
    .SYNOPSIS
        Space / digit on one row. Check rows toggle their mark ("apply" on a
        not-applied row, "remove" on an applied one - the checkbox never
        encodes live state); Radio rows move their group's single mark. An
        applied, non-Removable Check row cannot be marked: returns 'Refused'
        so the shell shows the hint; 'None' otherwise.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Selection,
        [hashtable]$Cycle
    )
    $props = $Item.PSObject.Properties.Name
    if ($Item.Kind -eq 'Check') {
        $applied = ($props -contains 'Applied') -and [bool]$Item.Applied
        $removable = ($props -contains 'Removable') -and [bool]$Item.Removable
        if ($applied -and -not $removable) { return 'Refused' }
        $targets = @($(if ($props -contains 'CycleTargets') { $Item.CycleTargets } else { @() }))
        if ($targets.Count -gt 0 -and $null -ne $Cycle) {
            $name = [string]$Item.Name
            $at = if ($Cycle.ContainsKey($name)) { [Array]::IndexOf($targets, [string]$Cycle[$name]) } else { -1 }
            $next = $at + 1
            if ($next -ge $targets.Count) { $Cycle.Remove($name); $Selection.Remove($name) | Out-Null }
            else { $Cycle[$name] = [string]$targets[$next]; $Selection.Add($name) | Out-Null }
            return 'None'
        }
        Set-WtSelectionToggle -SelectionSet $Selection -Item $Item | Out-Null
    }
    elseif ($Item.Kind -eq 'Radio' -and $Item.Selectable) {
        Set-WtRadioSelection -SelectionSet $Selection -Items $Items -Item $Item
    }
    return 'None'
}

# ---- Invoke-WtListScreen (lines 8379-8494) ----
function Invoke-WtListScreen {
    <#
    .SYNOPSIS
        The one interactive loop: frame -> key batch -> reducer, until the
        reducer emits @{ Emit; Char; Item; Selection; CursorIndex }. With
        Searchable on, CursorIndex always indexes the caller's Items, not
        the filtered view shown while a query is active.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [bool]$MultiSelect = $false,
        [System.Collections.Generic.HashSet[string]]$Selection,
        [string]$FooterText = '',
        [scriptblock]$OnSelectionChanged,
        [bool]$ShowBanner = $false,
        [string]$CounterText = '',
        [int]$InitialCursor = -1,
        [ValidateSet('Full', 'Compact')][string]$Layout = 'Full',
        [hashtable]$Cycle,
        [hashtable]$CycleLabels = @{},
        [bool]$Searchable = $false,
        [int]$DescriptionRows = 0
    )
    if ($null -eq $Selection) { $Selection = New-Object 'System.Collections.Generic.HashSet[string]' }
    if ($null -eq $Cycle) { $Cycle = @{} }
    $cursor = 0
    $anyFocusable = $false
    foreach ($probe in $Items) { if (Test-WtItemFocusable -Item $probe) { $anyFocusable = $true; break } }
    if (-not $anyFocusable) {
        $cursor = -1
    }
    elseif ($InitialCursor -ge 0 -and $InitialCursor -lt $Items.Count -and (Test-WtItemFocusable -Item $Items[$InitialCursor])) { $cursor = $InitialCursor }
    elseif ($Items.Count -gt 0 -and -not (Test-WtItemFocusable -Item $Items[0])) {
        $cursor = Get-WtNextFocusableIndex -Items $Items -FromIndex 0 -Direction 1
    }
    $state = @{ CursorIndex = $cursor; WindowStart = 0; Selection = $Selection; Cycle = $Cycle; Focus = 'List'; Query = '' }
    $shown = $Items
    $result = { param($Emit, $Char, $Item)
        $at = [int]$state.CursorIndex
        if ($Searchable -and $at -ge 0 -and $at -lt $shown.Count) {
            $name = [string]$shown[$at].Name
            $at = -1
            for ($i = 0; $i -lt $Items.Count; $i++) {
                if ([string]::Equals([string]$Items[$i].Name, $name, [System.StringComparison]::Ordinal)) { $at = $i; break }
            }
        }
        @{ Emit = $Emit; Char = $Char; Item = $Item; Selection = $Selection; Cycle = $Cycle; CursorIndex = $at }
    }
    $hintFooter = ''
    $footerSize = [string]$FooterText
    if ($Searchable) {
        foreach ($candidate in @((Get-WtSearchableFooter -Footer $FooterText -Hint (Get-Translation 'ListSearchKeyHint')), (Get-Translation 'ListSearchFooter'))) {
            if (([string]$candidate).Length -gt $footerSize.Length) { $footerSize = [string]$candidate }
        }
    }

    while ($true) {
        $shown = $Items
        $search = $null
        if ($Searchable) {
            $q = [string]$state.Query
            $filtered = ($q.Trim() -ne '')
            if ($filtered) {
                $shown = @(Select-WtListItems -Items $Items -Query $q)
                if ($shown.Count -eq 0) { $shown = @(Get-WtListSearchEmptyItem) }
            }
            $countText = ''
            if ($filtered) {
                $countText = (Get-Translation 'ListSearchCount') -f (Get-WtFocusableCount -Items $shown), (Get-WtFocusableCount -Items $Items)
                if ([string]$state.Focus -ne 'Input') { $countText += ' - ' + (Get-Translation 'ListSearchClearHint') }
            }
            $search = @{ Focus = [string]$state.Focus; Query = $q; CountText = $countText }
            $state.CursorIndex = Get-WtValidListCursor -Items $shown -CursorIndex ([int]$state.CursorIndex)
        }
        $size = Get-WtConsoleSize
        $viewHeight = [Math]::Max(1, $size.Height - (Get-WtFrameChromeHeight -Width $size.Width -ShowBanner $ShowBanner -Searchable $Searchable -DescriptionRows $DescriptionRows))
        $counter = $CounterText
        if ($MultiSelect) {
            $marked = (Get-WtMarkSummary -Items $Items -Selection $Selection).Text
            $counter = (@($CounterText, $marked) | Where-Object { $_ }) -join '  '
        }
        $footer = if ($hintFooter) { $hintFooter }
                  elseif ($Searchable -and [string]$state.Focus -eq 'Input') { Get-Translation 'ListSearchFooter' }
                  elseif ($Searchable) { Get-WtSearchableFooter -Footer $FooterText -Hint (Get-Translation 'ListSearchKeyHint') }
                  else { $FooterText }
        $hintFooter = ''
        $frame = Get-WtFrameRows -Breadcrumb $Breadcrumb -Items $shown -State $state -Width $size.Width -Height $size.Height `
            -Glyphs $script:WtGlyphs -CounterText $counter -FooterText $footer -CycleLabels $CycleLabels `
            -LineMode ($script:WtInputMode -eq 'Line') -ShowBanner $ShowBanner -Layout $Layout -Search $search `
            -SizeItems $Items -FooterSizeText $footerSize -DescriptionRows $DescriptionRows
        Write-WtFrame -FrameLines $frame -Width $size.Width -Height $size.Height

        $before = (@($Selection) | Sort-Object) -join "`n"
        $converter = $null
        if ($Searchable -and [string]$state.Focus -eq 'Input') {
            $converter = { param($Key, $KeyChar) ConvertTo-WtGridKeyToken -Key $Key -KeyChar $KeyChar }
        }
        $tokens = Read-WtInputBatch -Converter $converter
        $r = Invoke-WtTokenBatch -State $state -Tokens $tokens -Items $shown -ViewHeight $viewHeight -MultiSelect $MultiSelect -Searchable $Searchable
        $state = $r.State
        $after = (@($Selection) | Sort-Object) -join "`n"
        if ($OnSelectionChanged -and $after -ne $before) { & $OnSelectionChanged }

        if ($r.Emit -eq 'Back') { return (& $result 'Back' '' $null) }
        if ($r.Emit -eq 'Refused') { $hintFooter = Get-Translation 'RemoveUnavailableHint'; continue }
        if ($r.Emit -eq 'Activate') {
            $item = if ($state.CursorIndex -ge 0 -and $state.CursorIndex -lt $shown.Count) { $shown[$state.CursorIndex] } else { $null }
            return (& $result 'Activate' '' $item)
        }
        if ($r.Emit -eq 'Global') {
            if ($r.EmitChar -eq 'q') { return (& $result 'Quit' '' $null) }
            return (& $result 'Global' $r.EmitChar $null)
        }
    }
}

# ---- Invoke-WtMemoryFlush (lines 24796-24867) ----
function Invoke-WtMemoryFlush {
    <#
    .SYNOPSIS
        Runs the selected Free Memory operations, each in its own try/catch
        (one failure never stops the rest), and reports available memory
        before/after plus a per-operation outcome. Deliberately NOT wired
        through Invoke-WtGuardedChange: a memory flush changes no persistent
        state, so there is nothing to restore-point or undo. -FlushAction
        defaults to the real native call and throws on a non-zero NTSTATUS;
        -GetAvailableMemoryAction defaults to the real Win32_OperatingSystem
        read. Both are injectable, since neither ntdll nor CIM exists on
        the macOS dev host.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedNames,

        [scriptblock]$FlushAction = {
            param($Entry)
            Initialize-WtNativeMemory
            if ($Entry.Privilege) {
                if (-not [WinToolify.NativeMemory]::EnablePrivilege($Entry.Privilege)) {
                    throw "Could not enable $($Entry.Privilege)"
                }
            }
            $status = if ($Entry.Operation -eq 'RegistryReconcile') {
                [WinToolify.NativeMemory]::ReconcileRegistry()
            }
            else {
                [WinToolify.NativeMemory]::SetMemoryListCommand([int]$Entry.Command)
            }
            if ($status -ne 0) {
                throw ('NTSTATUS 0x{0:X8}' -f $status)
            }
        },

        [scriptblock]$GetAvailableMemoryAction = {
            [math]::Round((Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory / 1024)
        }
    )

    $catalog = Get-WtMemoryFlushCatalog
    $selected = @($catalog | Where-Object { $SelectedNames -contains $_.Name })

    $beforeMB = [double](& $GetAvailableMemoryAction)

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $selected) {
        $flushError = $null
        try {
            & $FlushAction $entry
        }
        catch {
            $flushError = $_.Exception.Message
        }
        $results.Add([PSCustomObject]@{
            Name      = $entry.Name
            Succeeded = ($null -eq $flushError)
            Error     = $flushError
        })
    }

    $afterMB = [double](& $GetAvailableMemoryAction)

    return [PSCustomObject]@{
        BeforeMB = $beforeMB
        AfterMB  = $afterMB
        FreedMB  = [math]::Max(0, $afterMB - $beforeMB)
        Results  = $results.ToArray()
    }
}

# ---- Invoke-WtOptimizeVolumesAction (lines 23421-23477) ----
function Invoke-WtOptimizeVolumesAction {
    <#
    .SYNOPSIS
        Per-volume TRIM or defragment, chosen in a picker rather than a
        blind loop over every drive - a defragment on a spinning disk can
        run for an hour with no cancel key, so picking by hand is the only
        guard.
    #>
    param(
        [scriptblock]$GetCatalog = { Get-WtOptimizeVolumeCatalog },
        [scriptblock]$SelectAction = { param($Catalog, $StateItems, $Title) @(Show-WtSelector -Catalog $Catalog -StateItems $StateItems -Title $Title -UnselectableNote '') },
        [scriptblock]$OptimizeAction = {
            param($DriveLetter, $Mode)
            if ($Mode -ceq 'Defrag') {
                Optimize-Volume -DriveLetter $DriveLetter -Defrag -Verbose -ErrorAction Stop
            }
            else {
                Optimize-Volume -DriveLetter $DriveLetter -ReTrim -Verbose -ErrorAction Stop
            }
        },
        [scriptblock]$Run = {
            param($Chosen, $Crumb)
            Invoke-WtCapturedAction -Title (Get-Translation 'OptimizeVolumes') -Breadcrumb $Crumb -Action {
                foreach ($entry in $Chosen) {
                    Write-Host ((Get-Translation 'OptimizeVolumeStarting') -f ($entry.DriveLetter + ':')) -ForegroundColor Cyan
                    try {
                        & $OptimizeAction $entry.DriveLetter $entry.Mode
                    }
                    catch {
                        Write-Host ('{0}: {1} - {2}' -f ($entry.DriveLetter + ':'), (Get-Translation 'OptimizeVolumeFailed'), $_.Exception.Message) -ForegroundColor Red
                    }
                }
                Write-Host (Get-Translation 'ActionCompleted') -ForegroundColor Green
            }
        }
    )
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'OptimizeVolumes'
    $script:WtPanelBreadcrumb = $crumb

    $catalog = @(& $GetCatalog)
    if ($catalog.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'NoFixedVolumeFound'))
        return
    }

    $stateItems = foreach ($entry in $catalog) {
        [PSCustomObject]@{ Name = $entry.Name; Selectable = $true; StateLabel = $entry.ModeLabel }
    }
    $selected = @(& $SelectAction $catalog @($stateItems) $crumb)
    if ($selected.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'ActionCancelled'))
        return
    }
    $chosen = @($catalog | Where-Object { @($selected) -ccontains $_.Name })

    & $Run $chosen $crumb
}

# ---- Invoke-WtPingTestAction (lines 24948-24967) ----
function Invoke-WtPingTestAction {
    <#
    .SYNOPSIS
        Asks for the address in the panel, then pings it with the replies
        streaming into the box. The address is captured by the closure
        and passed to ping as ONE argument, so nothing the user types is
        ever re-parsed as script.
    #>
    param(
        [scriptblock]$AskTarget = { Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @() -Prompt (Get-Translation 'Pinging') },
        [scriptblock]$Run = {
            param($Address, $Crumb)
            $target = $Address
            Invoke-WtCapturedAction -Title (Get-Translation 'PingTest') -Breadcrumb $Crumb -Action { ping $target }
        }
    )
    $entered = ([string](& $AskTarget)).Trim()
    if (-not $entered) { return }
    & $Run $entered $script:WtPanelBreadcrumb
}

# ---- Invoke-WtPowercfg (lines 16059-16080) ----
function Invoke-WtPowercfg {
    <#
    .SYNOPSIS
        The one seam every power function goes through: runs powercfg.exe
        with the given arguments and returns ExitCode + Output lines. Never
        throws itself - callers decide. powercfg.exe does not exist on the
        macOS dev host, so the real call lives behind -PowercfgAction and
        tests inject a scripted fake.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [scriptblock]$PowercfgAction = {
            param($Arguments)
            $out = & powercfg.exe @Arguments 2>&1
            [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = @($out | ForEach-Object { "$_" }) }
        }
    )

    return (& $PowercfgAction $Arguments)
}

# ---- Invoke-WtProcessAsInteractiveUser (lines 172-254) ----
function Invoke-WtProcessAsInteractiveUser {
    <#
    .SYNOPSIS
        Runs one executable in the signed-in user's non-elevated session
        and waits for it, returning its exit code and everything it
        printed. Needed because winget refuses to install, upgrade or
        uninstall a user-scoped package while running elevated
        (0x8A15007D); a scheduled task is the only mechanism that gives a
        medium-integrity token, the child's exit code, and its output
        without a P/Invoke into CreateProcessWithTokenW. Never throws -
        every failure mode comes back as Ran = $false with a Reason.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments,
        [int]$TimeoutSeconds = 1800,
        [int]$PollMs = 400,
        [scriptblock]$OnOutput,
        [scriptblock]$GetUserName = { Get-WtInteractiveUserName },
        [string]$WorkRoot,
        [hashtable]$TaskApi,
        [switch]$KeepWorkFiles
    )
    $userName = [string](& $GetUserName)
    if ([string]::IsNullOrWhiteSpace($userName)) {
        return @{ Ran = $false; ExitCode = $null; Lines = [string[]]@(); Reason = 'NoInteractiveUser' }
    }

    $root = if ($WorkRoot) { [string]$WorkRoot } else { Join-Path ([System.IO.Path]::GetTempPath()) 'WinToolify' }
    if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Path $root -Force }
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $context = @{
        TaskName       = 'WinToolify-RunAsUser'
        UserName       = $userName
        ShimPath       = Join-Path $root ("runas-$stamp.ps1")
        LogPath        = Join-Path $root ("runas-$stamp.log")
        TimeoutSeconds = $TimeoutSeconds
    }
    $api = if ($TaskApi) { $TaskApi } else { Get-WtInteractiveUserTaskApi }

    $exitCode = $null
    $reason = ''
    try {
        Set-Content -LiteralPath $context.ShimPath -Encoding UTF8 -Value (
            New-WtInteractiveUserShim -FilePath $FilePath -Arguments $Arguments -OutputPath $context.LogPath)

        try {
            & $api.Register $context
            & $api.Start $context
        }
        catch { $reason = 'ScheduleFailed' }

        if ($reason -eq '') {
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ($true) {
                Start-Sleep -Milliseconds ([Math]::Max(1, $PollMs))
                $state = [string](& $api.State $context)
                $raw = & $api.Result $context
                if ($OnOutput) { & $OnOutput (Get-WtSharedTextLines -Path $context.LogPath) }
                if ($state -ne 'Running') {
                    $exitCode = ConvertTo-WtTaskExitCode -LastTaskResult $raw
                    if ($null -ne $exitCode) { break }
                }
                if ((Get-Date) -ge $deadline) { $reason = 'Timeout'; break }
            }
        }
    }
    catch { $reason = 'ScheduleFailed' }
    finally {
        try { & $api.Remove $context } catch { }
    }

    $lines = Get-WtSharedTextLines -Path $context.LogPath
    if (-not $KeepWorkFiles) {
        foreach ($path in @($context.ShimPath, $context.LogPath)) {
            try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } }
            catch { }
        }
    }

    if ($reason -ne '') { return @{ Ran = $false; ExitCode = $null; Lines = $lines; Reason = $reason } }
    return @{ Ran = $true; ExitCode = $exitCode; Lines = $lines; Reason = '' }
}

# ---- Invoke-WtRebuildExplorerCaches (lines 26630-26661) ----
function Invoke-WtRebuildExplorerCaches {
    <#
    .SYNOPSIS
        Blank or wrong icons and thumbnails, fixed in one shell stop: the
        shell goes down, the cache databases are deleted while it comes
        back, ie4uinit rebuilds the icon cache, and
        Invoke-WtRestartExplorer runs LAST. Order is load-bearing:
        deleting before the stop deletes nothing (files are open);
        restarting before ie4uinit rebuilds from stale state. ie4uinit
        takes -show, the Windows 10/11 switch; -ClearIconCache is
        Windows 8 only.
    #>
    param(
        [scriptblock]$StopExplorer = { Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue },
        [scriptblock]$RemoveCaches = { Remove-WtExplorerCacheFiles },
        [scriptblock]$RefreshIcons = { ie4uinit.exe -show },
        [scriptblock]$RestartShell = { Invoke-WtRestartExplorer },
        [scriptblock]$Write = { param($Line, $Color) if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line } }
    )
    & $Write (Get-Translation 'IconCacheStopping') 'Cyan'
    & $StopExplorer | Out-Null
    $result = & $RemoveCaches
    foreach ($line in (Format-WtExplorerCacheLines -Result $result)) { & $Write $line '' }
    & $Write (Get-Translation 'IconCacheRefreshing') 'Cyan'
    try { & $RefreshIcons | Out-Null }
    catch { & $Write $_.Exception.Message 'Red' }
    & $Write (Get-Translation 'IconCacheRestartingShell') 'Cyan'
    $restart = & $RestartShell
    $restarted = [bool]($restart -and $restart.Restarted)
    & $Write $(if ($restarted) { Get-Translation 'RestartExplorerDone' } else { Get-Translation 'RestartExplorerFailed' }) $(if ($restarted) { 'Green' } else { 'Red' })
    return $result
}

# ---- Invoke-WtRebuildSearchIndexAction (lines 28558-28619) ----
function Invoke-WtRebuildSearchIndexAction {
    <#
    .SYNOPSIS
        Throws the Windows Search catalog away and lets the service build
        it again: WSearch stopped, SetupCompletedSuccessfully set to 0,
        WSearch started. SetupCompletedSuccessfully is self-clearing -
        Windows Search sets it back to 1 once the rebuild finishes - so
        no undo record is written for it; only a service that fails to
        restart leaves it at 0, which the action then resets by hand.
    #>
    param(
        [scriptblock]$GetServiceInfo = {
            param($Name)
            Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction SilentlyContinue
        },

        [scriptblock]$StopServiceAction = { param($Name) Stop-Service -Name $Name -Force -ErrorAction Stop },

        [scriptblock]$StartServiceAction = { param($Name) Start-Service -Name $Name -ErrorAction Stop },

        [scriptblock]$SetSetupFlagAction = {
            param($Value)
            Set-WtRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name 'SetupCompletedSuccessfully' -RegType 'DWord' -Value $Value
        }
    )

    Write-Host (Get-Translation 'SearchIndexStarting')

    $info = $null
    try { $info = & $GetServiceInfo 'WSearch' }
    catch { $info = $null }

    if ($null -eq $info) {
        Write-Host (Get-Translation 'SearchIndexServiceMissing') -ForegroundColor Yellow
        return
    }
    if ([string]::Equals([string]$info.StartMode, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host (Get-Translation 'SearchIndexServiceDisabled') -ForegroundColor Red
        return
    }

    try { & $StopServiceAction 'WSearch' }
    catch {
        Write-Host ((Get-Translation 'SearchIndexStopFailed') -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    & $SetSetupFlagAction 0
    Write-Host (Get-Translation 'SearchIndexFlagSet') -ForegroundColor Green
    Write-Host (Get-Translation 'SearchIndexNoUndoRecord')

    try { & $StartServiceAction 'WSearch' }
    catch {
        Write-Host ((Get-Translation 'SearchIndexStartFailed') -f $_.Exception.Message) -ForegroundColor Red
        & $SetSetupFlagAction 1
        Write-Host (Get-Translation 'SearchIndexFlagRolledBack') -ForegroundColor Yellow
        return
    }

    Write-Host (Get-Translation 'SearchIndexRestarted') -ForegroundColor Green
    Write-Host (Get-Translation 'SearchIndexCost') -ForegroundColor Yellow
}

# ---- Invoke-WtRepairWmiRepositoryAction (lines 28643-28701) ----
function Invoke-WtRepairWmiRepositoryAction {
    <#
    .SYNOPSIS
        winmgmt /verifyrepository, its output printed verbatim (Windows'
        own localized text, so a user who searches that exact line
        online finds the same string Microsoft prints) and - only on a
        real inconsistency and behind a typed gate - winmgmt
        /salvagerepository. This row is Captured, so the gate is opened
        explicitly here; that is safe because Confirm-WtDestructiveAction
        asks through its own painted panel modal, not a bare Read-Host on
        the captured stream. /resetrepository is deliberately out of
        scope: it rebuilds the repository from the MOF files and loses
        every third-party class.
    #>
    param(
        [scriptblock]$WinmgmtAction = {
            param($Arguments)
            $out = & winmgmt.exe @Arguments 2>&1
            [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = @($out | ForEach-Object { "$_" }) }
        },

        [scriptblock]$ConfirmAction = {
            param($Consequence, $Lines)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines
        }
    )

    Write-Host (Get-Translation 'WmiRepairVerifying')

    $verify = & $WinmgmtAction ([string[]]@('/verifyrepository'))
    foreach ($line in @($verify.Output)) { Write-Host ([string]$line) }

    $verdict = Get-WtWmiRepositoryVerdict -ExitCode ([int]$verify.ExitCode) -Output ([string[]]@($verify.Output))
    if ($verdict -ceq 'Consistent') {
        Write-Host (Get-Translation 'WmiRepairConsistent') -ForegroundColor Green
        return
    }
    if ($verdict -ceq 'CheckFailed') {
        Write-Host (Get-Translation 'WmiRepairCheckFailed') -ForegroundColor Yellow
        return
    }

    Write-Host (Get-Translation 'WmiRepairInconsistent') -ForegroundColor Red
    $gateLines = [string[]]@((Get-Translation 'WmiRepairGateLine'))
    if (-not (& $ConfirmAction (Get-Translation 'WmiRepairConsequence') $gateLines)) {
        Write-Host (Get-Translation 'ActionCancelled') -ForegroundColor Yellow
        return
    }

    Write-Host (Get-Translation 'WmiRepairSalvaging')
    $salvage = & $WinmgmtAction ([string[]]@('/salvagerepository'))
    foreach ($line in @($salvage.Output)) { Write-Host ([string]$line) }
    if ([int]$salvage.ExitCode -eq 0) {
        Write-Host (Get-Translation 'WmiRepairSalvageOk') -ForegroundColor Green
    }
    else {
        Write-Host ((Get-Translation 'WmiRepairSalvageFailed') -f ([int]$salvage.ExitCode)) -ForegroundColor Red
    }
}

# ---- Invoke-WtResetFirewallRulesAction (lines 25477-25501) ----
function Invoke-WtResetFirewallRulesAction {
    <#
    .SYNOPSIS
        Inline, not captured, even though the catalogue lists this row as
        captured: the counts are read and printed first, then
        Confirm-WtDestructiveAction gates the reset, since that gate reads
        the keyboard and would deadlock inside Invoke-WtCapturedAction.
    #>
    param(
        [scriptblock]$GetCounts = { Get-WtFirewallRuleCounts },
        [scriptblock]$Confirm = { param($Lines) Confirm-WtDestructiveAction -Consequence (Get-Translation 'FirewallResetConsequence') -Lines $Lines -Breadcrumb $script:WtPanelBreadcrumb },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$Run = { param($Crumb) Invoke-WtCapturedAction -Title (Get-Translation 'ResetFirewallRules') -Breadcrumb $Crumb -Action { Invoke-WtResetFirewallRulesCommands } }
    )
    $counts = & $GetCounts
    $lines = @(
        ((Get-Translation 'FirewallRuleCountWinToolify') -f $counts.WinToolify)
        ((Get-Translation 'FirewallRuleCountCustom') -f $counts.Custom)
    )
    if (-not (& $Confirm $lines)) {
        & $ShowMessage @((Get-Translation 'ActionCancelled'))
        return
    }
    & $Run $script:WtPanelBreadcrumb
}

# ---- Invoke-WtResetFirewallRulesCommands (lines 25420-25475) ----
function Invoke-WtResetFirewallRulesCommands {
    <#
    .SYNOPSIS
        The captured half: "netsh advfirewall reset", which also silently
        restores Windows' out-of-box policy and turns every profile's
        firewall back on. The per-profile enabled state is captured first
        and any changed profile is put back afterward, one Set- call each
        so one refusal does not abandon the rest. Also retires the
        Blocklist undo records this reset invalidates.
    #>
    param(
        [scriptblock]$RunReset = { netsh advfirewall reset },
        [scriptblock]$RetireRecords = { Set-WtUndoEntryRetired -ActionNames @('Apply Blocklist') -RetiredBy 'ResetFirewallRules' -ItemFilter { param($Item) $Item.ItemType -eq 'FirewallBlock' } },
        [scriptblock]$GetProfileState = { Get-NetFirewallProfile -All -ErrorAction Stop | Select-Object Name, Enabled },
        [scriptblock]$SetProfileState = { param($Name, $Enabled) Set-NetFirewallProfile -Name $Name -Enabled (ConvertTo-WtGpoBoolean -Enabled ([bool]$Enabled)) -ErrorAction Stop }
    )
    Write-Host (Get-Translation 'FirewallResetRunning')
    $before = $null
    try { $before = @(& $GetProfileState) }
    catch { $before = $null }

    foreach ($line in @(& $RunReset)) { Write-Host ([string]$line) }

    $retired = [int](& $RetireRecords)
    Write-Host ((Get-Translation 'UndoRetiredBlocklistFirewall') -f $retired)

    if ($null -eq $before) {
        Write-Host (Get-Translation 'FirewallStateReadFailed') -ForegroundColor Yellow
        return
    }
    $after = $null
    try { $after = @(& $GetProfileState) }
    catch { $after = $null }
    if ($null -eq $after) {
        Write-Host (Get-Translation 'FirewallStateReadFailed') -ForegroundColor Yellow
        return
    }
    $afterByName = @{}
    foreach ($profile in $after) { $afterByName[[string]$profile.Name] = [bool]$profile.Enabled }
    $restoredNames = New-Object System.Collections.Generic.List[string]
    foreach ($profile in $before) {
        $name = [string]$profile.Name
        $wanted = [bool]$profile.Enabled
        if (-not $afterByName.ContainsKey($name)) { continue }
        if ($afterByName[$name] -eq $wanted) { continue }
        try {
            & $SetProfileState $name $wanted
            $restoredNames.Add($name)
        }
        catch { Write-Host ((Get-Translation 'FirewallStateRestoreFailed') -f $name) -ForegroundColor Red }
    }
    if ($restoredNames.Count -gt 0) {
        $summary = ($restoredNames -join ', ')
        Write-Host ((Get-Translation 'FirewallStateRestored') -f $summary)
    }
}

# ---- Invoke-WtResetHostsFileAction (lines 25367-25394) ----
function Invoke-WtResetHostsFileAction {
    <#
    .SYNOPSIS
        Inline: the file is read and counted first, the gate names what
        disappears (including the user's own entries) and only then does
        the captured writer run. An unreadable file is not a crash - the
        counts come back as zero and the gate is still asked.
    #>
    param(
        [scriptblock]$ReadHosts = { [System.IO.File]::ReadAllText((Join-Path $env:WinDir 'System32\drivers\etc\hosts'), [System.Text.Encoding]::UTF8) },
        [scriptblock]$Confirm = { param($Lines) Confirm-WtDestructiveAction -Consequence (Get-Translation 'HostsResetConsequence') -Lines $Lines -Breadcrumb $script:WtPanelBreadcrumb },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$Run = {
            param($Crumb, $Marked)
            $markedCount = [int]$Marked
            Invoke-WtCapturedAction -Title (Get-Translation 'ResetHostsFile') -Breadcrumb $Crumb -Action { Invoke-WtResetHostsFileWrite -MarkedCount $markedCount }
        }
    )
    $content = ''
    try { $content = [string](& $ReadHosts) }
    catch { $content = '' }
    $summary = Get-WtHostsFileSummary -Content $content
    if (-not (& $Confirm (Get-WtHostsResetPreviewLines -Content $content))) {
        & $ShowMessage @((Get-Translation 'ActionCancelled'))
        return
    }
    & $Run $script:WtPanelBreadcrumb $summary.Marked
}

# ---- Invoke-WtResetHostsFileWrite (lines 25327-25365) ----
function Invoke-WtResetHostsFileWrite {
    <#
    .SYNOPSIS
        The captured half of the Hosts reset: back the file up, write the
        Windows default text over it and flush the DNS cache. Uses
        [System.IO.File]::WriteAllText, since Set-Content fails on hosts
        with "Stream was not readable". Retires the Blocklist undo records
        only past zero MarkedCount, since firewall-based blocklist rules
        stay live after a Hosts reset.
    #>
    param(
        [Parameter(Mandatory)][int]$MarkedCount,
        [scriptblock]$GetHostsPath = { Join-Path $env:WinDir 'System32\drivers\etc\hosts' },
        [scriptblock]$BackupHosts = {
            param($Path)
            $backupDir = Get-WtDataPath -Scope 'Machine' -SubPath 'backup'
            $target = Join-Path $backupDir ('hosts-{0}.bak' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Copy-Item -LiteralPath $Path -Destination $target -Force
            $target
        },
        [scriptblock]$WriteHosts = {
            param($Path, $Text)
            [System.IO.File]::WriteAllText($Path, $Text, [System.Text.Encoding]::UTF8)
        },
        [scriptblock]$FlushDns = { ipconfig /flushdns },
        [scriptblock]$RetireRecords = { Set-WtUndoEntryRetired -ActionNames @('Apply Blocklist') -RetiredBy 'ResetHostsFile' -ItemFilter { param($Item) $Item.ItemType -eq 'HostsBlock' } }
    )
    $path = [string](& $GetHostsPath)
    $backup = [string](& $BackupHosts $path)
    Write-Host ((Get-Translation 'HostsBackupWritten') -f $backup)
    & $WriteHosts $path (Get-WtDefaultHostsContent)
    Write-Host (Get-Translation 'HostsFileRewritten') -ForegroundColor Green
    Write-Host (Get-Translation 'HostsFlushingDns')
    foreach ($line in @(& $FlushDns)) { Write-Host ([string]$line) }
    if ($MarkedCount -gt 0) {
        $retired = [int](& $RetireRecords)
        Write-Host ((Get-Translation 'UndoRetiredBlocklistHosts') -f $retired)
    }
}

# ---- Invoke-WtResetTcpIpStackAction (lines 25164-25185) ----
function Invoke-WtResetTcpIpStackAction {
    <#
    .SYNOPSIS
        Inline, not captured: the static addresses and current DNS are
        shown first, then Confirm-WtDestructiveAction names the DoH DNS
        preset this tool wrote as what will be erased. The gate reads the
        keyboard, so only the netsh commands run inside
        Invoke-WtCapturedAction.
    #>
    param(
        [scriptblock]$GetPreviewLines = { Get-WtNetworkResetPreviewLines },
        [scriptblock]$Confirm = { param($Lines) Confirm-WtDestructiveAction -Consequence (Get-Translation 'ResetTcpIpConsequence') -Lines $Lines -Breadcrumb $script:WtPanelBreadcrumb },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$Run = { param($Crumb) Invoke-WtCapturedAction -Title (Get-Translation 'ResetTcpIpStack') -Breadcrumb $Crumb -Action { Invoke-WtResetTcpIpStackCommands } }
    )
    $preview = @(& $GetPreviewLines)
    if (-not (& $Confirm $preview)) {
        & $ShowMessage @((Get-Translation 'ActionCancelled'))
        return
    }
    & $Run $script:WtPanelBreadcrumb
}

# ---- Invoke-WtResetTcpIpStackCommands (lines 25133-25162) ----
function Invoke-WtResetTcpIpStackCommands {
    <#
    .SYNOPSIS
        The captured half of the TCP/IP reset: netsh int ip reset, then
        netsh int ipv6 reset, each exit code read and reported. A non-zero
        code here is usually the expected "access is denied" on a handful
        of system-owned registry keys, not a failure. Also retires the
        DnsPreset undo records this reset just erased.
    #>
    param(
        [scriptblock]$RunIpv4 = { netsh int ip reset },
        [scriptblock]$RunIpv6 = { netsh int ipv6 reset },
        [scriptblock]$GetExitCode = { $LASTEXITCODE },
        [scriptblock]$RetireDnsRecords = { Set-WtUndoEntryRetired -ActionNames @('Apply DNS Preset') -RetiredBy 'ResetTcpIpStack' }
    )
    Write-Host (Get-Translation 'ResetTcpIpStackRunning')
    $sawNonZero = $false
    foreach ($step in @($RunIpv4, $RunIpv6)) {
        foreach ($line in @(& $step)) { Write-Host ([string]$line) }
        $code = 0
        $raw = & $GetExitCode
        if ($null -ne $raw) { $code = [int]$raw }
        Write-Host ((Get-Translation 'ResetTcpIpExitCode') -f $code)
        if ($code -ne 0) { $sawNonZero = $true }
    }
    if ($sawNonZero) { Write-Host (Get-Translation 'ResetTcpIpAccessDeniedNote') -ForegroundColor Yellow }
    $retired = [int](& $RetireDnsRecords)
    Write-Host ((Get-Translation 'UndoRetiredDnsPreset') -f $retired)
    Write-Host (Get-Translation 'NetworkRestartRequired') -ForegroundColor Yellow
}

# ---- Invoke-WtResetWindowsUpdateComponentsAction (lines 28441-28556) ----
function Invoke-WtResetWindowsUpdateComponentsAction {
    <#
    .SYNOPSIS
        Rebuilds Windows Update's own state: stop the five services, move
        SoftwareDistribution and catroot2 aside under a timestamped name,
        start the services again and - only once every one of them
        reports Running - delete the two renamed trees. Refuses the
        whole reset if any of the five is Disabled, since Start-Service
        on a disabled service throws. This row is Captured, so the
        consequence gate is called explicitly here; that is safe even
        inside Invoke-WtCapturedAction's pipeline because
        Confirm-WtDestructiveAction asks through its own painted panel
        modal, not a bare Read-Host on the captured stream.
    #>
    param(
        [scriptblock]$ConfirmAction = {
            param($Consequence, $Lines)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines
        },

        [scriptblock]$GetPlan = { Get-WtWindowsUpdateServicePlan },

        [scriptblock]$StopServiceAction = { param($Name) Stop-Service -Name $Name -Force -ErrorAction Stop },

        [scriptblock]$StartServiceAction = { param($Name) Start-Service -Name $Name -ErrorAction Stop },

        [scriptblock]$GetServiceRunning = {
            param($Name)
            $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction SilentlyContinue
            return ($null -ne $svc -and [string]::Equals([string]$svc.State, 'Running', [System.StringComparison]::OrdinalIgnoreCase))
        },

        [scriptblock]$TestPathAction = { param($Path) Test-Path -LiteralPath $Path },

        [scriptblock]$RenamePathAction = { param($Path, $NewName) Rename-Item -LiteralPath $Path -NewName $NewName -Force -ErrorAction Stop },

        [scriptblock]$RemovePathAction = { param($Path) Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop },

        [string]$SystemRoot = $env:SystemRoot,

        [string]$Stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    )

    $gateLines = [string[]]@((Get-Translation 'WuResetGateLine1'), (Get-Translation 'WuResetGateLine2'))
    if (-not (& $ConfirmAction (Get-Translation 'WuResetConsequence') $gateLines)) {
        Write-Host (Get-Translation 'ActionCancelled') -ForegroundColor Yellow
        return
    }

    Write-Host (Get-Translation 'WuResetStarting')

    $plan = @(& $GetPlan)

    $disabled = @($plan | Where-Object { $_.Disabled })
    if ($disabled.Count -gt 0) {
        foreach ($svc in $disabled) { Write-Host ((Get-Translation 'WuResetServiceDisabled') -f $svc.Name) -ForegroundColor Red }
        Write-Host (Get-Translation 'WuResetAbortedDisabled') -ForegroundColor Yellow
        return
    }

    foreach ($svc in $plan) {
        if ($svc.Missing) {
            Write-Host ((Get-Translation 'WuResetServiceMissing') -f $svc.Name) -ForegroundColor Yellow
            continue
        }
        Write-Host ((Get-Translation 'WuResetStopping') -f $svc.Name)
        try { & $StopServiceAction $svc.Name }
        catch { Write-Host ((Get-Translation 'WuResetStopFailed') -f $svc.Name, $_.Exception.Message) -ForegroundColor Red }
    }

    $renamed = New-Object System.Collections.Generic.List[string]
    $targets = @(
        (Join-Path $SystemRoot 'SoftwareDistribution')
        (Join-Path (Join-Path $SystemRoot 'System32') 'catroot2')
    )
    foreach ($path in $targets) {
        if (-not (& $TestPathAction $path)) {
            Write-Host ((Get-Translation 'WuResetMissingFolder') -f $path) -ForegroundColor Yellow
            continue
        }
        $newName = '{0}.{1}.bak' -f (Split-Path -Path $path -Leaf), $Stamp
        try {
            & $RenamePathAction $path $newName
            $renamed.Add((Join-Path (Split-Path -Path $path -Parent) $newName))
            Write-Host ((Get-Translation 'WuResetRenamed') -f $path, $newName) -ForegroundColor Green
        }
        catch { Write-Host ((Get-Translation 'WuResetRenameFailed') -f $path, $_.Exception.Message) -ForegroundColor Red }
    }

    $allRunning = $true
    for ($i = $plan.Count - 1; $i -ge 0; $i--) {
        $svc = $plan[$i]
        if ($svc.Missing) { continue }
        Write-Host ((Get-Translation 'WuResetStartingService') -f $svc.Name)
        try { & $StartServiceAction $svc.Name }
        catch { Write-Host ((Get-Translation 'WuResetStartFailed') -f $svc.Name, $_.Exception.Message) -ForegroundColor Red }
        if (-not (& $GetServiceRunning $svc.Name)) {
            $allRunning = $false
            Write-Host ((Get-Translation 'WuResetNotRunning') -f $svc.Name) -ForegroundColor Red
        }
    }

    if (-not $allRunning) {
        Write-Host (Get-Translation 'WuResetKeepingBackups') -ForegroundColor Yellow
        return
    }

    foreach ($backup in $renamed) {
        try {
            & $RemovePathAction $backup
            Write-Host ((Get-Translation 'WuResetDeletedBackup') -f $backup) -ForegroundColor Green
        }
        catch { Write-Host ((Get-Translation 'WuResetDeleteFailed') -f $backup, $_.Exception.Message) -ForegroundColor Red }
    }
    Write-Host (Get-Translation 'WuResetDone') -ForegroundColor Green
}

# ---- Invoke-WtResetWinHttpProxyAction (lines 25226-25255) ----
function Invoke-WtResetWinHttpProxyAction {
    <#
    .SYNOPSIS
        Inline, not captured, even though the catalogue lists this row as
        captured: the gate is asked only when a proxy is really set, since
        Confirm-WtDestructiveAction reads the keyboard and would deadlock
        inside Invoke-WtCapturedAction. Only the reset commands run
        captured.
    #>
    param(
        [scriptblock]$ShowProxy = { netsh winhttp show proxy },
        [scriptblock]$Confirm = { param($Lines) Confirm-WtDestructiveAction -Consequence (Get-Translation 'WinHttpProxyConsequence') -Lines $Lines -Breadcrumb $script:WtPanelBreadcrumb },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$Run = {
            param($Crumb, $Configured)
            $wasConfigured = [bool]$Configured
            Invoke-WtCapturedAction -Title (Get-Translation 'ResetWinHttpProxy') -Breadcrumb $Crumb -Action { Invoke-WtResetWinHttpProxyCommands -ProxyWasConfigured $wasConfigured }
        }
    )
    $current = @(& $ShowProxy | ForEach-Object { [string]$_ })
    $configured = Test-WtWinHttpProxyConfigured -Lines $current
    if ($configured) {
        $lines = @((Get-Translation 'WinHttpProxyCurrent')) + @($current | Where-Object { $_.Trim() })
        if (-not (& $Confirm $lines)) {
            & $ShowMessage @((Get-Translation 'ActionCancelled'))
            return
        }
    }
    & $Run $script:WtPanelBreadcrumb $configured
}

# ---- Invoke-WtResetWinHttpProxyCommands (lines 25204-25224) ----
function Invoke-WtResetWinHttpProxyCommands {
    <#
    .SYNOPSIS
        The captured half: reset proxy + reset autoproxy, then the state
        afterwards so the user sees the result. Both subcommands ship with
        every supported Windows (Windows 8 and later), so neither is
        probed with a "netsh winhttp" help call first.
    #>
    param(
        [bool]$ProxyWasConfigured = $true,
        [scriptblock]$RunResetProxy = { netsh winhttp reset proxy },
        [scriptblock]$RunResetAutoProxy = { netsh winhttp reset autoproxy },
        [scriptblock]$ShowProxy = { netsh winhttp show proxy }
    )
    Write-Host (Get-Translation 'WinHttpProxyResetting')
    if (-not $ProxyWasConfigured) { Write-Host (Get-Translation 'WinHttpProxyNotSet') }
    foreach ($line in @(& $RunResetProxy)) { Write-Host ([string]$line) }
    foreach ($line in @(& $RunResetAutoProxy)) { Write-Host ([string]$line) }
    Write-Host (Get-Translation 'WinHttpProxyAfter')
    foreach ($line in @(& $ShowProxy)) { Write-Host ([string]$line) }
}

# ---- Invoke-WtResetWinsockAction (lines 25085-25099) ----
function Invoke-WtResetWinsockAction {
    <#
    .SYNOPSIS
        netsh winsock reset - rebuilds the Winsock catalog and removes
        third-party LSP layers dead VPN/AV software leaves behind. The
        restart notice prints unconditionally, since netsh never throws
        and gating it on output would leave the stack half-applied with no
        warning.
    #>
    param([scriptblock]$RunReset = { netsh winsock reset })
    Write-Host (Get-Translation 'WinsockResetRunning')
    foreach ($line in @(& $RunReset)) { Write-Host ([string]$line) }
    Write-Host (Get-Translation 'WinsockResetLspNote')
    Write-Host (Get-Translation 'NetworkRestartRequired') -ForegroundColor Yellow
}

# ---- Invoke-WtRestartAudioServices (lines 26674-26718) ----
function Invoke-WtRestartAudioServices {
    <#
    .SYNOPSIS
        Brings sound back after a driver hiccup without a reboot: stops
        Audiosrv, then AudioEndpointBuilder, starts them again in
        dependency order, and reports both. An explicit stop/start pair,
        never Restart-Service -Force on AudioEndpointBuilder: -Force also
        restarts dependent Audiosrv, but only the named service comes back,
        leaving no audio. Status compared Ordinal (tr-TR folds differently).
    #>
    param(
        [string[]]$Names = (Get-WtAudioServiceNames),
        [scriptblock]$StopService = { param($Name) Stop-Service -Name $Name -Force -ErrorAction Stop },
        [scriptblock]$StartService = { param($Name) Start-Service -Name $Name -ErrorAction Stop },
        [scriptblock]$GetStatus = {
            param($Name)
            $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if ($service) { [string]$service.Status } else { '' }
        },
        [scriptblock]$Write = { param($Line, $Color) if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line } }
    )
    & $Write (Get-Translation 'AudioRestartStart') 'Cyan'
    $stopOrder = @()
    for ($i = $Names.Count - 1; $i -ge 0; $i--) { $stopOrder += [string]$Names[$i] }
    foreach ($name in $stopOrder) {
        try { & $StopService $name | Out-Null }
        catch { & $Write ('  {0}: {1}' -f $name, $_.Exception.Message) 'Red' }
    }
    foreach ($name in @($Names)) {
        try { & $StartService $name | Out-Null }
        catch { & $Write ('  {0}: {1}' -f $name, $_.Exception.Message) 'Red' }
    }
    $statuses = New-Object System.Collections.Generic.List[object]
    $allRunning = $true
    foreach ($name in @($Names)) {
        $status = [string](& $GetStatus $name)
        if (-not $status) { $status = [string](Get-Translation 'AudioServiceMissing') }
        $running = [string]::Equals($status, 'Running', [System.StringComparison]::Ordinal)
        if (-not $running) { $allRunning = $false }
        $statuses.Add([PSCustomObject]@{ Name = [string]$name; Status = $status })
        & $Write ('  {0}: {1}' -f $name, $status) $(if ($running) { 'Green' } else { 'Red' })
    }
    & $Write $(if ($allRunning) { Get-Translation 'AudioRestartDone' } else { Get-Translation 'AudioRestartIncomplete' }) $(if ($allRunning) { 'Green' } else { 'Yellow' })
    return [PSCustomObject]@{ AllRunning = $allRunning; Services = @($statuses.ToArray()) }
}

# ---- Invoke-WtRestartExplorer (lines 18008-18049) ----
function Invoke-WtRestartExplorer {
    <#
    .SYNOPSIS
        Restarts the Windows shell so context-menu and view changes become
        visible: stops explorer.exe, then polls for a re-spawned instance
        (never a fixed sleep), starting one manually only on timeout. A
        "new" instance is one whose pid was not running before the stop.
    #>
    param(
        [scriptblock]$StopAction = {
            Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        },

        [scriptblock]$GetProcessAction = {
            return @(Get-Process -Name explorer -ErrorAction SilentlyContinue | ForEach-Object Id)
        },

        [scriptblock]$StartAction = {
            Start-Process -FilePath 'explorer.exe' | Out-Null
        },

        [double]$TimeoutSeconds = 10
    )

    $before = @(& $GetProcessAction)
    & $StopAction | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $now = @(& $GetProcessAction)
        $fresh = @($now | Where-Object { $before -notcontains $_ })
        if ($fresh.Count -gt 0) {
            return [PSCustomObject]@{ Restarted = $true; StartedManually = $false }
        }
        Start-Sleep -Milliseconds 250
    }

    & $StartAction | Out-Null
    $after = @(& $GetProcessAction)
    $started = @($after | Where-Object { $before -notcontains $_ })
    return [PSCustomObject]@{ Restarted = ($started.Count -gt 0); StartedManually = $true }
}

# ---- Invoke-WtRestartNetworkAdaptersAction (lines 24969-25020) ----
function Invoke-WtRestartNetworkAdaptersAction {
    <#
    .SYNOPSIS
        Disables and re-enables every adapter that is Up, then POLLS each
        one back to Up for up to 30 seconds. A fixed 5-second wait reports
        a healthy Wi-Fi as Disconnected - the adapter is back long before
        the association finishes. Refused outright inside an RDP session:
        the first adapter that goes down takes the session with it.
    #>
    param(
        [scriptblock]$GetSessionName = { [string]$env:SESSIONNAME },
        [scriptblock]$GetAdapters = { Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Sort-Object -Property Name },
        [scriptblock]$RestartAdapter = { param($Name) Restart-NetAdapter -Name $Name -Confirm:$false -ErrorAction Stop },
        [scriptblock]$GetAdapterStatus = { param($Name) [string](Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue).Status },
        [scriptblock]$WaitOneSecond = { Start-Sleep -Seconds 1 },
        [int]$TimeoutSeconds = 30
    )
    $session = [string](& $GetSessionName)
    if ($session.StartsWith('RDP-', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host ((Get-Translation 'NetAdaptersRdpBlocked') -f $session) -ForegroundColor Red
        return
    }
    $adapters = @()
    try { $adapters = @(& $GetAdapters) }
    catch { $adapters = @() }
    if ($adapters.Count -eq 0) {
        Write-Host (Get-Translation 'NetAdaptersNone') -ForegroundColor Yellow
        return
    }
    Write-Host ((Get-Translation 'NetAdaptersRestarting') -f $adapters.Count, $TimeoutSeconds)
    foreach ($adapter in $adapters) {
        $name = [string]$adapter.Name
        Write-Host ((Get-Translation 'NetAdapterRestarting') -f $name)
        try {
            & $RestartAdapter $name
        }
        catch {
            Write-Host ((Get-Translation 'NetAdapterFailed') -f $name, $_.Exception.Message) -ForegroundColor Red
            continue
        }
        $status = ''
        $waited = 0
        while ($waited -lt $TimeoutSeconds) {
            & $WaitOneSecond
            $waited++
            $status = [string](& $GetAdapterStatus $name)
            if ($status -ceq 'Up') { break }
        }
        if ($status -ceq 'Up') { Write-Host ((Get-Translation 'NetAdapterUp') -f $name, $waited) -ForegroundColor Green }
        else { Write-Host ((Get-Translation 'NetAdapterNotUp') -f $name, $status, $waited) -ForegroundColor Yellow }
    }
}

# ---- Invoke-WtRestartToAdvancedStartup (lines 25731-25757) ----
function Invoke-WtRestartToAdvancedStartup {
    <#
    .SYNOPSIS
        Restarts into the recovery menu (advanced startup) with
        "shutdown /r /o /t 0", but only after reagentc /info has proved
        WinRE actually exists - otherwise the box would restart straight
        back to the desktop with no explanation. The first Write-Host
        happens before the reagentc call itself, since
        Invoke-WtCapturedAction only repaints on output and a silent
        check would leave a frozen-looking panel.
    #>
    param(
        [scriptblock]$GetWinReInfo = { @(cmd.exe /c 'reagentc.exe /info 2>&1') },
        [scriptblock]$Restart = { Invoke-WtShutdownCommand -Arguments @('/r', '/o', '/t', '0') }
    )
    Write-Host (Get-Translation 'WinReChecking') -ForegroundColor Cyan
    if (-not (Test-WtWinReAvailable -GetInfo $GetWinReInfo)) {
        Write-Host (Get-Translation 'WinReUnavailable') -ForegroundColor Red
        Write-Host (Get-Translation 'WinReUnavailableHint') -ForegroundColor Yellow
        return
    }
    Write-Host (Get-Translation 'RestartingToAdvancedStartup') -ForegroundColor Cyan
    $powerResult = & $Restart
    if ([int]$powerResult.ExitCode -ne 0) {
        Write-Host ((Get-Translation 'PowerCommandFailed') -f [int]$powerResult.ExitCode) -ForegroundColor Red
    }
}

# ---- Invoke-WtRestartToFirmwareSettings (lines 25791-25815) ----
function Invoke-WtRestartToFirmwareSettings {
    <#
    .SYNOPSIS
        Restarts straight into the UEFI firmware setup with
        "shutdown /r /fw /t 0". On a legacy BIOS the row REFUSES: /fw is
        a UEFI-only request, and a machine that cannot honour it would
        just restart to the desktop, leaving the user to wonder what
        happened. Fast Boot is precisely why this row exists - reaching
        the firmware by keyboard is otherwise close to impossible.
    #>
    param(
        [scriptblock]$IsUefi = { Test-WtUefiFirmware },
        [scriptblock]$Restart = { Invoke-WtShutdownCommand -Arguments @('/r', '/fw', '/t', '0') }
    )
    if (-not (& $IsUefi)) {
        Write-Host (Get-Translation 'FirmwareNotUefi') -ForegroundColor Red
        Write-Host (Get-Translation 'FirmwareNotUefiHint') -ForegroundColor Yellow
        return
    }
    Write-Host (Get-Translation 'RestartingToFirmwareSettings') -ForegroundColor Cyan
    $powerResult = & $Restart
    if ([int]$powerResult.ExitCode -ne 0) {
        Write-Host ((Get-Translation 'PowerCommandFailed') -f [int]$powerResult.ExitCode) -ForegroundColor Red
    }
}

# ---- Invoke-WtRestorePowerSchemeDefaultsAction (lines 28703-28761) ----
function Invoke-WtRestorePowerSchemeDefaultsAction {
    <#
    .SYNOPSIS
        powercfg -restoredefaultschemes behind a typed gate: deletes every
        scheme Windows did not ship (Ultimate Performance included) and
        resets processor/core-parking settings to shipped values, then
        reads the plan list back with "powercfg /list" (never /query,
        which wants a scheme GUID). This row is Captured, so the gate is
        opened explicitly here - safe because Confirm-WtDestructiveAction
        asks through its own painted panel modal, not a bare Read-Host.
        Afterwards the PowerPlan undo entries are retired and the count
        printed, since a record that silently stops being offered is a
        lie the Undo screen must not tell.
    #>
    param(
        [scriptblock]$ConfirmAction = {
            param($Consequence, $Lines)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines
        },

        [scriptblock]$PowercfgAction,

        [scriptblock]$RetireUndoAction = {
            param($ActionNames, $RetiredBy)
            Set-WtUndoEntryRetired -ActionNames $ActionNames -RetiredBy $RetiredBy
        }
    )
    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }

    $gateLines = [string[]]@((Get-Translation 'PowerRestoreGateLine1'), (Get-Translation 'PowerRestoreGateLine2'))
    if (-not (& $ConfirmAction (Get-Translation 'PowerRestoreConsequence') $gateLines)) {
        Write-Host (Get-Translation 'ActionCancelled') -ForegroundColor Yellow
        return
    }

    Write-Host (Get-Translation 'PowerRestoreStarting')

    $restore = Invoke-WtPowercfg -Arguments ([string[]]@('-restoredefaultschemes')) @actionArgs
    foreach ($line in @($restore.Output)) { Write-Host ([string]$line) }
    if ([int]$restore.ExitCode -ne 0) {
        Write-Host ((Get-Translation 'PowerRestoreFailed') -f ([int]$restore.ExitCode)) -ForegroundColor Red
        return
    }

    $list = Invoke-WtPowercfg -Arguments ([string[]]@('/list')) @actionArgs
    Write-Host (Get-Translation 'PowerRestoreSchemesHeader')
    foreach ($line in @($list.Output)) { Write-Host ([string]$line) }

    $retired = [int](& $RetireUndoAction @('Apply Power Plan Settings', 'Revert Power Plan Settings') 'RestorePowerSchemeDefaults')
    if ($retired -gt 0) {
        Write-Host ((Get-Translation 'PowerRestoreRetired') -f $retired) -ForegroundColor Yellow
    }
    else {
        Write-Host (Get-Translation 'PowerRestoreRetiredNone')
    }

    Write-Host (Get-Translation 'PowerRestoreDone') -ForegroundColor Green
}

# ---- Invoke-WtScheduleDiskRepairAction (lines 23545-23611) ----
function Invoke-WtScheduleDiskRepairAction {
    <#
    .SYNOPSIS
        Schedules a real chkdsk /f repair for one volume the user picks:
        the dirty bit on the system drive, Repair-Volume
        -OfflineScanAndFix everywhere else. The repair itself runs only at
        next boot; a volume Windows refuses to dismount is reported
        honestly rather than called scheduled.
    #>
    param(
        [scriptblock]$GetCatalog = { Get-WtDiskRepairCatalog },
        [scriptblock]$SelectAction = { param($Catalog, $StateItems, $Title) @(Show-WtSelector -Catalog $Catalog -StateItems $StateItems -Title $Title -UnselectableNote '') },
        [scriptblock]$Confirm = { param($ConsequenceText, $Lines, $Crumb) Confirm-WtDestructiveAction -Consequence $ConsequenceText -Lines $Lines -Breadcrumb $Crumb },
        [scriptblock]$SetDirtyBit = { param($DriveLetter) fsutil dirty set ('{0}:' -f $DriveLetter) },
        [scriptblock]$RepairVolume = { param($DriveLetter) Repair-Volume -DriveLetter $DriveLetter -OfflineScanAndFix -ErrorAction Stop },
        [scriptblock]$ShowCancelled = { param($Lines) Wait-WtEnter -Lines $Lines }
    )
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'ScheduleDiskRepair'
    $script:WtPanelBreadcrumb = $crumb

    $catalog = @(& $GetCatalog)
    if ($catalog.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'NoFixedVolumeFound'))
        return
    }

    $stateItems = foreach ($entry in $catalog) {
        [PSCustomObject]@{ Name = $entry.Name; Selectable = $true; StateLabel = (Get-Translation $entry.Plan.NoteKey) }
    }
    $selected = @(& $SelectAction $catalog @($stateItems) $crumb)
    if ($selected.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'ActionCancelled'))
        return
    }
    $entry = @($catalog | Where-Object { $_.Name -ceq ([string]$selected[0]) })[0]
    $plan = $entry.Plan

    $gateLines = @(
        (Get-Translation $plan.NoteKey)
        ('  ' + $plan.ScheduleText)
        ''
        ((Get-Translation 'DiskRepairCancelHint') -f $plan.CancelCommand)
    )
    if (-not (& $Confirm ((Get-Translation 'ConsequenceScheduleDiskRepair') -f ($plan.DriveLetter + ':')) $gateLines $crumb)) {
        & $ShowCancelled @((Get-Translation 'ActionCancelled'))
        return
    }

    Invoke-WtCapturedAction -Title (Get-Translation 'ScheduleDiskRepair') -Breadcrumb $crumb -Action {
        Write-Host $plan.ScheduleText -ForegroundColor Cyan
        if ($plan.Method -ceq 'DirtyBit') {
            & $SetDirtyBit $plan.DriveLetter
            Write-Host ((Get-Translation 'DiskRepairScheduled') -f ($plan.DriveLetter + ':')) -ForegroundColor Green
        }
        else {
            try {
                & $RepairVolume $plan.DriveLetter
                Write-Host ((Get-Translation 'DiskRepairScheduled') -f ($plan.DriveLetter + ':')) -ForegroundColor Green
            }
            catch {
                Write-Host ((Get-Translation 'DiskRepairDismountFailed') -f ($plan.DriveLetter + ':')) -ForegroundColor Red
                Write-Host $_.Exception.Message
            }
        }
        Write-Host ((Get-Translation 'DiskRepairCancelHint') -f $plan.CancelCommand)
    }
}

# ---- Invoke-WtShadowOldestLoop (lines 23720-23746) ----
function Invoke-WtShadowOldestLoop {
    <#
    .SYNOPSIS
        Deletes shadow copies on one drive, oldest first, stopping the
        moment one remains or the count stops falling.
    #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][scriptblock]$CountAction,
        [Parameter(Mandatory)][scriptblock]$DeleteAction,
        [int]$MaxIterations = 512
    )

    $deleted = 0
    $rounds = 0
    $count = [int](& $CountAction $DriveLetter)
    while (($count -gt 1) -and ($rounds -lt $MaxIterations)) {
        & $DeleteAction $DriveLetter
        $rounds++
        $after = [int](& $CountAction $DriveLetter)
        if ($after -ge $count) { break }
        $deleted += ($count - $after)
        $count = $after
    }

    return [PSCustomObject]@{ Deleted = $deleted; Remaining = $count }
}

# ---- Invoke-WtShutdownCommand (lines 25624-25648) ----
function Invoke-WtShutdownCommand {
    <#
    .SYNOPSIS
        The ONLY place shutdown.exe is started, with stderr merged
        INSIDE cmd.exe rather than by PowerShell: on 5.1 a native
        stderr line crossing the PowerShell boundary is wrapped in a
        NativeCommandError ErrorRecord and would paint as a red stack
        trace under Invoke-WtCapturedAction. Returns the exit code and
        plain-string output without letting raw text reach the panel;
        $Arguments comes from the caller's already-validated values
        only. The local variable is $commandLine, not $line, to avoid
        the same collector-name call-stack shadowing documented on
        Show-WtShutdownTimerResult.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [scriptblock]$RunLine = {
            param($CommandLine)
            $out = @(cmd.exe /c $CommandLine)
            return [PSCustomObject]@{ ExitCode = [int]$LASTEXITCODE; Output = [string[]]$out }
        }
    )
    $commandLine = 'shutdown.exe ' + ($Arguments -join ' ') + ' 2>&1'
    return & $RunLine $commandLine
}

# ---- Invoke-WtShutdownTimerAction (lines 25671-25708) ----
function Invoke-WtShutdownTimerAction {
    <#
    .SYNOPSIS
        One row, both jobs: arm a shutdown timer or cancel a pending one.
        The minutes are asked IN THE PANEL first - a Read-Host inside
        Invoke-WtCapturedAction deadlocks behind the capture - and the
        answer only picks a branch. An empty answer (including the $null
        Read-WtPanelAnswer returns when input is exhausted) means cancel,
        which is both the documented answer and the safe direction.
    #>
    param(
        [scriptblock]$AskMinutes = {
            Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @((Get-Translation 'ShutdownTimerHint')) -Prompt (Get-Translation 'ShutdownTimerPrompt') -Risk 'CAUTION' -Layout 'Compact'
        },
        [scriptblock]$ShowInvalid = {
            $null = Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @((Get-Translation 'ShutdownTimerInvalid')) -Prompt (Get-Translation 'PressEnterContinue') -Risk 'CAUTION'
        },
        [scriptblock]$RunCancel = { Invoke-WtShutdownCommand -Arguments @('/a') },
        [scriptblock]$RunSchedule = { param($Seconds) Invoke-WtShutdownCommand -Arguments @('/s', '/t', ([string]$Seconds)) },
        [scriptblock]$ShowResult = {
            param($Rows)
            Show-WtShutdownTimerResult -Title (Get-Translation 'ShutdownTimer') -ResultLines $Rows -Breadcrumb $script:WtPanelBreadcrumb
        }
    )
    $answer = [string](& $AskMinutes)
    $plan = Get-WtShutdownTimerPlan -Answer $answer
    if ($plan.Mode -eq 'Invalid') {
        & $ShowInvalid
        return
    }
    if ($plan.Mode -eq 'Cancel') {
        $cancelResult = & $RunCancel
        & $ShowResult (Get-WtShutdownCancelLines -ExitCode ([int]$cancelResult.ExitCode))
        return
    }
    $armResult = & $RunSchedule $plan.Seconds
    & $ShowResult (Get-WtShutdownScheduleLines -Plan $plan -ExitCode ([int]$armResult.ExitCode))
}

# ---- Invoke-WtStartMenuRepair (lines 26449-26538) ----
function Invoke-WtStartMenuRepair {
    <#
    .SYNOPSIS
        The Start-button-does-nothing repair: stops both shell host
        processes, re-registers the Start menu packages one by one, clears
        StartMenuExperienceHost's TempState, and stops the hosts once more
        so Windows rebuilds them. Hosts are stopped FIRST because Windows
        refuses to re-register a package whose own process is running
        (0x80073D02); a package still failing that way is retried once
        after Windows auto-restarts the host.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Get-AppxPackage -AllUsers and Add-AppxPackage -Register are Windows-only by design and absent from the static PS 7.0 profile; on Windows they resolve through the Appx module on both 5.1 and 7.')]
    param(
        [scriptblock]$GetPackages = {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                Import-Module Appx -UseWindowsPowerShell -ErrorAction SilentlyContinue
            }
            try { Get-AppxPackage -AllUsers -ErrorAction Stop }
            catch { Get-AppxPackage -ErrorAction SilentlyContinue }
        },
        [scriptblock]$TestManifest = { param($Path) Test-Path -LiteralPath $Path },
        [scriptblock]$RegisterPackage = { param($Path) Add-AppxPackage -Register $Path -DisableDevelopmentMode -ErrorAction Stop },
        [scriptblock]$ClearTempState = {
            $path = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\TempState'
            if (-not (Test-Path -LiteralPath $path)) { return $false }
            Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            return $true
        },
        [scriptblock]$StopHosts = {
            $stopped = New-Object System.Collections.Generic.List[string]
            foreach ($hostName in @('StartMenuExperienceHost', 'ShellExperienceHost')) {
                $running = @(Get-Process -Name $hostName -ErrorAction SilentlyContinue)
                if ($running.Count -eq 0) { continue }
                $running | Stop-Process -Force -ErrorAction SilentlyContinue
                $stopped.Add($hostName)
            }
            return [string[]]$stopped.ToArray()
        },
        [scriptblock]$Write = { param($Line, $Color) if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line } }
    )
    & $Write (Get-Translation 'StartMenuRepairStart') 'Cyan'
    $packages = @(Select-WtStartMenuPackages -Packages @(& $GetPackages))
    if ($packages.Count -eq 0) {
        & $Write (Get-Translation 'StartMenuNoPackages') 'Yellow'
        return [PSCustomObject]@{ Registered = 0; Failed = 0; TempStateCleared = $false; StoppedHosts = [string[]]@() }
    }
    $stoppedHosts = New-Object System.Collections.Generic.List[string]
    $recordStopped = {
        foreach ($name in @(& $StopHosts)) { if (-not $stoppedHosts.Contains([string]$name)) { $stoppedHosts.Add([string]$name) } }
    }
    & $recordStopped
    $registered = 0
    $failed = 0
    foreach ($package in $packages) {
        if (-not $package.ManifestPath -or -not (& $TestManifest $package.ManifestPath)) {
            $failed++
            & $Write ('  {0}: {1} ({2})' -f $package.Name, (Get-Translation 'StartMenuPackageFailed'), (Get-Translation 'StartMenuManifestMissing')) 'Red'
            continue
        }
        $error1 = $null
        try { & $RegisterPackage $package.ManifestPath | Out-Null }
        catch { $error1 = $_.Exception.Message }
        if ($error1) {
            & $recordStopped
            try {
                & $RegisterPackage $package.ManifestPath | Out-Null
                $error1 = $null
            }
            catch { $error1 = $_.Exception.Message }
        }
        if ($error1) {
            $failed++
            & $Write ('  {0}: {1} ({2})' -f $package.Name, (Get-Translation 'StartMenuPackageFailed'), $error1) 'Red'
        }
        else {
            $registered++
            & $Write ('  {0}: {1}' -f $package.Name, (Get-Translation 'StartMenuPackageOk')) 'Green'
        }
    }
    $cleared = [bool](& $ClearTempState)
    & $Write $(if ($cleared) { Get-Translation 'StartMenuTempStateCleared' } else { Get-Translation 'StartMenuTempStateMissing' }) $(if ($cleared) { 'Green' } else { 'Yellow' })
    & $recordStopped
    $stopped = @($stoppedHosts.ToArray())
    if ($stopped.Count -gt 0) { & $Write ((Get-Translation 'StartMenuHostsStopped') + ' ' + ($stopped -join ', ')) 'Cyan' }
    else { & $Write (Get-Translation 'StartMenuHostsNotRunning') 'Yellow' }
    & $Write ((Get-Translation 'StartMenuRepairSummary') -f $registered, $failed) $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
    return [PSCustomObject]@{ Registered = $registered; Failed = $failed; TempStateCleared = $cleared; StoppedHosts = [string[]]$stopped }
}

# ---- Invoke-WtStoreUpdatesAction (lines 26879-26882) ----
function Invoke-WtStoreUpdatesAction {
    if (Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction SilentlyContinue) { Start-Process 'ms-windows-store://downloadsandupdates' }
    else { Write-Host (Get-Translation 'StoreNotAvailable') -ForegroundColor Yellow }
}

# ---- Invoke-WtSystemHealthAction (lines 27987-28000) ----
function Invoke-WtSystemHealthAction {
    <#
    .SYNOPSIS
        System Health Report - read-only: disks then sensors, every
        Windows-only source degrades to n/a. Rendered in the box, with
        "S" to save it.
    #>
    param(
        [scriptblock]$GetLines = { @(Format-WtDiskHealthLines -Report (Get-WtDiskHealthReport)) + @(Format-WtSensorLines -Snapshot (Get-WtSensorSnapshot)) },
        [scriptblock]$Show = { param($Crumb, $Rows) Show-WtSavableReport -Breadcrumb $Crumb -Lines $Rows -ReportName 'health' }
    )
    $crumb = if ($script:WtPanelBreadcrumb) { $script:WtPanelBreadcrumb } else { Get-Translation 'SystemHealthReport' }
    & $Show $crumb @(& $GetLines)
}

# ---- Invoke-WtTokenBatch (lines 8973-9001) ----
function Invoke-WtTokenBatch {
    <#
    .SYNOPSIS
        Runs a batch of input tokens through the pure reducer with NO
        rendering in between (that is how a held arrow key stays smooth:
        N reducer steps, one paint). Stops at the first emitting token;
        tokens after it are dropped on purpose (they were typed before
        the user saw the result).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tokens,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [int]$ViewHeight = 10,
        [bool]$MultiSelect = $false,
        [bool]$Searchable = $false
    )
    $state = $State
    $emit = 'None'
    $emitChar = ''
    $processed = 0
    foreach ($token in $Tokens) {
        $r = Update-WtListState -State $state -Token $token -Items $Items -ViewHeight $ViewHeight -MultiSelect $MultiSelect -Searchable $Searchable
        $state = $r.State
        $processed++
        if ($r.Emit -ne 'None') { $emit = $r.Emit; $emitChar = $r.EmitChar; break }
    }
    return @{ State = $state; Emit = $emit; EmitChar = $emitChar; Processed = $processed }
}

# ---- Invoke-WtUninstallProgramAction (lines 27287-27371) ----
function Invoke-WtUninstallProgramAction {
    <#
    .SYNOPSIS
        Lists the classic Win32 programs and removes the one the user
        picks. Inline: the picker and the typed gate both run BEFORE
        Invoke-WtCapturedAction is entered, since a prompt behind the
        capture deadlocks. Show-WtSelector is MULTI-select, so only the
        FIRST confirmed name is honoured. While the vendor uninstaller
        runs, a periodic heartbeat line doubles as the repaint trigger,
        since it can run for minutes with no output and a silent box
        reads as a crash.
    #>
    param(
        [scriptblock]$GetEntries = { Get-WtInstalledProgramEntries },
        [scriptblock]$GetUserHiveVisible = { Test-WtUninstallUserHiveVisible },
        [scriptblock]$Select = {
            param($Catalog, $StateItems, $Crumb, $InfoLines)
            Show-WtSelector -Catalog $Catalog -StateItems $StateItems -Title $Crumb `
                -UnselectableNote '' -InfoLines $InfoLines
        },
        [scriptblock]$Confirm = {
            param($Consequence, $Lines, $Crumb)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines -Breadcrumb $Crumb
        },
        [scriptblock]$RunUninstall = {
            param($Command, $ProgramName, $Crumb)
            $wtFile = [string]$Command.FilePath
            $wtArguments = [string]$Command.Arguments
            $wtName = [string]$ProgramName
            $script:WtUninstallExitCode = $null
            Invoke-WtCapturedAction -Title (Get-Translation 'UninstallProgram') -Breadcrumb $Crumb -Action {
                Write-Host ((Get-Translation 'UninstallStarting') -f $wtName)
                $startParams = @{ FilePath = $wtFile; PassThru = $true; ErrorAction = 'Stop' }
                if (-not [string]::IsNullOrWhiteSpace($wtArguments)) { $startParams['ArgumentList'] = $wtArguments }
                $proc = Start-Process @startParams
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                while (-not $proc.HasExited) {
                    Start-Sleep -Seconds 2
                    Write-Host ((Get-Translation 'UninstallWaiting') -f ([int]$watch.Elapsed.TotalSeconds))
                }
                $watch.Stop()
                $script:WtUninstallExitCode = $proc.ExitCode
            }
            return $script:WtUninstallExitCode
        },
        [scriptblock]$Show = { param($Lines) Wait-WtEnter -Lines @($Lines) }
    )
    $crumb = $script:WtPanelBreadcrumb
    $entries = @(& $GetEntries)
    if ($entries.Count -eq 0) {
        & $Show @((Get-Translation 'UninstallNoPrograms'))
        return
    }
    $infoLines = @()
    if (-not (& $GetUserHiveVisible)) { $infoLines = @((Get-Translation 'UninstallUserHiveMissing')) }

    $catalog = @(Get-WtUninstallProgramCatalog -Entries $entries)
    $stateItems = @(Get-WtUninstallProgramStateItems -Entries $entries)
    $picked = @(& $Select $catalog $stateItems $crumb $infoLines)
    if ($picked.Count -eq 0) {
        & $Show @((Get-Translation 'UninstallCancelled'))
        return
    }
    $key = [string]$picked[0]
    $entry = $entries | Where-Object { [string]::Equals([string]$_.Key, $key, [System.StringComparison]::Ordinal) } | Select-Object -First 1
    if (-not $entry) {
        & $Show @((Get-Translation 'UninstallCancelled'))
        return
    }
    $command = Get-WtUninstallCommand -Entry $entry
    if ([string]::Equals([string]$command.Kind, 'None', [System.StringComparison]::Ordinal)) {
        & $Show @(((Get-Translation 'UninstallNoSilentCommand') -f [string]$entry.DisplayName))
        return
    }
    $consequence = (Get-Translation 'UninstallConsequence') -f [string]$entry.DisplayName
    $detail = @((('{0} {1}' -f [string]$command.FilePath, [string]$command.Arguments)).Trim())
    if (-not (& $Confirm $consequence $detail $crumb)) {
        & $Show @((Get-Translation 'UninstallCancelled'))
        return
    }
    $code = & $RunUninstall $command ([string]$entry.DisplayName) $crumb
    $ok = ($null -ne $code) -and (@(0, 3010) -contains [int]$code)
    if ($ok) { & $Show @(((Get-Translation 'UninstallDone') -f [string]$entry.DisplayName, [string]$code)) }
    else { & $Show @(((Get-Translation 'UninstallFailed') -f [string]$entry.DisplayName, [string]$code)) }
}

# ---- Invoke-WtVcRedistAction (lines 28280-28396) ----
function Invoke-WtVcRedistAction {
    <#
    .SYNOPSIS
        Action Tools > Software > "Install Visual C++ (VCRedist) Packages":
        reads what is installed, then downloads and runs only the packages
        the plan needs, printing one line per step and summing up at the end.

        Every step prints a line to keep the captured panel's clock moving,
        since a silent download used to invite queued Enter presses that
        replayed (see Clear-WtPendingInput). Exit codes: 0 installed, 3010
        + restart wanted, 1638 a newer build already there (skipped),
        anything else a failure; a cached installer is deleted on success
        or refused-as-older, kept for retry on failure. The -OnProgress
        callback closes over $label through the call stack, not
        GetNewClosure, which breaks once the built file is run.
    #>
    param(
        [scriptblock]$GetInstalled = { Get-WtInstalledProgramEntries },
        [bool]$Is64Bit = [System.Environment]::Is64BitOperatingSystem,
        [AllowNull()][array]$Catalog = $null,
        [string]$CacheDir = '',
        [AllowNull()][string[]]$LocalDirs = $null,
        [scriptblock]$Download = { param($Url, $Path, $OnProgress) Invoke-WtVcRedistDownload -Url $Url -Path $Path -OnProgress $OnProgress },
        [scriptblock]$Install = { param($Path, $Arguments) (Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru).ExitCode }
    )
    if (-not $Catalog) { $Catalog = @(Get-WtVcRedistCatalog) }
    if (-not $CacheDir) { $CacheDir = Get-WtDataPath -Scope User -SubPath 'cache\vcredist' }
    if ($null -eq $LocalDirs) { $LocalDirs = @(Get-WtVcRedistLocalDirs) }

    Write-Host (Get-Translation 'VcRedistChecking')
    $entries = @()
    try { $entries = @(& $GetInstalled) } catch { $entries = @() }
    $installed = @(ConvertTo-WtVcRedistInstalled -Entries $entries)
    $plan = @(Get-WtVcRedistPlan -Catalog $Catalog -Installed $installed -Is64Bit $Is64Bit)

    $todo = New-Object 'System.Collections.Generic.List[object]'
    $skipped = 0
    foreach ($row in $plan) {
        $label = Get-WtVcRedistPackageLabel -Package $row.Package
        switch ([string]$row.Action) {
            'Skip' {
                Write-Host ((Get-Translation 'VcRedistSkip') -f $label, [string]$row.InstalledVersion)
                $skipped++
            }
            'Update' {
                Write-Host ((Get-Translation 'VcRedistToUpdate') -f $label, [string]$row.InstalledVersion, [string]$row.Package.MinVersion)
                $todo.Add($row)
            }
            default {
                Write-Host ((Get-Translation 'VcRedistToInstall') -f $label)
                $todo.Add($row)
            }
        }
    }
    if ($todo.Count -eq 0) {
        Write-Host (Get-Translation 'VcRedistNothingToDo')
        return
    }

    Write-Host ''
    $installedCount = 0
    $updatedCount = 0
    $failed = 0
    $rebootWanted = $false
    foreach ($row in $todo) {
        $package = $row.Package
        $label = Get-WtVcRedistPackageLabel -Package $package
        Write-Host ((Get-Translation 'VcRedistDownloading') -f $label, (Format-WtByteSize -Bytes ([long]$package.Size)))
        $file = $null
        try {
            $file = Get-WtVcRedistPackageFile -Package $package -CacheDir $CacheDir -LocalDirs $LocalDirs -Download $Download `
                -OnProgress { param($Percent) if ([int]$Percent -lt 100) { Write-Host ((Get-Translation 'VcRedistDownloadProgress') -f $label, [int]$Percent) } }
        }
        catch {
            Write-Host ((Get-Translation 'VcRedistDownloadFailed') -f $label, $_.Exception.Message)
            $failed++
            continue
        }
        if ([string]$file.Source -eq 'Local') { Write-Host ((Get-Translation 'VcRedistLocalCopy') -f $label) }
        Write-Host ((Get-Translation 'VcRedistInstalling') -f $label)
        $code = -1
        try { $code = [int](& $Install ([string]$file.Path) ([string]$package.Args)) }
        catch {
            Write-Host $_.Exception.Message
            $code = -1
        }
        $done = $false
        switch ($code) {
            0 {
                if ([string]$row.Action -eq 'Update') { Write-Host ((Get-Translation 'VcRedistUpdated') -f $label); $updatedCount++ }
                else { Write-Host ((Get-Translation 'VcRedistInstalled') -f $label); $installedCount++ }
                $done = $true
            }
            3010 {
                Write-Host ((Get-Translation 'VcRedistInstalledReboot') -f $label)
                if ([string]$row.Action -eq 'Update') { $updatedCount++ } else { $installedCount++ }
                $rebootWanted = $true
                $done = $true
            }
            1638 {
                Write-Host ((Get-Translation 'VcRedistNewerPresent') -f $label)
                $skipped++
                $done = $true
            }
            default {
                Write-Host ((Get-Translation 'VcRedistFailed') -f $label, $code)
                $failed++
            }
        }
        if ($done -and [string]$file.Source -ne 'Local') {
            Remove-Item -LiteralPath ([string]$file.Path) -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host ''
    Write-Host ((Get-Translation 'VcRedistSummary') -f $installedCount, $updatedCount, $skipped, $failed)
    if ($rebootWanted) { Write-Host (Get-Translation 'VcRedistRebootNote') }
}

# ---- Invoke-WtVcRedistDownload (lines 28180-28231) ----
function Invoke-WtVcRedistDownload {
    <#
    .SYNOPSIS
        Streams one installer to disk with HttpWebRequest, reporting 25 /
        50 / 75 percent through -OnProgress so the panel's clock never
        looks frozen on a 25 MB file. The old WebClient.DownloadFile said
        nothing for the whole 120 MB. Progress is called via $null = & ...,
        since a callback's return value must not leak into this function's
        own output.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$OnProgress = { param($Percent) }
    )
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch { $null = $_ }
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'WinToolify'
    $request.AllowAutoRedirect = $true
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 60000
    $response = $request.GetResponse()
    try {
        $total = [long]$response.ContentLength
        $input = $response.GetResponseStream()
        $output = [System.IO.File]::Create($Path)
        try {
            $buffer = New-Object byte[] 65536
            $done = [long]0
            $nextStep = 25
            while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $output.Write($buffer, 0, $read)
                $done += $read
                if ($total -gt 0) {
                    $percent = [int][Math]::Floor(($done * 100) / $total)
                    while ($nextStep -le 75 -and $percent -ge $nextStep) {
                        $null = & $OnProgress $nextStep
                        $nextStep += 25
                    }
                }
            }
        }
        finally {
            $output.Dispose()
            $input.Dispose()
        }
    }
    finally { $response.Close() }
}

# ---- Invoke-WtWifiPasswordAction (lines 25503-25519) ----
function Invoke-WtWifiPasswordAction {
    <#
    .SYNOPSIS
        Asks for the profile name in the panel, then shows the answer in
        the box. The prompt happens here rather than inside a captured
        action, so there is no Read-Host for Invoke-WtCapturedAction to
        deadlock on.
    #>
    param(
        [scriptblock]$AskName = { Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @() -Prompt (Get-Translation 'WiFiName') },
        [scriptblock]$LookUp = { param($Name) Get-WtWifiProfileKey -ProfileName $Name },
        [scriptblock]$ShowResult = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines }
    )
    $name = [string](& $AskName)
    if (-not $name.Trim()) { return }
    & $ShowResult @(Get-WtWifiPasswordLines -Result (& $LookUp $name.Trim())) | Out-Null
}

# ---- Invoke-WtWifiProfileExport (lines 22926-22973) ----
function Invoke-WtWifiProfileExport {
    <#
    .SYNOPSIS
        Writes every saved wireless network, passwords included, as
        re-importable XML - the pre-reinstall backup behind the typed
        gate of Invoke-WtExportWifiProfilesAction. The deliberate
        exception to this file's usual delete-after-export rule: these
        files are meant to survive. folder= is built as ONE argument
        ('folder=' + path) so a path with a space in the user name
        survives PowerShell's native-command argument passing.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [scriptblock]$EnsureFolder = {
            param($Path)
            if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        },
        [scriptblock]$ExportAction = {
            param($Path)
            $folderArg = 'folder=' + $Path
            netsh wlan export profile key=clear $folderArg
        },
        [scriptblock]$GetFiles = { param($Path) Get-ChildItem -LiteralPath $Path -Filter '*.xml' -File -ErrorAction SilentlyContinue }
    )

    Write-Host ((Get-Translation 'ExportWifiProfilesTargetLine') -f $Folder) -ForegroundColor Cyan
    try { & $EnsureFolder $Folder }
    catch {
        Write-Host ((Get-Translation 'ExportWifiProfilesFolderFailed') -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    Write-Host (Get-Translation 'ExportWifiProfilesRunning') -ForegroundColor Cyan
    & $ExportAction $Folder

    $files = @(& $GetFiles $Folder)
    if ($files.Count -eq 0) {
        Write-Host (Get-Translation 'ExportWifiProfilesNone') -ForegroundColor Yellow
        return
    }

    Write-Host ((Get-Translation 'ExportWifiProfilesDone') -f $files.Count, $Folder) -ForegroundColor Green
    Write-Host (Get-Translation 'ExportWifiProfilesClearTextWarning') -ForegroundColor Yellow
    Write-Host (Get-Translation 'ExportWifiProfilesRestoreHeader')
    foreach ($f in $files) {
        Write-Host ('  netsh wlan add profile filename="' + [string]$f.FullName + '"')
    }
}

# ---- Invoke-WtWingetUpgradeAction (lines 26884-26890) ----
function Invoke-WtWingetUpgradeAction {
    $null = Test-WingetInstalled
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget upgrade --all --include-unknown --accept-source-agreements --accept-package-agreements
    }
    else { Write-Host (Get-Translation 'WingetInstallError') -ForegroundColor Red }
}

# ---- Invoke-WtWingetUpgradeSinglePackageAction (lines 26993-27068) ----
function Invoke-WtWingetUpgradeSinglePackageAction {
    <#
    .SYNOPSIS
        Updates ONE named package instead of everything - the row for a
        metered link or a version-pinned application. Inline, not
        Captured: the id is asked with Read-WtPanelAnswer BEFORE
        Invoke-WtCapturedAction is entered, since a Read-Host behind the
        capture deadlocks. winget presence goes through
        Test-WingetInstalled (which bootstraps App Installer on LTSC),
        never a bare Get-Command. Its captured scriptblocks copy their
        arguments into locals first, since GetNewClosure breaks once
        this file runs unsourced. The args used for the last attempt are
        kept in a variable, not rebuilt, so a de-elevated retry repeats
        the pass that was actually refused.
    #>
    param(
        [scriptblock]$AskPackage = {
            Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb `
                -Lines @((Get-Translation 'WingetSingleHint')) `
                -Prompt (Get-Translation 'WingetSinglePrompt')
        },
        [scriptblock]$EnsureWinget = {
            $null = Test-WingetInstalled
            [bool](Get-Command winget -ErrorAction SilentlyContinue)
        },
        [scriptblock]$RunWinget = {
            param($Arguments, $Notice, $Crumb)
            $wtArgs = $Arguments
            $wtNotice = $Notice
            $script:WtWingetExitCode = $null
            Invoke-WtCapturedAction -Title (Get-Translation 'WingetUpgradeSinglePackage') `
                -Breadcrumb $Crumb -Encoding ([System.Text.Encoding]::UTF8) -Action {
                    Write-Host $wtNotice
                    & winget @wtArgs
                    $script:WtWingetExitCode = $LASTEXITCODE
                }
            return $script:WtWingetExitCode
        },
        [scriptblock]$RunAsUser = {
            param($Arguments, $Notice, $Crumb)
            Show-WtPanelMessage -Breadcrumb $Crumb -Lines @($Notice) -FooterText '' | Out-Null
            return (Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' -Arguments ([string[]]@($Arguments)))
        },
        [scriptblock]$Show = {
            param($Lines)
            Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null
        }
    )
    $entered = ([string](& $AskPackage)).Trim()
    if (-not $entered) { return }
    if (-not (& $EnsureWinget)) {
        & $Show @((Get-Translation 'WingetInstallError'))
        return
    }
    $crumb = $script:WtPanelBreadcrumb
    $package = $entered
    $wingetArgs = Get-WtWingetUpgradeArguments -Package $package
    $code = & $RunWinget $wingetArgs ((Get-Translation 'WingetSingleRunning') -f $package) $crumb
    if (Test-WtWingetShouldRetryByName -ExitCode $code) {
        $wingetArgs = Get-WtWingetUpgradeArguments -Package $package -ByName
        $code = & $RunWinget $wingetArgs ((Get-Translation 'WingetSingleRetry') -f $package) $crumb
    }
    $extraLines = [string[]]@()
    if (Test-WtWingetAdminContextProhibited -ExitCode $code) {
        $asUser = & $RunAsUser $wingetArgs (Get-Translation 'WsRetryAsUser') $crumb
        if ($asUser -and $asUser.Ran) {
            $code = $asUser.ExitCode
            $extraLines = [string[]]@($asUser.Lines)
        }
        else {
            $reason = if ($asUser) { [string]$asUser.Reason } else { '' }
            $extraLines = [string[]]@((Get-Translation (Get-WtRetryReasonKey -Reason $reason)))
        }
    }
    & $Show @($extraLines + @(Get-WtWingetUpgradeResultLines -Package $package -ExitCode $code))
}

# ---- New-WtCapturedActionItem (lines 16900-16917) ----
function New-WtCapturedActionItem {
    <#
    .SYNOPSIS
        An action whose output is captured and shown inside the box
        (Invoke-WtCapturedAction) instead of on a cleared console. The
        action must not call Read-Host - ask for input in the panel
        first, or build the row as a plain inline Action instead.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$LabelKey,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Risk = '',
        [AllowNull()][System.Text.Encoding]$Encoding = $null
    )
    $label = Get-Translation $LabelKey
    return New-WtListItem -Kind 'Action' -Name $Name -Label $label -Risk $Risk -Data @{ Captured = $true; Title = $label; Action = $Action; Encoding = $Encoding }
}

# ---- New-WtInteractiveUserShim (lines 54-82) ----
function New-WtInteractiveUserShim {
    <#
    .SYNOPSIS
        The little PowerShell script the scheduled task runs: it invokes
        one executable with one argument array, captures both streams to
        a file, and exits on the child's exit code. A shim file rather
        than a command line keeps the package id off a cmd.exe command
        line, where &, |, ^ and % would be live.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $literals = @(foreach ($a in $Arguments) { ConvertTo-WtPsSingleQuoted -Value ([string]$a) })
    $argLine = if ($literals.Count -eq 0) { '@()' } else { '@(' + ($literals -join ', ') + ')' }
    $lines = @(
        '# Generated by WinToolify. Runs one command as the signed-in user; deleted afterwards.'
        '$ErrorActionPreference = ''Continue'''
        '$wtArgv = ' + $argLine
        '$wtExe = ' + (ConvertTo-WtPsSingleQuoted -Value $FilePath)
        '$wtOut = ' + (ConvertTo-WtPsSingleQuoted -Value $OutputPath)
        '& $wtExe @wtArgv 2>&1 | Out-File -LiteralPath $wtOut -Encoding utf8'
        '$wtCode = $LASTEXITCODE'
        'if ($null -eq $wtCode) { $wtCode = 1 }'
        'exit $wtCode'
    )
    return ($lines -join "`r`n")
}

# ---- New-WtListItem (lines 36709-36756) ----
function New-WtListItem {
    <#
    .SYNOPSIS
        The one constructor for list rows, so every screen builder emits
        the shape Get-WtListRowSegments / Update-WtListState expect. Desc
        drives the description band under the cursor's row (empty shows
        nothing); RiskTag prints the "[CAUTION]"-style tag while Risk
        still drives the row's colour even when the tag is off.
        CycleTargets turns Space from a two-state toggle into a walk
        through those targets and back to unmarked. Header, Info and
        Spacer rows are never focusable; Applied means the live state
        already matches the target, Removable means it may also be
        marked back to the Windows default.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Link', 'Action', 'Check', 'Radio', 'Header', 'Info', 'Spacer', 'Rule')][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [string]$Risk = $null,
        [string]$StateLabel = '',
        [string]$PendingVerbKey = '',
        [string]$Desc = '',
        [bool]$Selectable = $true,
        [object]$Data = $null,
        [string]$Group = '',
        [bool]$Applied = $false,
        [bool]$Removable = $false,
        [bool]$RiskTag = $true,
        [AllowEmptyCollection()][string[]]$CycleTargets = @()
    )
    if (@('Header', 'Info', 'Spacer', 'Rule') -contains $Kind) { $Selectable = $false }
    return [PSCustomObject]@{
        Kind       = $Kind
        Name       = $Name
        Label      = $Label
        Risk       = $Risk
        StateLabel = $StateLabel
        PendingVerbKey = $PendingVerbKey
        Desc       = $Desc
        Selectable = $Selectable
        Data       = $Data
        Group      = $Group
        Applied      = $Applied
        Removable    = $Removable
        RiskTag      = $RiskTag
        CycleTargets = [string[]]@($CycleTargets)
    }
}

# ---- New-WtSeg (lines 6127-6134) ----
function New-WtSeg {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Fg = 'White',
        [string]$Bg = ''
    )
    return [PSCustomObject]@{ T = $Text; F = $Fg; B = $Bg }
}

# ---- New-WtToolRow (lines 16919-16960) ----
function New-WtToolRow {
    <#
    .SYNOPSIS
        The one declaration form for every Actions/Information row. Kind
        decides the shape: Captured streams output into the panel (its
        scriptblock must never call Read-Host - it deadlocks behind the
        capture); Inline paints its own panel to ask for a value first;
        Power is the reboot/shutdown class, gated by ConsequenceKey;
        Native runs one long console tool via FilePath/Arguments as a
        polled child process, for a row that prints nothing itself.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$Action,
        [ValidateSet('Captured', 'Inline', 'Power', 'Native')][string]$Kind = 'Captured',
        [ValidateSet('', 'SAFE', 'CAUTION', 'ADVANCED')][string]$Risk = '',
        [string]$ConsequenceKey = '',
        [AllowNull()][System.Text.Encoding]$Encoding = $null,
        [string]$FilePath = '',
        [string]$Arguments = ''
    )
    if ($Kind -eq 'Native') {
        if (-not $FilePath) { throw "New-WtToolRow: a Native row needs -FilePath ($Name)." }
    }
    elseif (-not $Action) { throw "New-WtToolRow: a $Kind row needs -Action ($Name)." }
    switch ($Kind) {
        'Native' {
            $label = Get-Translation $Name
            return New-WtListItem -Kind 'Action' -Name $Name -Label $label -Risk $Risk `
                -Data @{ Native = $true; Title = $label; FilePath = $FilePath; Arguments = $Arguments; Encoding = $Encoding }
        }
        'Captured' {
            return New-WtCapturedActionItem -Name $Name -LabelKey $Name -Action $Action -Risk $Risk -Encoding $Encoding
        }
        'Inline' {
            return New-WtListItem -Kind 'Action' -Name $Name -Label (Get-Translation $Name) -Risk $Risk -Data @{ Action = $Action }
        }
        'Power' {
            return New-WtListItem -Kind 'Action' -Name $Name -Label (Get-Translation $Name) -Risk 'ADVANCED' -Data @{ Power = $true; ConsequenceKey = $ConsequenceKey; Action = $Action }
        }
    }
}

# ---- Read-WtInputBatch (lines 5917-5962) ----
function Read-WtInputBatch {
    <#
    .SYNOPSIS
        One blocking ReadKey, then drains any auto-repeat queued after a
        navigation key. Never mixes RawUI.ReadKey / FlushInputBuffer -
        separate caches, phantom keys. Converter: (Key, KeyChar) -> token;
        no GetNewClosure, it breaks in the built (non-dot-sourced) script.
        Exhausted redirected stdin returns 'Eof' and sets
        $script:WtInputExhausted, which is how the main menu tells this
        Back from an Esc: Esc stays, this leaves.
    #>
    param([scriptblock]$Converter)

    if ($script:WtInputMode -eq 'Key') {
        $null = Assert-WtTuiCtrlCInput
        $null = Assert-WtWindowMaximized
        try {
            $ki = [Console]::ReadKey($true)
            $first = if ($Converter) { [string](& $Converter ([string]$ki.Key) ([string]$ki.KeyChar)) }
                     else { ConvertTo-WtKeyToken -Key ([string]$ki.Key) -KeyChar ([string]$ki.KeyChar) }
            $tokens = New-Object System.Collections.Generic.List[string]
            $tokens.Add($first)
            if (Test-WtNavToken -Token $first) {
                while ($tokens.Count -lt 64 -and [Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    $t = if ($Converter) { [string](& $Converter ([string]$k.Key) ([string]$k.KeyChar)) }
                         else { ConvertTo-WtKeyToken -Key ([string]$k.Key) -KeyChar ([string]$k.KeyChar) }
                    $tokens.Add($t)
                    if (-not (Test-WtNavToken -Token $t)) { break }
                }
            }
            return [string[]]$tokens.ToArray()
        }
        catch {
            $null = Write-WtErrorLog -ErrorRecord $_ -Context 'Read-WtInputBatch: key input failed, falling back to line mode'
            $script:WtInputMode = 'Line'
            Reset-WtFrameCache
        }
    }
    $line = Read-Host (Get-Translation 'InputPrompt')
    if ($null -eq $line) {
        $script:WtInputExhausted = $true
        return [string[]]@('Eof')
    }
    return [string[]]@((ConvertTo-WtLineToken -Line $line))
}

# ---- Read-WtJson (lines 1189-1213) ----
function Read-WtJson {
    <#
    .SYNOPSIS
        Reads and deserializes a JSON file written by Write-WtJson.
        Returns $null (and warns) for a missing or corrupt file rather than
        throwing - a malformed undo log must not prevent the tool starting.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        return $raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Read-WtJson: failed to parse '$Path' - $($_.Exception.Message)"
        return $null
    }
}

# ---- Read-WtPanelAnswer (lines 9222-9285) ----
function Read-WtPanelAnswer {
    <#
    .SYNOPSIS
        The in-panel modal: paints the lines, parks the cursor on the
        footer row inside the box, and reads one line there; $null when
        input is exhausted. Content taller than the viewport is shown
        first in the scrollable output screen, since Read-Host blocks and
        cannot be scrolled while the prompt is up. -Secret reads through
        Read-Host -AsSecureString and hands back plain text, so a typed
        secret echoes as '*' instead of in the clear. Resets the frame
        cache afterwards, since Read-Host's echo dirties the row.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Risk = '',
        [ValidateSet('Full', 'Compact')][string]$Layout = 'Full',
        [switch]$Secret,
        [scriptblock]$ShowScrollable = { param($Crumb, $Rows) Show-WtOutputScreen -Breadcrumb $Crumb -Lines $Rows -FooterText (Get-Translation 'OutputFooterThenAsk') | Out-Null }
    )
    $readAnswerLine = {
        if ($Secret) {
            $secure = Read-Host -AsSecureString $Prompt
            if ($null -eq $secure) { return $null }
            return ([System.Net.NetworkCredential]::new('', $secure)).Password
        }
        return (Read-Host $Prompt)
    }
    if ($script:WtInputMode -eq 'Line') {
        Clear-Host
        foreach ($l in @($Lines)) { Write-Host $l }
        $answer = & $readAnswerLine
        Reset-WtFrameCache
        return $answer
    }
    $size0 = Get-WtConsoleSize
    $Prompt = [string](Get-WtPanelPromptFit -Prompt $Prompt -Width ([int]$size0.Width))
    $wrapped = @(ConvertTo-WtPanelLines -Lines $Lines -Width (Get-WtPanelInnerWidth -Width $size0.Width) -Risk $Risk)
    $viewHeight = [Math]::Max(1, $size0.Height - (Get-WtFrameChromeHeight -Width $size0.Width))
    if ($wrapped.Count -gt $viewHeight) {
        & $ShowScrollable $Breadcrumb $wrapped
        $Lines = @()
        Reset-WtFrameCache
    }
    $footerText = if ($Layout -eq 'Compact') { $Prompt + ': ' } else { '' }
    $size = Show-WtPanelMessage -Breadcrumb $Breadcrumb -Lines $Lines -FooterText $footerText -Risk $Risk -Layout $Layout
    $footerRow = [int]$size.FooterRow
    $footerCol = [int]$size.FooterCol
    try {
        if ($script:WtVt) { $Host.UI.Write($script:WtEsc + '[' + ($footerRow + 1) + ';' + ($footerCol + 1) + 'H' + $script:WtEsc + '[?25h') }
        else { [Console]::SetCursorPosition($footerCol, $footerRow); [Console]::CursorVisible = $true }
    }
    catch { $null = $_ }
    $null = Assert-WtTuiCtrlCInput
    $null = Assert-WtWindowMaximized
    $answer = & $readAnswerLine
    try {
        if ($script:WtVt) { $Host.UI.Write($script:WtEsc + '[?25l') } else { [Console]::CursorVisible = $false }
    }
    catch { $null = $_ }
    Reset-WtFrameCache
    return $answer
}

# ---- Read-WtSettings (lines 1259-1292) ----
function Read-WtSettings {
    <#
    .SYNOPSIS
        Loads settings.json; never throws. A missing or corrupt file, or an
        unknown Language value, yields Language = $null so the caller falls
        back to the first-run language screen (Read-WtProfile idiom).
    #>
    param([string]$TestRootOverride)
    $raw = Read-WtJson -Path (Get-WtSettingsFilePath -TestRootOverride $TestRootOverride)
    $language = $null
    $endpoint = ''
    $model = ''
    $apiKey = ''
    $temperature = ''
    $maxTokens = ''
    $numCtx = ''
    $authMode = ''
    if ($null -ne $raw -and ($raw -is [PSCustomObject])) {
        $props = $raw.PSObject.Properties.Name
        if (($props -contains 'Language') -and (@('EN', 'TR') -contains [string]$raw.Language)) { $language = [string]$raw.Language }
        if ($props -contains 'AssistantEndpoint') { $endpoint = [string]$raw.AssistantEndpoint }
        if ($props -contains 'AssistantModel') { $model = [string]$raw.AssistantModel }
        if ($props -contains 'AssistantApiKey') { $apiKey = [string]$raw.AssistantApiKey }
        if ($props -contains 'AssistantTemperature') { $temperature = [string]$raw.AssistantTemperature }
        if ($props -contains 'AssistantMaxTokens') { $maxTokens = [string]$raw.AssistantMaxTokens }
        if ($props -contains 'AssistantNumCtx') { $numCtx = [string]$raw.AssistantNumCtx }
        if ($props -contains 'AssistantAuthMode') { $authMode = [string]$raw.AssistantAuthMode }
    }
    return [PSCustomObject]@{
        Language              = $language; AssistantEndpoint = $endpoint; AssistantModel = $model; AssistantApiKey = $apiKey
        AssistantTemperature  = $temperature; AssistantMaxTokens = $maxTokens; AssistantNumCtx = $numCtx
        AssistantAuthMode     = $authMode
    }
}

# ---- Remove-WtExplorerCacheFiles (lines 26581-26628) ----
function Remove-WtExplorerCacheFiles {
    <#
    .SYNOPSIS
        Deletes the icon / thumbnail cache databases with a BOUNDED retry
        loop: explorer.exe releases these files only a moment after
        exiting, so one pass deletes almost nothing. Stops at
        BudgetSeconds and reports what is still locked rather than hang.
    #>
    param(
        [array]$Targets = @(Get-WtExplorerCacheTargets),
        [double]$BudgetSeconds = 10,
        [scriptblock]$GetFiles = { param($Directory, $Filter) @(Get-ChildItem -LiteralPath $Directory -Filter $Filter -Force -File -ErrorAction SilentlyContinue) },
        [scriptblock]$RemoveFile = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop },
        [scriptblock]$GetNow = { Get-Date },
        [scriptblock]$Wait = { Start-Sleep -Milliseconds 500 }
    )
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($target in @($Targets)) {
        foreach ($file in @(& $GetFiles $target.Directory $target.Filter)) {
            if (-not $file) { continue }
            $length = [long]0
            try { $length = [long]$file.Length } catch { $length = [long]0 }
            $pending.Add([PSCustomObject]@{ Path = [string]$file.FullName; Length = $length })
        }
    }
    $deadline = (& $GetNow).AddSeconds($BudgetSeconds)
    $freed = [long]0
    $deleted = 0
    $remaining = $pending
    while ($remaining.Count -gt 0) {
        $still = New-Object System.Collections.Generic.List[object]
        foreach ($file in $remaining) {
            try {
                & $RemoveFile $file.Path | Out-Null
                $freed += [long]$file.Length
                $deleted++
            }
            catch { $still.Add($file) }
        }
        $remaining = $still
        if ($remaining.Count -eq 0) { break }
        if ((& $GetNow) -ge $deadline) { break }
        & $Wait | Out-Null
    }
    $locked = New-Object System.Collections.Generic.List[string]
    foreach ($file in $remaining) { $locked.Add([string]$file.Path) }
    return [PSCustomObject]@{ DeletedCount = $deleted; FreedBytes = $freed; Locked = [string[]]$locked.ToArray() }
}

# ---- Reset-WtFrameCache (lines 6008-6018) ----
function Reset-WtFrameCache {
    <#
    .SYNOPSIS
        Forget the previous frame so the next Write-WtFrame repaints every
        row. Called after anything that wrote to the console outside the
        painter (console-output mode, Read-Host prompts, native commands).
    #>
    $script:WtPrevRows = @()
    $script:WtPrevWidth = 0
    $script:WtPrevHeight = 0
}

# ---- Resolve-WtCatalogText (lines 1484-1529) ----
function Resolve-WtCatalogText {
    <#
    .SYNOPSIS
        Localizes catalog prose at build time: LabelKey -> DisplayLabel,
        ConsequenceKey -> Consequence, via the active language. A missing
        key leaves the shipped English literal in place, so a
        half-translated table degrades gracefully instead of blanking
        labels. With KeyPrefix, an entry with no explicit key gets one
        synthesized from its sanitized Name; the sanitizer uses
        -creplace, not -replace, because a culture-aware replace drops
        the capital I on Turkish systems.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Catalog,
        [string]$KeyPrefix
    )

    foreach ($entry in $Catalog) {
        $props = $entry.PSObject.Properties.Name
        if ($KeyPrefix) {
            $sanitized = ([string]$entry.Name) -creplace '[^A-Za-z0-9]', ''
            if ($props -contains 'DisplayLabel' -and $entry.DisplayLabel -and -not ($props -contains 'LabelKey' -and $entry.LabelKey)) {
                $entry | Add-Member -NotePropertyName 'LabelKey' -NotePropertyValue ('Cat{0}{1}Label' -f $KeyPrefix, $sanitized) -Force
            }
            if ($props -contains 'Consequence' -and $entry.Consequence -and -not ($props -contains 'ConsequenceKey' -and $entry.ConsequenceKey)) {
                $entry | Add-Member -NotePropertyName 'ConsequenceKey' -NotePropertyValue ('Cat{0}{1}Consequence' -f $KeyPrefix, $sanitized) -Force
            }
            $props = $entry.PSObject.Properties.Name
        }
        if ($props -contains 'LabelKey' -and $entry.LabelKey) {
            $text = Get-Translation $entry.LabelKey
            if ($text) {
                if ($props -contains 'LabelArgs' -and $null -ne $entry.LabelArgs) { $text = $text -f @($entry.LabelArgs) }
                $entry | Add-Member -NotePropertyName 'DisplayLabel' -NotePropertyValue $text -Force
            }
        }
        if ($props -contains 'ConsequenceKey' -and $entry.ConsequenceKey) {
            $text = Get-Translation $entry.ConsequenceKey
            if ($text) {
                if ($props -contains 'ConsequenceArgs' -and $null -ne $entry.ConsequenceArgs) { $text = $text -f @($entry.ConsequenceArgs) }
                $entry | Add-Member -NotePropertyName 'Consequence' -NotePropertyValue $text -Force
            }
        }
    }
    return $Catalog
}

# ---- Save-WtReport (lines 457-488) ----
function Save-WtReport {
    <#
    .SYNOPSIS
        Writes rendered report lines to LOCALAPPDATA\WinToolify\reports\
        <name>-yyyyMMdd-HHmmss.txt (UTF8) and returns the full path. The
        lines are exactly what the console showed - the file is the
        hand-off for long reports (duplicate lists) rather than a second
        format. AllowEmptyString is required: a mandatory [string[]]
        otherwise rejects a blank line as an empty element.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,

        [string]$TestRootOverride,

        [datetime]$Timestamp = (Get-Date)
    )

    $dataPathArgs = @{ Scope = 'User'; SubPath = 'reports' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    $reportDir = Get-WtDataPath @dataPathArgs

    $path = Join-Path $reportDir ('{0}-{1}.txt' -f $Name, $Timestamp.ToString('yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $path -Value ($Lines -join [Environment]::NewLine) -Encoding UTF8
    return $path
}

# ---- Select-WtListItems (lines 8576-8613) ----
function Select-WtListItems {
    <#
    .SYNOPSIS
        PURE: the rows a search query leaves. Every word of the query has
        to occur in the row's label or state column, in any order, compared
        OrdinalIgnoreCase - never a culture compare, which on tr-TR folds I
        to the dotless i. A Header/Rule stays only when a row of its group
        matched. Uses -split, not .Split(), since PS7 binds that call to the
        (string, options) overload and joins the terms into one separator.
        Emitted bare: wrap the call in @(), or empty comes back $null.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [AllowNull()][AllowEmptyString()][string]$Query = ''
    )
    $terms = @((([string]$Query).Trim() -split '\s+') | Where-Object { $_ -ne '' })
    if ($terms.Count -eq 0) { return @($Items) }
    $out = New-Object System.Collections.Generic.List[object]
    $pendingHeader = $null
    $headerShown = $false
    $pendingSpacer = $null
    foreach ($item in $Items) {
        $kind = [string]$item.Kind
        if ($kind -eq 'Header' -or $kind -eq 'Rule') { $pendingHeader = $item; $headerShown = $false; continue }
        if ($kind -eq 'Spacer') { if ($out.Count -gt 0) { $pendingSpacer = $item }; continue }
        if (-not (Test-WtItemFocusable -Item $item)) { continue }
        $hay = [string]$item.Label + ' ' + [string]$item.StateLabel
        $hit = $true
        foreach ($term in $terms) {
            if ($hay.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { $hit = $false; break }
        }
        if (-not $hit) { continue }
        if ($null -ne $pendingSpacer) { $out.Add($pendingSpacer); $pendingSpacer = $null }
        if ($null -ne $pendingHeader -and -not $headerShown) { $out.Add($pendingHeader); $headerShown = $true }
        $out.Add($item)
    }
    return $out.ToArray()
}

# ---- Select-WtStartMenuPackages (lines 26415-26447) ----
function Select-WtStartMenuPackages {
    <#
    .SYNOPSIS
        PURE: from a Get-AppxPackage -AllUsers listing, the Start menu
        packages to re-register, deduplicated by PackageFullName (the same
        package returns once per profile). Matched OrdinalIgnoreCase, not
        culture-aware -eq, since tr-TR's dotless I changes the comparison.
        A package with no InstallLocation is KEPT with an empty
        ManifestPath so the repair reports it FAILED, not silently dropped.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Packages,
        [string[]]$Names = (Get-WtStartMenuPackageNames)
    )
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($Packages)) {
        if (-not $package) { continue }
        $name = [string]$package.Name
        $wanted = $false
        foreach ($candidate in @($Names)) {
            if ([string]::Equals($name, [string]$candidate, [System.StringComparison]::OrdinalIgnoreCase)) { $wanted = $true; break }
        }
        if (-not $wanted) { continue }
        $full = [string]$package.PackageFullName
        if (-not $full) { continue }
        if (-not $seen.Add($full)) { continue }
        $location = [string]$package.InstallLocation
        $manifest = if ($location) { Join-Path $location 'AppxManifest.xml' } else { '' }
        $result.Add([PSCustomObject]@{ Name = $name; PackageFullName = $full; ManifestPath = $manifest })
    }
    return @($result.ToArray())
}

# ---- Select-WtStillHungProcesses (lines 26752-26775) ----
function Select-WtStillHungProcesses {
    <#
    .SYNOPSIS
        PURE: the processes that looked hung in BOTH samples, three
        seconds apart - a single poll would flag an app merely busy
        writing a large file. Matched on Id AND Name, Ordinal (tr-TR's
        dotless I breaks culture-aware matching), so a recycled process id
        cannot smuggle a healthy app onto the kill list.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$First,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Second
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($later in @($Second)) {
        foreach ($earlier in @($First)) {
            if ([int]$earlier.Id -ne [int]$later.Id) { continue }
            if (-not [string]::Equals([string]$earlier.Name, [string]$later.Name, [System.StringComparison]::Ordinal)) { continue }
            $result.Add($later)
            break
        }
    }
    return @($result.ToArray())
}

# ---- Set-WtRadioSelection (lines 8733-8751) ----
function Set-WtRadioSelection {
    <#
    .SYNOPSIS
        Radio semantics scoped to a group: removes every Radio item of the
        SAME group from the selection, then adds the chosen one. Items in
        other groups (and all Check items) are untouched, so one screen can
        host a single-choice DNS block next to multi-select blocks.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$SelectionSet,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][PSCustomObject]$Item
    )
    $group = Get-WtItemGroup -Item $Item
    foreach ($other in $Items) {
        if ($other.Kind -eq 'Radio' -and (Get-WtItemGroup -Item $other) -eq $group) { $SelectionSet.Remove([string]$other.Name) | Out-Null }
    }
    $SelectionSet.Add([string]$Item.Name) | Out-Null
}

# ---- Set-WtRegistryValue (lines 623-654) ----
function Set-WtRegistryValue {
    <#
    .SYNOPSIS
        Writes one registry value, creating the key chain first if needed.
        Entirely behind -SetValueAction for the same reason as
        Get-WtRegistryValue - no registry PSProvider on this dev host.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$RegType,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [scriptblock]$SetValueAction = {
            param($p, $n, $t, $v)
            if (-not (Test-Path -LiteralPath $p)) {
                New-Item -Path $p -Force | Out-Null
            }
            New-ItemProperty -LiteralPath $p -Name $n -PropertyType $t -Value $v -Force | Out-Null
        }
    )

    & $SetValueAction $Path $Name $RegType $Value
}

# ---- Set-WtSelectionToggle (lines 11827-11852) ----
function Set-WtSelectionToggle {
    <#
    .SYNOPSIS
        Toggles $Item.Name in/out of $SelectionSet, keyed by name (not
        page-relative index) so a selection survives paging away and back.
        Refuses to add an item whose .Selectable is $false (already in the
        target state - e.g. an absent service or a removed package).
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$SelectionSet,

        [Parameter(Mandatory)]
        [PSCustomObject]$Item
    )

    if ($SelectionSet.Contains($Item.Name)) {
        $SelectionSet.Remove($Item.Name) | Out-Null
    }
    elseif ($Item.Selectable) {
        $SelectionSet.Add($Item.Name) | Out-Null
    }

    return $SelectionSet
}

# ---- Set-WtUndoEntryRetired (lines 13062-13115) ----
function Set-WtUndoEntryRetired {
    <#
    .SYNOPSIS
        Marks still-open undo records as retired because the caller has just
        wiped the state they record; the entry file stays on disk. Without
        -ItemFilter the whole entry is retired; with it, only the matching
        items, closing the entry only once nothing restorable is left in it -
        e.g. an 'Apply Blocklist' entry carries HostsBlock and FirewallBlock
        together, and resetting the firewall must not drop the hosts undo too.
        Returns how many entries were touched.
    #>
    param(
        [Parameter(Mandatory)][string[]]$ActionNames,
        [Parameter(Mandatory)][string]$RetiredBy,
        [scriptblock]$ItemFilter,
        [string]$TestRootOverride
    )
    $entryArgs = @{}
    if ($TestRootOverride) { $entryArgs['TestRootOverride'] = $TestRootOverride }

    $stamp = (Get-Date).ToString('o')
    $touched = 0
    foreach ($entry in @(Get-WtUndoEntries @entryArgs)) {
        if ($ActionNames -notcontains [string]$entry.Action) { continue }
        if (Test-WtUndoEntryClosed -Entry $entry) { continue }

        if (-not $ItemFilter) {
            $entry | Add-Member -NotePropertyName 'RetiredAt' -NotePropertyValue $stamp -Force
            $entry | Add-Member -NotePropertyName 'RetiredBy' -NotePropertyValue $RetiredBy -Force
            Write-WtJson -Path ([string]$entry.Path) -InputObject $entry
            $touched++
            continue
        }

        $stamped = 0
        foreach ($item in @($entry.Items)) {
            if (Test-WtUndoItemClosed -Item $item) { continue }
            if (-not (& $ItemFilter $item)) { continue }
            $item | Add-Member -NotePropertyName 'RetiredAt' -NotePropertyValue $stamp -Force
            $item | Add-Member -NotePropertyName 'RetiredBy' -NotePropertyValue $RetiredBy -Force
            $stamped++
        }
        if ($stamped -eq 0) { continue }

        $open = @(@($entry.Items) | Where-Object { -not (Test-WtUndoItemClosed -Item $_) })
        if ($open.Count -eq 0) {
            $entry | Add-Member -NotePropertyName 'RetiredAt' -NotePropertyValue $stamp -Force
            $entry | Add-Member -NotePropertyName 'RetiredBy' -NotePropertyValue $RetiredBy -Force
        }
        Write-WtJson -Path ([string]$entry.Path) -InputObject $entry
        $touched++
    }
    return $touched
}

# ---- Set-WtWindowIcon (lines 12144-12182) ----
function Set-WtWindowIcon {
    <#
    .SYNOPSIS
        Puts the WinToolify logo on the console window - title bar,
        Alt+Tab and the taskbar - in place of the host's own PowerShell
        icon. WM_SETICON takes one handle per slot, so the embedded logo
        becomes a 16- and a 32-pixel icon at its own size rather than one
        bitmap Windows shrinks twice. CreateIconFromResourceEx reads a
        PNG directly on Vista and later, which keeps this on user32 next
        to the rest of the window work instead of pulling System.Drawing
        into a script that loads no other assembly. Inside Windows
        Terminal GetConsoleWindow is a hidden pseudo-console and the tab
        icon comes from the profile, so nothing is set there - the same
        case Lock-WtWindow steps around. What the window had is kept in
        $script:WtWindowIcon for Restore-WtWindowIcon. Returns $false and
        changes nothing when there is no window to brand; never throws.
    #>
    param([scriptblock]$Apply = {
        if ($env:WT_SESSION) { return $null }
        if (-not ('WtWindowNative' -as [type])) { Add-Type -TypeDefinition $script:WtWindowNativeSource -ErrorAction Stop }
        $hwnd = [WtWindowNative]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $null }
        $bytes = [byte[]][Convert]::FromBase64String([string](Get-WtWinToolifyLogoBase64))
        $set = New-Object System.Collections.Generic.List[object]
        foreach ($slot in @(@{ Which = 0; Size = 16 }, @{ Which = 1; Size = 32 })) {
            $made = [WtWindowNative]::CreateIconFromResourceEx($bytes, [uint32]$bytes.Length, $true, 0x00030000, [int]$slot.Size, [int]$slot.Size, 0)
            if ($made -eq [IntPtr]::Zero) { continue }
            $previous = [WtWindowNative]::SendMessage($hwnd, 0x0080, [IntPtr][int]$slot.Which, $made)
            $set.Add(@{ Which = [int]$slot.Which; Made = $made; Previous = $previous })
        }
        if ($set.Count -eq 0) { return $null }
        return @{ Handle = $hwnd; Icons = $set.ToArray() }
    })
    $script:WtWindowIcon = $null
    try { $state = & $Apply } catch { $state = $null }
    if ($null -eq $state) { return $false }
    $script:WtWindowIcon = $state
    return $true
}

# ---- Show-WtOutputScreen (lines 37184-37218) ----
function Show-WtOutputScreen {
    <#
    .SYNOPSIS
        A command's output inside the box: scrollable, read-only, and
        never a bare console page. Nothing in the list is focusable, so
        Update-WtListState's cursorless branch scrolls the window with
        the arrows / PgUp / PgDn / Home / End, and Enter or Esc closes.
        Wide rows are cut with '~' rather than wrapped, so table output
        keeps its columns. -Hotkeys are extra letters the screen hands
        back instead of closing; anything else closes and returns ''.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [string]$FooterText = '',
        [AllowEmptyCollection()][string[]]$Hotkeys = @()
    )
    $text = @($Lines)
    if ($text.Count -eq 0) { $text = @((Get-Translation 'OutputEmpty')) }
    if (-not $FooterText) { $FooterText = Get-Translation 'OutputFooter' }
    $script:WtPanelBreadcrumb = $Breadcrumb
    $items = @(Get-WtPanelItems -Lines $text)
    $pressed = ''
    while ($true) {
        $r = Invoke-WtListScreen -Breadcrumb $Breadcrumb -Items $items -FooterText $FooterText
        if ($r.Emit -eq 'Global') {
            $char = [string]$r.Char
            if (@($Hotkeys) -contains $char) { $pressed = $char; break }
            continue
        }
        break
    }
    Reset-WtFrameCache
    return $pressed
}

# ---- Show-WtPanelMessage (lines 9162-9185) ----
function Show-WtPanelMessage {
    <#
    .SYNOPSIS
        Paints a frame whose content is a list of text lines (summaries,
        progress, results). No input. Returns the console size used.
        Long lines are wrapped to the box, never cut with '~'.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [string]$FooterText = '',
        [string]$Risk = '',
        [ValidateSet('Full', 'Compact')][string]$Layout = 'Full'
    )
    $size = Get-WtConsoleSize
    $items = @(Get-WtPanelItems -Lines (ConvertTo-WtPanelLines -Lines $Lines -Width (Get-WtPanelInnerWidth -Width $size.Width) -Risk $Risk) -Risk $Risk)
    $state = @{ CursorIndex = -1; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
    $frame = Get-WtFrameRows -Breadcrumb $Breadcrumb -Items $items -State $state -Width $size.Width -Height $size.Height `
        -Glyphs $script:WtGlyphs -FooterText $FooterText -LineMode ($script:WtInputMode -eq 'Line') `
        -Layout $Layout
    Write-WtFrame -FrameLines $frame -Width $size.Width -Height $size.Height
    $geo = Get-WtFrameFooterCell -FrameLines $frame -Glyphs $script:WtGlyphs
    return @{ Width = $size.Width; Height = $size.Height; FooterRow = $geo.Row; FooterCol = $geo.Col }
}

# ---- Show-WtSavableReport (lines 37425-37449) ----
function Show-WtSavableReport {
    <#
    .SYNOPSIS
        A report in the scrollable box, with "S" on the footer to write
        it to a file. The save confirmation is appended to the same
        report and the screen reopens, so the user sees where it went
        without losing the report.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][string]$ReportName,
        [scriptblock]$SaveAction = { param($Name, $Rows) Save-WtReport -Name $Name -Lines $Rows },
        [scriptblock]$ShowResult = { param($Crumb, $Rows, $Footer) Show-WtOutputScreen -Breadcrumb $Crumb -Lines $Rows -FooterText $Footer -Hotkeys @('s') }
    )
    $rows = @($Lines)
    $footer = (Get-Translation 'OutputFooter') + ' - ' + (Get-Translation 'OutputSaveHint')
    while ($true) {
        $key = [string](& $ShowResult $Breadcrumb $rows $footer)
        if ($key -ne 's') { break }
        $saved = & $SaveAction $ReportName $rows
        $rows = @($rows) + @('', ('{0}: {1}' -f (Get-Translation 'ReportSaved'), $saved))
        $footer = Get-Translation 'OutputFooter'
    }
}

# ---- Show-WtSelector (lines 11900-11963) ----
function Show-WtSelector {
    <#
    .SYNOPSIS
        Interactive multi-select over a catalog on the arrow-key TUI
        engine: Up/Down move, Space toggles, digits jump-toggle the
        visible row, A/C select/clear all on the viewport, Enter
        confirms, Left/Esc/q cancels. An ADVANCED item in the selection
        requires typing CONFIRM; anything else drops the ADVANCED items
        and keeps the rest. Returns the confirmed names, empty if the
        user quit. -PageSize is unused - kept only for signature
        stability; the TUI engine paginates by viewport height instead.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Catalog,

        [Parameter(Mandatory)]
        [array]$StateItems,

        [string]$Title = 'Select items',

        [int]$PageSize = 10,

        [string]$UnselectableNote = (Get-Translation 'AlreadyInTargetState'),

        [string[]]$InfoLines = @()
    )

    $stateByName = @{}
    foreach ($state in $StateItems) { $stateByName[$state.Name] = $state }

    $infoItems = @($InfoLines | Where-Object { $_ } | ForEach-Object { [PSCustomObject]@{ Kind = 'Info'; Name = ('Info:' + $_); Label = $_; Risk = $null; StateLabel = ''; Selectable = $false; Data = $null } })
    $selectorItems = foreach ($entry in $Catalog) {
        $state = $stateByName[$entry.Name]
        $selectable = if ($state) { [bool]$state.Selectable } else { $true }
        $stateLabel = if ($state) { [string]$state.StateLabel } else { Get-Translation 'StateUnknown' }
        if (-not $selectable) { $stateLabel = $stateLabel + $UnselectableNote }
        [PSCustomObject]@{
            Kind = 'Check'; Name = $entry.Name
            Label = (Get-WtSelectorDisplayLabel -Entry $entry)
            Risk = $entry.Risk; StateLabel = $stateLabel
            Selectable = $selectable; Data = $entry
        }
    }

    $selection = New-Object 'System.Collections.Generic.HashSet[string]'
    while ($true) {
        $r = Invoke-WtListScreen -Breadcrumb $Title -Items @($infoItems + @($selectorItems)) -MultiSelect $true `
            -Selection $selection -FooterText (Get-Translation 'SelectorFooter') -CounterText ((Get-Translation 'SettingsCount') -f $Catalog.Count)
        if ($r.Emit -eq 'Back' -or $r.Emit -eq 'Quit') { return @() }
        if ($r.Emit -eq 'Activate') {
            if (Test-WtSelectionNeedsAdvancedConfirm -Catalog $Catalog -SelectionSet @($selection)) {
                $advancedEntries = $Catalog | Where-Object { $selection.Contains($_.Name) -and $_.Risk -eq 'ADVANCED' }
                $advancedTag = Get-WtRiskLabel -Risk 'ADVANCED'
                $lines = @(((Get-Translation 'SelectorAdvancedHeader') -f $advancedTag)) + @($advancedEntries | ForEach-Object { "  - $($_.Name): $($_.Consequence)" })
                $typed = Read-WtPanelAnswer -Breadcrumb $Title -Lines $lines -Prompt ((Get-Translation 'SelectorAdvancedPrompt') -f $advancedTag, (Get-WtTypedWord -Kind 'Confirm')) -Risk 'ADVANCED'
                if (-not (Test-WtTypedConfirmation -Answer $typed -Kind 'Confirm')) {
                    foreach ($advancedEntry in $advancedEntries) { $selection.Remove($advancedEntry.Name) | Out-Null }
                }
            }
            return @($selection)
        }
    }
}

# ---- Show-WtShutdownTimerResult (lines 25650-25669) ----
function Show-WtShutdownTimerResult {
    <#
    .SYNOPSIS
        Prints the timer's result rows inside the panel. The delegate
        deliberately reads $wtTimerRows and NOT $Lines:
        Invoke-WtCapturedAction keeps its collected output in a variable
        called $lines, PowerShell variable lookup is case-insensitive,
        and a plain script block resolves its captured variables through
        the CALL STACK - so a variable named $Lines here would be
        shadowed by the collector the moment the action runs inside the
        capture, and the panel would echo its own buffer.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowEmptyCollection()][string[]]$ResultLines = @(),
        [string]$Breadcrumb = ''
    )
    $wtTimerRows = @($ResultLines)
    Invoke-WtCapturedAction -Title $Title -Breadcrumb $Breadcrumb -Action { foreach ($row in $wtTimerRows) { Write-Host $row } }
}

# ---- Split-WtStateSegments (lines 6288-6327) ----
function Split-WtStateSegments {
    <#
    .SYNOPSIS
        PURE: turns the state column's text into colored segments. A
        vocabulary word gets its own colour; "/" and padding stay
        $DefaultFg. All-or-nothing: unless every character is a
        vocabulary word or the glue between them, the whole column comes
        back as one uncoloured segment, since a path or free-text state
        can match a word mid-string with no boundary. Joining the
        segments always returns $Text unchanged. Matching uses
        CompareOrdinal, not -match/-replace, because tr-TR's
        culture-aware comparison folds I/i the Turkish way.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$DefaultFg = 'DarkGray',
        [AllowEmptyCollection()][array]$Vocabulary = (Get-WtStateColorMap)
    )
    if (-not $Text) { return @() }
    $segs = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $Text.Length) {
        $hit = $null
        foreach ($v in $Vocabulary) {
            $w = [string]$v.Word
            if ($w.Length -gt 0 -and $w.Length -le ($Text.Length - $i) -and
                [string]::CompareOrdinal($Text, $i, $w, 0, $w.Length) -eq 0) { $hit = $v; break }
        }
        if ($hit) {
            $segs.Add((New-WtSeg -Text ([string]$hit.Word) -Fg ([string]$hit.Fg)))
            $i += ([string]$hit.Word).Length
            continue
        }
        $start = $i
        while ($i -lt $Text.Length -and ($Text[$i] -eq ' ' -or $Text[$i] -eq '/')) { $i++ }
        if ($i -eq $start) { return @(New-WtSeg -Text $Text -Fg $DefaultFg) }
        $segs.Add((New-WtSeg -Text $Text.Substring($start, $i - $start) -Fg $DefaultFg))
    }
    return $segs.ToArray()
}

# ---- Split-WtWrappedLines (lines 9121-9149) ----
function Split-WtWrappedLines {
    <#
    .SYNOPSIS
        PURE: word-wraps one long message into panel-width lines. Runs of
        whitespace collapse to single spaces, a word longer than Width is
        hard-broken, and blank input yields no lines at all.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )
    $w = [Math]::Max(8, $Width)
    $words = @(([string]$Text) -split '\s+' | Where-Object { $_ })
    $lines = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($word in $words) {
        $piece = [string]$word
        while ($piece.Length -gt $w) {
            if ($current) { $lines.Add($current); $current = '' }
            $lines.Add($piece.Substring(0, $w))
            $piece = $piece.Substring($w)
        }
        if (-not $current) { $current = $piece }
        elseif (($current.Length + 1 + $piece.Length) -le $w) { $current += ' ' + $piece }
        else { $lines.Add($current); $current = $piece }
    }
    if ($current) { $lines.Add($current) }
    return $lines.ToArray()
}

# ---- Sync-WtBufferToWindow (lines 12043-12057) ----
function Sync-WtBufferToWindow {
    <#
    .SYNOPSIS
        Pins the buffer to the window size so there is no scrollback and
        (0,0) is always the visible top-left. Skipped while the assistant
        REPL is open, which keeps a tall scrollback on purpose and whose
        BufferSize resize is exactly the console path known to FAST_FAIL.
    #>
    param([scriptblock]$Apply = {
        $raw = $Host.UI.RawUI
        for ($i = 0; $i -lt 2; $i++) { $raw.BufferSize = $raw.WindowSize }
    })
    if ($script:WtReplMode) { return }
    try { & $Apply } catch { $null = $_ }
}

# ---- Test-WingetInstalled (lines 298-321) ----
function Test-WingetInstalled {
    <#
    .SYNOPSIS
        Ensures winget exists; on Windows 10 / LTSC without App Installer
        bootstraps it the way Microsoft documents (TLS 1.2 for the
        gallery, Microsoft.WinGet.Client, Repair-WinGetPackageManager).
        Called lazily from the actions that need winget, never at startup.
    #>
    try {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host (Get-Translation 'WingetAlreadyInstalled') -ForegroundColor Green
            return
        }
        Write-Host (Get-Translation 'WingetNotInstalled') -ForegroundColor Yellow
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -Force | Out-Null
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -Command Repair-WinGetPackageManager -AllUsers -Force -Latest' -Wait -NoNewWindow
        Write-Host (Get-Translation 'WingetInstalled') -ForegroundColor Green
    }
    catch {
        Write-Host (Get-Translation 'WingetInstallError') -ForegroundColor Red
    }
}

# ---- Test-WtAffirmativeAnswer (lines 6866-6878) ----
function Test-WtAffirmativeAnswer {
    <#
    .SYNOPSIS
        True when a typed answer starts with the active language's "yes"
        letter (Y in English, E in Turkish). Every yes/no prompt in the
        script defaults to no, so this one predicate answers all of them:
        blank input, the "no" letter and any typo all mean no.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Answer)
    $text = ([string]$Answer).Trim()
    if (-not $text) { return $false }
    return ($text.Substring(0, 1).ToUpperInvariant() -eq (Get-WtAnswerLetter -Kind 'Yes'))
}

# ---- Test-WtDiskCleanupConfigured (lines 23033-23049) ----
function Test-WtDiskCleanupConfigured {
    <#
    .SYNOPSIS
        True when cleanmgr /sageset:65 has been run at least once on this
        machine (any VolumeCaches handler carries StateFlags0065).
    #>
    param(
        [scriptblock]$GetStateFlags = {
            $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
            Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
                (Get-ItemProperty -LiteralPath $_.PSPath -Name 'StateFlags0065' -ErrorAction SilentlyContinue).StateFlags0065
            }
        }
    )
    foreach ($flag in @(& $GetStateFlags)) { if ($null -ne $flag) { return $true } }
    return $false
}

# ---- Test-WtDismAvailable (lines 34023-34036) ----
function Test-WtDismAvailable {
    <#
    .SYNOPSIS
        True when Dism.exe is where Windows keeps it. The component-store
        row needs an honest "not available" line rather than a raw
        "command not found" spilling into the panel.
    #>
    param(
        [string]$DismPath = (Join-Path $env:SystemRoot 'System32\Dism.exe'),
        [scriptblock]$TestPathAction = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf }
    )
    try { return [bool](& $TestPathAction $DismPath) }
    catch { return $false }
}

# ---- Test-WtDriverExportSpace (lines 22795-22824) ----
function Test-WtDriverExportSpace {
    <#
    .SYNOPSIS
        How much room the driver export folder's drive has, and whether it
        clears the 5 GB a full third-party driver export can need. The
        trailing separator is trimmed since GetPathRoot returns "C:\" but
        Win32_LogicalDisk's DeviceID is "C:"; a source that throws counts
        as zero free space, so the row refuses rather than risk filling a
        disk it never measured.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$RequiredBytes = 5368709120,
        [scriptblock]$GetFreeBytes = {
            param($Root)
            (Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $Root + "'")).FreeSpace
        }
    )

    $root = ([System.IO.Path]::GetPathRoot($Path)).TrimEnd('\')
    $free = 0
    try { $free = [long](& $GetFreeBytes $root) } catch { $free = 0 }

    return [PSCustomObject]@{
        Root          = $root
        FreeBytes     = $free
        RequiredBytes = $RequiredBytes
        Sufficient    = ($free -ge $RequiredBytes)
    }
}

# ---- Test-WtHostName (lines 32634-32649) ----
function Test-WtHostName {
    <#
    .SYNOPSIS
        Is this text a plausible DNS host name? Labels of letters, digits
        and hyphens (never leading or trailing), 1-63 characters each, 253
        overall, with an optional trailing dot. Uses -cmatch on an
        explicit A-Za-z class, since under tr-TR a case-insensitive
        -match applies the dotless-I rules and would accept or reject the
        wrong names; nothing the user typed reaches a command before this
        returns $true.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if (-not $Name) { return $false }
    if ($Name.Length -gt 253) { return $false }
    return [bool]($Name -cmatch '^[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*\.?$')
}

# ---- Test-WtItemFocusable (lines 8526-8529) ----
function Test-WtItemFocusable {
    param([Parameter(Mandatory)][PSCustomObject]$Item)
    return (@('Link', 'Action', 'Check', 'Radio') -contains $Item.Kind)
}

# ---- Test-WtNavToken (lines 8753-8763) ----
function Test-WtNavToken {
    <#
    .SYNOPSIS
        Whether a token is a navigation key. Includes 'Left'/'Right'
        (grid-only; ConvertTo-WtKeyToken never emits them) so
        Read-WtInputBatch can drain horizontal auto-repeat the same way it
        drains vertical.
    #>
    param([Parameter(Mandatory)][string]$Token)
    return (@('Up', 'Down', 'Left', 'Right', 'PageUp', 'PageDown', 'Home', 'End') -contains $Token)
}

# ---- Test-WtSelectionNeedsAdvancedConfirm (lines 11854-11878) ----
function Test-WtSelectionNeedsAdvancedConfirm {
    <#
    .SYNOPSIS
        True when the selected names include at least one catalog entry
        tagged ADVANCED.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Catalog,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SelectionSet
    )

    $selectedNames = @($SelectionSet)
    if ($selectedNames.Count -eq 0) {
        return $false
    }

    $advancedSelected = $Catalog | Where-Object { $selectedNames -contains $_.Name -and $_.Risk -eq 'ADVANCED' }
    return @($advancedSelected).Count -gt 0
}

# ---- Test-WtStartupEntryEnabled (lines 33327-33345) ----
function Test-WtStartupEntryEnabled {
    <#
    .SYNOPSIS
        PURE: is a Run / Startup-folder entry enabled, given its
        StartupApproved value (or $null when Explorer has never written
        one)? The rule is inverted: byte 0's low bit SET means DISABLED
        (0x02/0x06 enabled, 0x03/0x05/0x07 disabled); no value at all
        means enabled, since Explorer only writes one once a user has
        toggled the entry.
    #>
    param([AllowNull()]$ApprovalValue)
    if ($null -eq $ApprovalValue) { return $true }
    $bytes = @($ApprovalValue)
    if ($bytes.Count -lt 1) { return $true }
    $first = 0
    try { $first = [int]$bytes[0] }
    catch { return $true }
    return (($first -band 1) -eq 0)
}

# ---- Test-WtTypedConfirmation (lines 6975-6992) ----
function Test-WtTypedConfirmation {
    <#
    .SYNOPSIS
        True when the user typed the gate word, in any shipped language,
        matched Ordinal-IgnoreCase rather than ToUpper/-eq because tr-TR
        maps i to I-with-dot and would otherwise miss the match.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Answer,
        [Parameter(Mandatory)][ValidateSet('Yes', 'Confirm')][string]$Kind
    )
    $text = ([string]$Answer).Trim()
    if (-not $text) { return $false }
    foreach ($word in (Get-WtAcceptedTypedWords -Kind $Kind)) {
        if ([string]::Equals($text, $word, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ---- Test-WtUefiFirmware (lines 25759-25789) ----
function Test-WtUefiFirmware {
    <#
    .SYNOPSIS
        True on a UEFI machine, false on legacy BIOS or when neither
        source can answer - refusing on doubt, since a wrong restart
        strands the user on the desktop with no explanation. Reads
        $env:firmware_type first ('UEFI' on PowerShell 5.1); falls back
        to Confirm-SecureBootUEFI, resolved via Get-Command since the
        module is not on every SKU, whose PlatformNotSupportedException
        means "not UEFI". Compared with [string]::Equals Ordinal, never
        -eq/ToUpper: tr-TR's dotless I makes 'UEFI' a documented trap.
    #>
    param(
        [scriptblock]$GetFirmwareType = { $env:firmware_type },
        [scriptblock]$GetSecureBootState = {
            $secureBootCmd = Get-Command -Name 'Confirm-SecureBootUEFI' -ErrorAction SilentlyContinue
            if (-not $secureBootCmd) { throw [System.PlatformNotSupportedException]::new('Confirm-SecureBootUEFI is not available') }
            & $secureBootCmd
        }
    )
    $firmware = [string](& $GetFirmwareType)
    if ($firmware) {
        if ([string]::Equals($firmware, 'UEFI', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ([string]::Equals($firmware, 'Legacy', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    try {
        $null = & $GetSecureBootState
        return $true
    }
    catch { return $false }
}

# ---- Test-WtUndoEntryClosed (lines 13046-13060) ----
function Test-WtUndoEntryClosed {
    <#
    .SYNOPSIS
        PURE: is this entry finished with? Either the user restored it
        (RestoredAt) or another action wiped the state it records and it
        was retired (RetiredAt). Either way the Undo screen must not
        offer it - restoring it would put back a setting that no longer
        exists anywhere.
    #>
    param([Parameter(Mandatory)][object]$Entry)
    $names = $Entry.PSObject.Properties.Name
    if (($names -contains 'RestoredAt') -and $Entry.RestoredAt) { return $true }
    if (($names -contains 'RetiredAt') -and $Entry.RetiredAt) { return $true }
    return $false
}

# ---- Test-WtUndoItemClosed (lines 13031-13044) ----
function Test-WtUndoItemClosed {
    <#
    .SYNOPSIS
        PURE: is this single item finished with? Either a per-setting
        revert put it back (RestoredAt) or another action wiped what it
        records and it was retired (RetiredAt). A closed item is skipped
        by the restore loop and no longer keeps its entry pending.
    #>
    param([Parameter(Mandatory)][object]$Item)
    $names = $Item.PSObject.Properties.Name
    if (($names -contains 'RestoredAt') -and $Item.RestoredAt) { return $true }
    if (($names -contains 'RetiredAt') -and $Item.RetiredAt) { return $true }
    return $false
}

# ---- Test-WtUninstallUserHiveVisible (lines 27111-27123) ----
function Test-WtUninstallUserHiveVisible {
    <#
    .SYNOPSIS
        Whether the interactive user's hive made it into the root list.
        When it did not, the selector has to SAY that only machine-wide
        programs are listed - silently showing a short list would be a lie.
    #>
    param([scriptblock]$GetRoots = { Get-WtUninstallRegistryRoots })
    foreach ($root in @(& $GetRoots)) {
        if ([string]::Equals([string]$root.ScopeKey, 'UninstallScopeUser', [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

# ---- Test-WtUsesCimRestorePointApi (lines 964-976) ----
function Test-WtUsesCimRestorePointApi {
    <#
    .SYNOPSIS
        True when the running PowerShell major version should use the CIM
        restore-point API (6+) instead of Checkpoint-Computer (5.1 and
        below); PS7 does not ship Checkpoint-Computer or Get-ComputerRestorePoint.
    #>
    param(
        [Parameter(Mandatory)]
        [int]$PSMajorVersion
    )
    return ($PSMajorVersion -ge 6)
}

# ---- Test-WtVcRedistFileComplete (lines 28138-28151) ----
function Test-WtVcRedistFileComplete {
    <#
    .SYNOPSIS
        A file exists and has exactly the catalog's byte length. The only
        integrity check the installers get; it catches the one failure
        that actually happens - a download cut short.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Size
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { return ((Get-Item -LiteralPath $Path).Length -eq $Size) } catch { return $false }
}

# ---- Test-WtWingetAdminContextProhibited (lines 29052-29069) ----
function Test-WtWingetAdminContextProhibited {
    <#
    .SYNOPSIS
        Whether winget refused (0x8A15007D,
        APPINSTALLER_CLI_ERROR_ADMIN_CONTEXT_ACTION_PROHIBITED) because the
        package lives in the USER scope while this process is elevated.
        WinToolify always relaunches itself elevated, so this is not an
        edge case: every per-user install (Antigravity, VS Code user setup,
        anything shipped through Squirrel) hits it, and winget has no flag
        that overrides it - the only fix is running the same command back
        in the user's own non-elevated session (Invoke-WtWingetBatch
        -RunOneAsUser).
    #>
    param([AllowNull()][object]$ExitCode)
    $code = ConvertTo-WtWingetExitCode -ExitCode $ExitCode
    if ($null -eq $code) { return $false }
    return ($code -eq [Convert]::ToUInt32('8A15007D', 16))
}

# ---- Test-WtWingetShouldRetryByName (lines 26946-26959) ----
function Test-WtWingetShouldRetryByName {
    <#
    .SYNOPSIS
        True only for APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
        (0x8A150014) - the code winget returns when --id --exact matched
        nothing, which is exactly when a --name retry can still help.
        Everything else is final. Goes through ConvertTo-WtWingetExitCode,
        since $LASTEXITCODE is signed.
    #>
    param([Parameter(Mandatory)][AllowNull()][object]$ExitCode)
    $code = ConvertTo-WtWingetExitCode -ExitCode $ExitCode
    if ($null -eq $code) { return $false }
    return ($code -eq [Convert]::ToUInt32('8A150014', 16))
}

# ---- Test-WtWinHttpProxyConfigured (lines 25187-25202) ----
function Test-WtWinHttpProxyConfigured {
    <#
    .SYNOPSIS
        PURE: true when "netsh winhttp show proxy" output names a proxy
        server. Matches on the shape of a proxy value (host:port), never
        on the surrounding text, since both the labels and the "no proxy"
        sentence are localized.
    #>
    param([AllowEmptyCollection()][string[]]$Lines = @())
    foreach ($raw in @($Lines)) {
        $line = [string]$raw
        if (-not $line) { continue }
        if ($line -cmatch '[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}(\s|;|$)') { return $true }
    }
    return $false
}

# ---- Test-WtWinReAvailable (lines 25710-25729) ----
function Test-WtWinReAvailable {
    <#
    .SYNOPSIS
        True when reagentc /info reports a recovery image location. Only
        the \\?\GLOBALROOT PATH substring is checked (labels are
        localized, the device path never is), matched Ordinal since
        tr-TR breaks case-insensitive I/i comparison. Streams merge
        through cmd.exe for the same NativeCommandError reason as
        Invoke-WtShutdownCommand; $wtReagentcDump avoids the same
        collector-shadowing trap as Show-WtShutdownTimerResult.
    #>
    param([scriptblock]$GetInfo = { @(cmd.exe /c 'reagentc.exe /info 2>&1') })
    $wtReagentcDump = @()
    try { $wtReagentcDump = @(& $GetInfo) }
    catch { return $false }
    foreach ($row in $wtReagentcDump) {
        if ([string]$row -and ([string]$row).IndexOf('\\?\GLOBALROOT', [System.StringComparison]::Ordinal) -ge 0) { return $true }
    }
    return $false
}

# ---- Update-WtListState (lines 8802-8971) ----
function Update-WtListState {
    <#
    .SYNOPSIS
        The pure list-screen reducer: one input token in, a new state and an
        emit out. The interactive shell (Invoke-WtListScreen) is a dumb loop
        around this; every navigation rule lives here where Pester can reach
        it. Movement keys scroll the window directly when nothing is
        focusable (no cursor to chase); the search-box branch runs before
        that check so an empty-match filter still answers '/' and Back. A
        Digit token counts position through the whole list, not just the
        page, via TryParse (line mode can hand it a digit run too long for
        a plain [int] cast). Returns
        @{ State = <same shape as input>; Emit = 'None'|'Activate'|'Refused'|'Back'|'Global'; EmitChar = [string] }.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [int]$ViewHeight = 10,
        [bool]$MultiSelect = $false,
        [bool]$Searchable = $false
    )

    $cursor = [int]$State.CursorIndex
    $window = [int]$State.WindowStart
    $selection = $State.Selection
    $cycle = $(if ($State.ContainsKey('Cycle') -and $null -ne $State.Cycle) { $State.Cycle } else { @{} })
    $focus = $(if ($State.ContainsKey('Focus') -and [string]$State.Focus -eq 'Input') { 'Input' } else { 'List' })
    $query = $(if ($State.ContainsKey('Query') -and $null -ne $State.Query) { [string]$State.Query } else { '' })
    $emit = 'None'
    $emitChar = ''
    $finish = { param([int]$c, [int]$w)
        @{
            State    = @{ CursorIndex = $c; WindowStart = $w; Selection = $selection; Cycle = $cycle; Focus = $focus; Query = $query }
            Emit     = $emit
            EmitChar = $emitChar
        }
    }

    if ($Searchable -and $focus -eq 'Input') {
        $moveWith = ''
        switch -Regex ($Token) {
            '^Eof$'        { $emit = 'Back' }
            '^(Esc|Back)$' { $focus = 'List'; $query = ''; $cursor = 0; $window = 0 }
            '^Enter$'      { $focus = 'List'; $cursor = 0; $window = 0 }
            '^Backspace$'  { if ($query.Length -gt 0) { $query = $query.Substring(0, $query.Length - 1) }; $cursor = 0; $window = 0 }
            '^Space$'      { $query += ' '; $cursor = 0; $window = 0 }
            '^Char:'       { $query += $Token.Substring(5); $cursor = 0; $window = 0 }
            '^Digit:'      { $query += $Token.Substring(6); $cursor = 0; $window = 0 }
            '^(Up|Down|PageUp|PageDown|Home|End)$' { $focus = 'List'; $moveWith = $Token }
        }
        if (-not $moveWith) { return (& $finish $cursor $window) }
        $Token = $moveWith
    }
    elseif ($Searchable) {
        if ($Token -eq 'Char:/') {
            $focus = 'Input'
            $query = ''
            return (& $finish 0 0)
        }
        if ($Token -eq 'Back' -and $query.Trim() -ne '') {
            $query = ''
            return (& $finish 0 0)
        }
    }

    $hasFocusable = $false
    foreach ($item in $Items) { if (Test-WtItemFocusable -Item $item) { $hasFocusable = $true; break } }
    if (-not $hasFocusable) {
        $maxStart = [Math]::Max(0, $Items.Count - $ViewHeight)
        switch -Regex ($Token) {
            '^Up$'       { $window-- }
            '^Down$'     { $window++ }
            '^PageUp$'   { $window -= $ViewHeight }
            '^PageDown$' { $window += $ViewHeight }
            '^Home$'     { $window = 0 }
            '^End$'      { $window = $maxStart }
            '^Enter$'    { $emit = 'Activate' }
            '^Back$'     { $emit = 'Back' }
            '^Eof$'      { $emit = 'Back' }
            '^Char:'     { $emit = 'Global'; $emitChar = $Token.Substring(5) }
        }
        $window = [Math]::Max(0, [Math]::Min($window, $maxStart))
        return (& $finish (-1) $window)
    }

    switch -Regex ($Token) {
        '^Up$'   { $cursor = Get-WtNextFocusableIndex -Items $Items -FromIndex $cursor -Direction -1 }
        '^Down$' { $cursor = Get-WtNextFocusableIndex -Items $Items -FromIndex $cursor -Direction 1 }
        '^Home$' {
            $cursor = -1
            $cursor = Get-WtNextFocusableIndex -Items $Items -FromIndex $cursor -Direction 1
            if ($cursor -lt 0) { $cursor = [int]$State.CursorIndex }
        }
        '^End$' {
            $cursor = $Items.Count
            $cursor = Get-WtNextFocusableIndex -Items $Items -FromIndex $cursor -Direction -1
            if ($cursor -ge $Items.Count) { $cursor = [int]$State.CursorIndex }
        }
        '^PageDown$' {
            $target = [Math]::Min($cursor + $ViewHeight, $Items.Count - 1)
            if (-not (Test-WtItemFocusable -Item $Items[$target])) {
                $target = Get-WtNextFocusableIndex -Items $Items -FromIndex $target -Direction -1
            }
            $cursor = $target
        }
        '^PageUp$' {
            $target = [Math]::Max($cursor - $ViewHeight, 0)
            if (-not (Test-WtItemFocusable -Item $Items[$target])) {
                $target = Get-WtNextFocusableIndex -Items $Items -FromIndex $target -Direction 1
            }
            $cursor = $target
        }
        '^Space$' {
            if ($cursor -ge 0 -and $cursor -lt $Items.Count) {
                $emit = Invoke-WtListMarkToggle -Item $Items[$cursor] -Items $Items -Selection $selection -Cycle $cycle
            }
        }
        '^Enter$' { $emit = 'Activate' }
        '^Back$'  { $emit = 'Back' }
        '^Eof$'   { $emit = 'Back' }
        '^Digit:' {
            $n = 0
            if ([int]::TryParse($Token.Substring(6), [ref]$n) -and $n -ge 1) {
                $seen = 0
                for ($i = 0; $i -lt $Items.Count; $i++) {
                    if (-not (Test-WtItemFocusable -Item $Items[$i])) { continue }
                    $seen++
                    if ($seen -eq $n) {
                        $cursor = $i
                        $emit = Invoke-WtListMarkToggle -Item $Items[$cursor] -Items $Items -Selection $selection -Cycle $cycle
                        break
                    }
                }
            }
        }
        '^Char:a$' {
            if ($MultiSelect) {
                $limit = [Math]::Min($window + $ViewHeight, $Items.Count)
                for ($i = $window; $i -lt $limit; $i++) {
                    $item = $Items[$i]
                    $isApplied = ($item.PSObject.Properties.Name -contains 'Applied') -and [bool]$item.Applied
                    if ($item.Kind -eq 'Check' -and $item.Selectable -and -not $isApplied -and -not $selection.Contains($item.Name)) {
                        $selection.Add($item.Name) | Out-Null
                        $ct = @($(if ($item.PSObject.Properties.Name -contains 'CycleTargets') { $item.CycleTargets } else { @() }))
                        if ($ct.Count -gt 0) { $cycle[[string]$item.Name] = [string]$ct[0] }
                    }
                }
            }
            else { $emit = 'Global'; $emitChar = 'a' }
            break
        }
        '^Char:c$' {
            if ($MultiSelect) {
                $limit = [Math]::Min($window + $ViewHeight, $Items.Count)
                for ($i = $window; $i -lt $limit; $i++) {
                    if ($selection.Contains($Items[$i].Name)) { $selection.Remove($Items[$i].Name) | Out-Null }
                    if ($cycle.ContainsKey([string]$Items[$i].Name)) { $cycle.Remove([string]$Items[$i].Name) }
                }
            }
            else { $emit = 'Global'; $emitChar = 'c' }
            break
        }
        '^Char:' { $emit = 'Global'; $emitChar = $Token.Substring(5) }
    }

    $window = Get-WtViewportWindow -ItemCount $Items.Count -CursorIndex $cursor -ViewHeight $ViewHeight -WindowStart $window

    return (& $finish $cursor $window)
}

# ---- Wait-WtEnter (lines 9287-9297) ----
function Wait-WtEnter {
    <#
    .SYNOPSIS
        The pause used by every transient flow, shown IN THE PANEL: the
        optional lines, then the translated prompt on the footer. The
        next TUI frame is drawn from scratch afterwards.
    #>
    param([AllowEmptyCollection()][string[]]$Lines = @())
    $null = Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @($Lines) -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
    Reset-WtFrameCache
}

# ---- Write-WtErrorLog (lines 345-376) ----
function Write-WtErrorLog {
    <#
    .SYNOPSIS
        Appends one exception to the error log - when, where it was
        caught, the type, the message, the script position and the
        script stack - and returns the log path ('' when even that
        failed). NEVER throws: it runs inside the catch blocks whose one
        job is to keep the app alive. A log past 1 MB is started over.
    #>
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [AllowEmptyString()][string]$Context = '',
        [string]$Path = ''
    )
    try {
        if (-not $Path) { $Path = Get-WtErrorLogPath }
        $exception = $(if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord })
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('==== ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Context)
        $lines.Add('Type: ' + $(if ($null -ne $exception) { $exception.GetType().FullName } else { '' }))
        $lines.Add('Message: ' + [string]$(if ($null -ne $exception) { $exception.Message } else { $ErrorRecord }))
        if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
            if ($ErrorRecord.InvocationInfo) { $lines.Add('At: ' + ([string]$ErrorRecord.InvocationInfo.PositionMessage).Trim()) }
            if ($ErrorRecord.ScriptStackTrace) { $lines.Add('Stack: ' + [string]$ErrorRecord.ScriptStackTrace) }
        }
        $lines.Add('')
        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 1MB) { Remove-Item -LiteralPath $Path -Force }
        Add-Content -LiteralPath $Path -Value ($lines.ToArray() -join [Environment]::NewLine) -Encoding UTF8
        return $Path
    }
    catch { return '' }
}

# ---- Write-WtFrame (lines 6056-6120) ----
function Write-WtFrame {
    <#
    .SYNOPSIS
        Paints a frame: key mode + VT emits one SGR string per changed row
        via CUP in a single host write (DECSET 2026) without touching the
        last column; key mode without VT does the same diff via
        SetCursorPosition + Write; line mode is Clear-Host plus plain rows.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$FrameLines,
        [int]$Width = 0,
        [int]$Height = 0
    )
    if ($Width -le 0 -or $Height -le 0) {
        $size = Get-WtConsoleSize
        if ($Width -le 0) { $Width = $size.Width }
        if ($Height -le 0) { $Height = $size.Height }
    }
    $w = Get-WtFrameWidth -Width $Width
    $lines = @($FrameLines)
    if ($lines.Count -gt $Height) { $lines = @($lines[0..($Height - 1)]) }

    if ($script:WtInputMode -eq 'Line') {
        Clear-Host
        foreach ($line in $lines) { Write-Host (ConvertTo-WtRowString -Segments @($line) -Width $w -Vt $false) }
        return
    }

    $force = ($Width -ne $script:WtPrevWidth -or $Height -ne $script:WtPrevHeight -or @($script:WtPrevRows).Count -eq 0)
    $rows = New-Object string[] $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) { $rows[$i] = ConvertTo-WtRowString -Segments @($lines[$i]) -Width $w -Vt $script:WtVt }
    $changed = Get-WtFrameDiff -Rows $rows -PrevRows ([string[]]@($script:WtPrevRows)) -Force $force

    if ($script:WtVt) {
        $e = $script:WtEsc
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append($e + '[?2026h')
        if ($force) { [void]$sb.Append($e + '[2J') }
        foreach ($i in $changed) { [void]$sb.Append($e + '[' + ($i + 1) + ';1H').Append($rows[$i]) }
        [void]$sb.Append($e + '[1;1H' + $e + '[?2026l')
        $Host.UI.Write($sb.ToString())
    }
    else {
        if ($force) { Clear-Host }
        $defaultBg = $Host.UI.RawUI.BackgroundColor
        foreach ($i in $changed) {
            try { [Console]::SetCursorPosition(0, $i) } catch { continue }
            $used = 0
            foreach ($seg in @($lines[$i])) {
                $text = [string]$seg.T
                if (($used + $text.Length) -gt $w) { $text = $text.Substring(0, [Math]::Max(0, $w - $used)) }
                if ($text.Length -eq 0) { continue }
                $fg = if ($seg.F -and $script:WtSgrMap.ContainsKey([string]$seg.F)) { [ConsoleColor]$seg.F } else { [ConsoleColor]'Gray' }
                $bg = if ($seg.B -and $script:WtSgrMap.ContainsKey([string]$seg.B)) { [ConsoleColor]$seg.B } else { $defaultBg }
                $Host.UI.Write($fg, $bg, $text)
                $used += $text.Length
            }
            if ($used -lt $w) { $Host.UI.Write([ConsoleColor]'Gray', $defaultBg, (' ' * ($w - $used))) }
        }
        try { [Console]::SetCursorPosition(0, 0) } catch { $null = $_ }
    }
    $script:WtPrevRows = $rows
    $script:WtPrevWidth = $Width
    $script:WtPrevHeight = $Height
}

# ---- Write-WtJson (lines 1171-1187) ----
function Write-WtJson {
    <#
    .SYNOPSIS
        Serializes an object to a JSON file with the project's fixed depth
        and encoding rules, so no caller has to remember them.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$InputObject
    )

    $json = $InputObject | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

#endregion

# Bu dosya ajan tarafindan dot-source edilir; ana akis kodu YOKTUR.