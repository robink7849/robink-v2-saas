# Robink V2 — Render.com'a Deploy Rehberi

Bu rehber sıfırdan, adım adım canlıya almayı anlatır. Toplam süre: ~15 dakika.

## Önkoşullar
- ✅ GitHub hesabı (var)
- ⏳ Render.com hesabı (aşağıda oluşturulacak)
- ⏳ Supabase hesabı (aşağıda oluşturulacak, ücretsiz)

---

## 1. Supabase'de Veritabanı Oluşturma (5 dk)

### 1.1 Hesap aç
1. https://supabase.com adresine gidin
2. **"Start your project"** tıklayın
3. **GitHub ile giriş yapın** (hesabınız zaten bağlı olacak)
4. E-posta doğrulaması gerekirse yapın

### 1.2 Yeni proje oluştur
1. **"New Project"** tıklayın
2. **Organization**: kişisel hesabınızı seçin (veya yeni oluşturun)
3. **Name**: `robink-v2` (veya istediğiniz bir ad)
4. **Database Password**: güçlü bir şifre belirleyin ve **bir yere not edin** (örn. `RobinkV2-DB-2026!`)
5. **Region**: `West EU (Ireland)` veya size yakın olanı
6. **Plan**: **Free** (otomatik seçili)
7. **"Create new project"** tıklayın
8. ~2 dakika proje oluşmasını bekleyin

### 1.3 Connection string'i alın
1. Sol menüden **Project Settings** (⚙️) → **Database** tıklayın
2. **Connection string** bölümünde sekme: **URI** seçin
3. Şuna benzeyen bir URL göreceksiniz:
   ```
   postgresql://postgres.xxxx:[YOUR-PASSWORD]@aws-0-eu-central-1.pooler.supabase.com:6543/postgres
   ```
4. **Şifreyi** değiştirin: `[YOUR-PASSWORD]` yerine 1.2'de not ettiğiniz şifreyi yazın
5. Bu URL'yi kopyalayıp bir yere kaydedin — buna **DATABASE_URL** diyeceğiz

### 1.4 SQL şemasını yükle
1. Sol menüden **SQL Editor** tıklayın
2. **"New query"** tıklayın
3. Bu klasördeki `backend/schema.sql` dosyasının içeriğini yapıştırın
4. **"Run"** tıklayın (veya `Ctrl+Enter`)
5. "Success. No rows returned" mesajını görmelisiniz

✅ **Supabase tarafı tamam.**

---

## 2. Kodu GitHub'a Yükleme (3 dk)

### 2.1 Yeni repo oluştur
1. https://github.com/new adresine gidin
2. **Repository name**: `robink-v2-saas`
3. **Description**: `Robink V2 SaaS backend`
4. **Public** veya **Private** (ikisi de olur; Private daha güvenli)
5. **"Create repository"** tıklayın

### 2.2 Kodu push'la

Bir terminal (PowerShell veya CMD) açın ve şu komutları sırayla çalıştırın:

```powershell
cd "C:\Users\HOBBY\Desktop\yeni program stress\robink-saas"

# Git yoksa
git init
git add .
git commit -m "Robink V2 SaaS - Render deploy hazir"

# GitHub kullanici adinizi kullanarak:
git remote add origin https://github.com/KULLANICI-ADINIZ/robink-v2-saas.git
git branch -M main
git push -u origin main
```

> İlk push'ta GitHub şifre/Personal Access Token isteyecek. Token oluşturmak için:
> GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token
> → `repo` yetkisi verin, süre: 90 gün.

✅ **GitHub tarafı tamam.**

---

## 3. Render.com'a Deploy (5 dk)

### 3.1 Hesap aç
1. https://render.com adresine gidin
2. **"Get Started for Free"** tıklayın
3. **"Sign in with GitHub"** ile giriş yapın
4. GitHub'dan repo erişimi için **"All repositories"** seçin veya sadece `robink-v2-saas`'a izin verin

### 3.2 Blueprint ile deploy
1. Render Dashboard'da **"New +"** → **"Blueprint"** tıklayın
2. **"Connect a repository"** bölümünde `robink-v2-saas` repo'sunu seçin
3. **Branch**: `main`
4. Render `render.yaml` dosyasını otomatik bulur ve bir plan gösterir:
   - Web Service: `robink-v2-saas` (Free)
5. **"Apply"** tıklayın

### 3.3 Ortam değişkenlerini ayarla
Deploy başladıktan sonra:
1. Sol menüden **"Web Services"** → **"robink-v2-saas"** tıklayın
2. **"Environment"** sekmesine gidin
3. **"Add Environment Variable"** ile şunları ekleyin:

