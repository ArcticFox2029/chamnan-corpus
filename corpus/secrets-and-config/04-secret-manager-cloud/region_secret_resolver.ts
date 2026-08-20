/**
 * Penyelesai rahasia lintas penyedia untuk proses Node yang berjalan di delapan region §0.6.
 *
 * Satu proses hanya pernah membaca rahasia region-nya sendiri: `OF_REGION_CODE` menentukan
 * penyedia, dan tidak ada jalur kode yang bisa mengambil rahasia region lain, karena menyalin
 * rahasia latam-br ke Eropa sama melanggarnya dengan menyalin datanya.
 *
 * Yang tersimpan di berkas ini hanya penunjuk — ARN, nama sumber daya, dan URI — persis seperti
 * yang dikeluarkan modul Terraform di sebelah. Nilai rahasianya diambil saat proses hidup,
 * disimpan di memori dengan TTL, dan tidak pernah ditulis ke disk atau ke log.
 *
 * @packageDocumentation
 */

import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { SecretManagerServiceClient } from '@google-cloud/secret-manager';
import { SecretClient } from '@azure/keyvault-secrets';
import { DefaultAzureCredential } from '@azure/identity';

/** Region yang dikenal platform. */
export type RegionCode =
  | 'eu-west'
  | 'eu-central'
  | 'na-east'
  | 'na-west'
  | 'apac-sg'
  | 'apac-jp'
  | 'latam-br'
  | 'mea-ae';

/** Penyedia tempat rahasia sebuah region disimpan. */
export type SecretBackend = 'aws' | 'gcp' | 'azure';

/** Kelompok rahasia; sama dengan sufiks path Vault dan nama Secrets Manager. */
export type SecretGroup =
  | 'postgres'
  | 'kafka'
  | 'object-store'
  | 'cdn'
  | 'providers'
  | 'push-keys'
  | 'authority'
  | 'signing-keys';

/** Pemetaan region ke penyedia dan wilayah teknisnya. */
interface BackendBinding {
  readonly backend: SecretBackend;
  /** Wilayah penyedia: AWS region, lokasi GCP, atau lokasi Azure. */
  readonly providerLocation: string;
  /** Awalan nama rahasia; pola persisnya berbeda per penyedia. */
  readonly namePrefix: string;
}

const BACKENDS: Readonly<Record<RegionCode, BackendBinding>> = {
  'eu-west': { backend: 'aws', providerLocation: 'eu-west-1', namePrefix: 'of' },
  'eu-central': { backend: 'aws', providerLocation: 'eu-central-1', namePrefix: 'of' },
  'na-east': { backend: 'aws', providerLocation: 'us-east-1', namePrefix: 'of' },
  'na-west': { backend: 'aws', providerLocation: 'us-west-2', namePrefix: 'of' },
  'apac-sg': { backend: 'aws', providerLocation: 'ap-southeast-1', namePrefix: 'of' },
  'latam-br': { backend: 'aws', providerLocation: 'sa-east-1', namePrefix: 'of' },
  'apac-jp': { backend: 'gcp', providerLocation: 'asia-northeast1', namePrefix: 'of' },
  'mea-ae': { backend: 'azure', providerLocation: 'uaenorth', namePrefix: 'of' },
};

const AWS_ACCOUNT_ID = '481920377154';
const GCP_PROJECT_ID = 'orbitalfreight-apac';
const AZURE_VAULT_URL = 'https://of-mea-ae.vault.azure.net';

/**
 * Umur cache rahasia di memori. Lebih pendek daripada `OF_IDENTITY_JWKS_GRACE_SECONDS` supaya
 * rotasi kredensial basis data terlihat oleh proses dalam satu siklus, tanpa membuat setiap
 * permintaan menembak API penyedia.
 */
const CACHE_TTL_MS = 240_000;

interface CacheEntry {
  readonly value: string;
  readonly expiresAt: number;
}

/**
 * Membentuk ARN AWS Secrets Manager untuk sebuah service dan kelompok.
 *
 * @param regionCode - Region proses yang memanggil.
 * @param serviceName - Nama service persis seperti pada §1, misalnya `document-service`.
 * @param group - Kelompok rahasia.
 */
export function awsSecretArn(
  regionCode: RegionCode,
  serviceName: string,
  group: SecretGroup,
): string {
  const binding = BACKENDS[regionCode];
  return `arn:aws:secretsmanager:${binding.providerLocation}:${AWS_ACCOUNT_ID}:secret:of/${serviceName}/${group}`;
}

/**
 * Membentuk nama sumber daya Google Secret Manager beserta versinya.
 *
 * @param serviceName - Nama service persis seperti pada §1.
 * @param group - Kelompok rahasia.
 * @param version - Versi yang diminta; `latest` untuk versi teraktif.
 */
export function gcpSecretName(
  serviceName: string,
  group: SecretGroup,
  version: string = 'latest',
): string {
  return `projects/${GCP_PROJECT_ID}/secrets/of-${serviceName}-${group}/versions/${version}`;
}

