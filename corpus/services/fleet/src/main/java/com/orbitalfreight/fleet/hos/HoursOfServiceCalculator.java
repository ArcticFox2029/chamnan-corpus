package com.orbitalfreight.fleet.hos;

import com.orbitalfreight.fleet.domain.DutyStatusChange;
import com.orbitalfreight.fleet.domain.DutyStatusChange.DutyStatus;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * 근무 상태 변경 이력을 받아 "지금 이 기사가 앞으로 몇 분을 더 운전할 수 있는가"를 계산한다.
 * {@code OF_FLEET_HOS_RULESET}이 {@code eu_561}이냐 {@code us_fmcsa}냐에 따라 한도만 갈리고
 * 누적 방식은 같으므로, 규정별 상수와 판정만 분리하고 스캔 로직은 한 벌로 유지한다.
 *
 * <p>이 계산 결과는 두 곳에서 쓰인다: {@code fleet.v1.FleetService/CheckEligibility}가 예약 없이
 * 미리 물어볼 때, 그리고 {@code GET /v1/drivers/{driver_id}/availability}가 기사 앱에 남은 시간을
 * 보여줄 때다. 배차를 실제로 잡는 경로에서도 같은 값을 다시 계산한다 — 사전 조회와 예약 사이에
 * 기사가 상태를 바꿨을 수 있기 때문에 CheckEligibility 결과를 신뢰해 캐시하지 않는다.</p>
 */
public final class HoursOfServiceCalculator {

    // --- EU 561/2006 ---
    private static final Duration EU_DAILY_DRIVING = Duration.ofHours(9);
    private static final Duration EU_EXTENDED_DAILY_DRIVING = Duration.ofHours(10);
    private static final Duration EU_CONTINUOUS_DRIVING = Duration.ofMinutes(270); // 4시간 30분
    private static final Duration EU_REQUIRED_BREAK = Duration.ofMinutes(45);
    private static final Duration EU_WEEKLY_DRIVING = Duration.ofHours(56);
    private static final Duration EU_DAILY_REST = Duration.ofHours(11);
    private static final Duration EU_REDUCED_DAILY_REST = Duration.ofHours(9);

    // --- US FMCSA property-carrying rules ---
    private static final Duration US_DAILY_DRIVING = Duration.ofHours(11);
    private static final Duration US_DUTY_WINDOW = Duration.ofHours(14);
    private static final Duration US_DRIVING_BEFORE_BREAK = Duration.ofHours(8);
    private static final Duration US_REQUIRED_BREAK = Duration.ofMinutes(30);
    private static final Duration US_WEEKLY_DUTY = Duration.ofHours(70);
    private static final Duration US_RESET_REST = Duration.ofHours(10);

    private final String ruleset;

    public HoursOfServiceCalculator(String ruleset) {
        this.ruleset = ruleset;
    }

    /**
     * 남은 운전 가능 시간과 그 이유를 계산한다.
     *
     * @param changes 최근 창의 상태 변경 이력. 정렬 여부는 신경 쓰지 않는다 — 기사 앱이 오프라인
     *                구간을 몰아서 올리면 {@code recorded_at} 순서와 {@code occurred_at} 순서가
     *                다르기 때문에 여기서 항상 {@code occurred_at} 기준으로 다시 정렬한다.
     * @param now     판정 시각
     * @return 잔여 시간과 위반 사유
     */
    public HoursOfServiceBalance evaluate(List<DutyStatusChange> changes, Instant now) {
        if ("none".equals(ruleset)) {
            // 로컬/CI 배포. 한도를 무제한으로 돌려주되 규정 이름은 그대로 남겨 로그에서 구분되게 한다.
            return HoursOfServiceBalance.unlimited(ruleset);
        }
        List<Segment> segments = toSegments(changes, now);
        if (segments.isEmpty()) {
            // 이력이 아예 없는 기사는 방금 로스터에 올라온 하청 기사다. 초기 한도를 그대로 준다.
            return new HoursOfServiceBalance(ruleset, dailyDrivingLimit(), dailyDrivingLimit(),
                    Duration.ZERO, false, null);
        }

        Duration drivingToday = Duration.ZERO;
        Duration workingInWindow = Duration.ZERO;
        Duration continuousDriving = Duration.ZERO;
        Duration currentRest = Duration.ZERO;
        Instant windowStart = null;

        for (Segment segment : segments) {
            if (segment.status().countsAsDriving()) {
                drivingToday = drivingToday.plus(segment.length());
                continuousDriving = continuousDriving.plus(segment.length());
                currentRest = Duration.ZERO;
                if (windowStart == null) {
                    windowStart = segment.start();
                }
            } else if (segment.status().countsAsWorking()) {
                workingInWindow = workingInWindow.plus(segment.length());
                currentRest = Duration.ZERO;
                if (windowStart == null) {
                    windowStart = segment.start();
                }
            } else {
                currentRest = currentRest.plus(segment.length());
                if (breakSatisfies(currentRest)) {
                    continuousDriving = Duration.ZERO;
                }
                if (resetSatisfies(currentRest)) {
                    // 일일 휴식을 채웠다. 창 전체가 초기화된다.
                    drivingToday = Duration.ZERO;
                    workingInWindow = Duration.ZERO;
                    continuousDriving = Duration.ZERO;
                    windowStart = null;
                }
            }
        }

        Duration remainingDaily = dailyDrivingLimit().minus(drivingToday);
        Duration remainingContinuous = continuousDrivingLimit().minus(continuousDriving);
        Duration remaining = min(remainingDaily, remainingContinuous);

        if (windowStart != null && "us_fmcsa".equals(ruleset)) {
            // FMCSA는 운전 시간과 별개로 근무 개시 후 14시간이라는 벽시계 창이 있다.
            Duration windowLeft = US_DUTY_WINDOW.minus(Duration.between(windowStart, now));
            remaining = min(remaining, windowLeft);
        }

        String blocker = null;
        if (remaining.isNegative() || remaining.isZero()) {
            remaining = Duration.ZERO;
            blocker = remainingContinuous.compareTo(remainingDaily) <= 0
                    ? "continuous_driving_limit"
                    : "daily_driving_limit";
        }
        boolean breakDue = remainingContinuous.compareTo(Duration.ofMinutes(15)) <= 0;
        return new HoursOfServiceBalance(ruleset, remaining, remainingDaily, continuousDriving, breakDue, blocker);
    }

