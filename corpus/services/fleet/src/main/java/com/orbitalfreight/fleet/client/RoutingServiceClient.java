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
package com.orbitalfreight.fleet.client;

import com.orbitalfreight.fleet.config.FleetProperties;
import com.orbitalfreight.fleet.error.FleetException;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

/**
 * routing-service에서 현재 경로와 구간을 읽어 온다. 배차는 언제나 "구간 하나"에 붙으므로
 * {@code leg_id}가 지금 유효한 경로에 속해 있는지, 그 구간의 운송 수단이 무엇인지,
 * 계획 소요 시간이 얼마인지를 여기서 확인한 뒤에야 {@code fleet.vehicle_assignments}에 넣는다.
 *
 * <p>{@code OF_ROUTING_BASE_URL}을 쓴다. routing-service는 gRPC 표면이 없으므로 HTTP만 있다.
 * 응답의 구간 목록은 {@code routing.route_legs}의 행을 그대로 옮긴 것이고,
 * {@code is_current}가 참인 경로 하나만 돌아온다 — 지난 버전을 보고 배차하면
 * {@code route.replanned} 소비자가 곧바로 그 배차를 반납해 버린다.</p>
 */
@Component
public class RoutingServiceClient {

    /** 배차 판정은 사용자 대기 경로라 짧게 끊는다. 경로 계획 자체보다 훨씬 가벼운 조회다. */
    private static final Duration READ_TIMEOUT = Duration.ofSeconds(3);

    private final RestClient http;

    public RoutingServiceClient(FleetProperties properties, RestClient.Builder builder) {
        this.http = builder.baseUrl(properties.routingBaseUrl()).build();
    }

    /**
     * 화물의 현재 경로를 읽는다. {@code GET /v1/shipments/{shipment_id}/route}는 언제나
     * {@code is_current} 경로만 돌려준다.
     *
     * @throws FleetException routing-service가 예산 안에 답하지 않으면 재시도 가능 오류로 올린다
     */
    public CurrentRoute currentRoute(String shipmentId, CallContext ctx) {
        try {
            CurrentRoute route = http.get()
                    .uri("/v1/shipments/{shipment_id}/route", shipmentId)
                    .header("Authorization", ctx.authorizationHeader())
                    .header("X-OF-Tenant", ctx.tenantId())
                    // Diamond A(§1.2): 이 트레이스가 그대로 geo-service까지 내려가야
                    // container-registry 경유 호출과 지오펜스 해석 캐시를 공유한다.
                    .header("X-OF-Trace-Id", ctx.traceId())
                    .header("X-OF-Actor-Kind", ctx.actorKind())
                    .retrieve()
                    .body(CurrentRoute.class);
            if (route == null) {
                throw FleetException.upstreamUnavailable("routing-service", "empty route body");
            }
            return route;
        } catch (FleetException e) {
            throw e;
        } catch (RuntimeException e) {
            throw FleetException.upstreamUnavailable("routing-service", e.getMessage());
        }
    }

    /**
     * 구간 하나를 현재 경로에서 찾는다. 없으면 replan이 방금 지나갔다는 뜻이라
     * {@code leg_not_on_current_route}로 거절한다 — 이 경우 호출자는 새 구간 id로 다시 시도해야 한다.
     */
    public RouteLeg requireLeg(String shipmentId, String legId, CallContext ctx) {
        return findLeg(shipmentId, legId, ctx)
                .orElseThrow(() -> FleetException.legNotOnCurrentRoute(legId, shipmentId));
    }

    public Optional<RouteLeg> findLeg(String shipmentId, String legId, CallContext ctx) {
        return currentRoute(shipmentId, ctx).legs().stream()
                .filter(leg -> leg.legId().equals(legId))
                .findFirst();
    }

    /**
     * {@code POST /v1/routes/{route_id}/replan} 이후 어떤 구간이 살아남았는지 확인할 때 쓴다.
     * {@code route.replanned} 이벤트에 이미 {@code legs_changed}가 들어 있지만, 이벤트는
     * 최소 한 번 배달이라 중복이 오고 순서가 밀릴 수 있어 반납 직전에 현재 경로를 한 번 더 본다.
     */
    public List<String> currentLegIds(String shipmentId, CallContext ctx) {
        return currentRoute(shipmentId, ctx).legs().stream().map(RouteLeg::legId).toList();
    }

    /** {@code GET /v1/shipments/{shipment_id}/route}의 응답 본문. */
    public record CurrentRoute(
            String routeId,
            String shipmentId,
            int version,
            String strategy,
            long totalDistanceM,
            int totalDurationS,
            List<RouteLeg> legs) {
    }

    /**
     * {@code routing.route_legs} 한 행. {@code crossingId}는 {@code geo.border_crossings}를
     * 가리키는 진짜 외래 키이며, 값이 있으면 이 구간에서 국경을 넘는다는 뜻이다 —
     * 그 경우 기사에게 ADR 서류와 통관 서류가 함께 필요할 수 있다.
     */
    public record RouteLeg(
            String legId,
            int seqNo,
            String mode,
            String fromFacilityId,
            String toFacilityId,
            String crossingId,
            Instant plannedDepartAt,
            Instant plannedArriveAt,
            long distanceM,
            String carrierId) {

        /** 계획상 이 구간에 필요한 운전 시간. HoursOfServiceCalculator가 이 값과 잔여 시간을 비교한다. */
        public Duration plannedDuration() {
            return Duration.between(plannedDepartAt, plannedArriveAt);
        }

        public boolean crossesBorder() {
            return crossingId != null;
        }
    }
}
