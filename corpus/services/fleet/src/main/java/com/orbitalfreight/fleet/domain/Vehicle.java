/*
 * Copyright 2026 ORBITALFREIGHT Holding B.V.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.orbitalfreight.fleet.domain;

import java.time.Instant;
import java.util.Locale;
import java.util.Set;

/**
 * {@code fleet.vehicles} 한 행을 그대로 옮긴 읽기 모델이다. 배차 가능 여부를 판단할 때 필요한
 * 세 가지 — 차량 등급, 최대 적재 중량, ADR 인증 — 를 한 곳에서 답하도록 헬퍼를 같이 둔다.
 *
 * <p>{@code telematicsUnitId}는 {@code telemetry.device_gateways.serial}과 같은 값이다.
 * 컬럼 이름이 다른 이유는 두 스키마의 소유 서비스가 다르기 때문이고, 조인은 하지 않는다(§7.2).
 * 게이트웨이 상태가 필요하면 telemetry-ingest의 API를 거친다.</p>
 *
 * @param vehicleId        {@code veh_} 접두사가 붙은 ULID
 * @param carrierId        {@code fleet.carriers}를 가리키는 실제 외래 키
 * @param decommissionedAt 폐차/반납 시각. null이 아니면 어떤 배차에도 다시 나타나지 않는다
 */
public record Vehicle(
        String vehicleId,
        String carrierId,
        String plate,
        String plateCountry,
        VehicleClass vehicleClass,
        int maxPayloadKg,
        String telematicsUnitId,
        boolean adrCertified,
        Instant decommissionedAt) {

    /**
     * {@code fleet.vehicles.vehicle_class} CHECK 제약과 값이 1:1로 대응한다.
     * 순서를 바꾸거나 이름을 줄이면 DB 값과 어긋나므로 {@link #fromColumn(String)}만 쓴다.
     */
    public enum VehicleClass {
        VAN,
        RIGID,
        TRACTOR,
        CHASSIS,
        REEFER_TRACTOR,
        RAIL_WAGON,
        BARGE;

        /** routing-service가 계획한 구간 mode 중 이 등급이 실제로 수행할 수 있는 것들. */
        public Set<String> supportedLegModes() {
            return switch (this) {
                case VAN, RIGID, TRACTOR, CHASSIS, REEFER_TRACTOR -> Set.of("road");
                case RAIL_WAGON -> Set.of("rail");
                case BARGE -> Set.of("sea", "barge");
            };
        }

        public static VehicleClass fromColumn(String value) {
            return valueOf(value.toUpperCase(Locale.ROOT));
        }

        public String toColumn() {
            return name().toLowerCase(Locale.ROOT);
        }
    }

    public boolean isActive() {
        return decommissionedAt == null;
    }

    /** 리퍼 컨테이너를 끄는 트랙터인지. 온도 관리 화물의 배차 후보를 좁힐 때 쓴다. */
    public boolean canPowerReefer() {
        return vehicleClass == VehicleClass.REEFER_TRACTOR;
    }

    /**
     * 적재 가능 여부. container-registry가 돌려주는 {@code freight.shipment_containers.gross_kg}의
     * 합계를 그대로 넣는다 — tare는 이미 포함된 값이라 여기서 다시 더하지 않는다.
     */
    public boolean canCarry(int grossKg) {
        return grossKg <= maxPayloadKg;
    }

    /** 로그와 오류 메시지에 쓰는 사람이 읽을 수 있는 식별자. 국가 코드 없는 번호판은 유일하지 않다. */
    public String displayPlate() {
        return plateCountry + "-" + plate;
    }
}
