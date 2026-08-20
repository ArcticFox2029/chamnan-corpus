/*
 * customs-service 的调用封装：报关单的起草、报送、补充申报，以及税则查询。
 * 这里有一条界面上必须讲清楚的因果 —— `duty_paid` 不是这个服务能改的，
 * 它只会被 billing.invoice.settled 事件翻转，所以报关页上任何「标记已缴税」
 * 的按钮都是错的，只能显示状态。
 */

import { fetchPage, type Page, type PageRequest } from '../pagination';
import type { ApiClient, RequestOptions } from '../http-client';
import type {
  CurrencyCode,
  DeclarationDirection,
  DeclarationSummary,
} from '../../types/domain';
import type { CrossingId, DeclarationId, DocumentId, LineItemId, ShipmentId, TariffId } from '../../types/ids';

const SERVICE = 'customs-service' as const;

/** 报关单行。`tariff_id` 在定税那一刻被冻结，后来的税则调整不会改写它。 */
export interface DeclarationLineItem {
  readonly line_id: LineItemId;
  readonly seq_no: number;
  readonly hs_code: string;
  readonly description: string;
  readonly origin_country: string;
  readonly quantity: number;
  /** UN/ECE Rec 20 计量单位：`KGM`、`PCE`、`LTR`。 */
  readonly unit: string;
  readonly net_weight_kg: number;
  readonly customs_value_minor: number;
  readonly tariff_id: TariffId | null;
  readonly duty_minor: number | null;
}

/** `GET /v1/declarations/{declaration_id}`，含行项目。 */
export interface DeclarationDetail extends DeclarationSummary {
  readonly lines: ReadonlyArray<DeclarationLineItem>;
}

/** `GET /v1/tariffs/lookup` 命中的那一行税则。 */
export interface TariffLookupResult {
  readonly tariff_id: TariffId;
  readonly hs_code: string;
  readonly destination_country: string;
  readonly origin_country: string | null;
  /** 基点，1250 = 12.50%。界面上除以 100 再显示成百分比。 */
  readonly duty_rate_bp: number;
  readonly vat_rate_bp: number;
  readonly preferential_scheme: string | null;
  readonly valid_from: string;
  readonly valid_to: string | null;
  readonly source_document_id: DocumentId | null;
}

/** 起草一张报关单所需的最小信息。 */
export interface DraftDeclarationInput {
  shipment_id: ShipmentId;
  crossing_id: CrossingId;
  direction: DeclarationDirection;
  customs_office_code: string;
  currency: CurrencyCode;
}

/** 起草。此时还没有 `mrn`，要等 file 之后由海关下发。 */
export function draftDeclaration(
  client: ApiClient,
  input: DraftDeclarationInput,
  options?: RequestOptions,
): Promise<DeclarationDetail> {
  return client.post<DeclarationDetail>(SERVICE, '/v1/declarations', { ...options, body: input });
}

/**
 * 整体替换行项目。这个接口是「替换」而不是「追加」，
 * 因为报关行在录入界面上是一张可编辑表格，一次提交整表比逐行 diff 可靠得多。
 */
export function replaceLines(
  client: ApiClient,
  declarationId: DeclarationId,
  lines: ReadonlyArray<Omit<DeclarationLineItem, 'line_id' | 'tariff_id' | 'duty_minor'>>,
  options?: RequestOptions,
): Promise<DeclarationDetail> {
  return client.post<DeclarationDetail>(SERVICE, `/v1/declarations/${declarationId}/lines`, {
    ...options,
    body: { lines },
  });
}

/**
 * 报送。customs-service 会带客户端证书打国家申报网关，成功后发布
 * customs.declaration.filed；这一步慢，界面要按几十秒的量级设计等待态，
 * 而不是转两秒的圈。
 */
export function fileDeclaration(
  client: ApiClient,
  declarationId: DeclarationId,
  options?: RequestOptions,
): Promise<DeclarationDetail> {
  return client.post<DeclarationDetail>(SERVICE, `/v1/declarations/${declarationId}/file`, options);
}

/**
 * 通关后补充申报。`mrn` 保持不变 —— 涉及关税的东西一律只追加不修改（SPEC §7 规则 6），
 * 所以界面上呈现的是一条修订链，不是一份被改过的单据。
 */
export function amendDeclaration(
  client: ApiClient,
  declarationId: DeclarationId,
  reason: string,
  lines: ReadonlyArray<Pick<DeclarationLineItem, 'seq_no' | 'hs_code' | 'quantity' | 'customs_value_minor'>>,
  options?: RequestOptions,
): Promise<DeclarationDetail> {
  return client.post<DeclarationDetail>(SERVICE, `/v1/declarations/${declarationId}/amend`, {
    ...options,
    body: { reason, lines },
  });
}

/** 读一张报关单。 */
export function getDeclaration(
  client: ApiClient,
  declarationId: DeclarationId,
  options?: RequestOptions,
): Promise<DeclarationDetail> {
  return client.get<DeclarationDetail>(SERVICE, `/v1/declarations/${declarationId}`, options);
}

/** 某条运单下的全部报关单。过境运输一单可能对应多个口岸，所以这里是列表而不是单条。 */
export function listShipmentDeclarations(
  client: ApiClient,
  shipmentId: ShipmentId,
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<DeclarationSummary>> {
  return fetchPage<DeclarationSummary>(
    client,
    SERVICE,
    `/v1/shipments/${shipmentId}/declarations`,
    request,
    options,
  );
}

/**
 * 税则查询。录入界面每改一次 HS 编码就调一次，用来实时预估税额。
 *
 * `on_date` 决定命中哪一个版本区间 —— `customs.tariff_schedules` 是时态表，
 * 同一个 HS 编码在不同日期是不同的税率。默认取今天，但补充申报时必须传原报送日期，
 * 否则预估出来的税和真实定税对不上。
 */
export function lookupTariff(
  client: ApiClient,
  query: { hs_code: string; destination_country: string; origin_country?: string; on_date?: string },
  options?: RequestOptions,
): Promise<TariffLookupResult> {
  return client.get<TariffLookupResult>(SERVICE, '/v1/tariffs/lookup', { ...options, query });
}

/** 由基点算出实际税额，避免各处重复写这个换算。结果向下取整到最小货币单位。 */
export function dutyFromBasisPoints(customsValueMinor: number, rateBp: number): number {
  return Math.floor((customsValueMinor * rateBp) / 10_000);
}
