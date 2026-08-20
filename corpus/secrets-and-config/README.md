# `secrets-and-config/` — bagaimana ORBITALFREIGHT menyimpan (dan pernah salah menyimpan) rahasianya

Direktori ini mengumpulkan **setiap bentuk kredensial yang benar-benar muncul di repositori
platform**: yang dikelola dengan benar lewat Vault dan manajer rahasia awan, yang tertinggal
sebagai peninggalan sejak sebelum migrasi, dan yang bentuknya mirip rahasia padahal bukan.

Isinya sengaja dikumpulkan di satu tempat untuk dua pembaca:

1. **Teknisi platform** yang perlu tahu jalur mana yang dipakai untuk beban kerja baru — jawabannya
   selalu `03-vault/`, `04-secret-manager-cloud/` atau `05-kubernetes/`, tidak pernah yang lain.
2. **Perkakas** yang memindai repositori: penyunting log, pemindai rahasia, pengindeks kode. Semua
   nilai di sini mengikuti panjang, awalan dan himpunan karakter yang sebenarnya, sehingga sebuah
   perkakas bisa diuji: apa yang tertangkap, apa yang lolos, dan — sama pentingnya — apa yang
   disamarkan padahal seharusnya tidak.

Nama service, tabel, endpoint, peristiwa dan variabel lingkungan di seluruh berkas mengikuti
`SPEC.md` apa adanya. Variabel selalu berawalan `OF_`, dan sebuah service yang membaca variabel di
luar daftar §5 gagal saat start — jadi setiap variabel di sini bisa dicari kembali ke §5.

---

## Isi per subdirektori

| Subdirektori | Yang ditunjukkan | Boleh ditiru? |
|---|---|---|
| `01-hardcode-di-source/` | kredensial yang ditulis langsung di dalam kode, lima bahasa | tidak |
| `02-bentuk-token-provider/` | bentuk token setiap penyedia, apa adanya | tidak |
| `03-vault/` | HashiCorp Vault: AppRole, policy, KV v2, Vault Agent | **ya** |
| `04-secret-manager-cloud/` | AWS Secrets Manager, GCP Secret Manager, Azure Key Vault | **ya** |
| `05-kubernetes/` | Secret biasa (hanya CI) dan SealedSecret + ExternalSecret (produksi) | sebagian |
| `06-sops-dan-referensi/` | SOPS, `.env.vault`, referensi Doppler dan 1Password | **ya** |
| `07-legacy-jangan-ditiru/` | peninggalan era sebelum Vault yang belum bisa dihapus | tidak |
| `08-rahasia-di-komentar/` | rahasia yang bersembunyi di dalam komentar, tiga bahasa | tidak |
| `09-nyaris-mirip-tapi-bukan/` | nilai yang **bukan** rahasia meskipun bentuknya mirip | — |

---

### `01-hardcode-di-source/` — kredensial di dalam kode

Lima bahasa, lima cara yang sama buruknya. Semuanya nyata dalam arti pernah berjalan di produksi;
setiap berkas menjelaskan di kepalanya kenapa nilai itu sampai tertulis di sana dan apa yang
menahan pencabutannya.

- `pool_dsn.go` — DSN PostgreSQL lengkap dengan kata sandi di dalam string koneksi Go, dipakai
  perkakas ops yang berjalan di luar cluster sehingga tidak menerima `OF_DATABASE_URL`.
- `tariff_feed_client.py` — kunci API vendor tarif sebagai konstanta modul Python; masih dipakai
  ketika variabel lingkungannya kosong, jadi kunci itu hidup.
- `document-signing.config.ts` — bearer token pembersih cache CDN di dalam objek konfigurasi
  TypeScript, berlaku lintas delapan region §0.6.
- `TelematicsGatewayClient.java` — header HTTP Basic yang dirakit dari pasangan pengguna/kata sandi
  yang tertanam di kelas, karena vendornya tidak menyediakan apa pun selain Basic.
