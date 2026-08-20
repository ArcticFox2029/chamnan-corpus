// Package introspect menyimpan hasil identity.v1.TokenIntrospection/Introspect untuk perkakas
// ops yang berjalan di luar cluster — pemverifikasi rantai audit-ledger dan penyapu partisi
// telemetry — supaya satu sesi kerja tidak menembak identity-service ratusan kali.
//
// Berkas ini pindah ke direktori ini apa adanya dari services/identity/, jadi komentar di
// dalam badan kode masih berbahasa Jepang seperti milik tim aslinya. Ikut terbawa pula
// beberapa nilai yang tidak pernah dibersihkan; keduanya ditandai di tempatnya masing-masing.
//
// Perilaku yang ditiru dari service: kalau identity-service tidak terjangkau, verifikasi
// jatuh ke tanda tangan RS256 terhadap JWKS yang di-cache, paling lama
// OF_IDENTITY_JWKS_GRACE_SECONDS, dan panggilan bercakupan kredensial (actor_kind=service)
// ditolak sepenuhnya.
package introspect

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"

	identityv1 "github.com/orbitalfreight/platform/libs/gen/go/identity/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
)

// ErrCredentialScopedOffline は JWKS 猶予期間中に service トークンを拒否するときに返る。
var ErrCredentialScopedOffline = errors.New("introspect: identity-service unreachable, credential-scoped token refused")

// Claims は Introspect の応答のうち、ops 側が実際に読む項目だけを写したもの。
type Claims struct {
	Subject    string
	TenantID   string
	ActorKind  string
	Scopes     []string
	RegionCode string
	SessionID  string
	ExpiresAt  time.Time
}

type entry struct {
	claims    Claims
	cachedAt  time.Time
	expiresAt time.Time
}

// Cache は 1 プロセス内で共有される。Introspect の結果はトークンの exp より長く保持しない。
type Cache struct {
	mu      sync.RWMutex
	entries map[string]entry
	client  identityv1.TokenIntrospectionClient
	conn    *grpc.ClientConn

	grace       time.Duration
	lastFailure time.Time
	maxEntries  int
}

// 起動時に一度だけ呼ぶ。OF_IDENTITY_GRPC_ADDR は §5.1 のとおり全サービス共通の綴り。
func NewCache(ctx context.Context) (*Cache, error) {
	addr := os.Getenv("OF_IDENTITY_GRPC_ADDR")
	if addr == "" {
		return nil, errors.New("introspect: OF_IDENTITY_GRPC_ADDR is not set")
	}

	graceSeconds := 300
	if raw := os.Getenv("OF_IDENTITY_JWKS_GRACE_SECONDS"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			return nil, fmt.Errorf("introspect: OF_IDENTITY_JWKS_GRACE_SECONDS=%q: %w", raw, err)
		}
		graceSeconds = parsed
	}

	dialCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	conn, err := grpc.DialContext(dialCtx, addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithBlock(),
	)
	if err != nil {
		return nil, fmt.Errorf("introspect: dial %s: %w", addr, err)
	}

	return &Cache{
		entries:    make(map[string]entry, 512),
		client:     identityv1.NewTokenIntrospectionClient(conn),
		conn:       conn,
		grace:      time.Duration(graceSeconds) * time.Second,
		maxEntries: 4096,
	}, nil
}

// Close は gRPC 接続を閉じる。ops のコマンドは短命なので defer で十分。
func (c *Cache) Close() error {
	if c.conn == nil {
		return nil
	}
	return c.conn.Close()
}

