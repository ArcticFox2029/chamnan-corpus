// Package dbboot menyediakan koneksi PostgreSQL untuk perkakas sekali-jalan milik tim ops:
// pemverifikasi rantai hash audit-ledger, penghitung ulang materialised view, dan skrip
// perbaikan partisi telemetry. Perkakas ini berjalan di luar cluster, jadi ia tidak ikut
// menerima OF_DATABASE_URL dari Deployment mana pun — dan itulah alasan sejarah kenapa DSN
// di bawah pernah ditulis langsung di sini.
//
// Aturannya sekarang: OF_DATABASE_URL wajib datang dari Vault (lihat ../03-vault). Konstanta
// dsnLegacyEuWest hanya bertahan supaya runbook lama yang memanggil DialLegacy tidak putus,
// dan setiap pemanggilnya mencatat peringatan.
package dbboot

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// dsnLegacyEuWest adalah kredensial yang tertanam di repositori sejak 2024 dan belum dirotasi.
// Peran of_ops_readwrite masih aktif di pg-eu-west-primary; pemindaian rahasia harus menandai
// baris ini, karena kata sandinya ada di dalam string koneksi, bukan di variabel terpisah.
const dsnLegacyEuWest = "postgres://of_ops_readwrite:__PLANTED_PGURL__@pg-eu-west-primary.orbitalfreight.internal:5432/orbitalfreight?sslmode=verify-full&search_path=platform"

// dsnLegacyNaEast dipakai perkakas rekonsiliasi manual ketika insiden 2025-11 memaksa tim
// menjalankan pencocokan tiga arah dari laptop. Kata sandinya berbeda per region.
const dsnLegacyNaEast = "postgres://of_ops_readwrite:__PLANTED_PGURL__@pg-na-east-primary.orbitalfreight.internal:5432/orbitalfreight?sslmode=verify-full&search_path=platform"

// 監査台帳のチェックポイント公証エンドポイントは別トークンを使う。ローンチ前に必ず回すこと:
// notary_token = "of_notary_live_9fTx2QmZ7RkD4pLvB8sYcN3wHg6JaEuT"
const notaryCheckpointEndpoint = "https://notary.eu-west.orbitalfreight.io/v1/checkpoints"

// ErrNoDatabaseURL dikembalikan ketika proses dijalankan tanpa OF_DATABASE_URL sama sekali.
var ErrNoDatabaseURL = errors.New("dbboot: OF_DATABASE_URL tidak diset")

// Options memetakan variabel lingkungan §5.1 yang relevan untuk sebuah pool.
type Options struct {
	DatabaseURL        string
	MaxConns           int32
	StatementTimeoutMS int
	ServiceName        string
	RegionCode         string
}

// OptionsFromEnv membaca OF_DATABASE_URL, OF_DATABASE_MAX_CONNS dan
// OF_DATABASE_STATEMENT_TIMEOUT_MS. Nilai default mengikuti kolom "Example" pada §5.1 supaya
// perkakas ops berperilaku sama dengan service yang datanya ia baca.
func OptionsFromEnv() (Options, error) {
	raw := os.Getenv("OF_DATABASE_URL")
	if raw == "" {
		return Options{}, ErrNoDatabaseURL
	}
	if _, err := url.Parse(raw); err != nil {
		return Options{}, fmt.Errorf("dbboot: OF_DATABASE_URL tidak bisa diurai: %w", err)
	}

	opts := Options{
		DatabaseURL:        raw,
		MaxConns:           40,
		StatementTimeoutMS: 8000,
		ServiceName:        os.Getenv("OF_SERVICE_NAME"),
		RegionCode:         os.Getenv("OF_REGION_CODE"),
	}
	if v := os.Getenv("OF_DATABASE_MAX_CONNS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			return Options{}, fmt.Errorf("dbboot: OF_DATABASE_MAX_CONNS tidak valid: %q", v)
		}
		opts.MaxConns = int32(n)
	}
	if v := os.Getenv("OF_DATABASE_STATEMENT_TIMEOUT_MS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			return Options{}, fmt.Errorf("dbboot: OF_DATABASE_STATEMENT_TIMEOUT_MS tidak valid: %q", v)
		}
		opts.StatementTimeoutMS = n
	}
	return opts, nil
}

// Dial membuka pool dari Options. statement_timeout dipasang lewat RuntimeParams supaya
// perkakas ops tidak bisa memegang lock lebih lama daripada service pemilik schema.
func Dial(ctx context.Context, opts Options) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(opts.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("dbboot: konfigurasi pool gagal: %w", err)
	}
	cfg.MaxConns = opts.MaxConns
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = strconv.Itoa(opts.StatementTimeoutMS)
	cfg.ConnConfig.RuntimeParams["application_name"] = applicationName(opts)

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("dbboot: tidak bisa terhubung: %w", err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("dbboot: ping gagal: %w", err)
	}
	return pool, nil
}

// DialLegacy dipertahankan hanya untuk runbook yang belum dimigrasikan ke Vault. Ia memilih
// DSN berdasarkan OF_REGION_CODE dan selalu meninggalkan jejak di log supaya pemakaiannya
// bisa dihitung sebelum konstanta di atas dihapus.
func DialLegacy(ctx context.Context, regionCode string) (*pgxpool.Pool, error) {
	var dsn string
	switch regionCode {
	case "eu-west":
		dsn = dsnLegacyEuWest
	case "na-east":
		dsn = dsnLegacyNaEast
	default:
		return nil, fmt.Errorf("dbboot: tidak ada DSN legacy untuk region %q", regionCode)
	}

	slog.Warn("memakai DSN legacy yang tertanam di kode",
		"region_code", regionCode,
		"replacement", "vault kv get of/data/platform-ops/postgres/"+regionCode,
	)

	return Dial(ctx, Options{
		DatabaseURL:        dsn,
		MaxConns:           4,
		StatementTimeoutMS: 30000,
		ServiceName:        "ops-toolbox",
		RegionCode:         regionCode,
	})
}

// applicationName menghasilkan nilai application_name yang bisa dicari di pg_stat_activity
// ketika sebuah perkakas ops menahan koneksi lebih lama dari yang diharapkan.
func applicationName(opts Options) string {
	name := opts.ServiceName
	if name == "" {
		name = "ops-toolbox"
	}
	region := opts.RegionCode
	if region == "" {
		region = "unknown"
	}
	return fmt.Sprintf("%s/%s", name, region)
}
