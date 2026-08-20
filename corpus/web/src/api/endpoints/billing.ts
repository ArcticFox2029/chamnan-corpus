/*
 * billing-service 的调用封装。财务页面的开票、记款、作废都在这里，
 * 金额一律以最小货币单位的整数进出（SPEC §0.2），前端从不构造浮点金额。
 */

import { fetchPage, type Page, type PageRequest } from '../pagination';
import type { ApiClient, RequestOptions } from '../http-client';
import type {
  ChargeCode,
  CurrencyCode,
  InvoiceStatus,
  InvoiceSummary,
  PaymentMethod,
} from '../../types/domain';
import type { DocumentId, InvoiceId, InvoiceLineId, PaymentId, ShipmentId, TenantId } from '../../types/ids';

const SERVICE = 'billing-service' as const;

/** 发票行。`source_kind`/`source_id` 指回产生这笔费用的那条事实。 */
export interface InvoiceLine {
  readonly invoice_line_id: InvoiceLineId;
  readonly seq_no: number;
  readonly charge_code: ChargeCode;
  readonly description: string;
  readonly quantity: number;
  readonly unit_price_minor: number;
  readonly amount_minor: number;
  readonly source_kind: 'leg' | 'alert' | 'declaration' | 'assignment' | 'manual' | null;
  readonly source_id: string | null;
}

/** 一笔收款。 */
export interface Payment {
  readonly payment_id: PaymentId;
  readonly invoice_id: InvoiceId;
  readonly method: PaymentMethod;
  readonly amount_minor: number;
  readonly currency: CurrencyCode;
  readonly received_at: string;
  readonly external_ref: string | null;
  readonly reversed_at: string | null;
}

/** `GET /v1/invoices/{invoice_id}`：抬头 + 行 + 收款。 */
export interface InvoiceDetail extends InvoiceSummary {
  readonly lines: ReadonlyArray<InvoiceLine>;
  readonly payments: ReadonlyArray<Payment>;
  /** 已渲染的 PDF，存在 document-service，kind 为 `rendered_invoice`。 */
  readonly rendered_document_id: DocumentId | null;
}

/** 起草一张发票。此时 `invoice_number` 还是 null，签发时才分配。 */
export function draftInvoice(
  client: ApiClient,
  shipmentId: ShipmentId,
  currency: CurrencyCode,
  options?: RequestOptions,
): Promise<InvoiceDetail> {
  return client.post<InvoiceDetail>(SERVICE, '/v1/invoices', {
    ...options,
    body: { shipment_id: shipmentId, currency },
  });
}

/**
 * 追加费用行。`duty_disbursement` 这一类的金额不该手填 ——
 * billing-service 是从 customs.declaration.cleared 事件里拿到最终税额的，
 * 界面上应该把它预填成只读，人只补 `waiting_time` 这类现场费用。
 */
export function appendLines(
  client: ApiClient,
  invoiceId: InvoiceId,
  lines: ReadonlyArray<Pick<InvoiceLine, 'charge_code' | 'description' | 'quantity' | 'unit_price_minor'>>,
  options?: RequestOptions,
): Promise<InvoiceDetail> {
  return client.post<InvoiceDetail>(SERVICE, `/v1/invoices/${invoiceId}/lines`, {
    ...options,
    body: { lines },
  });
}

/**
 * 签发。这一步分配 `invoice_number`（按 `OF_BILLING_INVOICE_NUMBER_FORMAT`，
 * 租户内按年连号且不允许断号），并发布 billing.invoice.issued。
 * 一旦签发就不能改金额，只能作废后重开或者开红字发票。
 */
export function issueInvoice(
  client: ApiClient,
  invoiceId: InvoiceId,
  options?: RequestOptions,
): Promise<InvoiceDetail> {
  return client.post<InvoiceDetail>(SERVICE, `/v1/invoices/${invoiceId}/issue`, options);
}

/**
 * 记一笔收款。余额归零时 billing-service 把发票置为 `settled` 并发布
 * billing.invoice.settled —— 那条事件是 customs-service 得知税款已付的唯一途径，
 * 也是 `customs.customs_declarations.duty_paid` 唯一的写入来源。
 * 界面上因此可以承诺：这笔款记完，报关页上的「税款已结清」几秒内会自己亮起来。
 */
export function recordPayment(
  client: ApiClient,
  invoiceId: InvoiceId,
  input: { method: PaymentMethod; amount_minor: number; currency: CurrencyCode; received_at: string; external_ref?: string },
  options?: RequestOptions,
): Promise<InvoiceDetail> {
  return client.post<InvoiceDetail>(SERVICE, `/v1/invoices/${invoiceId}/payments`, {
    ...options,
    body: input,
  });
}

/**
 * 作废一张已签发的发票。后端要求先有一份 `credit_note` 文档 ——
 * 上传走 document-service，`owner_type` 填 `invoice`，拿到 doc_ id 再调这里。
 */
export function voidInvoice(
  client: ApiClient,
  invoiceId: InvoiceId,
  creditNoteDocumentId: DocumentId,
  reason: string,
  options?: RequestOptions,
): Promise<InvoiceDetail> {
  return client.post<InvoiceDetail>(SERVICE, `/v1/invoices/${invoiceId}/void`, {
    ...options,
    body: { credit_note_document_id: creditNoteDocumentId, reason },
  });
}

/** 读一张发票。 */
export function getInvoice(
  client: ApiClient,
  invoiceId: InvoiceId,
  options?: RequestOptions,
): Promise<InvoiceDetail> {
  return client.get<InvoiceDetail>(SERVICE, `/v1/invoices/${invoiceId}`, options);
}

/**
 * 应收列表。`status=on_hold` 这一栏值得单独做一个页签：
 * 挂起状态只可能来自 reconciliation.discrepancy.opened，
 * `hold_reason` 里放的就是差异的 `kind`，所以那一栏的每一行都对应一个待处理的对账差异。
 */
export function listTenantInvoices(
  client: ApiClient,
  tenantId: TenantId,
  filters: { status?: InvoiceStatus; due_before?: string },
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<InvoiceSummary>> {
  return fetchPage<InvoiceSummary>(
    client,
    SERVICE,
    `/v1/tenants/${tenantId}/invoices`,
    { ...request, filters: { ...request?.filters, ...filters } },
    options,
  );
}

/** 未收金额。三个分项相加必须等于 `total_minor`，这是数据库层面的 CHECK。 */
export function outstandingMinor(invoice: InvoiceDetail): number {
  const paid = invoice.payments
    .filter((p) => p.reversed_at === null)
    .reduce((sum, p) => sum + p.amount_minor, 0);
  return invoice.total_minor - paid;
}
