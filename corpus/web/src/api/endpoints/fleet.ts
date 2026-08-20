/*
 * fleet-service 的 HTTP 面。派车本身是 gRPC（fleet.v1.FleetService/Assign），
 * 浏览器打不到，所以控制台的「派车」按钮走的是 BFF 转发；这里封装的是
 * 车队名册、派车列表和司机可用工时这些真正的 REST 接口。
 */

import { fetchPage, type Page, type PageRequest } from '../pagination';
import type { ApiClient, RequestOptions } from '../http-client';
import type { CarrierRef, VehicleClass } from '../../types/domain';
import type {
  AssignmentId,
  CarrierId,
  DriverId,
  LegId,
  ShipmentId,
  VehicleId,
} from '../../types/ids';

const SERVICE = 'fleet-service' as const;

/** `GET /v1/vehicles/{vehicle_id}`。 */
export interface Vehicle {
  readonly vehicle_id: VehicleId;
  readonly carrier_id: CarrierId;
  readonly plate: string;
  readonly plate_country: string;
  readonly vehicle_class: VehicleClass;
  readonly max_payload_kg: number;
  /** 与 `telemetry.device_gateways.serial` 对得上；没有车载盒子的车这里是 null。 */
  readonly telematics_unit_id: string | null;
  readonly adr_certified: boolean;
  readonly decommissioned_at: string | null;
}

/** `GET /v1/assignments` 的一行。 */
export interface Assignment {
  readonly assignment_id: AssignmentId;
  readonly vehicle_id: VehicleId;
  readonly driver_id: DriverId;
  readonly shipment_id: ShipmentId;
  readonly leg_id: LegId | null;
  readonly assigned_at: string;
  readonly released_at: string | null;
  readonly assigned_by: string;
}

/** `GET /v1/drivers/{driver_id}/availability` 的响应。 */
export interface DriverAvailability {
  readonly driver_id: DriverId;
  /** 当前工时窗口内剩余可驾驶秒数，按 `OF_FLEET_HOS_RULESET` 指定的法规算。 */
  readonly remaining_drive_seconds: number;
  readonly remaining_duty_seconds: number;
  readonly window_resets_at: string;
  readonly licence_expires_on: string;
  readonly adr_expires_on: string | null;
  /** 距离证件到期不足 `OF_FLEET_LICENCE_EXPIRY_WARN_DAYS` 天时为 true。 */
  readonly licence_expiring_soon: boolean;
}

/**
 * 某条运单当前的派车。
 *
 * 只筛 `active=true` 时返回的至多是每条路段一行 —— `fleet.vehicle_assignments`
 * 上的排他约束保证同一辆车、同一个司机在时间上不可能重叠。
 * 界面因此可以把返回结果直接当成「现在谁在跑这单」，不需要再做去重。
 */
export function listAssignments(
  client: ApiClient,
  filters: { shipment_id?: ShipmentId; vehicle_id?: VehicleId; driver_id?: DriverId; active?: boolean },
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<Assignment>> {
  return fetchPage<Assignment>(
    client,
    SERVICE,
    '/v1/assignments',
    { ...request, filters: { ...request?.filters, ...filters } },
    options,
  );
}

/** 读一辆车。 */
export function getVehicle(
  client: ApiClient,
  vehicleId: VehicleId,
  options?: RequestOptions,
): Promise<Vehicle> {
  return client.get<Vehicle>(SERVICE, `/v1/vehicles/${vehicleId}`, options);
}

/** 某承运人的车辆名册，游标分页。 */
export function listCarrierVehicles(
  client: ApiClient,
  carrierId: CarrierId,
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<Vehicle>> {
  return fetchPage<Vehicle>(client, SERVICE, `/v1/carriers/${carrierId}/vehicles`, request, options);
}

/** 司机剩余工时。派车抽屉在候选人列表里逐个调，所以要走并发而不是串行。 */
export function getDriverAvailability(
  client: ApiClient,
  driverId: DriverId,
  options?: RequestOptions,
): Promise<DriverAvailability> {
  return client.get<DriverAvailability>(SERVICE, `/v1/drivers/${driverId}/availability`, options);
}

/**
 * 记一次勤务状态变更。正常情况下这条数据由 driver-ios 上报，
 * 调度台只在司机手机没电、或者忘了切状态时替他补一条 —— 因此 `note` 是必填的。
 */
export function appendHoursOfService(
  client: ApiClient,
  driverId: DriverId,
  input: { status: 'off_duty' | 'sleeper' | 'driving' | 'on_duty'; effective_at: string; note: string },
  options?: RequestOptions,
): Promise<void> {
  return client.post<void>(SERVICE, `/v1/drivers/${driverId}/hours-of-service`, {
    ...options,
    body: input,
  });
}

/**
 * 派车前的资格预检，对应 gRPC 的 fleet.v1.FleetService/CheckEligibility，
 * 由 BFF 以 `POST /v1/assignments/eligibility` 暴露给浏览器。
 *
 * 它只查证件、ADR 和工时，不占用车 —— 真正的占用发生在
 * fleet.v1.FleetService/Assign，仲裁者是 `fleet.vehicle_assignments` 上的排他约束。
 * 也就是说预检通过不等于派得上，界面必须处理 Assign 阶段的 409。
 */
export function checkEligibility(
  client: ApiClient,
  input: { vehicle_id: VehicleId; driver_id: DriverId; shipment_id: ShipmentId; leg_id?: LegId },
  options?: RequestOptions,
): Promise<{ eligible: boolean; blocking_reasons: ReadonlyArray<string> }> {
  return client.post(SERVICE, '/v1/assignments/eligibility', { ...options, body: input });
}

/**
 * 承运人下拉框的数据源。保险到期日一并取回来，
 * 让界面能把 `insurance_expires_on` 已过期的承运人置灰 —— 后端也会拦，
 * 但让调度员在点下去之前就看到原因，比事后弹一个 422 好得多。
 */
export function listCarriers(
  client: ApiClient,
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<CarrierRef>> {
  return fetchPage<CarrierRef>(client, SERVICE, '/v1/carriers', request, options);
}
