/**
 * §0.5의 커서 페이지네이션을 [Flow]로 감싸, 목록 전체를 한 번에 순회할 수 있게 해 준다.
 * 커서를 손으로 돌리다 마지막 장을 빠뜨리거나 같은 장을 두 번 읽는 실수가 실제로 자주 나서
 * SDK 쪽에 한 번만 구현해 두었다.
 *
 * 플랫폼 어디에도 오프셋 페이지네이션은 없다. 배차 목록은 읽는 도중에도 계속 늘어나므로
 * 오프셋으로는 항상 항목이 겹치거나 빠진다 — 커서가 취향이 아니라 정확성 때문에 선택된 것이다.
 */

package com.orbitalfreight.fleet.sdk

import com.orbitalfreight.fleet.sdk.model.Assignment
import com.orbitalfreight.fleet.sdk.model.Page
import com.orbitalfreight.fleet.sdk.model.Vehicle
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * 페이지를 하나씩 가져오는 공통 순회기.
 *
 * @param fetch 커서를 받아 한 장을 가져오는 함수. 첫 호출에는 `null`이 들어간다
 */
public fun <T> pagesOf(fetch: suspend (String?) -> Page<T>): Flow<Page<T>> = flow {
    var cursor: String? = null
    do {
        val page = fetch(cursor)
        emit(page)
        cursor = page.nextCursor
    } while (cursor != null)
}

/** 페이지를 펴서 항목 단위로 흘려보낸다. 대부분의 호출자가 실제로 원하는 형태다. */
public fun <T> itemsOf(fetch: suspend (String?) -> Page<T>): Flow<T> = flow {
    pagesOf(fetch).collect { page -> page.items.forEach { emit(it) } }
}

/**
 * 운송사의 모든 차량. 큰 운송사는 차량이 수천 대라 한 장에 담기지 않는다.
 *
 * @param limit 한 장의 크기. 서버 상한은 200이고 그보다 크게 요청하면 422가 온다
 */
public fun FleetClient.vehiclesOf(
    carrierId: String,
    limit: Int = 200,
    traceId: String = FleetClient.newTraceId(),
): Flow<Vehicle> = itemsOf { cursor -> vehiclePage(carrierId, cursor, limit, traceId) }

/**
 * 화물에 걸린 배차 전체(반납된 것 포함). 감사 화면이 배차 이력을 재구성할 때 쓴다.
 *
 * 같은 [traceId]를 전 페이지에 걸쳐 그대로 쓰는 것이 의도다. 한 번의 논리적 조회이므로
 * 로그에서도 한 흐름으로 보이는 편이 맞다.
 */
public fun FleetClient.assignmentsOf(
    shipmentId: String,
    activeOnly: Boolean = false,
    traceId: String = FleetClient.newTraceId(),
): Flow<Assignment> = itemsOf { cursor ->
    assignmentPage(shipmentId = shipmentId, activeOnly = activeOnly, cursor = cursor, traceId = traceId)
}
