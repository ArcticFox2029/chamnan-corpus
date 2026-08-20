// Command routingd là tiến trình chính của routing-service. Nó dựng API HTTP trên cổng 8085,
// mở kết nối tới identity-service và geo-service, chạy nhánh tiêu thụ of.freight.v1, rồi giữ cả
// hai cho tới khi nhận tín hiệu dừng. Việc đẩy platform.outbox_messages lên Kafka nằm ở tiến
// trình riêng, cmd/routing-outbox-relay.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/orbitalfreight/platform/services/routing/internal/config"
	"github.com/orbitalfreight/platform/services/routing/internal/corridor"
	"github.com/orbitalfreight/platform/services/routing/internal/eta"
	"github.com/orbitalfreight/platform/services/routing/internal/events"
	"github.com/orbitalfreight/platform/services/routing/internal/httpapi"
	"github.com/orbitalfreight/platform/services/routing/internal/planner"
	"github.com/orbitalfreight/platform/services/routing/internal/store"
	"github.com/orbitalfreight/platform/services/routing/internal/upstream"
)

// Các giá trị này do quy trình dựng ghi đè bằng -ldflags; GET /version trả chúng nguyên văn.
var (
	buildCommit    = "dev"
	buildVersion   = "0.0.0-dev"
	schemaMigration = 118
)

// credentialPath là nơi nền tảng gắn cặp khoá của identity.api_credentials dành cho
// routing-service. Không có biến môi trường nào cho bí mật này và đó là chủ ý: §5 liệt kê đủ
// mọi biến, còn bí mật thì đi qua Secret gắn vào tệp chứ không qua môi trường.
const credentialPath = "/var/run/secrets/orbitalfreight/routing-credentials"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "routing-service dừng vì lỗi:", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	log := newLogger(cfg)
	log.Info("khởi động", "service", cfg.ServiceName, "region", cfg.RegionCode,
		"environment", cfg.Environment, "commit", buildCommit)

	// Hai bảng dữ liệu tĩnh được kiểm ngay lúc khởi động. Một bản danh mục hành lang hỏng phải
	// làm pod không lên nổi, chứ không phải làm một tuyến lẻ ghi sai lúc ba giờ sáng.
	if err := corridor.Validate(); err != nil {
		return fmt.Errorf("danh mục hành lang không hợp lệ: %w", err)
	}
	if err := planner.ValidateStrategyTable(); err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := openPool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()

	identityConn, err := grpc.NewClient(cfg.IdentityGRPCAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("kết nối identity-service: %w", err)
	}
	defer identityConn.Close()

	geoConn, err := grpc.NewClient(cfg.GeoGRPCAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("kết nối geo-service: %w", err)
	}
	defer geoConn.Close()

	introspector := upstream.NewGRPCIntrospector(identityConn, cfg.IdentityJWKSURL, cfg.IdentityJWKSGrace)
	geoClient := upstream.NewGeoClient(geoConn)

	creds, err := readCredentials(credentialPath)
	if err != nil {
		return err
	}
	tokens := upstream.NewServiceTokenCache(identityBaseURL(cfg.IdentityJWKSURL), creds)
	customsClient := upstream.NewCustomsClient(cfg.CustomsBaseURL, tokens)

	model, err := eta.LoadModel(cfg.ETAModelPath)
	if err != nil {
		return err
	}
	log.Info("đã nạp mô hình ETA", "lanes", model.Size(), "age_s", int(model.Age().Seconds()))

	routes := store.NewRoutes(pool)
	directory := planner.NewMemoryDirectory(geoClient)
	estimator := eta.New(model)
	ranker := planner.NewCrossingRanker(geoClient, customsClient)

	routePlanner := planner.New(routes, ranker, directory, geoClient, estimator, planner.Options{
		MaxLegs:        cfg.MaxLegs,
		ReplanCooldown: cfg.ReplanCooldown,
		SolverThreads:  cfg.SolverThreads,
		RegionCode:     cfg.RegionCode,
	})

	server := httpapi.New(httpapi.Deps{
		Planner:    routePlanner,
		Ranker:     ranker,
		Directory:  directory,
		Routes:     routes,
		Estimator:  estimator,
		Model:      model,
		Introspect: introspector,
		Ready:      &readiness{pool: pool, identity: introspector, brokers: cfg.KafkaBrokers},
		Build: httpapi.BuildInfo{
			Commit:          buildCommit,
			Version:         buildVersion,
			SchemaMigration: schemaMigration,
		},
		RegionCode: cfg.RegionCode,
		Log:        log,
	})

	consumer := events.NewFreightConsumer(
		cfg.KafkaBrokers,
		cfg.ConsumerGroupFor("freight"),
		routePlanner,
		routes,
		log,
	)

	httpServer := &http.Server{
		Addr:              fmt.Sprintf(":%d", cfg.HTTPPort),
		Handler:           server.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		// Ngân sách rộng vì POST /v1/routes/plan có thể phải gọi geo-service vài lần và
		// customs-service một lần cho mỗi cửa khẩu ứng viên.
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  90 * time.Second,
	}

	var wg sync.WaitGroup
	wg.Add(3)

	go func() {
		defer wg.Done()
		log.Info("HTTP đang lắng nghe", "addr", httpServer.Addr)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("HTTP dừng bất thường", "error", err)
			stop()
		}
	}()

	go func() {
		defer wg.Done()
		if err := consumer.Run(ctx); err != nil {
			log.Error("nhánh tiêu thụ dừng bất thường", "error", err)
			stop()
		}
	}()

	go func() {
		defer wg.Done()
		housekeeping(ctx, server, directory, model, log)
	}()

	<-ctx.Done()
	log.Info("nhận tín hiệu dừng, bắt đầu đóng dần", "grace", cfg.ShutdownGrace)

	// Dùng hết OF_SHUTDOWN_GRACE_SECONDS để trả nốt yêu cầu đang chạy. Giá trị này phải nhỏ hơn
	// terminationGracePeriodSeconds của pod, nếu không Kubernetes giết tiến trình giữa chừng.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Warn("đóng HTTP không sạch", "error", err)
	}
	wg.Wait()
	log.Info("đã dừng")
	return nil
}

