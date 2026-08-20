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
package com.orbitalfreight.fleet.web;

import com.orbitalfreight.fleet.domain.DutyStatusChange;
import com.orbitalfreight.fleet.domain.DutyStatusChange.DutyStatus;
import com.orbitalfreight.fleet.error.FleetException;
import com.orbitalfreight.fleet.hos.HoursOfServiceCalculator.HoursOfServiceBalance;
import com.orbitalfreight.fleet.repository.DutyStatusJournal;
import com.orbitalfreight.fleet.repository.FleetRosterRepository;
import com.orbitalfreight.fleet.service.EligibilityService;
import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 기사 앱(apps/driver-ios)이 근무 상태를 올리고 남은 운전 시간을 확인하는 두 엔드포인트를 맡는다.
 * §3.2의 {@code POST /v1/drivers/{driver_id}/hours-of-service}와
 * {@code GET /v1/drivers/{driver_id}/availability}가 전부다.
 *
 * <p>이 두 호출은 신호가 나쁜 곳에서 온다. 기사는 국경 대기줄이나 지하 물류센터에서 몇 시간씩
 * 오프라인이었다가 한꺼번에 밀어 넣으므로, 등록 시각({@code recorded_at})과 발생
 * 시각({@code occurred_at})이 크게 벌어지는 것을 오류로 보지 않는다. 대신 미래 시각만 거절한다 —
 * 기기 시계가 앞서 있으면 남은 시간이 실제보다 길게 계산되어 법정 한도를 넘길 수 있다.</p>
 */
@RestController
@RequestMapping(produces = MediaType.APPLICATION_JSON_VALUE)
public class DriverHoursController {

    /** 기기 시계가 앞서 있어도 이만큼은 봐준다. 그 이상은 거절한다. */
    private static final Duration MAX_CLOCK_SKEW = Duration.ofMinutes(5);

    private final DutyStatusJournal journal;
    private final FleetRosterRepository roster;
    private final EligibilityService eligibility;

    public DriverHoursController(DutyStatusJournal journal, FleetRosterRepository roster,
                                 EligibilityService eligibility) {
        this.journal = journal;
        this.roster = roster;
        this.eligibility = eligibility;
    }

    /**
     * 근무 상태 변경 하나를 덧붙인다. 갱신이나 삭제 경로는 없다 — 잘못 올라온 상태는 새 항목으로
     * 정정한다. 같은 {@code occurred_at}에 같은 상태가 재전송되면 조용히 같은 항목으로 덮어써지므로
     * 기사 앱은 배달 확인 없이 재전송해도 된다.
     *
     * @param idempotencyKey §0.3의 {@code X-OF-Idempotency-Key}. 오프라인 재전송이 잦아
     *                       실제로 자주 쓰이는 몇 안 되는 엔드포인트다
     */
    @PostMapping(value = "/v1/drivers/{driver_id}/hours-of-service",
            consumes = MediaType.APPLICATION_JSON_VALUE)
    @ResponseStatus(HttpStatus.ACCEPTED)
    public Map<String, Object> appendDutyStatus(
            @PathVariable("driver_id") String driverId,
            @RequestHeader(value = "X-OF-Idempotency-Key", required = false) String idempotencyKey,
            @RequestBody DutyStatusRequest request) {

        roster.findDriver(driverId).orElseThrow(() -> new FleetException("driver_not_found", 404, false,
                "driver " + driverId + " is not in fleet.drivers", List.of()));

        Instant now = Instant.now();
        Instant occurredAt = Instant.parse(request.occurredAt());
        if (occurredAt.isAfter(now.plus(MAX_CLOCK_SKEW))) {
            throw new FleetException("duty_status_in_the_future", 422, false,
                    "occurred_at is ahead of server time by more than " + MAX_CLOCK_SKEW.toMinutes() + " minutes",
                    List.of(new FleetException.FieldViolation("occurred_at", "clock_skew")));
        }

        DutyStatusChange change = new DutyStatusChange(
                driverId,
                DutyStatus.fromWire(request.status()),
                occurredAt,
                now,
                request.vehicleId(),
                request.odometerKm(),
                request.source() == null ? "driver-ios" : request.source());
        journal.append(change);

        HoursOfServiceBalance balance = eligibility.driverAvailability(driverId, now);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("driver_id", driverId);
        body.put("accepted_status", change.status().toWire());
        body.put("recorded_at", now.toString());
        body.put("recording_lag_seconds", change.recordingLagSeconds());
        body.put("remaining_driving_minutes", balance.remainingDrivingMinutes());
        return body;
    }

    /**
     * 남은 운전 가능 시간. 기사 앱의 상단 배지와 배차 화면의 후보 목록이 같은 값을 본다.
     * 계산은 {@code fleet.v1.FleetService/CheckEligibility}와 동일한 코드 경로를 탄다 —
     * 두 표면이 다른 답을 내면 기사와 배차 담당자가 서로 다른 화면을 보고 다투게 된다.
     */
    @GetMapping("/v1/drivers/{driver_id}/availability")
    public Map<String, Object> availability(@PathVariable("driver_id") String driverId) {
        roster.findDriver(driverId).orElseThrow(() -> new FleetException("driver_not_found", 404, false,
                "driver " + driverId + " is not in fleet.drivers", List.of()));

        HoursOfServiceBalance balance = eligibility.driverAvailability(driverId, Instant.now());
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("driver_id", driverId);
        body.put("ruleset", balance.ruleset());
        body.put("can_drive", balance.canDrive());
        body.put("remaining_driving_minutes", balance.remainingDrivingMinutes());
        body.put("remaining_daily_minutes", balance.remainingDaily().toMinutes());
        body.put("continuous_driving_minutes", balance.continuousDriving().toMinutes());
        body.put("break_due", balance.breakDue());
        body.put("blocked_by", balance.blockedBy());
        return body;
    }

    /**
     * 요청 본문. {@code occurred_at}은 §0.2에 따라 항상 UTC RFC 3339 문자열이다.
     *
     * @param odometerKm 주행 거리계. 없어도 되지만 있으면 반납 시 거리 검증에 쓴다
     * @param source     {@code driver-ios} 또는 {@code inspector-android}. 배차 담당자가
     *                   콘솔에서 대신 넣으면 {@code console}이 온다
     */
    public record DutyStatusRequest(
            String status,
            String occurredAt,
            String vehicleId,
            Integer odometerKm,
            String source) {
    }
}
