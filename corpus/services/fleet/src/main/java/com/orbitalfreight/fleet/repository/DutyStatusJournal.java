package com.orbitalfreight.fleet.repository;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.orbitalfreight.fleet.domain.DutyStatusChange;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Set;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * 기사별 근무 상태 변경의 "최근 36시간 창"을 들고 있는 저장소다. 영속 테이블이 아니라 Redis
 * sorted set을 쓰는 이유는 §2에 근무 로그 테이블이 없기 때문이며, 그건 누락이 아니라 결정이다 —
 * 법정 보존본은 기사 앱 쪽 ELD 기록이고 우리는 배차 판정에 필요한 만큼만 본다.
 *
 * <p>키는 {@code fleet:hos:{driver_id}}, 점수는 {@code occurred_at}의 epoch 초다. 기사 앱이
 * 오프라인 구간을 몰아서 올려도 점수 기준으로 자동 정렬되므로 재정렬 비용이 없고, 같은 순간에
 * 같은 상태가 재전송되면 같은 member로 덮어써져 중복이 생기지 않는다.</p>
 *
 * <p>창이 비어 있으면 {@code FleetRosterRepository.reconstructDutyWindow}로 채운다.
 * 캐시가 날아가도 배차가 멈추지 않게 하려는 것이고, 복원값은 실제보다 보수적이다.</p>
 */
@Component
public class DutyStatusJournal {

    private static final Logger log = LoggerFactory.getLogger(DutyStatusJournal.class);

    /** 창의 길이. EU 561의 일일 휴식(11시간)이 반드시 안에 들어오도록 넉넉하게 잡았다. */
    private static final Duration WINDOW = Duration.ofHours(36);

    private static final String KEY_PREFIX = "fleet:hos:";

    private final StringRedisTemplate redis;
    private final FleetRosterRepository roster;
    private final ObjectMapper json;

    public DutyStatusJournal(StringRedisTemplate redis, FleetRosterRepository roster, ObjectMapper json) {
        this.redis = redis;
        this.roster = roster;
        this.json = json;
    }

    /**
     * 상태 변경 하나를 창에 넣는다. {@code POST /v1/drivers/{driver_id}/hours-of-service}가
     * 유일한 진입점이며, 창 밖으로 밀려난 항목은 같은 호출에서 잘라낸다.
     */
    public void append(DutyStatusChange change) {
        String key = KEY_PREFIX + change.driverId();
        try {
            redis.opsForZSet().add(key, json.writeValueAsString(change), change.occurredAt().getEpochSecond());
            redis.expire(key, WINDOW.plusHours(2));
            trim(key, Instant.now().minus(WINDOW));
        } catch (Exception e) {
            // 창을 못 썼다고 요청을 실패시키지는 않는다. 다음 판정에서 vehicle_assignments 복원으로
            // 떨어질 뿐이고, 그쪽은 항상 보수적이라 안전 방향으로 틀린다.
            log.warn("could not append duty status for driver={} occurredAt={}: {}",
                    change.driverId(), change.occurredAt(), e.toString());
        }
    }

    /**
     * 판정에 쓸 창을 읽는다. 비어 있으면 배차 이력에서 복원하고, 복원한 결과는 다시 캐시하지
     * 않는다 — 복원값을 캐시하면 기사 앱이 올린 진짜 기록과 섞여 어느 쪽이 원본인지 알 수 없게 된다.
     */
    public List<DutyStatusChange> window(String driverId, Instant now) {
        Instant since = now.minus(WINDOW);
        String key = KEY_PREFIX + driverId;
        try {
            Set<String> raw = redis.opsForZSet().rangeByScore(key, since.getEpochSecond(), now.getEpochSecond());
            if (raw != null && !raw.isEmpty()) {
                return raw.stream().map(this::parse).filter(java.util.Objects::nonNull).toList();
            }
        } catch (Exception e) {
            log.warn("duty status window unavailable for driver={}, falling back to assignments: {}",
                    driverId, e.toString());
        }
        return roster.reconstructDutyWindow(driverId, since);
    }

    private void trim(String key, Instant cutoff) {
        redis.opsForZSet().removeRangeByScore(key, Double.NEGATIVE_INFINITY, cutoff.getEpochSecond());
    }

    private DutyStatusChange parse(String raw) {
        try {
            return json.readValue(raw, DutyStatusChange.class);
        } catch (Exception e) {
            // 스키마가 바뀐 옛날 항목. 버리는 편이 창 전체를 못 쓰게 되는 것보다 낫다.
            log.debug("dropping unreadable duty status entry: {}", raw);
            return null;
        }
    }
}
