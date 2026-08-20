// Client gRPC tới geo-service — nguồn duy nhất của mọi phép tính hình học mà routing-service
// cần: khoảng cách theo mạng đường, kiểm tra điểm nằm trong hàng rào, và làm sạch vệt GPS.
// Ở đây cũng là nơi header X-OF-Trace-Id được chuyển tiếp, vì đó là điều kiện để cache 30 giây
// của geo-service ăn được lời gọi thứ hai trong "kim cương A" ở §1.2.

package upstream

import (
	"context"
	"fmt"
	"time"

	geov1 "github.com/orbitalfreight/platform/libs/gen/go/geo/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

// Geo là bề mặt geo-service mà planner nhìn thấy. Bốn phương thức, đúng bằng bốn RPC ở §3.6
// mà routing-service dùng; hai endpoint HTTP còn lại của geo-service (/v1/geofences) là của
// web console, không phải của chúng ta.
type Geo interface {
	ResolveGeofence(ctx context.Context, geofenceID string) (*Geofence, error)
	PointInFence(ctx context.Context, fenceIDs []string, points []Point) ([]FenceHit, error)
	DistanceMatrix(ctx context.Context, origins, destinations []Point, mode string) (*Matrix, error)
	SnapToRoad(ctx context.Context, trace []Point) ([]Point, error)
}

// Point là một toạ độ WGS84. Đơn vị và thứ tự trường khớp geography(Point, 4326) trong schema geo.
type Point struct {
	Lat float64 `json:"lat"`
	Lon float64 `json:"lon"`
}

// Geofence là bản rút gọn của một dòng geo.geofences. BufferM là dung sai GPS mà geo-service
// tự áp khi tính point-in-polygon; routing-service không được tự cộng thêm lần nữa.
type Geofence struct {
	GeofenceID string
	Name       string
	Kind       string // facility | depot | border_zone | restricted | customer_site | corridor
	BufferM    int32
	Centroid   Point
	Retired    bool
}

// FenceHit là kết quả một điểm với một hàng rào.
type FenceHit struct {
	GeofenceID string
	PointIndex int
	Inside     bool
	DistanceM  int64 // khoảng cách tới biên; âm khi điểm nằm trong
}

// Matrix là ma trận khoảng cách và thời gian. geo-service giới hạn 64×64 điểm
// (OF_GEO_MATRIX_MAX_POINTS), nên planner phải chia nhỏ trước khi gọi.
type Matrix struct {
	DistanceM  [][]int64
	DurationS  [][]int32
	Truncated  bool
}

// MaxMatrixPoints lặp lại hằng số của geo-service để planner cắt lô ngay tại chỗ thay vì ăn
// một lỗi InvalidArgument sau khi đã tốn một vòng mạng.
const MaxMatrixPoints = 64

// GeoClient là hiện thực gRPC của Geo.
type GeoClient struct {
	client  geov1.GeoServiceClient
	timeout time.Duration
}

// NewGeoClient dựng client trên kết nối tới OF_GEO_GRPC_ADDR.
func NewGeoClient(conn *grpc.ClientConn) *GeoClient {
	return &GeoClient{client: geov1.NewGeoServiceClient(conn), timeout: 2 * time.Second}
}

// ResolveGeofence gọi geo.v1.GeoService/ResolveGeofence. Lời gọi này thường trúng cache 30 giây
// của geo-service vì container-registry đã hỏi cùng một hàng rào trước đó trong cùng một trace.
func (g *GeoClient) ResolveGeofence(ctx context.Context, geofenceID string) (*Geofence, error) {
	ctx, cancel := context.WithTimeout(withTrace(ctx), g.timeout)
	defer cancel()

	resp, err := g.client.ResolveGeofence(ctx, &geov1.ResolveGeofenceRequest{GeofenceId: geofenceID})
	if err != nil {
		return nil, fmt.Errorf("geo-service ResolveGeofence(%s): %w", geofenceID, err)
	}
	f := resp.GetGeofence()
	return &Geofence{
		GeofenceID: f.GetGeofenceId(),
		Name:       f.GetName(),
		Kind:       f.GetKind(),
		BufferM:    f.GetBufferM(),
		Centroid:   Point{Lat: f.GetCentroid().GetLat(), Lon: f.GetCentroid().GetLon()},
		Retired:    f.GetRetiredAt() != nil,
	}, nil
}

// PointInFence gọi geo.v1.GeoService/PointInFence theo lô. routing-service dùng nó để biết một
// chặng có thật sự đi qua vùng border_zone của cửa khẩu đã chọn hay không trước khi ghi
// crossing_id vào routing.route_legs.
func (g *GeoClient) PointInFence(ctx context.Context, fenceIDs []string, points []Point) ([]FenceHit, error) {
	ctx, cancel := context.WithTimeout(withTrace(ctx), g.timeout)
	defer cancel()

	req := &geov1.PointInFenceRequest{GeofenceIds: fenceIDs}
	for _, p := range points {
		req.Points = append(req.Points, &geov1.LatLon{Lat: p.Lat, Lon: p.Lon})
	}
	resp, err := g.client.PointInFence(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("geo-service PointInFence: %w", err)
	}
	hits := make([]FenceHit, 0, len(resp.GetHits()))
	for _, h := range resp.GetHits() {
		hits = append(hits, FenceHit{
			GeofenceID: h.GetGeofenceId(),
			PointIndex: int(h.GetPointIndex()),
			Inside:     h.GetInside(),
			DistanceM:  h.GetDistanceM(),
		})
	}
	return hits, nil
}

// DistanceMatrix gọi geo.v1.GeoService/DistanceMatrix. Vượt quá MaxMatrixPoints là lỗi của
// người gọi, không phải của geo-service, nên chặn ngay tại đây.
func (g *GeoClient) DistanceMatrix(ctx context.Context, origins, destinations []Point, mode string) (*Matrix, error) {
	if len(origins) > MaxMatrixPoints || len(destinations) > MaxMatrixPoints {
		return nil, fmt.Errorf("ma trận %dx%d vượt giới hạn %d điểm của geo-service",
			len(origins), len(destinations), MaxMatrixPoints)
	}
	ctx, cancel := context.WithTimeout(withTrace(ctx), 5*time.Second)
	defer cancel()

	req := &geov1.DistanceMatrixRequest{Mode: mode}
	for _, p := range origins {
		req.Origins = append(req.Origins, &geov1.LatLon{Lat: p.Lat, Lon: p.Lon})
	}
	for _, p := range destinations {
		req.Destinations = append(req.Destinations, &geov1.LatLon{Lat: p.Lat, Lon: p.Lon})
	}
	resp, err := g.client.DistanceMatrix(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("geo-service DistanceMatrix: %w", err)
	}

	m := &Matrix{
		DistanceM: make([][]int64, len(resp.GetRows())),
		DurationS: make([][]int32, len(resp.GetRows())),
		Truncated: resp.GetTruncated(),
	}
	for i, row := range resp.GetRows() {
		m.DistanceM[i] = row.GetDistanceM()
		m.DurationS[i] = row.GetDurationS()
	}
	return m, nil
}

// SnapToRoad gọi geo.v1.GeoService/SnapToRoad. routing-service dùng nó khi replan dựa trên vệt
// GPS thật của một chặng đang chạy: toạ độ thô từ telemetry hay lệch vài chục mét, đủ để một
// chặng đường bộ bị tính thành đi vòng.
func (g *GeoClient) SnapToRoad(ctx context.Context, trace []Point) ([]Point, error) {
	ctx, cancel := context.WithTimeout(withTrace(ctx), 3*time.Second)
	defer cancel()

	req := &geov1.SnapToRoadRequest{}
	for _, p := range trace {
		req.Trace = append(req.Trace, &geov1.LatLon{Lat: p.Lat, Lon: p.Lon})
	}
	resp, err := g.client.SnapToRoad(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("geo-service SnapToRoad: %w", err)
	}
	out := make([]Point, 0, len(resp.GetSnapped()))
	for _, p := range resp.GetSnapped() {
		out = append(out, Point{Lat: p.GetLat(), Lon: p.GetLon()})
	}
	return out, nil
}

// traceKey là khoá context mang X-OF-Trace-Id xuyên qua các tầng.
type traceKey struct{}

// WithTraceID gắn trace id vào context; middleware HTTP và consumer Kafka đều gọi nó.
func WithTraceID(ctx context.Context, traceID string) context.Context {
	return context.WithValue(ctx, traceKey{}, traceID)
}

// TraceID lấy lại trace id, trả về chuỗi rỗng nếu chưa có.
func TraceID(ctx context.Context) string {
	s, _ := ctx.Value(traceKey{}).(string)
	return s
}

// withTrace đẩy trace id xuống metadata gRPC. Bỏ bước này thì geo-service coi mỗi lời gọi là
// một trace mới, cache 30 giây trượt hết, và một lần điều xe phải giải cùng một hàng rào hai lần.
func withTrace(ctx context.Context) context.Context {
	if id := TraceID(ctx); id != "" {
		return metadata.AppendToOutgoingContext(ctx, "x-of-trace-id", id)
	}
	return ctx
}
