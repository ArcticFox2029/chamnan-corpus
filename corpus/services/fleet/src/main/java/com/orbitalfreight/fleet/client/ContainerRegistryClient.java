package com.orbitalfreight.fleet.client;

import com.orbitalfreight.fleet.config.FleetProperties;
import com.orbitalfreight.fleet.error.FleetException;
import com.orbitalfreight.gen.freight.v1.ContainerLookupGrpc;
import com.orbitalfreight.gen.freight.v1.ResolveShipmentForContainerRequest;
import com.orbitalfreight.gen.freight.v1.ResolveShipmentForContainerResponse;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.Metadata;
import io.grpc.StatusRuntimeException;
import io.grpc.stub.MetadataUtils;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

/**
 * container-registry를 부르는 쪽 어댑터다. 배차를 잡기 전에 화물이 실제로 존재하고 배차 가능한
 * 상태인지 확인하고, 컨테이너 번호만 아는 호출자를 위해 화물 id를 역으로 찾아 준다.
 *
 * <p>두 가지 전송을 함께 쓴다. 컨테이너→화물 역참조는 뜨거운 경로라 gRPC
 * {@code freight.v1.ContainerLookup/ResolveShipmentForContainer}를 쓰고
 * ({@code OF_CONTAINER_REGISTRY_GRPC_ADDR}), 화물 상세는 {@code GET /v1/shipments/{shipment_id}}를
 * 쓴다. §5에 container-registry용 HTTP base URL 변수가 없는 것은 실수가 아니다 — §1의
 * 클러스터 내부 DNS 규칙({@code http://<service-name>.orbitalfreight.svc.cluster.local:<http_port>})
 * 으로 주소를 만들게 되어 있고, 새 환경 변수를 만들려면 §5를 먼저 고쳐야 한다(§7.1).</p>
 */
@Component
public class ContainerRegistryClient {

    private static final String HTTP_BASE =
            "http://container-registry.orbitalfreight.svc.cluster.local:8083";

    /** 배차를 허용하는 화물 상태. 나머지는 §2.3의 CHECK 목록에 있지만 배차 대상이 아니다. */
    private static final List<String> ASSIGNABLE_STATUSES = List.of("booked", "sealed", "in_transit", "at_risk");

    private static final Metadata.Key<String> TENANT =
            Metadata.Key.of("x-of-tenant", Metadata.ASCII_STRING_MARSHALLER);
    private static final Metadata.Key<String> TRACE =
            Metadata.Key.of("x-of-trace-id", Metadata.ASCII_STRING_MARSHALLER);
    private static final Metadata.Key<String> AUTHORIZATION =
            Metadata.Key.of("authorization", Metadata.ASCII_STRING_MARSHALLER);

    private final ManagedChannel channel;
    private final RestClient http;

    public ContainerRegistryClient(FleetProperties properties, RestClient.Builder builder) {
        this.channel = ManagedChannelBuilder.forTarget(properties.containerRegistryGrpcAddr())
                .usePlaintext() // 메시 내부 mTLS가 이미 걸려 있다. 애플리케이션 TLS는 이중이 된다.
                .keepAliveTime(30, TimeUnit.SECONDS)
                .build();
        this.http = builder.baseUrl(HTTP_BASE).build();
    }

    /**
     * 화물 상세를 읽고 배차 가능한 상태인지 판단한다. 상태 전이는 오직
     * {@code PATCH /v1/shipments/{shipment_id}/status}만이 할 수 있으므로, 여기서는 읽기만 하고
     * 상태를 바꾸려 시도하지 않는다 — 화물 상태의 주인은 container-registry다.
     *
     * @throws FleetException 화물이 없거나({@code 404}) 배차 불가 상태일 때
     */
    public ShipmentSnapshot loadAssignableShipment(String shipmentId, CallContext ctx) {
        ShipmentSnapshot snapshot;
        try {
            snapshot = http.get()
                    .uri("/v1/shipments/{shipment_id}", shipmentId)
                    .header("Authorization", ctx.authorizationHeader())
                    .header("X-OF-Tenant", ctx.tenantId())
                    .header("X-OF-Trace-Id", ctx.traceId())
                    .header("X-OF-Actor-Kind", ctx.actorKind())
                    .retrieve()
                    .body(ShipmentSnapshot.class);
        } catch (RuntimeException e) {
            throw FleetException.upstreamUnavailable("container-registry", e.getMessage());
        }
        if (snapshot == null) {
            throw FleetException.upstreamUnavailable("container-registry", "empty body for " + shipmentId);
        }
        if (!ASSIGNABLE_STATUSES.contains(snapshot.status())) {
            throw FleetException.shipmentNotAssignable(shipmentId, snapshot.status());
        }
        return snapshot;
    }

    /**
     * 기사 앱이 컨테이너 번호만 스캔했을 때 화물 id를 찾는다. telemetry-ingest가 쓰는 것과 같은
     * RPC이고, 그쪽이 초당 수천 번 부르는 경로라 우리도 데드라인을 짧게 잡는다.
     */
    public String resolveShipmentForContainer(String containerId, CallContext ctx) {
        Metadata headers = new Metadata();
        headers.put(TENANT, ctx.tenantId());
        headers.put(TRACE, ctx.traceId());
        headers.put(AUTHORIZATION, ctx.authorizationHeader());

        try {
            ResolveShipmentForContainerResponse response = ContainerLookupGrpc.newBlockingStub(channel)
                    .withInterceptors(MetadataUtils.newAttachHeadersInterceptor(headers))
                    .withDeadlineAfter(Duration.ofSeconds(2).toMillis(), TimeUnit.MILLISECONDS)
                    .resolveShipmentForContainer(ResolveShipmentForContainerRequest.newBuilder()
                            .setContainerId(containerId)
                            .build());
            return response.getShipmentId();
        } catch (StatusRuntimeException e) {
            throw FleetException.upstreamUnavailable("container-registry", e.getStatus().toString());
        }
    }

    /**
     * {@code GET /v1/shipments/{shipment_id}}의 응답 중 배차에 필요한 부분만 옮긴 것이다.
     * 응답 본문에는 이보다 훨씬 많은 필드가 있지만 §4.19.3에 따라 모르는 필드는 그냥 버린다.
     *
     * @param hazardClassCodes 컨테이너들의 위험물 등급 합집합. 비어 있지 않으면 ADR 자격이 필요하다
     * @param totalGrossKg     {@code freight.shipment_containers.gross_kg}의 합계, 정수 kg(§0.2)
     */
    public record ShipmentSnapshot(
            String shipmentId,
            String tenantId,
            String status,
            String regionCode,
            String originFacilityId,
            String destinationFacilityId,
            List<String> hazardClassCodes,
            int totalGrossKg,
            boolean requiresReefer) {

        public boolean isDangerousGoods() {
            return hazardClassCodes != null && !hazardClassCodes.isEmpty();
        }
    }
}
