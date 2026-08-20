package com.orbitalfreight.fleet.grpc;

import com.google.protobuf.Any;
import com.google.rpc.Code;
import com.orbitalfreight.fleet.client.CallContext;
import com.orbitalfreight.fleet.domain.VehicleAssignment;
import com.orbitalfreight.fleet.domain.VehicleAssignment.ReleaseReason;
import com.orbitalfreight.fleet.error.FleetException;
import com.orbitalfreight.fleet.hos.HoursOfServiceCalculator.HoursOfServiceBalance;
import com.orbitalfreight.fleet.service.AssignmentService;
import com.orbitalfreight.fleet.service.AssignmentService.AssignCommand;
import com.orbitalfreight.fleet.service.AssignmentService.AssignmentOutcome;
import com.orbitalfreight.fleet.service.AssignmentService.ReleaseCommand;
import com.orbitalfreight.fleet.service.EligibilityService;
import com.orbitalfreight.gen.fleet.v1.AssignRequest;
import com.orbitalfreight.gen.fleet.v1.AssignResponse;
import com.orbitalfreight.gen.fleet.v1.CheckEligibilityRequest;
import com.orbitalfreight.gen.fleet.v1.CheckEligibilityResponse;
import com.orbitalfreight.gen.fleet.v1.FleetServiceGrpc;
import com.orbitalfreight.gen.fleet.v1.ReleaseRequest;
import com.orbitalfreight.gen.fleet.v1.ReleaseResponse;
import com.orbitalfreight.gen.platform.v1.ErrorEnvelope;
import com.orbitalfreight.gen.platform.v1.FieldViolation;
import io.grpc.protobuf.StatusProto;
import io.grpc.stub.StreamObserver;
import java.time.Instant;
import java.util.Locale;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * {@code fleet.v1.FleetService}의 gRPC 표면이다. 포트 9082에 붙으며, 다른 서비스와 기사 앱이
 * 배차를 잡고 푸는 유일한 경로다. 여기서 하는 일은 요청 변환과 오류 변환뿐이고, 판단은 전부
 * {@code AssignmentService}와 {@code EligibilityService}에 있다.
 *
 * <p>세 개의 RPC 모두 인증은 인터셉터에서 끝난 상태로 들어온다. 인터셉터는
 * {@code identity.v1.TokenIntrospection/Introspect}를 부르고, identity-service가 닿지 않으면
 * {@code OF_IDENTITY_JWKS_GRACE_SECONDS} 동안 캐시된 JWKS로 서명만 검증한다(§1.2). 그 유예
 * 상태에서는 {@code X-OF-Actor-Kind: service}인 호출을 아예 거절하므로, 이 클래스에 도달한
 * 요청은 이미 사람이 낸 요청이거나 정상 introspection을 통과한 요청이다.</p>
 *
 * <p>오류는 §0.4의 봉투를 {@code google.rpc.Status.details}에 그대로 실어 보낸다. HTTP 표면과
 * 코드 문자열이 갈라지지 않게 하려는 것이며, Kotlin SDK는 두 표면에서 같은 코드로 분기한다.</p>
 */
@Component
public class FleetGrpcService extends FleetServiceGrpc.FleetServiceImplBase {

    private static final Logger log = LoggerFactory.getLogger(FleetGrpcService.class);

    private final AssignmentService assignmentService;
    private final EligibilityService eligibilityService;

    public FleetGrpcService(AssignmentService assignmentService, EligibilityService eligibilityService) {
        this.assignmentService = assignmentService;
        this.eligibilityService = eligibilityService;
    }

    /**
     * 차량과 기사를 구간 하나에 예약한다. 중복 예약의 최종 심판은 애플리케이션이 아니라
     * {@code fleet.vehicle_assignments}의 GiST exclusion 제약이다(§3.2).
     */
    @Override
    public void assign(AssignRequest request, StreamObserver<AssignResponse> observer) {
        CallContext ctx = GrpcCallContext.current();
        try {
            AssignmentOutcome outcome = assignmentService.assign(new AssignCommand(
                    request.getShipmentId(),
                    request.getLegId().isEmpty() ? null : request.getLegId(),
                    request.getVehicleId(),
                    request.getDriverId(),
                    request.getAssignedBy(),
                    request.getAllowCrossCarrier()), ctx);

            VehicleAssignment assignment = outcome.assignment();
            observer.onNext(AssignResponse.newBuilder()
                    .setAssignmentId(assignment.assignmentId())
                    .setShipmentId(assignment.shipmentId())
                    .setLegId(assignment.legId() == null ? "" : assignment.legId())
                    .setVehicleId(assignment.vehicleId())
                    .setDriverId(assignment.driverId())
                    .setAssignedAt(assignment.assignedAt().toString())
                    .addAllWarnings(outcome.eligibility().warnings())
                    .build());
            observer.onCompleted();
        } catch (FleetException e) {
            observer.onError(toStatusException(e, ctx));
        }
    }

