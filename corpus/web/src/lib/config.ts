/*
 * 运行期配置的读取口。页面上那个注入进来的全局对象只在这里被碰一次，
 * 别处一律通过这些函数拿值 —— 这样「配置缺了什么」是一个启动期就能发现的错误，
 * 而不是某个页面在用户点进去时才炸出来的 undefined。
 */

import type { ConsoleConfig, Environment, FeatureFlags } from '../types/config';
import type { RegionCode } from '../types/domain';

/** SPEC §0.6 的八个区域码，封闭列表。注入的值不在其中就是部署配错了。 */
const REGION_CODES: ReadonlySet<string> = new Set<RegionCode>([
  'eu-west',
  'eu-central',
  'na-east',
  'na-west',
  'apac-sg',
  'apac-jp',
  'latam-br',
  'mea-ae',
]);

/** SPEC §1 的十四个服务名。少一个都会让某个页面在运行时拿到 undefined 的基地址。 */
const REQUIRED_ROUTES: ReadonlyArray<keyof ConsoleConfig['service_routes']> = [
  'identity-service',
  'fleet-service',
  'container-registry',
  'telemetry-ingest',
  'routing-service',
  'geo-service',
  'customs-service',
  'billing-service',
  'document-service',
  'notification-service',
  'analytics-pipeline',
  'audit-ledger',
  'reconciliation-service',
];

let cached: ConsoleConfig | null = null;

/**
 * 校验注入进来的对象。
 *
 * 故意不做「补齐缺省值」这件事：一个缺了 region_code 的配置，猜一个出来
 * 只会让请求在边缘代理的 region_guard.lua 那里被 403 掉，
 * 而报错信息会指向鉴权而不是配置。
 */
function validate(raw: unknown): ConsoleConfig {
  if (typeof raw !== 'object' || raw === null) {
    throw new Error('__OF_CONSOLE_CONFIG__ is missing: the deployment did not inject config');
  }
  const config = raw as ConsoleConfig;

  if (!REGION_CODES.has(config.region_code)) {
    throw new Error(`region_code "${config.region_code}" is not one of the eight in SPEC §0.6`);
  }
  const missing = REQUIRED_ROUTES.filter((name) => !config.service_routes?.[name]);
  if (missing.length > 0) {
    throw new Error(`service_routes is missing: ${missing.join(', ')}`);
  }
  if (!config.realtime_url.startsWith('wss://') && config.environment !== 'local') {
    // 明文 WebSocket 会把访问令牌以查询参数的形式裸奔一路 ——
    // console-channel.ts 只能把令牌放在查询串里，所以这条限制没有商量余地。
    throw new Error('realtime_url must be wss:// outside the local environment');
  }
  return config;
}

/** 取配置。第一次调用时校验并缓存，之后直接返回同一个对象。 */
export function requireConsoleConfig(): ConsoleConfig {
  if (cached) return cached;
  cached = validate(window.__OF_CONSOLE_CONFIG__);
  return cached;
}

/** 某个功能开关是否打开。缺失一律当作关。 */
export function isEnabled(flag: keyof FeatureFlags): boolean {
  return requireConsoleConfig().features[flag] === true;
}

/** 当前环境。生产环境上要收掉调试面板与 trace-id 的明文展示。 */
export function environment(): Environment {
  return requireConsoleConfig().environment;
}

/**
 * 当前区域。
 *
 * 界面右上角会一直显示它 —— 运维同时开着四个区域的控制台是常态，
 * 而在错误的那一个里点「作废发票」不会有任何提示，只会 403。
 */
export function regionCode(): RegionCode {
  return requireConsoleConfig().region_code;
}

/** 测试用：替换掉缓存的配置。生产代码里没有任何调用点。 */
export function __setConfigForTests(config: ConsoleConfig | null): void {
  cached = config;
}
