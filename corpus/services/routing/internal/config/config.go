// Package config đọc và kiểm tra toàn bộ biến môi trường mà routing-service được phép dùng.
// Danh sách ở đây phải khớp từng chữ với §5.1 và §5.6 của SPEC: ops/validate-env.py so bộ
// biến đang chạy với chính tài liệu đó, nên một tên tự nghĩ ra sẽ làm hỏng bước triển khai
// chứ không phải làm hỏng service.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/domain"
)

// Config là ảnh chụp môi trường lúc khởi động. Không có gì trong đây được đọc lại khi service
// đang chạy — đổi cấu hình nghĩa là thay pod, đúng như mọi service khác trong nền tảng.
type Config struct {
	Environment string
	RegionCode  string
	ServiceName string
	LogLevel    string
	LogFormat   string
	HTTPPort    int

	DatabaseURL             string
	DatabaseMaxConns        int
	DatabaseStatementTimeout time.Duration

	KafkaBrokers       []string
	KafkaConsumerGroup string

	OTELEndpoint    string
	OTELSampleRatio float64

	IdentityGRPCAddr        string
	IdentityJWKSURL         string
	IdentityJWKSGrace       time.Duration
	OutboxRelayInterval     time.Duration
	ShutdownGrace           time.Duration

	// §5.6 — chỉ riêng của routing-service.
	SolverThreads         int
	MaxLegs               int
	ETAModelPath          string
	ReplanCooldown        time.Duration

	// Địa chỉ của hai dịch vụ mà routing-service được phép gọi đồng bộ ngoài identity-service:
	// geo-service và customs-service (§1.1). Không có OF_CONTAINER_REGISTRY_* ở đây, và điều đó
	// là cố ý: routing-service biết về lô hàng qua sự kiện shipment.created chứ không gọi
	// container-registry.
	GeoGRPCAddr    string
	CustomsBaseURL string
}

// spec mô tả từng biến một lần duy nhất: tên, có bắt buộc không, giá trị mặc định. Bảng này
// vừa là tài liệu vừa là bộ kiểm tra, nên không có đường nào để một biến được đọc mà không
// xuất hiện ở đây.
var spec = []struct {
	name     string
	required bool
	fallback string
}{
	{"OF_ENVIRONMENT", true, ""},
	{"OF_REGION_CODE", true, ""},
	{"OF_SERVICE_NAME", true, ""},
	{"OF_LOG_LEVEL", false, "info"},
	{"OF_LOG_FORMAT", false, "json"},
	{"OF_HTTP_PORT", false, "8085"},
	{"OF_DATABASE_URL", true, ""},
	{"OF_DATABASE_MAX_CONNS", false, "40"},
	{"OF_DATABASE_STATEMENT_TIMEOUT_MS", false, "8000"},
	{"OF_KAFKA_BROKERS", true, ""},
	{"OF_KAFKA_CONSUMER_GROUP", true, ""},
	{"OF_OTEL_EXPORTER_ENDPOINT", false, ""},
	{"OF_OTEL_SAMPLE_RATIO", false, "0.05"},
	{"OF_IDENTITY_GRPC_ADDR", true, ""},
	{"OF_IDENTITY_JWKS_URL", true, ""},
	{"OF_IDENTITY_JWKS_GRACE_SECONDS", false, "300"},
	{"OF_OUTBOX_RELAY_INTERVAL_MS", false, "250"},
	{"OF_SHUTDOWN_GRACE_SECONDS", false, "25"},
	{"OF_ROUTING_SOLVER_THREADS", false, "4"},
	{"OF_ROUTING_MAX_LEGS", false, "12"},
	{"OF_ROUTING_ETA_MODEL_PATH", true, ""},
	{"OF_ROUTING_REPLAN_COOLDOWN_SECONDS", false, "600"},
	{"OF_GEO_GRPC_ADDR", true, ""},
	{"OF_CUSTOMS_BASE_URL", true, ""},
}

