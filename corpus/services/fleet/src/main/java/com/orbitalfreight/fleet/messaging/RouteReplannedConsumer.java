package com.orbitalfreight.fleet.messaging;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.orbitalfreight.fleet.client.CallContext;
import com.orbitalfreight.fleet.domain.VehicleAssignment;
import com.orbitalfreight.fleet.service.AssignmentService;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Supplier;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

/**
 * {@code of.platform.v1} 토픽에서 {@code route.replanned}를 받아, 사라진 구간에 걸려 있던 배차를
 * 반납한다. §4.11에 적힌 대로 fleet-service가 이 이벤트를 소비하는 이유가 정확히 이것이다 —
 * routing-service가 경로를 다시 짜면 {@code leg_id}가 통째로 바뀌고, 그대로 두면 차량과 기사가
 * 존재하지 않는 구간에 묶인 채 exclusion 제약에 걸려 다음 배차를 막는다.
 *
 * <p>이 핸들러는 절대 routing-service를 "다시 계획해 달라"고 부르지 않는다. 읽기 호출은
 * §1.1에 있는 정상 간선이지만, 소비 핸들러 안에서 발행자에게 되쏘는 쓰기는 §4.19.2가 금지한
 * 바로 그 형태다. 여기서 하는 상류 호출은 현재 경로를 확인하는 조회 하나뿐이다.</p>
 *
 * <p>멱등성은 {@code event_id} 기준이다(§4.19.1). {@code of.platform.v1}의 보존 기간이 30일이라
 * 본 이벤트 집합도 같은 기간을 들고 있는다. 여덟 번 실패하면 {@code of.platform.v1.dlq}로 간다.</p>
 */
@Component
public class RouteReplannedConsumer {

    private static final Logger log = LoggerFactory.getLogger(RouteReplannedConsumer.class);

    /** {@code of.platform.v1}의 보존 기간과 같다. 그보다 짧으면 재생 시 중복 처리가 생긴다. */
    private static final Duration SEEN_TTL = Duration.ofDays(30);

    private static final String SEEN_KEY_PREFIX = "fleet:seen:";

    private final AssignmentService assignments;
    private final StringRedisTemplate redis;
    private final ObjectMapper json;
    private final Supplier<String> serviceToken;

    public RouteReplannedConsumer(AssignmentService assignments,
                                  StringRedisTemplate redis,
                                  ObjectMapper json,
                                  @Qualifier("serviceAccessToken") Supplier<String> serviceToken) {
        this.assignments = assignments;
        this.redis = redis;
        this.json = json;
        this.serviceToken = serviceToken;
    }

    /**
     * 봉투(§0.7)를 풀고 {@code route.replanned}만 처리한다. 같은 토픽에 document-service,
     * notification-service, reconciliation-service의 이벤트도 흐르므로 이름으로 먼저 거른다.
     *
     * @param record Kafka 레코드. 키는 봉투의 {@code partition_key}, 즉 {@code shipment_id}다
     */
    @KafkaListener(topics = "of.platform.v1", groupId = "${of.kafka-consumer-group}")
    public void onMessage(ConsumerRecord<String, String> record) throws Exception {
        JsonNode envelope = json.readTree(record.value());
        String eventName = envelope.path("event_name").asText();
        if (!"route.replanned".equals(eventName)) {
            return;
        }

        String eventId = envelope.path("event_id").asText();
        if (!markSeen(eventId)) {
            // 이미 처리한 이벤트. 최소 한 번 배달이므로 이 경로는 실제로 매일 탄다.
            log.debug("skipping already-processed event {}", eventId);
            return;
        }

        JsonNode payload = envelope.path("payload");
        String shipmentId = payload.path("shipment_id").asText();
        List<String> changedLegIds = new ArrayList<>();
        payload.path("legs_changed").forEach(node -> changedLegIds.add(node.asText()));

        if (changedLegIds.isEmpty()) {
            // 거리나 ETA만 바뀐 replan. 구간 id가 그대로면 배차도 그대로 유효하다.
            log.debug("replan of shipment {} changed no legs, nothing to release", shipmentId);
            return;
        }

        CallContext ctx = CallContext.continuing(
                envelope.path("tenant_id").asText(),
                envelope.path("trace_id").asText(),
                serviceToken.get());

        List<VehicleAssignment> released =
                assignments.releaseSupersededLegs(shipmentId, changedLegIds, ctx);

        log.info("route.replanned shipment={} version={}->{} releasedAssignments={} trace={}",
                shipmentId,
                payload.path("previous_version").asInt(),
                payload.path("version").asInt(),
                released.size(),
                ctx.traceId());
    }

    /**
     * 처음 보는 이벤트면 참. Redis의 {@code SET NX}를 그대로 쓴다 — 파드가 여러 개라 인메모리
     * 집합으로는 안 되고, 이 판정은 재처리를 막을 뿐 정확성의 최후 보루는 아니다.
     * 실제로 두 번 처리되더라도 반납은 멱등이라 두 번째는 조용히 아무 일도 하지 않는다.
     */
    private boolean markSeen(String eventId) {
        Boolean first = redis.opsForValue().setIfAbsent(SEEN_KEY_PREFIX + eventId, "1", SEEN_TTL);
        return Boolean.TRUE.equals(first);
    }
}
