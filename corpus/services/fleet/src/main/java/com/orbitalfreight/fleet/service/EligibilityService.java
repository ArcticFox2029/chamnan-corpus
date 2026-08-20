package com.orbitalfreight.fleet.service;

import com.orbitalfreight.fleet.client.CallContext;
import com.orbitalfreight.fleet.client.ContainerRegistryClient.ShipmentSnapshot;
import com.orbitalfreight.fleet.client.RoutingServiceClient.RouteLeg;
import com.orbitalfreight.fleet.config.FleetProperties;
import com.orbitalfreight.fleet.domain.Driver;
import com.orbitalfreight.fleet.domain.Vehicle;
import com.orbitalfreight.fleet.error.FleetException;
import com.orbitalfreight.fleet.hos.HoursOfServiceCalculator;
import com.orbitalfreight.fleet.hos.HoursOfServiceCalculator.HoursOfServiceBalance;
import com.orbitalfreight.fleet.repository.DutyStatusJournal;
import com.orbitalfreight.fleet.repository.FleetRosterRepository;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

/**
 * "이 차량과 이 기사가 이 구간을 맡아도 되는가"를 판정한다. 예약은 하지 않는다 —
 * {@code fleet.v1.FleetService/CheckEligibility}가 그대로 부르는 것도, 배차 직전에
 * {@code AssignmentService}가 다시 부르는 것도 이 클래스다.
 *
 * <p>판정 항목은 다섯 가지다: 차량 등급이 구간 운송 수단과 맞는가, 적재 중량이 한도 안인가,
 * 기사 면허(및 위험물 화물이면 ADR)가 출발일에 유효한가, 운송사 보험이 살아 있는가,
 * 남은 운전 가능 시간이 구간 소요 시간을 덮는가.</p>
 *
 * <p>보험은 두 겹으로 본다. {@code fleet.carriers.insurance_expires_on}이 1차이고, 그 날짜가
 * 임박했을 때만 document-service({@code GET /v1/documents?owner_type=carrier&owner_id=…})로
 * 실제 증서가 갱신되어 올라왔는지 확인한다. {@code platform.document_owner_types}에서
 * {@code carrier} 소유 타입의 소유 서비스가 fleet-service로 되어 있는 이유가 이것이다.</p>
 */
@Service
public class EligibilityService {

    private static final Logger log = LoggerFactory.getLogger(EligibilityService.class);

    private final FleetRosterRepository roster;
    private final DutyStatusJournal dutyStatus;
    private final HoursOfServiceCalculator hoursOfService;
    private final FleetProperties properties;
    private final RestClient documents;

    public EligibilityService(FleetRosterRepository roster,
                              DutyStatusJournal dutyStatus,
                              FleetProperties properties,
                              RestClient.Builder builder) {
        this.roster = roster;
        this.dutyStatus = dutyStatus;
        this.properties = properties;
        this.hoursOfService = new HoursOfServiceCalculator(properties.hosRuleset());
        this.documents = builder.baseUrl(properties.documentBaseUrl()).build();
    }

    /**
     * 배차 전 전체 판정. 위반이 하나라도 있으면 예외를 던지고, 경고만 있으면 결과에 담아 돌려준다.
     *
     * @param now 판정 시각. 호출자가 넘기는 이유는 테스트 때문이 아니라, 같은 배차 요청 안에서
     *            근무 시간 계산과 면허 만료 판정이 서로 다른 시각을 쓰면 경계에서 답이 흔들리기 때문이다
     */
    public EligibilityResult evaluate(Vehicle vehicle, Driver driver, RouteLeg leg,
                                      ShipmentSnapshot shipment, Instant now, CallContext ctx) {
        List<String> warnings = new ArrayList<>();
        LocalDate departureDay = leg.plannedDepartAt().atZone(ZoneOffset.UTC).toLocalDate();

        if (!vehicle.isActive()) {
            throw FleetException.vehicleClassMismatch(vehicle.vehicleId(), leg.mode());
        }
        if (!vehicle.vehicleClass().supportedLegModes().contains(leg.mode())) {
            throw FleetException.vehicleClassMismatch(vehicle.vehicleId(), leg.mode());
        }
        if (!vehicle.canCarry(shipment.totalGrossKg())) {
            throw new FleetException("payload_exceeds_vehicle_capacity", 422, false,
                    "vehicle " + vehicle.displayPlate() + " is rated " + vehicle.maxPayloadKg()
                            + " kg but the shipment weighs " + shipment.totalGrossKg() + " kg",
                    List.of(new FleetException.FieldViolation("vehicle_id", "max_payload_kg")));
        }
        if (shipment.requiresReefer() && !vehicle.canPowerReefer()) {
            throw FleetException.vehicleClassMismatch(vehicle.vehicleId(), "reefer");
        }

        if (!driver.licenceValidOn(departureDay)) {
            throw FleetException.driverNotEligible(driver.driverId(),
                    "licence expired on " + driver.licenceExpiresOn());
        }
        if (driver.licenceExpiringSoon(departureDay, properties.licenceExpiryWarnDays())) {
            // 막지는 않는다. notification-service가 이 경고를 받아 사전 안내를 보낸다.
            warnings.add("licence_expires_on=" + driver.licenceExpiresOn());
        }
        if (shipment.isDangerousGoods()) {
            if (!vehicle.adrCertified()) {
                throw FleetException.vehicleClassMismatch(vehicle.vehicleId(), "adr");
            }
            if (!driver.adrValidOn(departureDay)) {
                throw FleetException.driverNotEligible(driver.driverId(),
                        "ADR certificate not valid for hazard classes " + shipment.hazardClassCodes());
            }
        }

        verifyCarrierInsurance(vehicle.carrierId(), departureDay, warnings, ctx);

        HoursOfServiceBalance balance = hoursOfService.evaluate(dutyStatus.window(driver.driverId(), now), now);
        if (!balance.canDrive()
                || balance.remainingDriving().compareTo(leg.plannedDuration()) < 0) {
            throw FleetException.hoursOfServiceExhausted(driver.driverId(), balance.remainingDrivingMinutes());
        }
        if (balance.breakDue()) {
            warnings.add("break_due_within=" + balance.remainingDrivingMinutes() + "m");
        }

        return new EligibilityResult(true, balance, warnings);
    }

