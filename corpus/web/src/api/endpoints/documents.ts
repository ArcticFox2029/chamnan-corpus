/*
 * document-service 的调用封装：附件抽屉的上传、列表与下载。
 * 这个服务只发短时效链接，从不直接吐字节流，所以界面上的「下载」是两步：
 * 先换一个 15 分钟有效的 URL，再让浏览器去对象存储取。
 */

import { fetchPage, type Page, type PageRequest } from '../pagination';
import type { ApiClient, RequestOptions } from '../http-client';
import type { DocumentKind, DocumentOwnerType, RegionCode } from '../../types/domain';
import type { DocumentId, TenantId } from '../../types/ids';

const SERVICE = 'document-service' as const;

/** `GET /v1/documents/{document_id}`，只有元数据。 */
export interface DocumentMeta {
  readonly document_id: DocumentId;
  readonly tenant_id: TenantId;
  readonly owner_type: DocumentOwnerType;
  readonly owner_id: string;
  readonly kind: DocumentKind;
  readonly mime_type: string;
  readonly byte_size: number;
  /** 十六进制。同一份 PDF 被两个服务分别上传时，两次都会拿到同一个 document_id。 */
  readonly sha256: string;
  readonly region_code: RegionCode;
  readonly uploaded_by: string;
  readonly uploaded_at: string;
  /** 海关类文档是归档日 + `OF_CUSTOMS_RETENTION_YEARS` 年；到期前删不掉。 */
  readonly retained_until: string | null;
}

/** `POST /v1/documents/{document_id}/signed-url` 的响应。 */
export interface SignedUrl {
  readonly url: string;
  /** 有效期由 `OF_DOCUMENT_SIGNED_URL_TTL_SECONDS` 决定，当前是 900 秒。 */
  readonly expires_at: string;
}

/**
 * 上传一份附件。
 *
 * `owner_type` 必须是 `platform.document_owner_types` 里已登记的六种之一，
 * 而且 document-service 在落库前会回调所属服务确认 `owner_id` 真的存在 ——
 * 例如 owner_type 为 `shipment` 时它去问 container-registry。
 * 因此上传一个刚创建、事务还没提交的运单的附件会失败，界面要按顺序来。
 */
export function uploadDocument(
  client: ApiClient,
  file: File,
  meta: { owner_type: DocumentOwnerType; owner_id: string; kind: DocumentKind },
  options?: RequestOptions,
): Promise<DocumentMeta> {
  const form = new FormData();
  form.append('file', file, file.name);
  form.append('owner_type', meta.owner_type);
  form.append('owner_id', meta.owner_id);
  form.append('kind', meta.kind);
  return client.upload<DocumentMeta>(form, options);
}

/** 读元数据。 */
export function getDocument(
  client: ApiClient,
  documentId: DocumentId,
  options?: RequestOptions,
): Promise<DocumentMeta> {
  return client.get<DocumentMeta>(SERVICE, `/v1/documents/${documentId}`, options);
}

/**
 * 换一个下载链接。链接过期就得重新换，所以不要在组件挂载时批量预取一屏的链接 ——
 * 用户点开抽屉再点某一行的时候才调，命中率高得多。
 */
export function createSignedUrl(
  client: ApiClient,
  documentId: DocumentId,
  options?: RequestOptions,
): Promise<SignedUrl> {
  return client.post<SignedUrl>(SERVICE, `/v1/documents/${documentId}/signed-url`, options);
}

/** 按归属对象列附件，附件抽屉打开时调这一个。 */
export function listDocuments(
  client: ApiClient,
  filters: { owner_type: DocumentOwnerType; owner_id: string; kind?: DocumentKind },
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<DocumentMeta>> {
  return fetchPage<DocumentMeta>(
    client,
    SERVICE,
    '/v1/documents',
    { ...request, filters: { ...request?.filters, ...filters } },
    options,
  );
}

/**
 * 软删除。留存期未到时会被拒 —— 这不是权限问题，界面要把 `retained_until`
 * 显示出来并解释「这份单证要留到某年某月」，否则用户会反复点删除然后来提工单。
 */
export function deleteDocument(
  client: ApiClient,
  documentId: DocumentId,
  options?: RequestOptions,
): Promise<void> {
  return client.delete<void>(SERVICE, `/v1/documents/${documentId}`, options);
}

/** 在归档期内的文档不允许删除，按钮据此置灰。 */
export function isDeletable(doc: DocumentMeta, now = new Date()): boolean {
  if (!doc.retained_until) return true;
  return new Date(doc.retained_until).getTime() <= now.getTime();
}
