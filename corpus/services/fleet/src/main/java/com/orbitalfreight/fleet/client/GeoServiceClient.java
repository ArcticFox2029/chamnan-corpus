package com.orbitalfreight.fleet.client;

import com.orbitalfreight.fleet.config.FleetProperties;
import com.orbitalfreight.fleet.error.FleetException;
import com.orbitalfreight.gen.geo.v1.GeoServiceGrpc;
import com.orbitalfreight.gen.geo.v1.Point;
import com.orbitalfreight.gen.geo.v1.PointInFenceRequest;
import com.orbitalfreight.gen.geo.v1.PointInFenceResponse;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.Metadata;
import io.grpc.StatusRuntimeException;
import io.grpc.stub.MetadataUtils;
import java.util.concurrent.TimeUnit;
import org.springframework.stereotype.Component;

/**
 * geo-service의 기하 판정을 부르는 얇은 어댑터다. fleet-service가 여기서 필요한 것은 하나뿐이다:
 * 배차를 반납할 때 차량이 실제로 도착 데포 지오펜스 안에 있는가.
 *
 * <p>{@code geo.v1.GeoService/PointInFence}는 배치 호출이고 {@code buffer_m}가 이미 적용되어
 * 돌아온다 — {@code geo.geofences.buffer_m}의 기본값 50 m가 GPS 오차를 흡수한다. 우리가 다시
 * 반경을 더하면 이중 보정이 되어 데포 옆 도로에 세운 차량도 "안에 있다"가 된다.</p>
 *
 * <p>§1.2의 Diamond A 때문에 {@code X-OF-Trace-Id}를 반드시 그대로 전달한다. 같은 배차 흐름에서
 * container-registry와 routing-service도 geo-service를 부르므로, 트레이스가 같으면
 * geo-service의 30초 캐시가 지오펜스 해석을 한 번만 하게 된다.</p>
 */
@Component
public class GeoServiceClient {

    private static final Metadata.Key<String> TENANT =
            Metadata.Key.of("x-of-tenant", Metadata.ASCII_STRING_MARSHALLER);
    private static final Metadata.Key<String> TRACE =
            Metadata.Key.of("x-of-trace-id", Metadata.ASCII_STRING_MARSHALLER);
    private static final Metadata.Key<String> AUTHORIZATION =
            Metadata.Key.of("authorization", Metadata.ASCII_STRING_MARSHALLER);

    private final ManagedChannel channel;

    public GeoServiceClient(FleetProperties properties) {
        this.channel = ManagedChannelBuilder.forTarget(properties.geoGrpcAddr())
                .usePlaintext()
                .keepAliveTime(30, TimeUnit.SECONDS)
                .build();
    }

    /**
     * 좌표 하나가 지오펜스 안에 있는지 묻는다.
     *
     * @param geofenceId {@code fleet.depots.geofence_id} 또는 시설 쪽 지오펜스 id
     * @param lat        WGS84 위도
     * @param lon        WGS84 경도
     * @return 안에 있으면 참. geo-service가 답하지 못하면 예외를 던지지 않고 거짓을 돌려주는
     *         쪽이 아니라, 판단 자체를 실패로 올린다 — "모르겠다"를 "밖에 있다"로 바꾸면
     *         반납이 조용히 막힌다
     */
    public boolean isInsideFence(String geofenceId, double lat, double lon, CallContext ctx) {
        Metadata headers = new Metadata();
        headers.put(TENANT, ctx.tenantId());
        headers.put(TRACE, ctx.traceId());
        headers.put(AUTHORIZATION, ctx.authorizationHeader());

        try {
            PointInFenceResponse response = GeoServiceGrpc.newBlockingStub(channel)
                    .withInterceptors(MetadataUtils.newAttachHeadersInterceptor(headers))
                    .withDeadlineAfter(1500, TimeUnit.MILLISECONDS)
                    .pointInFence(PointInFenceRequest.newBuilder()
                            .setGeofenceId(geofenceId)
                            .addPoints(Point.newBuilder().setLat(lat).setLon(lon).build())
                            .build());
            return !response.getInsideList().isEmpty() && response.getInside(0);
        } catch (StatusRuntimeException e) {
            throw FleetException.upstreamUnavailable("geo-service", e.getStatus().toString());
        }
    }

    /**
     * 반납 시 위치 확인을 아예 건너뛰어야 하는 경우를 한 곳에서 판단한다. 기사 앱이 좌표를 못 붙여
     * 보낸 경우(터널, 지하 물류센터)가 실제로 흔하고, 그때 반납을 막으면 차량이 계속 점유된 채
     * 남아 다음 배차가 exclusion 제약에 걸린다.
     */
    public boolean shouldVerifyPosition(Double lat, Double lon) {
        return lat != null && lon != null;
    }
}
