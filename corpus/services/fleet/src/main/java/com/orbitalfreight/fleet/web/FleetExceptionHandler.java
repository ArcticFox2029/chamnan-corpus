package com.orbitalfreight.fleet.web;

import com.orbitalfreight.fleet.error.FleetException;
import jakarta.servlet.http.HttpServletRequest;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/**
 * HTTP 표면에서 나가는 모든 오류를 §0.4의 봉투 한 가지 모양으로 통일한다. Spring이 기본으로
 * 만들어 주는 오류 본문은 이 계약과 다르기 때문에, 프레임워크 예외까지 여기서 잡아 다시 싼다.
 *
 * <p>{@code trace_id}는 반드시 채운다. 지원 문의가 들어왔을 때 이 값 하나로 fleet-service,
 * container-registry, routing-service, geo-service의 로그를 한 줄로 꿸 수 있고, 그게 없으면
 * "배차가 안 된다"는 신고를 재현부터 해야 한다.</p>
 *
 * <p>{@code retryable}은 클라이언트의 백오프를 직접 움직인다. Kotlin SDK는 이 값이 참일 때만
 * 재시도하므로, 여기서 아무 오류에나 참을 주면 상류가 죽었을 때 재시도 폭풍이 된다.</p>
 */
@RestControllerAdvice
public class FleetExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(FleetExceptionHandler.class);

    /** 우리가 의도적으로 던진 오류. 코드와 상태가 이미 정해져 있다. */
    @ExceptionHandler(FleetException.class)
    public ResponseEntity<Map<String, Object>> handleFleet(FleetException e, HttpServletRequest request) {
        String traceId = traceIdOf(request);
        if (e.httpStatus() >= 500) {
            log.error("fleet request failed code={} trace={}", e.code(), traceId, e);
        } else {
            log.info("fleet request rejected code={} trace={} path={}", e.code(), traceId, request.getRequestURI());
        }
        return ResponseEntity.status(e.httpStatus()).body(envelope(e.code(), e.httpStatus(), e.getMessage(),
                traceId, e.retryable(), e.fields()));
    }

    /**
     * 본문 파싱 실패, 타입 불일치 등 프레임워크가 던지는 400류. 코드는 하나로 묶는다 —
     * 클라이언트가 구분해서 할 수 있는 일이 없기 때문이다.
     */
    @ExceptionHandler({org.springframework.http.converter.HttpMessageNotReadableException.class,
            org.springframework.web.method.annotation.MethodArgumentTypeMismatchException.class,
            java.time.format.DateTimeParseException.class})
    public ResponseEntity<Map<String, Object>> handleMalformed(Exception e, HttpServletRequest request) {
        return ResponseEntity.status(400).body(envelope("request_malformed", 400,
                "request body or parameter could not be read: " + e.getMessage(),
                traceIdOf(request), false, List.of()));
    }

    /**
     * 나머지 전부. 메시지를 그대로 노출하지 않는다 — 스택에 담긴 SQL 조각이나 상류 주소가
     * 파트너에게 그대로 나가는 사고를 두 번 겪었다. 상세는 로그에만 남긴다.
     */
    @ExceptionHandler(Exception.class)
    public ResponseEntity<Map<String, Object>> handleUnexpected(Exception e, HttpServletRequest request) {
        String traceId = traceIdOf(request);
        log.error("unhandled exception trace={} path={}", traceId, request.getRequestURI(), e);
        return ResponseEntity.status(500).body(envelope("internal_error", 500,
                "fleet-service could not complete the request", traceId, true, List.of()));
    }

    private static Map<String, Object> envelope(String code, int status, String message, String traceId,
                                                boolean retryable, List<FleetException.FieldViolation> fields) {
        Map<String, Object> error = new LinkedHashMap<>();
        error.put("code", code);
        error.put("http_status", status);
        error.put("message", message);
        error.put("trace_id", traceId);
        error.put("retryable", retryable);
        error.put("fields", fields.stream()
                .map(f -> Map.of("path", f.path(), "reason", f.reason()))
                .toList());
        return Map.of("error", error);
    }

    /**
     * 엣지에서 붙여 주는 값이지만, 내부 도구가 직접 부를 때는 없을 수 있다. 없으면 빈 문자열로
     * 두고 새로 만들지 않는다 — 응답에 있는 트레이스가 실제로 로그에 없는 것보다 낫다.
     */
    private static String traceIdOf(HttpServletRequest request) {
        String traceId = request.getHeader("X-OF-Trace-Id");
        return traceId == null ? "" : traceId;
    }
}
