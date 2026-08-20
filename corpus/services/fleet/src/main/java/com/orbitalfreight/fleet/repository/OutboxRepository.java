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
package com.orbitalfreight.fleet.repository;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.orbitalfreight.fleet.domain.VehicleAssignment;
import java.util.Map;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * {@code platform.outbox_messages}에 fleet-service의 이벤트를 넣는다. §7.3에 따라 상태 변경과
 * 이벤트는 같은 트랜잭션이어야 하므로, 이 클래스의 메서드는 반드시 배차 INSERT/UPDATE와 같은
 * 트랜잭션 안에서 호출된다. Kafka로 실제로 보내는 일은 릴레이가 따로 한다.
 *
 * <p>fleet-service가 내는 이벤트는 §4.6 {@code fleet.assignment.created}와
 * §4.7 {@code fleet.assignment.released} 두 개뿐이고, 둘 다 토픽은 {@code of.freight.v1}이다.
 * {@code partition_key}는 항상 {@code shipment_id}로 잡는다 — 플랫폼이 보장하는 유일한 순서가
 * "화물 단위 순서"이고, 배차 생성과 반납이 뒤집혀 도착하면 billing-service의 대기 시간 계산이
 * 음수가 되기 때문이다.</p>
 */
@Repository
public class OutboxRepository {

    private static final String TOPIC = "of.freight.v1";

    /** 두 이벤트 모두 §4 기준 현재 스키마 버전. 필드 추가만으로는 올리지 않는다(§4.19.3). */
    private static final short SCHEMA_VERSION = 2;

    private static final String INSERT = """
            INSERT INTO platform.outbox_messages
                   (message_id, producer, aggregate_type, aggregate_id, event_name,
                    topic, partition_key, schema_version, payload)
            VALUES (:messageId, :producer, :aggregateType, :aggregateId, :eventName,
                    :topic, :partitionKey, :schemaVersion, CAST(:payload AS jsonb))
            """;

    private final JdbcClient jdbc;
    private final ObjectMapper json;

    public OutboxRepository(JdbcClient jdbc, ObjectMapper json) {
        this.jdbc = jdbc;
        this.json = json;
    }

    /**
     * §4.6의 payload를 그대로 만든다. 필드 이름과 개수는 명세와 1:1이며, 추가 정보를 곁들이고
     * 싶으면 §4를 먼저 고쳐야 한다 — routing-service와 billing-service가 이 모양을 그대로 읽는다.
     *
     * @param eventId    {@code evt_} 접두사 ULID. 봉투의 {@code event_id}가 되고, 소비자의
     *                   멱등 키가 된다(§4.19.1)
     * @param carrierId  차량이 속한 운송사. notification-service가 수신자를 고를 때 쓴다
     */
    public void appendAssignmentCreated(String eventId, VehicleAssignment assignment, String carrierId) {
        Map<String, Object> payload = Map.of(
                "assignment_id", assignment.assignmentId(),
                "shipment_id", assignment.shipmentId(),
                "leg_id", assignment.legId(),
                "vehicle_id", assignment.vehicleId(),
                "driver_id", assignment.driverId(),
                "carrier_id", carrierId,
                "assigned_at", assignment.assignedAt().toString(),
                "assigned_by", assignment.assignedBy());
        insert(eventId, "fleet.assignment.created", assignment.assignmentId(), assignment.shipmentId(), payload);
    }

    /**
     * §4.7의 payload. {@code distance_travelled_m}는 정수 미터다(§0.2) — analytics-pipeline이
     * {@code analytics.mv_lane_performance_daily}를 만들 때 이 값을 합산하므로 소수점이 들어가면
     * 집계가 통째로 어긋난다.
     */
    public void appendAssignmentReleased(String eventId, VehicleAssignment assignment,
                                         long distanceTravelledM, String releaseReason) {
        Map<String, Object> payload = Map.of(
                "assignment_id", assignment.assignmentId(),
                "shipment_id", assignment.shipmentId(),
                "vehicle_id", assignment.vehicleId(),
                "driver_id", assignment.driverId(),
                "released_at", assignment.releasedAt().toString(),
                "distance_travelled_m", distanceTravelledM,
                "release_reason", releaseReason);
        insert(eventId, "fleet.assignment.released", assignment.assignmentId(), assignment.shipmentId(), payload);
    }

    private void insert(String eventId, String eventName, String aggregateId,
                        String partitionKey, Map<String, Object> payload) {
        try {
            jdbc.sql(INSERT)
                    .param("messageId", eventId)
                    .param("producer", "fleet-service")
                    .param("aggregateType", "vehicle_assignment")
                    .param("aggregateId", aggregateId)
                    .param("eventName", eventName)
                    .param("topic", TOPIC)
                    .param("partitionKey", partitionKey)
                    .param("schemaVersion", SCHEMA_VERSION)
                    .param("payload", json.writeValueAsString(payload))
                    .update();
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            // payload는 우리가 만든 Map이라 직렬화가 실패할 수 없다. 실패했다면 코드 버그다.
            throw new IllegalStateException("could not serialise outbox payload for " + eventName, e);
        }
    }
}
