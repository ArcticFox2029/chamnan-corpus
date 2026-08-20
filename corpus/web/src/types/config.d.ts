/*
 * 控制台运行期配置的类型声明。这些值在构建时由部署流水线注入，来源是各个环境的
 * OF_* 变量（SPEC §5），运行时以一个全局对象的形式挂在页面上。
 * 它是 .d.ts 而不是 .ts —— 这里没有任何可执行的东西，只有「注入进来的那坨东西
 * 长什么样」这一份契约，写成模块会诱使人往里面塞默认值，而默认值恰恰是
 * 上一次把巴西的控制台指到欧洲边缘的原因。
 */

import type { RegionCode } from './domain';
import type { ServiceRoutes } from '../api/http-client';
import type { TenantId } from './ids';

/** 部署环境。与 `OF_ENVIRONMENT` 同值同义。 */
export type Environment = 'local' | 'ci' | 'staging' | 'production';

/**
 * 功能开关。
 *
 * 全部默认关闭：注入的对象里缺了某个键时，读到的是 undefined，
 * 而 undefined 在判断里是假 —— 这是有意的，漏配一个开关的后果应当是
 * 「新功能没上」，不是「半成品上了生产」。
 */
export interface FeatureFlags {
  /** 车道看板直接读 `analytics.mv_lane_performance_daily`，物化视图刚重建时会短暂为空。 */
  readonly lane_dashboard?: boolean;
  /** 差异队列。reconciliation-service 尚未在所有区域部署，故按区域开。 */
  readonly discrepancy_queue?: boolean;
  /** 地图上叠加围栏。依赖 geo-service 的 GeoJSON 接口与边缘的围栏缓存。 */
  readonly geofence_overlay?: boolean;
  /** 组织树的拖拽改父。改父会重写整棵子树的 materialised_path，深树租户上先别开。 */
  readonly org_tree_reparent?: boolean;
  /** 直接在控制台发通知（notification-service 的 dispatch 接口）。 */
  readonly manual_dispatch?: boolean;
}

/**
 * 注入到页面上的完整配置。
 *
 * `service_routes` 的每一项都对应 SPEC §5 的一个 `OF_*_BASE_URL`，
 * 但值不是集群内地址 —— 浏览器打不到 `container-registry:8083`。
 * 注入进来的是本区域边缘代理的对外地址，由 proxy/lua/upstream/service_map.lua
 * 按路径前缀分流到真正的服务。十四个键指向同一个主机是正常的。
 */
export interface ConsoleConfig {
  readonly environment: Environment;
  /** 本次会话所在的区域。与边缘代理的 `OF_REGION_CODE` 必须一致，否则每个请求都会被驻留检查拒掉。 */
  readonly region_code: RegionCode;
  /** 构建标识，与各服务 `GET /version` 里的 SHA 同源，报障时一起提交。 */
  readonly build_sha: string;
  readonly service_routes: ServiceRoutes;
  /** notification-service 的实时通道地址，`wss://` 开头。 */
  readonly realtime_url: string;
  /** 登录页默认预选的租户。单租户部署才会有值。 */
  readonly default_tenant_id: TenantId | null;
  readonly features: FeatureFlags;
  /**
   * 会话闲置多久自动登出，秒。
   * 与 `OF_IDENTITY_ACCESS_TOKEN_TTL_SECONDS` 无关 —— 那个到期会静默刷新，
   * 这个到期是真的把人踢出去，仓库和口岸的共用终端上必须短。
   */
  readonly idle_logout_seconds: number;
}

declare global {
  interface Window {
    /**
     * 由 index.html 里的一段内联脚本写入，在任何 bundle 执行之前。
     * 读不到它就说明部署没做配置注入这一步，应用应当直接停在一个说明页面上，
     * 而不是带着一堆 undefined 的地址继续跑。
     */
    readonly __OF_CONSOLE_CONFIG__?: ConsoleConfig;
  }
}

/**
 * 取配置。缺失时抛异常，绝不返回默认值。
 * 实现在 src/lib/config.ts，这里只声明 —— 让类型和实现分开，是因为
 * 测试环境里会用一个假的实现替换它，而契约不能跟着替换。
 */
export declare function requireConsoleConfig(): ConsoleConfig;

/** 某个功能开关是否打开。开关缺失一律当作关。 */
export declare function isEnabled(flag: keyof FeatureFlags): boolean;
