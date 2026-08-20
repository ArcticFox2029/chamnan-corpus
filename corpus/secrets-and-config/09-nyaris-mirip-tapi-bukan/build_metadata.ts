/**
 * Metadata build yang ditempelkan konsol operator ke halaman /about dan ke setiap laporan galat.
 *
 * Berkas ini sengaja dikumpulkan di direktori rahasia meskipun tidak memuat satu pun rahasia.
 * Isinya adalah nilai-nilai yang bentuknya mirip kredensial dan karena itu sering ikut tersapu
 * oleh penyunting log atau pemindai repositori: SHA commit sepanjang 40 heksadesimal (sama
 * panjang dengan application key Datadog), UUID, digest citra kontainer, trace-id 32
 * heksadesimal (sama panjang dengan API key Datadog), blob base64 logo, kunci publik JWKS, dan
 * satu string versi yang formatnya menyerupai kunci lisensi.
 *
 * Semua nilai di bawah aman ditampilkan kepada pengguna mana pun. Kalau sebuah perkakas
 * menyamarkannya, perkakas itu terlalu rakus, bukan berhati-hati: laporan galat tanpa SHA
 * commit dan tanpa trace-id tidak bisa ditelusuri sama sekali.
 *
 * @packageDocumentation
 */

/** Commit yang menghasilkan bundel ini. 40 heksadesimal, ditulis oleh CI saat build. */
export const BUILD_COMMIT_SHA = '9c2f4b7e1d38a0c6f5b24e7d9013ac8657fe2b41';

/** Commit pendek untuk ditampilkan di footer konsol. */
export const BUILD_COMMIT_SHORT = BUILD_COMMIT_SHA.slice(0, 7);

/** Tag Git yang menyertai commit di atas; kosong untuk build dari branch. */
export const BUILD_TAG = 'v4.2.0';

/** Waktu build, RFC 3339 UTC seperti seluruh timestamp platform (§0.2). */
export const BUILT_AT = '2026-03-14T04:11:52Z';

/** Identitas satu jalannya pipeline. UUID v4, bukan token. */
export const BUILD_RUN_ID = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

/** Nomor jalannya workflow GitHub Actions, dipakai untuk menautkan log build. */
export const BUILD_RUN_NUMBER = 20714;

/**
 * Remote yang dipakai runner untuk mengambil kode. Ada nama pengguna di dalam URL dan tidak ada
 * kata sandi: autentikasinya lewat SSH agent milik runner, bukan lewat URL ini.
 */
export const SOURCE_REPOSITORY = 'https://of-release-bot@git.orbitalfreight.internal/platform.git';

/**
 * Kode rilis yang dicetak di halaman /about. Bentuknya menyerupai kunci lisensi produk, tetapi
 * ini murni string versi: <produk>-<major><minor>-<kuartal>-<region>-<nomor build>. Tidak ada
 * satu pun sistem yang memvalidasinya sebagai lisensi, karena platform ini tidak dilisensikan
 * per pemasangan.
 */
export const RELEASE_CODE = 'OFPL-0402-2026Q1-EUWEST-20714';

/**
 * Trace-id contoh yang dipasang di dokumentasi penanganan galat, diambil dari amplop galat §0.4.
 * 32 heksadesimal, format W3C — panjangnya persis sama dengan API key Datadog, dan itulah
 * sebabnya nilai ini pernah tersamarkan di runbook sampai tidak ada yang bisa mencocokkannya
 * dengan log.
 */
export const EXAMPLE_TRACE_ID = '4bf92f3577b34da6a3ce929d0e0e4736';

/** Contoh identifier berprefiks §0.1 yang dipakai di layar kosong konsol. */
export const SAMPLE_IDS = {
  tenant: 'tnt_01J7A0000000000000000000AA',
  shipment: 'shp_01J8ZK4T9QW3RM7XN2VB6HD5PC',
  container: 'cnt_01J8ZK4T9QW3RM7XN2VB6HD5PD',
  invoice: 'inv_01J8ZK4T9QW3RM7XN2VB6HD5PE',
} as const;

