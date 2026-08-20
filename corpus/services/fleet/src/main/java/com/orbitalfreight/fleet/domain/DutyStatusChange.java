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

/**
 * 기사 한 명의 근무 상태가 바뀐 순간 하나를 나타낸다. {@code POST /v1/drivers/{driver_id}/hours-of-service}로
 * 들어오는 요청의 본문이자, 남은 운전 가능 시간을 계산하는 입력이기도 하다.
 *
 * <p>이 이력에 대응하는 테이블은 §2의 {@code fleet} 스키마에 없다. 법정 보존본은 기사 앱의 ELD
 * 기록이 원본이고, fleet-service는 판정에 필요한 최근 창만 {@code DutyStatusJournal}에 들고
 * 있으면 되기 때문이다. 창이 비어 있으면 {@code fleet.vehicle_assignments}에서 보수적으로
 * 복원한다.</p>
 *
 * <p>{@code recordedAt}과 {@code occurredAt}이 다른 이유는 스캔 이벤트와 같다. 기사 앱은 국경
 * 지대에서 몇 시간씩 오프라인으로 있다가 한꺼번에 밀어 넣는다.</p>
 */
public record DutyStatusChange(
        String driverId,
        DutyStatus status,
        Instant occurredAt,
        Instant recordedAt,
        String vehicleId,
        Integer odometerKm,
        String source) {

    /**
     * EU 561/2006과 US FMCSA가 공통으로 쓰는 네 가지 상태. 두 규정의 차이는 상태 이름이 아니라
     * 각 상태에 걸리는 한도이므로, 이 enum은 한 벌만 두고 계산기 쪽에서 갈린다.
     */
    public enum DutyStatus {
        /** 운전 중. 두 규정 모두 이 시간만 누적 운전 시간에 들어간다. */
        DRIVING,
        /** 근무 중이지만 운전은 아님 — 상하차, 세관 대기, 검수 입회. */
        ON_DUTY_NOT_DRIVING,
        /** 휴식. 연속 휴식이 일정 길이를 넘겨야 창이 초기화된다. */
        OFF_DUTY,
        /** 침대칸 휴식. FMCSA에서만 분할 휴식으로 인정된다. */
        SLEEPER_BERTH;

        public static DutyStatus fromWire(String value) {
            return valueOf(value.toUpperCase(Locale.ROOT));
        }

        public String toWire() {
            return name().toLowerCase(Locale.ROOT);
        }

        /** 이 상태가 누적 운전 시간에 더해지는가. */
        public boolean countsAsDriving() {
            return this == DRIVING;
        }

        /** 이 상태가 근무 시간(운전 + 비운전)에 더해지는가. */
        public boolean countsAsWorking() {
            return this == DRIVING || this == ON_DUTY_NOT_DRIVING;
        }
    }

    /** 기록 지연. 이 값이 크면 기사 앱이 오래 오프라인이었다는 뜻이고, 잔여 시간 계산은 보수적으로 간다. */
    public long recordingLagSeconds() {
        return recordedAt.getEpochSecond() - occurredAt.getEpochSecond();
    }

    /** 기사 앱(apps/driver-ios)에서 올라온 기록인지, 배차 담당자가 콘솔에서 대신 넣은 것인지. */
    public boolean isFromDriverApp() {
        return "driver-ios".equals(source) || "inspector-android".equals(source);
    }
}
