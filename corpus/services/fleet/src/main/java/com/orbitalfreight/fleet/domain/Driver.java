package com.orbitalfreight.fleet.domain;

import java.time.LocalDate;
import java.time.temporal.ChronoUnit;

/**
 * {@code fleet.drivers}의 읽기 모델이며, 배차 전에 확인해야 하는 면허·ADR 유효성 판정을 담는다.
 * 실제 근무 시간 판정은 여기 없다 — 그쪽은 {@code fleet.drivers}가 아니라 근무 상태 변경 이력을
 * 봐야 하므로 {@code com.orbitalfreight.fleet.hos} 패키지가 담당한다.
 *
 * <p>{@code userId}가 null일 수 있다는 점이 이 모델에서 가장 자주 사고를 내는 부분이다.
 * 하청 기사는 콘솔 로그인 없이 로스터에만 올라오므로 identity-service의 사용자와 연결되지
 * 않는다. 알림 대상으로 넘길 때 이 필드를 그대로 쓰면 notification-service가 수신자를 찾지
 * 못하고 {@code notification.delivery.failed}를 뱉는다.</p>
 */
public record Driver(
        String driverId,
        String carrierId,
        String userId,
        String fullName,
        String licenceNumber,
        String licenceCountry,
        LocalDate licenceExpiresOn,
        LocalDate adrExpiresOn,
        String phoneE164) {

    /** 면허가 해당 날짜에 유효한가. 만료일 당일은 유효한 것으로 본다(EU 회원국 공통 해석). */
    public boolean licenceValidOn(LocalDate day) {
        return !licenceExpiresOn.isBefore(day);
    }

    /**
     * 위험물(ADR) 화물을 끌 수 있는가. {@code adrExpiresOn}이 null이면 애초에 ADR 교육을 받지
     * 않은 기사다. 차량 쪽 {@code fleet.vehicles.adr_certified}와 둘 다 참이어야 배차된다.
     */
    public boolean adrValidOn(LocalDate day) {
        return adrExpiresOn != null && !adrExpiresOn.isBefore(day);
    }

    /**
     * {@code OF_FLEET_LICENCE_EXPIRY_WARN_DAYS} 안쪽으로 들어왔는지. 배차를 막지는 않고,
     * notification-service가 사전 경고를 보내도록 하는 신호로만 쓴다.
     *
     * @param warnDays 경고 창의 길이(일)
     */
    public boolean licenceExpiringSoon(LocalDate today, int warnDays) {
        long remaining = ChronoUnit.DAYS.between(today, licenceExpiresOn);
        return remaining >= 0 && remaining <= warnDays;
    }

    /** 면허 국가와 번호의 조합이 전역 유일하다 — {@code fleet.drivers}의 UNIQUE 제약과 같은 키. */
    public String licenceKey() {
        return licenceCountry + ":" + licenceNumber;
    }
}
