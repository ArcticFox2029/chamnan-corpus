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
package com.orbitalfreight.fleet.sdk

import com.orbitalfreight.fleet.sdk.model.DutyStatusPost
import java.util.ArrayDeque
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 기사 앱이 오프라인일 때 근무 상태 변경을 쌓아 두었다가, 연결이 돌아오면 발생 순서대로
 * `POST /v1/drivers/{driver_id}/hours-of-service`에 밀어 넣는 큐다.
 *
 * 이런 것이 SDK 안에 있는 이유는 두 앱(apps/driver-ios의 코틀린 공유 모듈,
 * apps/inspector-android)이 같은 실수를 각자 하게 두지 않기 위해서다. 실수는 늘 같은
 * 두 가지였다: 재전송할 때 멱등 키를 새로 만들어 중복 기록을 만드는 것, 그리고 밀린 항목을
 * 수신 순서대로 보내 근무 시간 계산을 뒤집어 놓는 것.
 *
 * 큐는 발생 시각 순서를 지키고, 각 항목의 멱등 키를 `driver:occurred_at:status`로 고정한다.
 * 서버는 같은 키의 재전송을 같은 항목으로 덮어쓰므로 몇 번을 다시 보내도 결과가 같다.
 */
public class DutyStatusQueue(
    private val client: FleetClient,
    private val driverId: String,
) {

    private val pending = ArrayDeque<DutyStatusPost>()
    private val mutex = Mutex()

    /** 큐에 남아 있는 항목 수. 앱이 "동기화 대기 3건" 배지를 그릴 때 쓴다. */
    public suspend fun pendingCount(): Int = mutex.withLock { pending.size }

    /**
     * 상태 변경을 큐에 넣는다. 온라인이면 곧바로 [flush]를 부르면 되고, 오프라인이면 그냥
     * 쌓인다. 발생 시각을 앱이 직접 찍는다는 점이 중요하다 — 서버 시각으로 다시 찍으면
     * 터널을 지나는 두 시간이 통째로 사라진다.
     */
    public suspend fun enqueue(post: DutyStatusPost) {
        mutex.withLock {
            pending.addLast(post)
        }
    }

    /**
     * 밀린 항목을 발생 순서대로 보낸다. 하나가 재시도 불가 오류로 거절되면 그 항목만 버리고
     * 계속 진행한다 — 예를 들어 기기 시계가 앞서 있어 `duty_status_in_the_future`로 거절된
     * 항목은 몇 번을 보내도 같은 답이 오고, 그것 때문에 뒤의 정상 항목까지 막히면 안 된다.
     *
     * @return 서버가 받아들인 항목 수
     * @throws FleetApiException 전송 자체가 계속 실패할 때(연결 없음). 이때 큐는 그대로 남는다
     */
    public suspend fun flush(): Int = mutex.withLock {
        var accepted = 0
        val ordered = pending.sortedBy { it.occurredAt }
        pending.clear()

        for (post in ordered) {
            try {
                client.postDutyStatus(driverId, post)
                accepted += 1
            } catch (e: FleetApiException) {
                if (e.retryable) {
                    // 연결 문제나 상류 장애. 이 항목과 그 뒤를 전부 되돌려 놓고 나중에 다시 시도한다.
                    pending.addLast(post)
                    ordered.dropWhile { it !== post }.drop(1).forEach { pending.addLast(it) }
                    throw e
                }
                // 재시도해도 결과가 같은 거절. 버리되 흔적은 남긴다.
                dropped.add(post to e.code)
            }
        }
        accepted
    }

    /**
     * 서버가 영구히 거절한 항목들. 앱은 이것을 기사에게 보여 주고 수동 정정을 유도한다 —
     * 조용히 사라지면 나중에 근무 시간 감사에서 설명할 수 없는 공백이 된다.
     */
    public val dropped: MutableList<Pair<DutyStatusPost, String>> = mutableListOf()
}