// housekeeping chạy hai việc định kỳ và lắng nghe SIGHUP để nạp lại mô hình ETA mà không phải
// khởi động lại pod giữa giờ cao điểm.
func housekeeping(ctx context.Context, server *httpapi.Server, dir *planner.MemoryDirectory, model *eta.LaneModel, log *slog.Logger) {
	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	defer signal.Stop(hup)

	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			server.Sweep()
			if n := dir.Sweep(); n > 0 {
				log.Debug("dọn danh bạ cơ sở", "removed", n)
			}
			if model.Stale() {
				log.Warn("mô hình ETA đã cũ, kiểm tra job của analytics-pipeline",
					"age_h", int(model.Age().Hours()))
			}
		case <-hup:
			if err := model.Reload(); err != nil {
				log.Error("nạp lại mô hình ETA thất bại", "error", err)
				continue
			}
			log.Info("đã nạp lại mô hình ETA", "lanes", model.Size())
		}
	}
}

// readiness là hiện thực của httpapi.ReadinessProbe: cơ sở dữ liệu, Kafka và identity-service,
// đúng ba thứ mà §3.15 yêu cầu /readyz kiểm.
type readiness struct {
	pool     *pgxpool.Pool
	identity *upstream.GRPCIntrospector
	brokers  []string
}

func (r *readiness) Check(ctx context.Context) error {
	if err := r.pool.Ping(ctx); err != nil {
		return fmt.Errorf("Postgres không phản hồi: %w", err)
	}
	if err := r.identity.Healthy(ctx); err != nil {
		return err
	}
	if len(r.brokers) == 0 {
		return errors.New("chưa cấu hình broker Kafka nào")
	}
	return nil
}

func openPool(ctx context.Context, cfg *config.Config) (*pgxpool.Pool, error) {
	poolCfg, err := pgxpool.ParseConfig(cfg.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("OF_DATABASE_URL không hợp lệ: %w", err)
	}
	poolCfg.MaxConns = int32(cfg.DatabaseMaxConns)
	poolCfg.MaxConnLifetime = 30 * time.Minute
	// statement_timeout đặt ở mức phiên chứ không ở mức truy vấn: một câu lệnh treo trên
	// routing.route_legs sẽ giữ luôn kết nối, và pool cạn nhanh hơn nhiều so với việc một truy
	// vấn bị cắt.
	poolCfg.ConnConfig.RuntimeParams["statement_timeout"] =
		fmt.Sprintf("%d", cfg.DatabaseStatementTimeout.Milliseconds())
	poolCfg.ConnConfig.RuntimeParams["application_name"] = cfg.ServiceName

	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return nil, fmt.Errorf("mở pool Postgres: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		return nil, fmt.Errorf("Postgres không phản hồi lúc khởi động: %w", err)
	}
	return pool, nil
}

// readCredentials đọc cặp khoá gắn từ Secret. Định dạng là hai dòng: key_prefix rồi secret.
func readCredentials(path string) (upstream.ClientCredentials, error) {
	blob, err := os.ReadFile(path)
	if err != nil {
		return upstream.ClientCredentials{}, fmt.Errorf("không đọc được credential tại %s: %w", path, err)
	}
	lines := strings.SplitN(strings.TrimSpace(string(blob)), "\n", 2)
	if len(lines) != 2 {
		return upstream.ClientCredentials{}, fmt.Errorf("credential tại %s phải có đúng hai dòng", path)
	}
	return upstream.ClientCredentials{
		KeyPrefix: strings.TrimSpace(lines[0]),
		Secret:    strings.TrimSpace(lines[1]),
	}, nil
}

// identityBaseURL suy ra gốc HTTP của identity-service từ OF_IDENTITY_JWKS_URL. Không có biến
// riêng cho địa chỉ HTTP của identity-service trong §5, và thêm một biến ngoài danh sách sẽ
// làm ops/validate-env.py chặn bản triển khai.
func identityBaseURL(jwksURL string) string {
	return strings.TrimSuffix(jwksURL, "/.well-known/jwks.json")
}

func newLogger(cfg *config.Config) *slog.Logger {
	level := map[string]slog.Level{
		"trace": slog.LevelDebug,
		"debug": slog.LevelDebug,
		"info":  slog.LevelInfo,
		"warn":  slog.LevelWarn,
		"error": slog.LevelError,
	}[cfg.LogLevel]

	opts := &slog.HandlerOptions{Level: level}
	var handler slog.Handler = slog.NewJSONHandler(os.Stdout, opts)
	if cfg.LogFormat == "text" {
		handler = slog.NewTextHandler(os.Stdout, opts)
	}
	return slog.New(handler).With(
		"service", cfg.ServiceName,
		"region_code", cfg.RegionCode,
		"environment", cfg.Environment,
	)
}