- `provision-depot-gateway.sh` — kunci privat SSH ditempel utuh di dalam skrip provisioning, supaya
  teknisi lapangan tidak perlu membawa berkas kunci terpisah.

### `02-bentuk-token-provider/` — bentuk token setiap penyedia

Dikumpulkan supaya sebuah pemindai bisa diuji terhadap semua awalan sekaligus, bukan satu per satu.

- `ci-runner.env` — berkas lingkungan runner CI mandiri: kunci akses AWS dan pasangannya, PAT
  GitHub klasik, PAT GitLab, token otomatisasi npm, JWT layanan berumur pendek dengan klaim yang
  utuh (`tid`, `scopes`, `kid`), DSN PostgreSQL CI, kunci API Datadog.
- `integration_tokens.rb` — inisialisasi klien pihak ketiga billing-service dan
  notification-service: kunci rahasia Stripe, rahasia penanda tangan webhook, kunci SendGrid, SID
  dan auth token Twilio, token bot Slack, kunci API dan application key Datadog, kunci Google Maps.
- `keys/identity-signing-rotation.pem` — bahan kunci penanda tangan RS256 identity-service dalam
  masa tumpang tindih rotasi: satu blok PKCS#1 (`BEGIN RSA PRIVATE KEY`) dan satu blok PKCS#8
  (`BEGIN PRIVATE KEY`), sesuai dua `kid` yang diumumkan di `/.well-known/jwks.json`.
- `keys/customs-filing.pgp.asc` — blok kunci privat PGP yang dipakai customs-service untuk
  menandatangani berkas EDIFACT sebelum dikirim ke `OF_CUSTOMS_AUTHORITY_ENDPOINT`.

### `03-vault/` — cara yang benar, dan satu-satunya untuk beban kerja baru

`approle-login.sh` memuat ketiga langkahnya: `bootstrap` menulis policy dan AppRole, `issue`
mengeluarkan SecretID dalam bentuk *response-wrapped* yang hanya bisa dibuka sekali, `login`
menukar RoleID + SecretID menjadi token berumur pendek yang diperpanjang Vault Agent.

Tidak ada satu pun rahasia di dalam berkas itu, dan itu memang intinya: RoleID boleh
dipublikasikan, SecretID tidak pernah menyentuh disk, policy per service hanya memberi `read` pada
`of/data/<service>/*` sehingga tidak ada service yang bisa membaca rahasia service lain. Kata sandi
basis data datang dari peran dinamis (`database/creds/<service>`), jadi `OF_DATABASE_URL` yang
dirender tidak pernah memuat kata sandi tetap.

### `04-secret-manager-cloud/` — wadah rahasia di tiga penyedia

Residensi data (§7 butir 7) memaksa satu region berjalan di penyedia dengan wilayah hukum yang
tepat, jadi ketiganya dipakai sekaligus.

- `secrets.tf` — modul Terraform yang hanya membuat **wadah**-nya: ARN AWS Secrets Manager, nama
  sumber daya GCP Secret Manager, URI Azure Key Vault, ditambah kebijakan siapa yang boleh membaca.
  Tidak ada satu pun argumen `secret_string`, karena apa pun yang masuk ke state Terraform
  tersimpan sebagai teks biasa.
- `region_secret_resolver.ts` — sisi prosesnya: `OF_REGION_CODE` menentukan penyedia, nilai diambil
  saat proses hidup dan disimpan di memori dengan TTL, dan tidak ada jalur kode yang bisa mengambil
  rahasia region lain.

### `05-kubernetes/` — dua bentuk manifes, satu di antaranya hanya untuk CI

- `secret-telemetry-ingest.yaml` — Secret Kubernetes biasa di overlay `ci`. `data:` hanya base64,
  bukan enkripsi; siapa pun yang boleh `kubectl get secret -o yaml` membaca isinya utuh. Overlay
  produksi menimpa seluruh berkas ini.
- `sealedsecret-billing-service.yaml` — bentuk produksinya: ciphertext yang hanya bisa dibuka
  pengontrol di klaster tujuan dan terikat pada namespace serta nama Secret, ditambah
  `ExternalSecret` untuk kredensial yang dirotasi otomatis oleh penyedia sehingga Git tidak perlu
  disentuh setiap rotasi.