| Key | Value |
|-----|-------|
| `DATABASE_URL` | 1.3'te aldığınız Supabase connection string |
| `JWT_SECRET` | (zaten otomatik oluştu — dokunmayın) |
| `NODE_ENV` | `production` |
| `WEB_ORIGIN` | `https://robink-v2-saas.onrender.com` |

4. **"Save Changes"** tıklayın → otomatik yeniden deploy olur

### 3.4 Deploy durumunu izle
1. **"Logs"** sekmesine geçin
2. Şu satırları görmelisiniz:
   ```
   [Robink V2] PostgreSQL modu aktif
   [Robink V2 PG] Schema basariyla yuklendi
   [Robink V2] API + frontend serving on http://localhost:10000  (mode: postgres)
   ```
3. Render otomatik bir URL verir (üstte, sarı/kahverengi banner'da): `https://robink-v2-saas.onrender.com`

> ⏳ İlk deploy 2-5 dakika sürebilir. `npm install` + container başlatma dahil.

✅ **Render tarafı tamam.**

---

## 4. Canlıyı Test Etme (2 dk)

### 4.1 Web sitesini aç
Tarayıcınızda şu adresi açın:
```
https://robink-v2-saas.onrender.com
```
Robink V2 giriş ekranını görmelisiniz.

### 4.2 Hesap oluştur
1. **"Kayıt Ol"** sekmesine geçin
2. Bir kullanıcı adı ve şifre girin
3. **"Kayıt Ol"** tıklayın

### 4.3 Cihaz eşleme kodu al
1. Giriş yaptıktan sonra **"+ Cihaz Ekle"** tıklayın
2. 6 haneli kod görünür (örn. `ABC123`)
3. 10 dakika içinde kullanmanız gerekir

### 4.4 Ajanı yeniden eşle
Windows makinenizde PowerShell açın:

```powershell
cd "C:\Users\HOBBY\Desktop\yeni program stress\robink-saas\agent"
.\RobinkV2-Agent.ps1 -Server "https://robink-v2-saas.onrender.com" -PairingCode "ABC123" -DeviceName "Ev PC"
```

> Mevcut `data.json`'daki eski cihaz bilgisi artık geçersiz. Yeni eşleme yapmanız gerekir.

✅ **Tamamlandı!**

---

## 5. Sorun Giderme

### "Build failed" hatası
- Render Logs'a bakın
- Genellikle `npm install` hatası — internet erişimi veya `package.json` sorunu

### "Application failed to start" hatası
- En sık neden: `DATABASE_URL` yanlış
- Logs'ta `[Robink V2 PG] Pool hatasi: ...` mesajı görürsünüz
- Supabase connection string'in şifresini doğru yazdığınızdan emin olun

### "CORS" hatası (tarayıcı konsolunda)
- Render'da `WEB_ORIGIN` değişkenini doğru ayarlayın
- Veya `server.js`'te CORS middleware'i genişletin (şu an tüm origin'lere izin veriliyor — zaten açık)

### Ajan bağlanamıyor
- Render URL'sini `-Server` parametresinde **tam** girin: `https://...` (http değil)
- Render free tier ilk istek 30-60 sn gecikebilir (cold start)

### Veriler sıfırlandı
- Supabase connection string değiştiyse eski verilere erişilemez
- Kullanıcı adı/şifre yeniden oluşturulması gerekir

---

## 6. Render Ücretsiz Tier Limitleri

| Kaynak | Limit |
|--------|-------|
| Aylık çalışma süresi | 750 saat |
| RAM | 512 MB |
| CPU | 0.1 vCPU |
| Disk | Ephemeral (geçici — DB kullanın!) |
| Cold start | 30-60 sn (15 dk hareketsizlikten sonra) |
| Custom domain | ✅ (ücretsiz) |

> 💡 İpucu: Sürekli canlı tutmak için ücretli plana geç ($7/ay). Test amaçlı free yeterli.

---

## 7. Özel Domain (Opsiyonel)

1. Bir domain satın alın (örn. Namecheap, GoDaddy)
2. Render → Web Service → **"Settings"** → **"Custom Domain"** → **"Add Custom Domain"**
3. Domain sağlayıcınızda CNAME kaydı ekleyin:
   ```
   CNAME  @  robink-v2-saas.onrender.com
   ```
4. ~10 dakika sonra SSL otomatik aktif olur

---

## Özet Akış

```
Lokal geliştirme     →   JSON DB  (DATABASE_URL yok)
       ↓
GitHub'a push         →   Render otomatik algılar
       ↓
Render.com deploy     →   DATABASE_URL=Supabase → PG modu
       ↓
Ajanı yeniden eşle    →   Yeni server URL ile
       ↓
✅ Canlıda
```

Daha fazla yardım için: `server.js` ve `db-pg.js`'in yorumlarını okuyabilirsiniz.
