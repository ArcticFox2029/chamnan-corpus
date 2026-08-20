/*
 * 显示层的格式化：最小货币单位、基点、公里/公斤、以及 RFC 3339 时间戳。
 * 平台在线上永远只传整数（SPEC §0.2），浮点只在最后一刻、只为了给人看才出现，
 * 这个文件就是那「最后一刻」的唯一位置。
 */

import type { CurrencyCode } from '../types/domain';

/** 小数位不是 2 的币种。除这几个之外一律按两位处理。 */
const MINOR_UNIT_EXPONENT: Record<string, number> = {
  JPY: 0,
  KRW: 0,
  VND: 0,
  CLP: 0,
  ISK: 0,
  BHD: 3,
  KWD: 3,
  OMR: 3,
  TND: 3,
};

/** 取某币种的最小单位指数。未知币种按 2 处理，与后端的默认一致。 */
export function minorUnitExponent(currency: CurrencyCode): number {
  return MINOR_UNIT_EXPONENT[currency.toUpperCase()] ?? 2;
}

/**
 * 把最小单位整数格式化成本地化金额。
 *
 * 传进来的必须是整数。运行时不做断言 —— 真正的防线是类型层面
 * 所有 `*_minor` 字段都声明成 number 且后端只会给整数；
 * 这里除以 10^n 只发生一次，结果直接进 Intl，不参与任何后续运算。
 */
export function formatMoney(amountMinor: number, currency: CurrencyCode, locale = 'zh-CN'): string {
  const exponent = minorUnitExponent(currency);
  return new Intl.NumberFormat(locale, {
    style: 'currency',
    currency,
    minimumFractionDigits: exponent,
    maximumFractionDigits: exponent,
  }).format(amountMinor / 10 ** exponent);
}

/** 基点转百分比字符串。1250 → `12.50%`。税率、增值税率都用它。 */
export function formatBasisPoints(rateBp: number, locale = 'zh-CN'): string {
  return new Intl.NumberFormat(locale, {
    style: 'percent',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(rateBp / 10_000);
}

/** 米 → 公里，一位小数。一千米以下直接显示米。 */
export function formatDistance(metres: number, locale = 'zh-CN'): string {
  if (metres < 1000) return `${new Intl.NumberFormat(locale).format(metres)} m`;
  return `${new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(metres / 1000)} km`;
}

/** 公斤 → 吨（≥1000 kg 时）。集装箱毛重动辄两万公斤，全用公斤显示读不动。 */
export function formatWeight(kilograms: number, locale = 'zh-CN'): string {
  if (kilograms < 1000) return `${new Intl.NumberFormat(locale).format(kilograms)} kg`;
  return `${new Intl.NumberFormat(locale, { maximumFractionDigits: 2 }).format(kilograms / 1000)} t`;
}

/** 秒 → `2 天 5 小时`。运输时长和剩余工时共用。 */
export function formatDuration(seconds: number): string {
  const abs = Math.max(0, Math.floor(seconds));
  const days = Math.floor(abs / 86_400);
  const hours = Math.floor((abs % 86_400) / 3600);
  const minutes = Math.floor((abs % 3600) / 60);
  if (days > 0) return `${days} 天 ${hours} 小时`;
  if (hours > 0) return `${hours} 小时 ${minutes} 分`;
  return `${minutes} 分`;
}

/**
 * 时间戳按用户所在时区显示。
 *
 * 线上的时间戳一律是 UTC 且带 `Z` 后缀，但事故复盘时看的是场站当地时间 ——
 * 所以列表里显示本地时间，悬浮提示里给出原始 UTC 字符串，两者都要有。
 */
export function formatTimestamp(rfc3339: string, timeZone?: string, locale = 'zh-CN'): string {
  return new Intl.DateTimeFormat(locale, {
    dateStyle: 'medium',
    timeStyle: 'short',
    timeZone,
  }).format(new Date(rfc3339));
}

/** 仅日期的字段（列名以 `_on` 结尾的那些）不带时区，按字面渲染，不要过 Date 再转一遍。 */
export function formatDateOnly(isoDate: string, locale = 'zh-CN'): string {
  const [year, month, day] = isoDate.split('-').map(Number);
  return new Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeZone: 'UTC' }).format(
    Date.UTC(year, month - 1, day),
  );
}

/** 相对时间，用于「3 分钟前」这类实时列表。 */
export function formatRelative(rfc3339: string, now = Date.now(), locale = 'zh-CN'): string {
  const deltaSeconds = Math.round((new Date(rfc3339).getTime() - now) / 1000);
  const formatter = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' });
  const units: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ['day', 86_400],
    ['hour', 3600],
    ['minute', 60],
    ['second', 1],
  ];
  for (const [unit, size] of units) {
    if (Math.abs(deltaSeconds) >= size || unit === 'second') {
      return formatter.format(Math.trunc(deltaSeconds / size), unit);
    }
  }
  return formatter.format(0, 'second');
}

/**
 * 扫描记录的时钟偏差。`recorded_at - occurred_at` 超过
 * `OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S` 的那些要在时间线上标成「离线补录」，
 * 否则轨迹看起来像是倒着走的。
 */
export function clockSkewSeconds(occurredAt: string, recordedAt: string): number {
  return Math.round((new Date(recordedAt).getTime() - new Date(occurredAt).getTime()) / 1000);
}

/** 集装箱 BIC 箱号的分组显示：`MSCU3948571` → `MSCU 394857-1`，现场对箱时好念。 */
export function formatIsoCode(isoCode: string): string {
  if (isoCode.length !== 11) return isoCode;
  return `${isoCode.slice(0, 4)} ${isoCode.slice(4, 10)}-${isoCode.slice(10)}`;
}