/**
 * Membentuk URI rahasia Azure Key Vault.
 *
 * @param serviceName - Nama service persis seperti pada §1.
 * @param group - Kelompok rahasia.
 */
export function azureSecretUri(serviceName: string, group: SecretGroup): string {
  return `${AZURE_VAULT_URL}/secrets/of-${serviceName}-${group}`;
}

/**
 * Pembaca rahasia satu region. Instansnya dibuat sekali per proses; klien penyedia mahal untuk
 * dibangun ulang dan menyimpan kredensial identitas beban kerja di dalamnya.
 */
export class RegionSecretResolver {
  private readonly cache = new Map<string, CacheEntry>();
  private readonly binding: BackendBinding;
  private awsClient?: SecretsManagerClient;
  private gcpClient?: SecretManagerServiceClient;
  private azureClient?: SecretClient;

  /**
   * @param regionCode - Nilai `OF_REGION_CODE` proses ini.
   * @param serviceName - Nilai `OF_SERVICE_NAME` proses ini.
   */
  constructor(
    private readonly regionCode: RegionCode,
    private readonly serviceName: string,
  ) {
    const binding = BACKENDS[regionCode];
    if (!binding) {
      throw new Error(`OF_REGION_CODE tidak dikenal: ${regionCode}`);
    }
    this.binding = binding;
  }

  /**
   * Mengambil satu rahasia milik service ini.
   *
   * @param group - Kelompok rahasia yang diminta.
   * @returns Isi rahasia sebagai string; pemanggil yang mengurai JSON-nya.
   * @throws Error kalau penyedia menolak, yang hampir selalu berarti identitas beban kerja
   *   belum diberi peran baca pada rahasia tersebut.
   */
  async get(group: SecretGroup): Promise<string> {
    const cacheKey = `${this.serviceName}/${group}`;
    const cached = this.cache.get(cacheKey);
    if (cached && cached.expiresAt > Date.now()) {
      return cached.value;
    }

    const value = await this.fetch(group);
    this.cache.set(cacheKey, { value, expiresAt: Date.now() + CACHE_TTL_MS });
    return value;
  }

  /**
   * Menghapus satu entri cache, dipanggil ketika koneksi basis data ditolak dan kecurigaannya
   * adalah kredensial sudah dirotasi di tengah umur cache.
   *
   * @param group - Kelompok rahasia yang ingin dibaca ulang.
   */
  invalidate(group: SecretGroup): void {
    this.cache.delete(`${this.serviceName}/${group}`);
  }

  private async fetch(group: SecretGroup): Promise<string> {
    switch (this.binding.backend) {
      case 'aws':
        return this.fetchFromAws(group);
      case 'gcp':
        return this.fetchFromGcp(group);
      case 'azure':
        return this.fetchFromAzure(group);
    }
  }

  private async fetchFromAws(group: SecretGroup): Promise<string> {
    this.awsClient ??= new SecretsManagerClient({ region: this.binding.providerLocation });
    const response = await this.awsClient.send(
      new GetSecretValueCommand({
        SecretId: awsSecretArn(this.regionCode, this.serviceName, group),
      }),
    );
    if (!response.SecretString) {
      throw new Error(`rahasia ${this.serviceName}/${group} kosong di Secrets Manager`);
    }
    return response.SecretString;
  }

  private async fetchFromGcp(group: SecretGroup): Promise<string> {
    this.gcpClient ??= new SecretManagerServiceClient();
    const [version] = await this.gcpClient.accessSecretVersion({
      name: gcpSecretName(this.serviceName, group),
    });
    const payload = version.payload?.data;
    if (!payload) {
      throw new Error(`rahasia ${this.serviceName}/${group} kosong di Secret Manager`);
    }
    return Buffer.from(payload).toString('utf8');
  }

  private async fetchFromAzure(group: SecretGroup): Promise<string> {
    this.azureClient ??= new SecretClient(AZURE_VAULT_URL, new DefaultAzureCredential());
    const secret = await this.azureClient.getSecret(`of-${this.serviceName}-${group}`);
    if (!secret.value) {
      throw new Error(`rahasia ${this.serviceName}/${group} kosong di Key Vault`);
    }
    return secret.value;
  }
}

/**
 * Membangun penyelesai dari variabel lingkungan proses.
 *
 * @throws Error kalau `OF_REGION_CODE` atau `OF_SERVICE_NAME` tidak diset, karena tanpa keduanya
 *   proses tidak tahu rahasia siapa yang boleh ia baca.
 */
export function resolverFromEnv(): RegionSecretResolver {
  const regionCode = process.env.OF_REGION_CODE as RegionCode | undefined;
  const serviceName = process.env.OF_SERVICE_NAME;
  if (!regionCode || !serviceName) {
    throw new Error('OF_REGION_CODE dan OF_SERVICE_NAME wajib diset sebelum membaca rahasia');
  }
  return new RegionSecretResolver(regionCode, serviceName);
}