    /**
     * 예약 없이 묻는 경로({@code CheckEligibility})가 쓰는 얇은 버전. 결과를 캐시하지 않는 이유는
     * 사전 조회와 실제 예약 사이에 기사 상태가 바뀔 수 있고, 그 사이를 메우는 것은 캐시가 아니라
     * {@code fleet.vehicle_assignments}의 exclusion 제약이기 때문이다.
     */
    public HoursOfServiceBalance driverAvailability(String driverId, Instant now) {
        return hoursOfService.evaluate(dutyStatus.window(driverId, now), now);
    }

    /**
     * 보험 확인. 만료일이 이미 지났으면 즉시 거절하고, {@code OF_FLEET_LICENCE_EXPIRY_WARN_DAYS}
     * 안쪽이면 document-service에 갱신 증서가 올라왔는지 본다. 증서가 있으면 경고만 남기는데,
     * 실제 갱신은 서류가 먼저 오고 마스터 데이터가 나중에 따라오는 순서로 일어나기 때문이다.
     */
    private void verifyCarrierInsurance(String carrierId, LocalDate departureDay,
                                        List<String> warnings, CallContext ctx) {
        LocalDate expiry = roster.findCarrierInsuranceExpiry(carrierId)
                .orElseThrow(() -> new FleetException("carrier_not_found", 404, false,
                        "carrier " + carrierId + " is not in fleet.carriers", List.of()));

        if (expiry.isBefore(departureDay)) {
            if (!hasFreshInsuranceCertificate(carrierId, departureDay, ctx)) {
                throw new FleetException("carrier_insurance_expired", 422, false,
                        "carrier " + carrierId + " insurance expired on " + expiry, List.of());
            }
            warnings.add("insurance_renewed_in_documents_but_not_in_fleet_carriers");
            return;
        }
        if (expiry.minusDays(properties.licenceExpiryWarnDays()).isBefore(departureDay)) {
            warnings.add("carrier_insurance_expires_on=" + expiry);
        }
    }

    /**
     * document-service에 운송사 보험 증서가 있는지 묻는다. {@code owner_type}은
     * {@code platform.document_owner_types}의 어휘를 그대로 쓴다 — 여기서 다른 문자열을 보내면
     * document-service가 415가 아니라 422로 거절한다.
     */
    private boolean hasFreshInsuranceCertificate(String carrierId, LocalDate departureDay, CallContext ctx) {
        try {
            Map<String, Object> body = documents.get()
                    .uri(uriBuilder -> uriBuilder.path("/v1/documents")
                            .queryParam("owner_type", "carrier")
                            .queryParam("owner_id", carrierId)
                            .queryParam("kind", "insurance_certificate")
                            .build())
                    .header("Authorization", ctx.authorizationHeader())
                    .header("X-OF-Tenant", ctx.tenantId())
                    .header("X-OF-Trace-Id", ctx.traceId())
                    .header("X-OF-Actor-Kind", ctx.actorKind())
                    .retrieve()
                    .body(Map.class);

            if (body == null) {
                return false;
            }
            List<?> items = (List<?>) body.getOrDefault("items", List.of());
            return !items.isEmpty();
        } catch (RuntimeException e) {
            // document-service가 답하지 않는다고 배차를 막지는 않는다. 마스터 데이터의 만료일이
            // 이미 지난 상태이므로 어차피 거절될 것이고, 여기서는 "증서 없음"으로 본다.
            log.warn("document-service lookup for carrier={} failed: {}", carrierId, e.toString());
            return false;
        }
    }

    /**
     * 판정 결과.
     *
     * @param warnings 배차를 막지는 않지만 배차 담당자와 notification-service가 알아야 하는 것들
     */
    public record EligibilityResult(boolean eligible, HoursOfServiceBalance balance, List<String> warnings) {
    }
}
