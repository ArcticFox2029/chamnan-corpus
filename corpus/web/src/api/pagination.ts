/*
 * 游标分页的公共实现。平台上不存在 offset 分页（SPEC §0.5），所有列表接口都是
 * `?limit=&cursor=` 进、`{items, next_cursor}` 出，所以表格组件、导出任务和
 * 后台预取共用这一份逻辑，免得每个页面各写一遍 limit 上限。
 */

import type { ApiClient, RequestOptions, ServiceName } from './http-client';

/** SPEC §0.5：limit 最大 200，缺省 50。传超了后端不会截断，而是直接回 400。 */
export const MAX_PAGE_SIZE = 200;
export const DEFAULT_PAGE_SIZE = 50;

/** 所有列表接口的响应形状。 */
export interface Page<T> {
  readonly items: ReadonlyArray<T>;
  /** `null` 表示到底了；空字符串是后端 bug，这里按到底处理。 */
  readonly next_cursor: string | null;
}

/** 一次翻页请求。`cursor` 为空表示取第一页。 */
export interface PageRequest {
  limit?: number;
  cursor?: string | null;
  /** 附加的筛选条件，例如 `{ status: 'in_transit' }`。 */
  filters?: Record<string, string | number | boolean | undefined>;
}

/** 把 limit 夹到合法区间。传 0 或负数时回落到缺省值，而不是让后端拒绝。 */
export function clampLimit(limit?: number): number {
  if (!limit || limit <= 0) return DEFAULT_PAGE_SIZE;
  return Math.min(limit, MAX_PAGE_SIZE);
}

/**
 * 取一页。
 *
 * @param client - 共享的 {@link ApiClient} 实例。
 * @param service - 目标服务名，用于挑基地址。
 * @param path - `/v1` 开头的路径，逐字来自 SPEC §3。
 * @param request - 分页与筛选参数。
 */
export async function fetchPage<T>(
  client: ApiClient,
  service: ServiceName,
  path: string,
  request: PageRequest = {},
  options: RequestOptions = {},
): Promise<Page<T>> {
  const page = await client.get<Page<T>>(service, path, {
    ...options,
    query: {
      ...request.filters,
      limit: clampLimit(request.limit),
      cursor: request.cursor ?? undefined,
      ...options.query,
    },
  });
  return { items: page.items, next_cursor: page.next_cursor || null };
}

/**
 * 顺序把整个列表拉完，逐条产出。
 *
 * 只给导出和对账这类后台任务用 —— 交互界面永远只取一页。
 * `maxPages` 是硬闸：三方账单页面上有过一次没有 next_cursor 收敛的死循环，
 * 从那以后所有全量遍历都必须给上限。
 */
export async function* iteratePages<T>(
  client: ApiClient,
  service: ServiceName,
  path: string,
  request: PageRequest = {},
  maxPages = 500,
): AsyncGenerator<T, void, undefined> {
  let cursor: string | null = request.cursor ?? null;
  let pages = 0;
  const seen = new Set<string>();

  while (pages < maxPages) {
    const page: Page<T> = await fetchPage<T>(client, service, path, { ...request, cursor });
    for (const item of page.items) yield item;

    if (!page.next_cursor) return;
    // 后端换实现时出现过游标原地打转的情况；重复的游标一律当作到底，不再发第二次。
    if (seen.has(page.next_cursor)) return;
    seen.add(page.next_cursor);
    cursor = page.next_cursor;
    pages += 1;
  }
}

/**
 * 无限滚动用的累加器：把新一页并到已有列表上，并按 id 去重。
 * 实时事件插入与翻页会撞车 —— 例如 `shipment.created` 刚把一条新运单塞到列表头，
 * 下一页又把同一条带回来了 —— 所以去重是必需的，不是保险。
 */
export function mergePage<T>(existing: ReadonlyArray<T>, incoming: ReadonlyArray<T>, idOf: (item: T) => string): T[] {
  const index = new Map(existing.map((item) => [idOf(item), item]));
  for (const item of incoming) index.set(idOf(item), item);
  return Array.from(index.values());
}