    /**
     * 이 기사가 앞으로 {@code needed}만큼 더 운전할 수 있는가. routing-service가 돌려준 구간의
     * {@code planned_arrive_at - planned_depart_at}을 그대로 넣어 배차 전에 확인한다.
     */
    public boolean canCover(List<DutyStatusChange> changes, Instant now, Duration needed) {
        return evaluate(changes, now).remainingDriving().compareTo(needed) >= 0;
    }

    private Duration dailyDrivingLimit() {
        return "us_fmcsa".equals(ruleset) ? US_DAILY_DRIVING : EU_DAILY_DRIVING;
    }

    private Duration continuousDrivingLimit() {
        return "us_fmcsa".equals(ruleset) ? US_DRIVING_BEFORE_BREAK : EU_CONTINUOUS_DRIVING;
    }

    private boolean breakSatisfies(Duration rest) {
        return rest.compareTo("us_fmcsa".equals(ruleset) ? US_REQUIRED_BREAK : EU_REQUIRED_BREAK) >= 0;
    }

    private boolean resetSatisfies(Duration rest) {
        // EU는 조건부로 9시간 단축 휴식을 인정한다. 여기서는 배차를 막는 쪽으로 기울여
        // 단축 휴식도 초기화로 인정하되, 주간 한도(56시간)는 별도 조회에서 다시 본다.
        return rest.compareTo("us_fmcsa".equals(ruleset) ? US_RESET_REST : EU_REDUCED_DAILY_REST) >= 0;
    }

    /**
     * 상태 변경점 목록을 구간 목록으로 편다. 마지막 상태는 {@code now}까지 이어진 것으로 본다 —
     * 기사가 아직 상태를 안 바꿨다는 뜻이기 때문이다.
     */
    private List<Segment> toSegments(List<DutyStatusChange> changes, Instant now) {
        List<DutyStatusChange> ordered = new ArrayList<>(changes);
        ordered.sort(Comparator.comparing(DutyStatusChange::occurredAt));
        List<Segment> segments = new ArrayList<>(ordered.size());
        for (int i = 0; i < ordered.size(); i++) {
            Instant start = ordered.get(i).occurredAt();
            Instant end = (i + 1 < ordered.size()) ? ordered.get(i + 1).occurredAt() : now;
            if (end.isAfter(start)) {
                segments.add(new Segment(ordered.get(i).status(), start, Duration.between(start, end)));
            }
        }
        return segments;
    }

    private static Duration min(Duration a, Duration b) {
        return a.compareTo(b) <= 0 ? a : b;
    }

    /** 한 가지 상태로 이어진 시간 구간. */
    private record Segment(DutyStatus status, Instant start, Duration length) {
    }

    /**
     * 계산 결과. {@code GET /v1/drivers/{driver_id}/availability}의 응답 본문이 이 모양 그대로다.
     *
     * @param blockedBy 지금 배차가 막힌 이유. 막히지 않았으면 null이며, 값이 있으면 오류 봉투의
     *                  {@code code}로 그대로 올라간다(§0.4).
     */
    public record HoursOfServiceBalance(
            String ruleset,
            Duration remainingDriving,
            Duration remainingDaily,
            Duration continuousDriving,
            boolean breakDue,
            String blockedBy) {

        static HoursOfServiceBalance unlimited(String ruleset) {
            return new HoursOfServiceBalance(ruleset, Duration.ofHours(24), Duration.ofHours(24),
                    Duration.ZERO, false, null);
        }

        public boolean canDrive() {
            return blockedBy == null && !remainingDriving.isZero();
        }

        /** 응답 본문의 분 단위 필드. §0.2에 시간 단위 접미사 규칙이 따로 없어 분으로 통일한다. */
        public long remainingDrivingMinutes() {
            return remainingDriving.toMinutes();
        }
    }
}
