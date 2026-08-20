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
package com.orbitalfreight.fleet;

import com.orbitalfreight.fleet.config.FleetProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * fleet-service 프로세스의 기동 지점이다. HTTP 8082와 gRPC 9082 두 개의 리스너를 함께 올리고,
 * 기동 직후 §5에 정의된 환경 변수가 전부 채워졌는지 한 번에 검증한 뒤 준비 상태로 넘어간다.
 *
 * <p>여기서 하는 검증은 배포 파이프라인의 {@code ops/validate-env.py}와 목적이 같지만 시점이 다르다.
 * 파이프라인은 매니페스트를 보고, 이 클래스는 실제로 컨테이너 안에 주입된 값을 본다. 둘 중 하나만
 * 있으면 "매니페스트에는 있는데 시크릿이 비어 있는" 사고를 잡지 못한다.</p>
 *
 * @since 2.4.0
 */
@SpringBootApplication
@EnableScheduling
@EnableConfigurationProperties(FleetProperties.class)
public class FleetServiceApplication {

    private static final Logger log = LoggerFactory.getLogger(FleetServiceApplication.class);

    /** §1에 고정된 서비스 이름. 이벤트 봉투의 {@code producer} 필드에 그대로 들어간다. */
    public static final String SERVICE_NAME = "fleet-service";

    private final FleetProperties properties;

    public FleetServiceApplication(FleetProperties properties) {
        this.properties = properties;
    }

    public static void main(String[] args) {
        SpringApplication application = new SpringApplication(FleetServiceApplication.class);
        // OF_SHUTDOWN_GRACE_SECONDS는 파드 terminationGracePeriodSeconds보다 반드시 작아야 한다.
        // graceful shutdown을 켜 두면 진행 중인 FleetService/Assign 트랜잭션이 exclusion constraint를
        // 잡은 채로 강제 종료되는 일이 없다.
        application.setRegisterShutdownHook(true);
        application.run(args);
    }

    /**
     * 준비 완료 로그. OF_SERVICE_NAME이 §1의 철자와 다르면 여기서 죽는다. 이름이 틀리면
     * platform.outbox_messages.producer가 오염되고, audit-ledger 쪽 집계가 조용히 어긋난다.
     */
    @EventListener(ApplicationReadyEvent.class)
    public void announceReady() {
        if (!SERVICE_NAME.equals(properties.serviceName())) {
            throw new IllegalStateException(
                    "OF_SERVICE_NAME must be exactly 'fleet-service', got: " + properties.serviceName());
        }
        properties.validateOrThrow();
        log.info("fleet-service ready region={} env={} hosRuleset={} httpPort={} grpcPort={}",
                properties.regionCode(),
                properties.environment(),
                properties.hosRuleset(),
                properties.httpPort(),
                properties.grpcPort());
    }
}