    /**
     * 배차를 닫는다. 이미 닫혀 있으면 {@code released=false}로 성공 응답을 준다 — 멱등해야 하는
     * 호출이고, 두 번째 호출을 오류로 만들면 {@code route.replanned} 소비자가 재시도에 갇힌다.
     */
    @Override
    public void release(ReleaseRequest request, StreamObserver<ReleaseResponse> observer) {
        CallContext ctx = GrpcCallContext.current();
        try {
            Optional<VehicleAssignment> released = assignmentService.release(new ReleaseCommand(
                    request.getAssignmentId(),
                    parseReason(request.getReleaseReason()),
                    request.getDepotId().isEmpty() ? null : request.getDepotId(),
                    request.hasPosition() ? request.getPosition().getLat() : null,
                    request.hasPosition() ? request.getPosition().getLon() : null), ctx);

            observer.onNext(ReleaseResponse.newBuilder()
                    .setReleased(released.isPresent())
                    .setReleasedAt(released.map(a -> a.releasedAt().toString()).orElse(""))
                    .build());
            observer.onCompleted();
        } catch (FleetException e) {
            observer.onError(toStatusException(e, ctx));
        }
    }

    /**
     * 예약 없이 자격만 확인한다. 배차 화면이 후보 목록을 그릴 때 기사별로 부르므로 호출량이 많고,
     * 그래서 상류 호출을 하지 않는 경로만 탄다 — 근무 시간과 면허만 본다.
     *
     * <p>이 응답을 캐시해 두었다가 배차에 쓰면 안 된다. 사전 조회와 예약 사이에 기사가 상태를
     * 바꾸는 일이 실제로 일어나고, 그 간극을 메우는 것은 캐시가 아니라 exclusion 제약이다.</p>
     */
    @Override
    public void checkEligibility(CheckEligibilityRequest request,
                                 StreamObserver<CheckEligibilityResponse> observer) {
        try {
            HoursOfServiceBalance balance =
                    eligibilityService.driverAvailability(request.getDriverId(), Instant.now());
            observer.onNext(CheckEligibilityResponse.newBuilder()
                    .setEligible(balance.canDrive())
                    .setRuleset(balance.ruleset())
                    .setRemainingDrivingMinutes(balance.remainingDrivingMinutes())
                    .setBreakDue(balance.breakDue())
                    .setBlockedBy(balance.blockedBy() == null ? "" : balance.blockedBy())
                    .build());
            observer.onCompleted();
        } catch (FleetException e) {
            observer.onError(toStatusException(e, GrpcCallContext.current()));
        }
    }

    /**
     * §0.4의 봉투를 {@code google.rpc.Status}로 감싼다. gRPC 코드는 HTTP 상태에서 유도하되,
     * 소비자가 실제로 분기하는 값은 details 안의 {@code code} 문자열이다.
     */
    private io.grpc.StatusRuntimeException toStatusException(FleetException e, CallContext ctx) {
        log.info("fleet rpc rejected code={} retryable={} trace={}", e.code(), e.retryable(), ctx.traceId());
        com.google.rpc.Status status = com.google.rpc.Status.newBuilder()
                .setCode(toGrpcCode(e.httpStatus()).getNumber())
                .setMessage(e.getMessage())
                .addDetails(Any.pack(toEnvelope(e, ctx.traceId())))
                .build();
        return StatusProto.toStatusRuntimeException(status);
    }

    /** §0.4의 오류 봉투를 그대로 만든 proto 메시지. HTTP 응답 본문과 필드가 하나도 다르지 않다. */
    private static ErrorEnvelope toEnvelope(FleetException e, String traceId) {
        ErrorEnvelope.Builder envelope = ErrorEnvelope.newBuilder()
                .setCode(e.code())
                .setHttpStatus(e.httpStatus())
                .setMessage(e.getMessage())
                .setTraceId(traceId)
                .setRetryable(e.retryable());
        for (FleetException.FieldViolation violation : e.fields()) {
            envelope.addFields(FieldViolation.newBuilder()
                    .setPath(violation.path())
                    .setReason(violation.reason())
                    .build());
        }
        return envelope.build();
    }

    private static Code toGrpcCode(int httpStatus) {
        return switch (httpStatus) {
            case 403 -> Code.PERMISSION_DENIED;
            case 404 -> Code.NOT_FOUND;
            case 409 -> Code.ABORTED;
            case 422 -> Code.FAILED_PRECONDITION;
            case 503 -> Code.UNAVAILABLE;
            default -> Code.INTERNAL;
        };
    }

    private static ReleaseReason parseReason(String wire) {
        if (wire == null || wire.isEmpty()) {
            return ReleaseReason.COMPLETED;
        }
        return ReleaseReason.valueOf(wire.toUpperCase(Locale.ROOT));
    }
}
