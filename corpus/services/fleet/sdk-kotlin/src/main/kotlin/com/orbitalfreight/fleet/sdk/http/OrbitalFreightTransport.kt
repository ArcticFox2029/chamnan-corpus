package com.orbitalfreight.fleet.sdk.http

import com.orbitalfreight.fleet.sdk.ErrorEnvelope
import com.orbitalfreight.fleet.sdk.FleetApiException
import java.io.IOException
import java.security.SecureRandom
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/**
 * SDK의 HTTP 바닥이다. §0.3의 필수 헤더 네 개를 모든 요청에 붙이고, 응답이 오류면 §0.4 봉투를
 * [FleetApiException]으로 바꾸며, `retryable`이 참인 실패만 지수 백오프로 다시 시도한다.
 *
 * 재시도 정책이 이 클래스에 있는 이유는 한 곳에만 있어야 하기 때문이다. 호출부마다 재시도를
 * 흩어 놓으면 상류가 잠깐 죽었을 때 재시도가 곱해져서 폭풍이 된다 — 실제로 telemetry-ingest
 * 쪽에서 한 번 겪은 형태다.
 *
 * `X-OF-Idempotency-Key`는 GET이 아닌 요청에 자동으로 붙는다. 재시도할 때 키를 **바꾸지 않는
 * 것**이 핵심이다. 키를 새로 만들면 서버 입장에서는 다른 요청이라 배차가 두 건 생긴다.
 */
public class OrbitalFreightTransport(
    private val baseUrl: String,
    private val tenantId: String,
    private val tokenProvider: suspend () -> String,
    private val client: OkHttpClient = defaultClient(),
    private val json: Json = defaultJson(),
) {

    /** 재시도 상한. 이 이상은 사용자가 기다리지 않는다. */
    private val maxAttempts: Int = 4

    /** 첫 백오프. 이후 2배씩, 지터를 섞어 늘어난다. */
    private val initialBackoff: Duration = 250.milliseconds

    private val random = SecureRandom()

    /**
     * GET 요청 하나. 응답 본문을 [T]로 역직렬화한다.
     *
     * @param path `/v1/...`로 시작하는 경로. 서비스 표면은 전부 `/v1` 아래에 있다
     * @param traceId W3C trace-id 32자리 hex. 호출자가 이미 갖고 있으면 그대로 넘긴다 —
     *   그래야 fleet-service가 container-registry와 routing-service로 같은 트레이스를 이어 준다
     */
    public suspend inline fun <reified T> get(path: String, traceId: String): T =
        json.decodeFromString(execute(buildGet(path, traceId), traceId))

    /** 본문이 있는 POST. 멱등 키는 [idempotencyKey]로 고정한다. */
    public suspend inline fun <reified T> post(
        path: String,
        body: String,
        traceId: String,
        idempotencyKey: String,
    ): T = json.decodeFromString(execute(buildPost(path, body, traceId, idempotencyKey), traceId))

    public suspend fun buildGet(path: String, traceId: String): Request =
        Request.Builder()
            .url(baseUrl + path)
            .header("Authorization", "Bearer ${tokenProvider()}")
            .header("X-OF-Tenant", tenantId)
            .header("X-OF-Trace-Id", traceId)
            .header("X-OF-Actor-Kind", "user")
            .get()
            .build()

    public suspend fun buildPost(path: String, body: String, traceId: String, idempotencyKey: String): Request =
        Request.Builder()
            .url(baseUrl + path)
            .header("Authorization", "Bearer ${tokenProvider()}")
            .header("X-OF-Tenant", tenantId)
            .header("X-OF-Trace-Id", traceId)
            .header("X-OF-Actor-Kind", "user")
            .header("X-OF-Idempotency-Key", idempotencyKey)
            .post(body.toRequestBody(APPLICATION_JSON))
            .build()

    /**
     * 요청을 보내고, 재시도 가능한 실패면 백오프 후 다시 보낸다. 같은 [Request] 객체를 다시
     * 쓰기 때문에 멱등 키도 그대로 유지된다.
     */
    public suspend fun execute(request: Request, traceId: String): String {
        var attempt = 1
        var backoff = initialBackoff
        while (true) {
            val failure = try {
                return call(request)
            } catch (e: FleetApiException) {
                e
            }

            if (!failure.retryable || attempt >= maxAttempts) {
                throw failure
            }
            // 지터가 없으면 여러 클라이언트가 같은 순간에 동시에 재시도해 상류를 다시 눕힌다.
            val jitter = random.nextInt(100).milliseconds
            delay(backoff + jitter)
            backoff = minOf(backoff * 2, 4.seconds)
            attempt += 1
        }
    }

    private suspend fun call(request: Request): String = suspendCancellableCoroutine { continuation ->
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                val traceId = request.header("X-OF-Trace-Id").orEmpty()
                continuation.resumeWithException(FleetApiException.transport(e.message ?: "io failure", traceId))
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    val body = it.body?.string().orEmpty()
                    if (it.isSuccessful) {
                        continuation.resume(body)
                    } else {
                        continuation.resumeWithException(toException(body, it.code, request))
                    }
                }
            }
        })
    }

    /**
     * 오류 본문을 예외로 바꾼다. 봉투가 아닌 본문(게이트웨이가 만든 502 HTML 같은 것)이 올 때는
     * 코드가 없으므로 상태 코드만 보고 재시도 여부를 정한다.
     */
    private fun toException(body: String, status: Int, request: Request): FleetApiException =
        runCatching { json.decodeFromString<ErrorEnvelope>(body).toException() }
            .getOrElse {
                FleetApiException(
                    code = "unexpected_response",
                    httpStatus = status,
                    retryable = status >= 500 || status == 429,
                    traceId = request.header("X-OF-Trace-Id").orEmpty(),
                    fields = emptyList(),
                    message = "non-envelope response with status $status",
                )
            }

    public companion object {
        private val APPLICATION_JSON = "application/json; charset=utf-8".toMediaType()

        /**
         * 서버가 필드를 추가해도 깨지지 않도록 `ignoreUnknownKeys`를 켠다. §4.19.3과 같은 이유이며,
         * 이것을 끄면 배포 순서를 클라이언트가 강제하게 된다.
         */
        public fun defaultJson(): Json = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
            encodeDefaults = true
        }

        /** 배차 조회는 사용자 대기 경로다. 연결/읽기 타임아웃을 서버의 예산보다 짧게 잡는다. */
        public fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(java.time.Duration.ofSeconds(2))
            .readTimeout(java.time.Duration.ofSeconds(8))
            .retryOnConnectionFailure(false) // 재시도는 위쪽 execute가 전담한다
            .build()
    }
}
