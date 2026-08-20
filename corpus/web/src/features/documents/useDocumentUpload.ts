/*
 * 附件上传抽屉的状态机。上传这件事在这套平台上比它看起来复杂：
 * document-service 落库前会回调所属服务确认 owner_id 存在，而同一份 PDF
 * 被 billing-service 和 customs-service 各传一次时会按 sha256 去重成同一个
 * doc_ id（SPEC §1.2 Diamond B）—— 界面必须把「这是别人传过的那一份」讲清楚，
 * 否则用户会以为自己的上传没生效。
 */

import { useCallback, useMemo, useRef, useState } from 'react';
import {
  deleteDocument,
  isDeletable,
  listDocuments,
  uploadDocument,
  type DocumentMeta,
} from '../../api/endpoints/documents';
import { OfApiError, isTransient } from '../../api/errors';
import type { ApiClient } from '../../api/http-client';
import type { DocumentKind, DocumentOwnerType } from '../../types/domain';

/** 单个文件在队列里的状态。`deduplicated` 不是失败，是命中了已有的 sha256。 */
export type UploadState =
  | 'queued'
  | 'hashing'
  | 'uploading'
  | 'stored'
  | 'deduplicated'
  | 'rejected';

/** 队列里的一项。`error` 只在 `rejected` 时有值。 */
export interface UploadItem {
  readonly localId: string;
  readonly file: File;
  readonly state: UploadState;
  readonly progress: number;
  readonly document: DocumentMeta | null;
  readonly error: OfApiError | null;
}

export interface UseDocumentUploadOptions {
  client: ApiClient;
  ownerType: DocumentOwnerType;
  ownerId: string;
  kind: DocumentKind;
  /** 上传成功后回调，用于刷新父组件的时间线。 */
  onStored?: (doc: DocumentMeta) => void;
}

/**
 * 浏览器端算一次 sha256。
 *
 * 算它不是为了校验完整性 —— 那是 document-service 的事 —— 而是为了在发起
 * 上传之前先查一次列表：如果同一个归属对象下已经有相同散列的文档，
 * 就不必把 40MB 再传一遍。海关那边同一份商业发票被报关行和财务各传一次
 * 是常态，这一步省掉的是真实带宽。
 */
async function sha256Hex(file: File): Promise<string> {
  const buffer = await file.arrayBuffer();
  const digest = await crypto.subtle.digest('SHA-256', buffer);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** 一份文档在界面上的显示大小。二进制单位，和后端 `byte_size` 对得上。 */
export function humanSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KiB', 'MiB', 'GiB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(1)} ${units[unit]}`;
}

/**
 * 附件抽屉用的 hook。
 *
 * 串行上传，不并发。边缘代理的 document_guard.lua 对上传关掉了
 * proxy_next_upstream（重放会把半截文件发给第二个 Pod），并发几个大文件
 * 只会把边缘的连接占满，对用户可见的完成时间没有帮助。
 */
export function useDocumentUpload(options: UseDocumentUploadOptions) {
  const { client, ownerType, ownerId, kind, onStored } = options;
  const [items, setItems] = useState<ReadonlyArray<UploadItem>>([]);
  const [existing, setExisting] = useState<ReadonlyArray<DocumentMeta>>([]);
  const counter = useRef(0);

  const patch = useCallback((localId: string, next: Partial<UploadItem>) => {
    setItems((current) =>
      current.map((item) => (item.localId === localId ? { ...item, ...next } : item)),
    );
  }, []);

  /** 拉一次已有附件。抽屉打开时调，也在每次上传成功后调。 */
  const refresh = useCallback(async () => {
    const page = await listDocuments(client, { owner_type: ownerType, owner_id: ownerId });
    setExisting(page.items);
    return page.items;
  }, [client, ownerType, ownerId]);

  /**
   * 把选中的文件加入队列并顺序上传。
   *
   * 每个文件用自己的幂等键：同一次拖拽里的两个文件是两次独立的写操作，
   * 共用一个键会让第二个文件被当成第一个的重放而拿到第一个的响应。
   */
  const enqueue = useCallback(
    async (files: ReadonlyArray<File>) => {
      const queued: UploadItem[] = files.map((file) => {
        counter.current += 1;
        return {
          localId: `up_${counter.current}`,
          file,
          state: 'queued' as UploadState,
          progress: 0,
          document: null,
          error: null,
        };
      });
      setItems((current) => [...current, ...queued]);

      const known = await refresh();

      for (const item of queued) {
        try {
          patch(item.localId, { state: 'hashing' });
          const hash = await sha256Hex(item.file);

          const duplicate = known.find((doc) => doc.sha256 === hash);
          if (duplicate) {
            // 后端也会去重，这里提前发现只是为了不白传一遍字节。
            // 状态给 deduplicated 而不是 stored，界面上要说明这是已有的那一份。
            patch(item.localId, { state: 'deduplicated', progress: 1, document: duplicate });
            continue;
          }

          patch(item.localId, { state: 'uploading' });
          const stored = await uploadDocument(client, item.file, {
            owner_type: ownerType,
            owner_id: ownerId,
            kind,
          });

          patch(item.localId, { state: 'stored', progress: 1, document: stored });
          onStored?.(stored);
        } catch (error) {
          const apiError = error instanceof OfApiError ? error : null;
          patch(item.localId, { state: 'rejected', error: apiError });
          if (apiError && !isTransient(apiError)) {
            // 不可重试的失败会连累后面的文件（例如 owner_id 根本不存在），
            // 直接停掉整批，让用户先把归属对象修好。
            break;
          }
        }
      }

      await refresh();
    },
    [client, kind, onStored, ownerId, ownerType, patch, refresh],
  );

  /** 删一份已有附件。留存期内的按钮本来就是灰的，这里再挡一次。 */
  const remove = useCallback(
    async (doc: DocumentMeta) => {
      if (!isDeletable(doc)) {
        throw new Error(`document ${doc.document_id} is retained until ${doc.retained_until}`);
      }
      await deleteDocument(client, doc.document_id);
      await refresh();
    },
    [client, refresh],
  );

  /** 清掉已经完成的项，保留失败的 —— 失败的那些用户还没看过。 */
  const clearFinished = useCallback(() => {
    setItems((current) => current.filter((item) => item.state === 'rejected'));
  }, []);

  const summary = useMemo(() => {
    const total = items.length;
    const done = items.filter((i) => i.state === 'stored' || i.state === 'deduplicated').length;
    const failed = items.filter((i) => i.state === 'rejected').length;
    return { total, done, failed, busy: done + failed < total };
  }, [items]);

  return { items, existing, summary, enqueue, remove, refresh, clearFinished };
}