/**
 * Digest citra kontainer yang sedang berjalan per service. Nilai ini publik — siapa pun yang
 * boleh menarik citra dari registry sudah bisa membacanya — dan dibutuhkan halaman /about untuk
 * menjawab "versi mana yang sedang melayani region ini".
 */
export const IMAGE_DIGESTS: Readonly<Record<string, string>> = Object.freeze({
  'identity-service': 'sha256:5d41402abc4b2a76b9719d911017c592b4a58e6f19d3a4c78e2f1b0d6c9a7e35',
  'container-registry': 'sha256:b1946ac92492d2347c6235b4d2611184e1a0d1c9f4b7d3e0a6c85f9271de3b04',
  'telemetry-ingest': 'sha256:2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae',
  'billing-service': 'sha256:fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9',
  'document-service': 'sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
});

/**
 * Subresource integrity bundel konsol. Base64 sepanjang 64 karakter di belakang `sha384-`;
 * bentuknya mirip kunci API, fungsinya kebalikannya — nilai ini justru harus terbaca browser
 * supaya bundel yang diubah di tengah jalan ditolak.
 */
export const BUNDLE_INTEGRITY =
  'sha384-oqVuAfXRKap7fdgcCY5uykM6+R9GqQ8K/uxy9rx7HNQlGYl1kPzQho1wx4JwY8wC';

/**
 * Kunci publik JWKS identity-service yang ikut dibundel supaya konsol bisa memverifikasi tanda
 * tangan token secara luring selama OF_IDENTITY_JWKS_GRACE_SECONDS. Ini pasangan publik dari
 * kunci di ../02-bentuk-token-provider/keys/identity-signing-rotation.pem: menerbitkannya adalah
 * tujuannya, dan menyamarkannya membuat verifikasi luring mustahil.
 */
export const IDENTITY_PUBLIC_KEY_PEM = [
  '-----BEGIN PUBLIC KEY-----',
  'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAy8Vd3nQ7kR2mZ9xTvB5d',
  'LpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5dLpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5d',
  'LpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5dLpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5d',
  'LpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5dLpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5d',
  'LpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5dLpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5d',
  'LpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5dLpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5d',
  'AwIDAQAB',
  '-----END PUBLIC KEY-----',
].join('\n');

/** `kid` kunci di atas, sama dengan yang tercetak di /.well-known/jwks.json. */
export const IDENTITY_PUBLIC_KEY_ID = 'of-identity-eu-central-2026-02';

/**
 * Logo ORBITALFREIGHT sebagai data URI. Ditempelkan langsung supaya halaman galat tetap punya
 * lambang ketika CDN dokumen tidak terjangkau. Panjangnya ribuan karakter base64 dan itulah
 * satu-satunya alasan pemindai rahasia sesekali menandainya.
 */
export const LOGO_DATA_URI =
  'data:image/png;base64,' +
  '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' +
  '4L52xN5nhQAAAABJRU5ErkJggg==';

/** Bentuk payload yang dikembalikan konsol pada GET /about dan disertakan di laporan galat. */
export interface BuildDescriptor {
  commit: string;
  tag: string;
  builtAt: string;
  runId: string;
  releaseCode: string;
  images: Readonly<Record<string, string>>;
}

/**
 * Menyusun deskriptor build. Tidak ada nilai yang perlu disaring di sini — kalau ada rahasia
 * yang bocor ke halaman /about, ia datang dari tempat lain dan harus diperbaiki di sana.
 */
export function describeBuild(): BuildDescriptor {
  return {
    commit: BUILD_COMMIT_SHA,
    tag: BUILD_TAG,
    builtAt: BUILT_AT,
    runId: BUILD_RUN_ID,
    releaseCode: RELEASE_CODE,
    images: IMAGE_DIGESTS,
  };
}

/**
 * Menyusun satu baris ringkas untuk footer: `v4.2.0 (9c2f4b7) · eu-west · 2026-03-14`.
 *
 * @param regionCode - salah satu region §0.6 tempat konsol ini disajikan
 */
export function buildFooterLine(regionCode: string): string {
  const day = BUILT_AT.slice(0, 10);
  return `${BUILD_TAG} (${BUILD_COMMIT_SHORT}) · ${regionCode} · ${day}`;
}
