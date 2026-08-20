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
package com.orbitalfreight.fleet.grpc;

import com.orbitalfreight.fleet.client.CallContext;
import io.grpc.Context;
import io.grpc.Contexts;
import io.grpc.Metadata;
import io.grpc.ServerCall;
import io.grpc.ServerCallHandler;
import io.grpc.ServerInterceptor;
import io.grpc.Status;
import org.springframework.stereotype.Component;

/**
 * gRPC 요청의 §0.3 헤더를 읽어 {@link CallContext}로 만들고, 핸들러가 그것을 꺼내 쓸 수 있게
 * gRPC {@code Context}에 심는다. 상류로 나가는 모든 호출이 같은 테넌트와 같은 트레이스를 달고
 * 나가도록 만드는 지점이 여기 하나다.
 *
 * <p>토큰 자체의 검증은 이 인터셉터 앞단의 인증 인터셉터가
 * {@code identity.v1.TokenIntrospection/Introspect}로 이미 끝낸다. 여기서는 헤더가 형식적으로
 * 갖춰졌는지만 본다 — 테넌트가 없거나 트레이스가 32자 hex가 아니면 핸들러까지 보내지 않는다.
 * 트레이스가 없으면 새로 만들지 않고 거절하는데, gRPC 호출은 전부 서비스 간 호출이고 엣지에서
 * 이미 트레이스가 붙었어야 하기 때문이다. 여기서 새로 만들면 §1.2 Diamond A의 캐시 공유가
 * 조용히 깨진 채로 동작한다.</p>
 */
@Component
public class GrpcCallContext implements ServerInterceptor {

    private static final Context.Key<CallContext> CONTEXT_KEY = Context.key("of-call-context");

    private static final Metadata.Key<String> TENANT =
            Metadata.Key.of("x-of-tenant", Metadata.ASCII_STRING_MARSHALLER);
    private static final Metadata.Key<String> TRACE =
            Metadata.Key.of("x-of-trace-id", Metadata.ASCII_STRING_MARSHALLER);
    private static final Metadata.Key<String> AUTHORIZATION =
            Metadata.Key.of("authorization", Metadata.ASCII_STRING_MARSHALLER);
    private static final Metadata.Key<String> ACTOR_KIND =
            Metadata.Key.of("x-of-actor-kind", Metadata.ASCII_STRING_MARSHALLER);

    /** 현재 RPC의 문맥. 핸들러 스레드 밖에서 부르면 null이므로, 비동기 작업에는 넘겨 주어야 한다. */
    public static CallContext current() {
        return CONTEXT_KEY.get();
    }

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
            ServerCall<ReqT, RespT> call, Metadata headers, ServerCallHandler<ReqT, RespT> next) {

        String tenant = headers.get(TENANT);
        String trace = headers.get(TRACE);
        String authorization = headers.get(AUTHORIZATION);
        String actorKind = headers.get(ACTOR_KIND);

        if (tenant == null || trace == null || authorization == null) {
            call.close(Status.UNAUTHENTICATED.withDescription(
                    "X-OF-Tenant, X-OF-Trace-Id and Authorization are mandatory on every RPC"), new Metadata());
            return new ServerCall.Listener<>() {
            };
        }

        CallContext ctx;
        try {
            ctx = new CallContext(tenant, trace,
                    authorization.startsWith("Bearer ") ? authorization.substring(7) : authorization,
                    actorKind == null ? CallContext.ACTOR_SERVICE : actorKind);
        } catch (IllegalArgumentException e) {
            call.close(Status.INVALID_ARGUMENT.withDescription(e.getMessage()), new Metadata());
            return new ServerCall.Listener<>() {
            };
        }

        return Contexts.interceptCall(Context.current().withValue(CONTEXT_KEY, ctx), call, headers, next);
    }
}
