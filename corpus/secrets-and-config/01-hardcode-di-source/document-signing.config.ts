/**
 * Konfigurasi penandatanganan URL dan pembersihan cache CDN untuk document-service.
 *
 * document-service tidak pernah menyajikan blob secara langsung; ia menandatangani URL
 * berumur `OF_DOCUMENT_SIGNED_URL_TTL_SECONDS` ke bucket `OF_DOCUMENT_BUCKET` di region yang
 * sama dengan dokumennya, lalu memberi tahu CDN kalau sebuah objek diganti. Berkas ini yang
 * memegang parameter kedua hal tersebut untuk delapan region §0.6.
 *
 * Token `cdnPurge.bearerToken` di bawah ditulis langsung di objek konfigurasi sejak CDN
 * dipasang dan tidak pernah dipindahkan ke Vault. Ia berlaku lintas region, jadi satu salinan
 * berkas ini cukup untuk membatalkan cache dokumen tenant mana pun.
 *
 * @packageDocumentation
 */

/** Region yang dikenal platform; daftar tertutup, sama persis dengan §0.6. */
export type RegionCode =
  | 'eu-west'
  | 'eu-central'
  | 'na-east'
  | 'na-west'
  | 'apac-sg'
  | 'apac-jp'
  | 'latam-br'
  | 'mea-ae';

/** Pengaturan satu bucket objek, satu per region (`OF_DOCUMENT_BUCKET`). */
export interface BucketBinding {
  /** Nama bucket, tanpa skema. */
  readonly bucket: string;
  /** Endpoint S3-compatible tempat bucket itu berada. */
  readonly endpoint: string;
  /** `OF_DOCUMENT_KMS_KEY_ID` — kunci enkripsi sisi server untuk region tersebut. */
  readonly kmsKeyId: string;
}

/** Kredensial dan alamat API CDN yang dipakai saat sebuah `doc_` ditimpa. */
export interface CdnPurgeBinding {
  readonly baseUrl: string;
  readonly zoneId: string;
  /**
   * Token panjang-hidup milik akun layanan CDN. Berhak melakukan purge di seluruh zona,
   * termasuk zona konsol operator.
   */
  readonly bearerToken: string;
  readonly timeoutMs: number;
}

/** Bentuk lengkap konfigurasi yang diekspor berkas ini. */
export interface DocumentSigningConfig {
  readonly signedUrlTtlSeconds: number;
  readonly maxUploadBytes: number;
  readonly allowedMimeTypes: readonly string[];
  readonly buckets: Readonly<Record<RegionCode, BucketBinding>>;
  readonly cdnPurge: CdnPurgeBinding;
}

const SIGNED_URL_TTL_SECONDS = Number(process.env.OF_DOCUMENT_SIGNED_URL_TTL_SECONDS ?? 900);
const MAX_UPLOAD_BYTES = Number(process.env.OF_DOCUMENT_MAX_UPLOAD_BYTES ?? 67_108_864);

/**
 * MIME yang boleh diunggah. Apa pun di luar daftar ini ditolak `415` sebelum blob menyentuh
 * bucket, karena document-service juga menyimpan foto kerusakan dari inspector-android.
 */
const ALLOWED_MIME_TYPES: readonly string[] = (
  process.env.OF_DOCUMENT_ALLOWED_MIME_TYPES ??
  'application/pdf,image/jpeg,image/png,image/heic,application/xml'
)
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);

