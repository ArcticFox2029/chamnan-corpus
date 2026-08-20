package com.orbitalfreight.fleet.client;

import java.util.UUID;

/**
 * 상류 서비스로 나가는 호출에 그대로 실어야 하는 요청 문맥이다. §0.3의 필수 헤더 네 개를
 * 한 덩어리로 묶어 두어, 클라이언트마다 헤더를 따로 챙기다가 하나를 빠뜨리는 일을 막는다.
 *
 * <p>{@code traceId}를 반드시 전파해야 하는 이유는 §1.2의 Diamond A다. 배차 한 건은
 * container-registry와 routing-service를 모두 부르고 두 서비스는 각각 geo-service를 부르는데,
 * 같은 {@code X-OF-Trace-Id}로 들어가야 geo-service가 30초짜리 트레이스 캐시로 같은 지오펜스
 * 해석을 두 번 하지 않는다. 트레이스를 새로 만들어 버리면 정확도는 같지만 geo-service 부하가
 * 두 배가 된다.</p>
 */
public record CallContext(String tenantId, String traceId, String bearerToken, String actorKind) {

    /** {@code X-OF-Actor-Kind}가 가질 수 있는 값 중 fleet-service가 실제로 보게 되는 것들. */
    public static final String ACTOR_USER = "user";
    public static final String ACTOR_SERVICE = "service";
    public static final String ACTOR_DEVICE = "device";

    public CallContext {
        if (tenantId == null || !tenantId.startsWith("tnt_")) {
            throw new IllegalArgumentException("X-OF-Tenant must be a tnt_ ULID, got: " + tenantId);
        }
        if (traceId == null || traceId.length() != 32) {
            throw new IllegalArgumentException("X-OF-Trace-Id must be 32 hex characters");
        }
    }

    /**
     * 배경 작업(아웃박스 릴레이, {@code route.replanned} 소비자)에서 쓰는 문맥. 사용자 요청이
     * 없으므로 트레이스를 새로 만들되, 행위자 종류는 {@code service}로 남겨 audit-ledger가
     * 사람이 한 일과 구분할 수 있게 한다.
     */
    public static CallContext forBackgroundWork(String tenantId, String serviceToken) {
        return new CallContext(tenantId, newTraceId(), serviceToken, ACTOR_SERVICE);
    }

    /** 이벤트 봉투의 {@code trace_id}에서 이어받은 문맥. 소비자 쪽에서 인과를 잇는 데 쓴다. */
    public static CallContext continuing(String tenantId, String traceIdFromEnvelope, String serviceToken) {
        return new CallContext(tenantId, traceIdFromEnvelope, serviceToken, ACTOR_SERVICE);
    }

    public String authorizationHeader() {
        return "Bearer " + bearerToken;
    }

    private static String newTraceId() {
        UUID uuid = UUID.randomUUID();
        return String.format("%016x%016x", uuid.getMostSignificantBits(), uuid.getLeastSignificantBits());
    }
}