// Load đọc môi trường, trả về lỗi gộp cho tất cả biến sai thay vì dừng ở biến đầu tiên.
// Người trực ca sửa một lần là chạy, thay vì phải triển khai lại năm lần liên tiếp.
func Load() (*Config, error) {
	raw := make(map[string]string, len(spec))
	var problems []string

	for _, v := range spec {
		val, present := os.LookupEnv(v.name)
		if !present || strings.TrimSpace(val) == "" {
			if v.required {
				problems = append(problems, fmt.Sprintf("thiếu biến bắt buộc %s", v.name))
				continue
			}
			val = v.fallback
		}
		raw[v.name] = strings.TrimSpace(val)
	}
	if len(problems) > 0 {
		return nil, fmt.Errorf("cấu hình không hợp lệ:\n  - %s", strings.Join(problems, "\n  - "))
	}

	c := &Config{
		Environment:        raw["OF_ENVIRONMENT"],
		RegionCode:         raw["OF_REGION_CODE"],
		ServiceName:        raw["OF_SERVICE_NAME"],
		LogLevel:           raw["OF_LOG_LEVEL"],
		LogFormat:          raw["OF_LOG_FORMAT"],
		DatabaseURL:        raw["OF_DATABASE_URL"],
		KafkaBrokers:       splitList(raw["OF_KAFKA_BROKERS"]),
		KafkaConsumerGroup: raw["OF_KAFKA_CONSUMER_GROUP"],
		OTELEndpoint:       raw["OF_OTEL_EXPORTER_ENDPOINT"],
		IdentityGRPCAddr:   raw["OF_IDENTITY_GRPC_ADDR"],
		IdentityJWKSURL:    raw["OF_IDENTITY_JWKS_URL"],
		ETAModelPath:       raw["OF_ROUTING_ETA_MODEL_PATH"],
		GeoGRPCAddr:        raw["OF_GEO_GRPC_ADDR"],
		CustomsBaseURL:     raw["OF_CUSTOMS_BASE_URL"],
	}

	var err error
	if c.HTTPPort, err = atoi(raw, "OF_HTTP_PORT", &problems); err == nil && c.HTTPPort != 8085 {
		// §1 gán cổng 8085 cho routing-service. Cho phép ghi đè ở môi trường local, chặn ở nơi khác:
		// một cổng lệch nghĩa là Service của Kubernetes trỏ vào khoảng không.
		if c.Environment != "local" {
			problems = append(problems, "OF_HTTP_PORT phải là 8085 ngoài môi trường local")
		}
	}
	c.DatabaseMaxConns, _ = atoi(raw, "OF_DATABASE_MAX_CONNS", &problems)
	c.SolverThreads, _ = atoi(raw, "OF_ROUTING_SOLVER_THREADS", &problems)
	c.MaxLegs, _ = atoi(raw, "OF_ROUTING_MAX_LEGS", &problems)
	c.OTELSampleRatio = atof(raw, "OF_OTEL_SAMPLE_RATIO", &problems)

	c.DatabaseStatementTimeout = millis(raw, "OF_DATABASE_STATEMENT_TIMEOUT_MS", &problems)
	c.OutboxRelayInterval = millis(raw, "OF_OUTBOX_RELAY_INTERVAL_MS", &problems)
	c.IdentityJWKSGrace = seconds(raw, "OF_IDENTITY_JWKS_GRACE_SECONDS", &problems)
	c.ShutdownGrace = seconds(raw, "OF_SHUTDOWN_GRACE_SECONDS", &problems)
	c.ReplanCooldown = seconds(raw, "OF_ROUTING_REPLAN_COOLDOWN_SECONDS", &problems)

	if c.ServiceName != "routing-service" {
		problems = append(problems, fmt.Sprintf(
			"OF_SERVICE_NAME phải đúng bằng \"routing-service\" theo §1, đang là %q", c.ServiceName))
	}
	if !domain.IsKnownRegion(c.RegionCode) {
		problems = append(problems, fmt.Sprintf("OF_REGION_CODE %q không nằm trong §0.6", c.RegionCode))
	}
	if c.MaxLegs < 2 || c.MaxLegs > 40 {
		problems = append(problems, "OF_ROUTING_MAX_LEGS phải nằm trong khoảng 2..40")
	}
	if c.SolverThreads < 1 {
		problems = append(problems, "OF_ROUTING_SOLVER_THREADS phải lớn hơn 0")
	}
	if len(problems) > 0 {
		return nil, fmt.Errorf("cấu hình không hợp lệ:\n  - %s", strings.Join(problems, "\n  - "))
	}
	return c, nil
}

// ConsumerGroupFor trả tên nhóm consumer cho một topic. Đổi hậu tố phiên bản trong
// OF_KAFKA_CONSUMER_GROUP là cách duy nhất để buộc đọc lại of.freight.v1 từ đầu.
func (c *Config) ConsumerGroupFor(topic string) string {
	return fmt.Sprintf("%s.%s", c.KafkaConsumerGroup, topic)
}

func splitList(v string) []string {
	parts := strings.Split(v, ",")
	out := parts[:0]
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func atoi(raw map[string]string, key string, problems *[]string) (int, error) {
	n, err := strconv.Atoi(raw[key])
	if err != nil {
		*problems = append(*problems, fmt.Sprintf("%s phải là số nguyên, đang là %q", key, raw[key]))
	}
	return n, err
}

func atof(raw map[string]string, key string, problems *[]string) float64 {
	f, err := strconv.ParseFloat(raw[key], 64)
	if err != nil {
		*problems = append(*problems, fmt.Sprintf("%s phải là số thực, đang là %q", key, raw[key]))
	}
	return f
}

func millis(raw map[string]string, key string, problems *[]string) time.Duration {
	n, err := atoi(raw, key, problems)
	if err != nil {
		return 0
	}
	return time.Duration(n) * time.Millisecond
}

func seconds(raw map[string]string, key string, problems *[]string) time.Duration {
	n, err := atoi(raw, key, problems)
	if err != nil {
		return 0
	}
	return time.Duration(n) * time.Second
}