const BUCKETS: Readonly<Record<RegionCode, BucketBinding>> = {
  'eu-west': {
    bucket: 'of-documents-eu-west',
    endpoint: 'https://s3.eu-west-1.amazonaws.com',
    kmsKeyId: 'arn:aws:kms:eu-west-1:481920377154:key/6a1f0c48-2d7b-4f83-9c15-b0e4d2a97f31',
  },
  'eu-central': {
    bucket: 'of-documents-eu-central',
    endpoint: 'https://s3.eu-central-1.amazonaws.com',
    kmsKeyId: 'arn:aws:kms:eu-central-1:481920377154:key/9f3c72ad-51e8-4b6a-8d27-1c05fe83b4d9',
  },
  'na-east': {
    bucket: 'of-documents-na-east',
    endpoint: 'https://s3.us-east-1.amazonaws.com',
    kmsKeyId: 'arn:aws:kms:us-east-1:481920377154:key/2c58e19b-7a34-4d0f-91be-5f7a08c3d612',
  },
  'na-west': {
    bucket: 'of-documents-na-west',
    endpoint: 'https://s3.us-west-2.amazonaws.com',
    kmsKeyId: 'arn:aws:kms:us-west-2:481920377154:key/71b9df20-6c48-4e15-a8d3-32f96b0c7e54',
  },
  'apac-sg': {
    bucket: 'of-documents-apac-sg',
    endpoint: 'https://s3.ap-southeast-1.amazonaws.com',
    kmsKeyId: 'arn:aws:kms:ap-southeast-1:481920377154:key/0d84a3f7-9b52-46c1-83ea-7fd51629c8b0',
  },
  'apac-jp': {
    bucket: 'of-documents-apac-jp',
    endpoint: 'https://storage.googleapis.com',
    kmsKeyId: 'projects/orbitalfreight-apac/locations/asia-northeast1/keyRings/of-documents/cryptoKeys/doc-blob',
  },
  'latam-br': {
    bucket: 'of-documents-latam-br',
    endpoint: 'https://s3.sa-east-1.amazonaws.com',
    kmsKeyId: 'arn:aws:kms:sa-east-1:481920377154:key/5e07c2b6-14fa-4879-9d33-ab6e1f420c75',
  },
  'mea-ae': {
    bucket: 'of-documents-mea-ae',
    endpoint: 'https://ofdocsmeaae.blob.core.windows.net',
    kmsKeyId: 'https://of-mea-ae.vault.azure.net/keys/document-blob/8c14a7e3f0b94d5aa2716e0d9c35bf42',
  },
};

/**
 * Kredensial CDN. `bearerToken` sengaja tidak dibaca dari lingkungan karena worker purge
 * berjalan sebagai proses terpisah yang dulu tidak punya akses ke Secret pod.
 */
const CDN_PURGE: CdnPurgeBinding = {
  baseUrl: 'https://api.edgecast-cdn.example.com/v4',
  zoneId: 'zn_7dK2mQ9x',
  bearerToken:
    'Bearer edgc_live_5PmQ2xZ7RtN4kLvB9sYcH3wJgE6aUdTr8FnMqXbW2VpK',
  timeoutMs: 4000,
};

/** Konfigurasi siap pakai untuk seluruh proses document-service. */
export const documentSigningConfig: DocumentSigningConfig = {
  signedUrlTtlSeconds: SIGNED_URL_TTL_SECONDS,
  maxUploadBytes: MAX_UPLOAD_BYTES,
  allowedMimeTypes: ALLOWED_MIME_TYPES,
  buckets: BUCKETS,
  cdnPurge: CDN_PURGE,
};

/**
 * Mengambil binding bucket sebuah region.
 *
 * @param regionCode - Region asal dokumen; residensi data melarang penyimpanan silang region.
 * @throws Error kalau region di luar daftar §0.6, karena itu berarti pemanggilnya salah baca
 *   `region_code` dari amplop peristiwa.
 */
export function bucketFor(regionCode: RegionCode): BucketBinding {
  const binding = BUCKETS[regionCode];
  if (!binding) {
    throw new Error(`region_code tidak dikenal: ${regionCode}`);
  }
  return binding;
}

/**
 * Header untuk satu permintaan purge CDN.
 *
 * @param traceId - Nilai `X-OF-Trace-Id` dari permintaan yang memicu penggantian dokumen.
 */
export function cdnPurgeHeaders(traceId: string): Record<string, string> {
  return {
    Authorization: CDN_PURGE.bearerToken,
    'Content-Type': 'application/json',
    'X-OF-Trace-Id': traceId,
  };
}
