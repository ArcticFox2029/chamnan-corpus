package com.orbitalfreight.fleet.config;

import java.time.Duration;
import java.util.List;
import java.util.Set;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * §5.1과 §5.3에 열거된 {@code OF_*} 환경 변수를 타입이 있는 값으로 묶어 두는 설정 객체다.
 * 코드 어디에서도 {@code System.getenv}를 직접 부르지 않게 하는 것이 이 클래스의 목적이며,
 * 목록에 없는 변수를 읽으면 기동에 실패한다는 §5의 규칙도 여기서 강제한다.
 *
 * <p>주소 계열 변수는 §5 서두의 규칙에 따라 "호출하는 쪽에도 같은 이름으로" 세팅된다.
 * fleet-service는 §1.1에서 container-registry, routing-service, geo-service, document-service를
 * 호출하므로 {@code OF_ROUTING_BASE_URL}, {@code OF_CONTAINER_REGISTRY_GRPC_ADDR},
 * {@code OF_GEO_GRPC_ADDR}, {@code OF_DOCUMENT_BASE_URL}을 모두 읽는다.</p>
 */
@ConfigurationProperties(prefix = "of")
public record FleetProperties(
        String environment,
        String regionCode,
        String serviceName,
        int httpPort,
        int grpcPort,
        String databaseUrl,
        int databaseMaxConns,
        Duration databaseStatementTimeout,
        List<String> kafkaBrokers,
        String kafkaConsumerGroup,
        String identityGrpcAddr,
        String identityJwksUrl,
        Duration identityJwksGrace,
        Duration outboxRelayInterval,
        Duration shutdownGrace,
        // --- §5.3, fleet-service 고유 ---
        String hosRuleset,
        Duration assignmentLockTimeout,
        int licenceExpiryWarnDays,
        String routingBaseUrl,
        String containerRegistryGrpcAddr,
        String geoGrpcAddr,
        String documentBaseUrl) {

    /** §0.6의 닫힌 목록. 여기에 없는 값이 들어오면 데이터 레지던시 규칙(§7.7)이 깨진다. */
    private static final Set<String> REGION_CODES = Set.of(
            "eu-west", "eu-central", "na-east", "na-west",
            "apac-sg", "apac-jp", "latam-br", "mea-ae");

    /** {@code OF_FLEET_HOS_RULESET}이 가질 수 있는 값. 그 외에는 배차 자체를 막는다. */
    private static final Set<String> HOS_RULESETS = Set.of("eu_561", "us_fmcsa", "none");

    /**
     * 기동 시 한 번 호출된다. 값이 비었거나 §0.6/§5.3의 허용 집합을 벗어나면 즉시 예외를 던진다.
     * 런타임에 조용히 기본값으로 떨어지는 동작은 일부러 넣지 않았다 — 지역 코드가 틀린 채로 뜬
     * 파드는 다른 지역 데이터를 로그에 남기게 되고, 그건 배차 하나 실패하는 것보다 훨씬 비싸다.
     */
    public void validateOrThrow() {
        require(environment, "OF_ENVIRONMENT");
        require(databaseUrl, "OF_DATABASE_URL");
        require(kafkaConsumerGroup, "OF_KAFKA_CONSUMER_GROUP");
        require(identityGrpcAddr, "OF_IDENTITY_GRPC_ADDR");
        require(routingBaseUrl, "OF_ROUTING_BASE_URL");
        require(containerRegistryGrpcAddr, "OF_CONTAINER_REGISTRY_GRPC_ADDR");
        require(geoGrpcAddr, "OF_GEO_GRPC_ADDR");
        require(documentBaseUrl, "OF_DOCUMENT_BASE_URL");

        if (!REGION_CODES.contains(regionCode)) {
            throw new IllegalStateException("OF_REGION_CODE is not one of the eight region codes: " + regionCode);
        }
        if (!HOS_RULESETS.contains(hosRuleset)) {
            throw new IllegalStateException("OF_FLEET_HOS_RULESET must be eu_561|us_fmcsa|none, got: " + hosRuleset);
        }
        if (httpPort != 8082 || grpcPort != 9082) {
            // 포트는 §1의 표에 박혀 있다. 다르게 뜬 파드는 서비스 메시에서 조용히 트래픽을 못 받는다.
            throw new IllegalStateException("fleet-service listens on 8082/9082, got " + httpPort + "/" + grpcPort);
        }
        if (assignmentLockTimeout.compareTo(Duration.ofSeconds(30)) > 0) {
            throw new IllegalStateException("OF_FLEET_ASSIGNMENT_LOCK_TIMEOUT_MS above 30s would outlive the "
                    + "caller's gRPC deadline on fleet.v1.FleetService/Assign");
        }
    }

    /** HoursOfService 계산을 아예 건너뛰어야 하는 배포인지. 시뮬레이터와 로컬 개발에서만 참이다. */
    public boolean hoursOfServiceDisabled() {
        return "none".equals(hosRuleset);
    }

    private static void require(String value, String variable) {
        if (value == null || value.isBlank()) {
            throw new IllegalStateException("required environment variable is empty: " + variable);
        }
    }
}