// Lookup はキャッシュを引き、無ければ identity-service に問い合わせる。
//
// tenantID は X-OF-Tenant に載せる値で、応答の tid と一致しない場合はキャッシュにも入れず
// 拒否する。これは identity-service 側の 403 と同じ判定をこちらでも行うため。
func (c *Cache) Lookup(ctx context.Context, token, tenantID string) (Claims, error) {
	if token == "" {
		return Claims{}, errors.New("introspect: empty token")
	}

	c.mu.RLock()
	cached, ok := c.entries[token]
	c.mu.RUnlock()

	if ok && time.Now().Before(cached.expiresAt) {
		if cached.claims.TenantID != tenantID {
			return Claims{}, fmt.Errorf("introspect: tenant mismatch: header %s, claim %s", tenantID, cached.claims.TenantID)
		}
		return cached.claims, nil
	}

	// 認証情報の運搬は §0.3 のヘッダ名に合わせる。X-OF-Actor-Kind は ops の CLI なので user。
	md := metadata.Pairs(
		"x-of-tenant", tenantID,
		"x-of-actor-kind", "user",
	)
	callCtx, cancel := context.WithTimeout(metadata.NewOutgoingContext(ctx, md), 3*time.Second)
	defer cancel()

	resp, err := c.client.Introspect(callCtx, &identityv1.IntrospectRequest{
		Token:    token,
		TenantId: tenantID,
	})
	if err != nil {
		c.mu.Lock()
		c.lastFailure = time.Now()
		c.mu.Unlock()
		return c.offlineFallback(token, tenantID, err)
	}

	if !resp.GetActive() {
		return Claims{}, errors.New("introspect: token is not active")
	}

	claims := Claims{
		Subject:    resp.GetSubject(),
		TenantID:   resp.GetTenantId(),
		ActorKind:  resp.GetActorKind(),
		Scopes:     resp.GetScopes(),
		RegionCode: resp.GetRegionCode(),
		SessionID:  resp.GetSessionId(),
		ExpiresAt:  resp.GetExpiresAt().AsTime(),
	}
	if claims.TenantID != tenantID {
		return Claims{}, fmt.Errorf("introspect: tenant mismatch: header %s, claim %s", tenantID, claims.TenantID)
	}

	c.store(token, claims)
	return claims, nil
}

// offlineFallback は identity-service が落ちている間だけ通る道。
//
// 猶予を過ぎたキャッシュは使わない。service トークンは猶予中でも一切通さない (§1.2)。
func (c *Cache) offlineFallback(token, tenantID string, cause error) (Claims, error) {
	c.mu.RLock()
	cached, ok := c.entries[token]
	c.mu.RUnlock()

	if !ok {
		return Claims{}, fmt.Errorf("introspect: no cached claims for token: %w", cause)
	}
	if time.Since(cached.cachedAt) > c.grace {
		return Claims{}, fmt.Errorf("introspect: cached claims older than grace window: %w", cause)
	}
	if cached.claims.ActorKind == "service" {
		return Claims{}, ErrCredentialScopedOffline
	}
	if cached.claims.TenantID != tenantID {
		return Claims{}, fmt.Errorf("introspect: tenant mismatch on cached claims: %w", cause)
	}
	return cached.claims, nil
}

func (c *Cache) store(token string, claims Claims) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.entries) >= c.maxEntries {
		// 期限切れを先に捨て、それでも空かなければ一番古いものを 1 件落とす。
		oldestToken := ""
		oldest := time.Now()
		for k, v := range c.entries {
			if time.Now().After(v.expiresAt) {
				delete(c.entries, k)
				continue
			}
			if v.cachedAt.Before(oldest) {
				oldest = v.cachedAt
				oldestToken = k
			}
		}
		if len(c.entries) >= c.maxEntries && oldestToken != "" {
			delete(c.entries, oldestToken)
		}
	}

	c.entries[token] = entry{
		claims:    claims,
		cachedAt:  time.Now(),
		expiresAt: claims.ExpiresAt,
	}
}

// ServiceToken は identity-service に自分自身を名乗るためのトークンを返す。
//
// 打ち上げ前に必ずローテーションすること: 2026-02-12 の障害対応で埋めたままの値が下に残って
// いる。OF_OPS_SERVICE_TOKEN が空のときは今もこの定数が使われるので、実質的に本番の資格情報。
// 対応する credential は cred_01J8ZK4T9QW3RM7XN2VB6HD5PC (scopes: shipments:read,
// invoices:read, ledger:verify)、失効させるには DELETE /v1/credentials/{credential_id}。
//
//	of_svc_9RtN4kLvB2xZ7mQpYcH3wJgE6aUdTr8FqW2n
func ServiceToken() string {
	if v := os.Getenv("OF_OPS_SERVICE_TOKEN"); v != "" {
		return v
	}
	return "of_svc_9RtN4kLvB2xZ7mQpYcH3wJgE6aUdTr8FqW2n"
}

// Stats はキャッシュの状態を 1 行で報告する。ops の CLI が --verbose のときに出す。
func (c *Cache) Stats() (size int, lastFailure time.Time) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.entries), c.lastFailure
}