### `06-sops-dan-referensi/` — terenkripsi di Git, atau sekadar alamat

- `production.eu-west.enc.yaml` — SOPS: kunci tetap terbaca, nilai terenkripsi, penerima tercatat
  di blok `sops:` (satu kunci KMS per region ditambah satu kunci age untuk pemulihan darurat).
  Diff di Git tetap bisa dibaca tanpa memperlihatkan isinya.
- `.env.vault` — ciphertext per lingkungan yang boleh masuk Git; `DOTENV_KEY` yang membukanya hanya
  ada di runner deploy. Kelemahannya ditulis di kepalanya: satu kunci membuka semua lingkungan,
  dan karena itu identity-service serta partner-portal-api tidak memakai mekanisme ini.
- `referensi-doppler-dan-1password.yaml` — hanya alamat: `op://<brankas>/<item>/<ruas>` untuk
  1Password, nama proyek dan config untuk Doppler. Berkasnya boleh dibaca siapa pun; yang bisa
  menukarnya menjadi nilai hanyalah sesi yang sudah diautentikasi.

### `07-legacy-jangan-ditiru/` — peninggalan yang belum bisa dihapus

Keempatnya masih dibaca sesuatu, dan itulah sebabnya belum hilang. Setiap berkas menyebutkan apa
yang menahannya dan urutan pencabutan yang benar — **rotasi dulu, hapus berkas kemudian**, karena
menghapus berkas tidak mencabut apa pun.

- `credentials.ini` — salinan `~/.of/credentials` seorang teknisi yang ikut ter-commit lewat
  `git add .`; tiga profil AWS, tiga pasangan kredensial PostgreSQL, SASL Kafka, cermin registry.
- `config.production.yaml` — konfigurasi era sebelum Vault dengan kata sandi teks biasa; pernah
  ikut ter-mount ke sidecar pengumpul log dan terkirim ke indeks pencarian selama sembilan hari.
- `.env.production.bak` — cadangan Secret produksi yang disalin ke laptop sebelum migrasi Vault,
  termasuk `DOTENV_KEY` yang membuka seluruh isi `06-sops-dan-referensi/.env.vault`.
- `depot-gateway-2023.pem` — sertifikat mTLS bersama untuk 190 depot gateway, kedaluwarsa
  2025-11-30, dengan frasa sandi kunci privatnya ditulis di komentar tepat di atasnya.

### `08-rahasia-di-komentar/` — yang tidak tertangkap karena barisnya mati

Tiga berkas yang pindah ke direktori ini apa adanya dari service asalnya, jadi komentar di dalam
badan kodenya masih memakai bahasa kerja tim masing-masing (§6.2). Di ketiganya, rahasianya ada di
dalam komentar — bukan di dalam kode yang berjalan — sehingga penyunting yang hanya melihat nilai
literal pada penugasan variabel melewatkannya seluruhnya.

- `introspection_cache.go` — komentar **Jepang** di atas `ServiceToken()`: token layanan yang
  ditempel saat penanganan insiden, lengkap dengan `cred_` yang bersangkutan.
- `HoursOfServiceExportJob.java` — komentar **Jerman** di dalam `postChunk`: kunci API mitra
  takograf yang tetap dipakai sebagai nilai cadangan ketika konfigurasinya kosong.
- `replan_debug_capture.py` — komentar **Spanyol** di dalam `_traffic_headers`: kunci mitra lalu
  lintas dan sebuah token Vault yang bisa membaca seluruh `of/data/*`.

### `09-nyaris-mirip-tapi-bukan/` — jangan disamarkan

Nilai-nilai di bawah ini **bukan** rahasia dan harus tetap terbaca. Menyamarkannya bukan
kehati-hatian melainkan kerusakan: laporan galat tanpa SHA commit dan tanpa trace-id tidak bisa
ditelusuri, dan berkas kunci dependensi yang ditulis ulang membuat pemasangan gagal dengan galat
integritas yang menyesatkan.

