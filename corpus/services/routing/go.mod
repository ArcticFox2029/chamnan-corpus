// Module của routing-service. Tên module theo đúng đường dẫn trong repo (services/routing/),
// còn các stub gRPC sinh sẵn cho geo-service và identity-service nằm ngoài module này,
// dưới libs/gen/go/ theo quy ước §6.4 và không bao giờ được sửa tay.
module github.com/orbitalfreight/platform/services/routing

go 1.22

require (
	github.com/jackc/pgx/v5 v5.5.5
	github.com/oklog/ulid/v2 v2.1.0
	github.com/orbitalfreight/platform/libs v0.0.0
	github.com/prometheus/client_golang v1.19.0
	github.com/segmentio/kafka-go v0.4.47
	go.opentelemetry.io/otel v1.25.0
	go.opentelemetry.io/otel/trace v1.25.0
	google.golang.org/grpc v1.63.2
)

// libs/ nằm cùng repo, không xuất bản ra proxy.
replace github.com/orbitalfreight/platform/libs => ../../libs