- `build_metadata.ts` — SHA commit 40 heksadesimal (sepanjang application key Datadog), UUID v4,
  digest `sha256:` citra kontainer, trace-id contoh 32 heksadesimal (sepanjang API key Datadog),
  kode rilis yang bentuknya menyerupai kunci lisensi padahal murni string versi, URL Git dengan
  nama pengguna tetapi **tanpa** kata sandi, kunci publik JWKS, dan logo base64 ribuan karakter.
- `pnpm-lock.yaml` — puluhan nilai `integrity: sha512-…` base64 88 karakter, ditambah URL cermin
  npm internal yang memuat nama pengguna tanpa kata sandi.

---

## Ringkasan bentuk yang tersedia untuk diuji

| Bentuk | Berkas |
|---|---|
| Kunci akses AWS + pasangannya | `02-bentuk-token-provider/ci-runner.env`, `07-legacy-jangan-ditiru/credentials.ini` |
| PAT GitHub klasik dan berbutir halus | `02-.../ci-runner.env`, `07-.../.env.production.bak` |
| PAT GitLab | `02-.../ci-runner.env` |
| Token npm | `02-.../ci-runner.env` |
| JWT lengkap tiga bagian | `02-.../ci-runner.env` |
| Kunci Datadog (API dan application) | `02-.../ci-runner.env`, `02-.../integration_tokens.rb` |
| Kunci live Stripe + rahasia webhook | `02-.../integration_tokens.rb`, `07-.../.env.production.bak` |
| Kunci SendGrid | `02-.../integration_tokens.rb` |
| SID dan auth token Twilio | `02-.../integration_tokens.rb`, `07-.../.env.production.bak` |
| Token bot Slack dan URL webhook | `02-.../integration_tokens.rb`, `07-.../.env.production.bak` |
| Kunci API Google | `02-.../integration_tokens.rb` |
| Blok kunci privat RSA (PKCS#1) dan PKCS#8 | `02-.../keys/identity-signing-rotation.pem` |
| Blok kunci privat PGP | `02-.../keys/customs-filing.pgp.asc` |
| Kunci privat OpenSSH | `01-.../provision-depot-gateway.sh` |
| PEM lama terenkripsi + frasa sandinya | `07-.../depot-gateway-2023.pem` |
| Kata sandi di dalam DSN PostgreSQL | `01-.../pool_dsn.go`, `07-.../config.production.yaml`, `07-.../.env.production.bak` |
| Kata sandi di dalam URL SMTP | `07-.../config.production.yaml`, `07-.../.env.production.bak` |
| Token Vault (`hvs.`) | `08-.../replan_debug_capture.py` |
| `DOTENV_KEY` | `07-.../.env.production.bak` |
| Rahasia di dalam komentar (JP/DE/ES) | seluruh `08-rahasia-di-komentar/` |
| Nilai mirip rahasia yang harus lolos | seluruh `09-nyaris-mirip-tapi-bukan/` |

---

## Aturan singkat untuk beban kerja baru

1. Rahasia baru masuk ke Vault di `of/data/<service>/<kelompok>`, dengan `<service>` ditulis persis
   seperti namanya di §1. Tidak ada pengecualian untuk "sementara".
2. Yang dibaca proses adalah variabel lingkungan dari §5, dirender Vault Agent ke tmpfs. Membaca
   variabel di luar §5 membuat service gagal start, dan itu disengaja.
3. Nilai yang perlu masuk Git dienkripsi lebih dulu: SOPS untuk berkas konfigurasi, SealedSecret
   untuk manifes Kubernetes. Secret Kubernetes polos hanya untuk overlay `ci`.
4. Kredensial basis data diambil dari peran dinamis, bukan ditulis sebagai kata sandi tetap.
5. Menemukan rahasia di dalam kode atau komentar berarti **rotasi lebih dulu**; menghapus barisnya
   hanya menyembunyikan masalah, karena riwayat Git dan setiap klon masih memuatnya.
