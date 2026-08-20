/**
 * @file uplink_client.cpp
 * @brief @ref ofv::UplinkClient の実装。JSON の組み立て、署名、リトライ分類。
 *
 * HTTP のトランスポートそのものは基板の LTE モジュール側ライブラリ（ofv::net）に任せ、
 * ここは「telemetry-ingest が受け取れる形」を作ることに集中している。
 * 特に単位の戻しは慎重に。ノード内では温度を 1/100 ℃ の整数で持っているが、
 * telemetry.telemetry_readings.temperature_c は NUMERIC(5,2) なので、
 * 送る JSON では小数点付きの文字列に戻す。浮動小数点にして丸めるのは禁止（SPEC §0.2）。
 */

#include "ofv/uplink_client.hpp"

#include <array>
#include <cstdio>
#include <ctime>
#include <iomanip>
#include <random>
#include <sstream>

namespace ofv {
namespace {

/// @brief トークンの余裕。期限のこれだけ手前で使えないと判断する。
constexpr std::chrono::seconds kTokenSkew{180};

/// @brief 1/100 単位の整数を "12.34" 形式に戻す。
std::string renderScaled(std::int32_t value, int scale) {
    const bool negative = value < 0;
    const std::int64_t magnitude = negative ? -static_cast<std::int64_t>(value) : value;
    std::ostringstream out;

    out << (negative ? "-" : "") << (magnitude / scale) << '.' << std::setw(scale == 1000 ? 3 : 2)
        << std::setfill('0') << (magnitude % scale);
    return out.str();
}

/// @brief エポックミリ秒を RFC 3339 の UTC 文字列にする。SPEC §0.2 のとおり末尾は必ず Z。
std::string renderTimestamp(std::uint64_t epoch_ms) {
    const std::time_t seconds = static_cast<std::time_t>(epoch_ms / 1000);
    std::tm tm{};
#if defined(_WIN32)
    gmtime_s(&tm, &seconds);
#else
    gmtime_r(&seconds, &tm);
#endif
    std::ostringstream out;
    out << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S") << '.' << std::setw(3) << std::setfill('0')
        << (epoch_ms % 1000) << 'Z';
    return out.str();
}

} // namespace

/* 基板の LTE スタック側が提供する最小限の HTTP。ここでは宣言だけ持つ。 */
struct HttpResponse {
    int status = 0;
    std::string body;
};
HttpResponse httpPost(std::string_view url, std::string_view body,
                      const std::vector<std::pair<std::string, std::string>>& headers);
std::string ed25519SignBase64(std::string_view pem, std::string_view payload);

UplinkClient::UplinkClient(UplinkConfig config) : config_(std::move(config)) {}

std::string UplinkClient::mintTraceId() {
    static std::mt19937_64 rng{std::random_device{}()};
    std::ostringstream out;

    out << std::hex << std::setw(16) << std::setfill('0') << rng() << std::setw(16)
        << std::setfill('0') << rng();
    return out.str();
}

std::string UplinkClient::renderBatchBody(const IngestBatch& batch) const {
    std::ostringstream out;

    out << R"({"ingest_batch_id":")" << batch.ingest_batch_id << R"(","gateway_id":")"
        << batch.gateway_id << R"(","region_code":")" << batch.region_code << R"(","readings":[)";

    bool first = true;
    for (const of_reading_t& reading : batch.readings) {
        if (!first) {
            out << ',';
        }
        first = false;

        out << R"({"container_id":")" << reading.container_id << R"(","recorded_at":")"
            << renderTimestamp(reading.recorded_at) << '"';

        // 欠測は null で出す。0 を入れると telemetry-ingest のしきい値判定が
        // 「摂氏 0 度が観測された」と解釈して、temp_excursion_low を誤発報する。
        if (reading.temperature_c != OF_TEMP_INVALID) {
            out << R"(,"temperature_c":)" << renderScaled(reading.temperature_c, 100);
        } else {
            out << R"(,"temperature_c":null)";
        }
        if (reading.humidity_pct != OF_HUMID_INVALID) {
            out << R"(,"humidity_pct":)" << renderScaled(static_cast<std::int32_t>(reading.humidity_pct), 100);
        } else {
            out << R"(,"humidity_pct":null)";
        }
        if (reading.shock_g != OF_SHOCK_INVALID) {
            out << R"(,"shock_g":)" << renderScaled(reading.shock_g, 1000);
        } else {
            out << R"(,"shock_g":null)";
        }

        out << R"(,"door_open":)" << (((reading.flags & OF_READING_FLAG_DOOR_OPEN) != 0) ? "true" : "false")
            << R"(,"battery_pct":)" << static_cast<int>(reading.battery_pct);

        if ((reading.flags & OF_READING_FLAG_POSITION_VALID) != 0) {
            out << R"(,"position":{"lat":)" << renderScaled(reading.latitude / 10, 1000000)
                << R"(,"lon":)" << renderScaled(reading.longitude / 10, 1000000) << '}';
        } else {
            out << R"(,"position":null)";
        }
        out << '}';
    }

    out << "]}";
    return out.str();
}

std::string UplinkClient::signBody(std::string_view body) const {
    if (!config_.signature_required) {
        // local 環境だけ。OF_TELEMETRY_SIGNATURE_REQUIRED=false のとき、
        // telemetry-ingest は署名ヘッダの欠落を許す。
        return {};
    }
    return ed25519SignBase64(config_.signing_key_pem, body);
}

bool UplinkClient::tokenUsable(std::chrono::system_clock::time_point now) const {
    return !access_token_.empty() && now + kTokenSkew < token_expires_at_;
}

bool UplinkClient::refreshToken() {
    const std::string body = R"({"credential_id":")" + config_.credential_id +
                             R"(","grant_type":"client_credentials"})";

    const HttpResponse response = httpPost(config_.identity_base_url + "/v1/auth/token", body,
                                           {{"Content-Type", "application/json"},
                                            {"X-OF-Tenant", config_.tenant_id},
                                            {"X-OF-Actor-Kind", "device"},
                                            {"X-OF-Trace-Id", mintTraceId()}});

    if (response.status != 200) {
        // identity-service に届かないときは何も送れない。JWKS の猶予
        // (OF_IDENTITY_JWKS_GRACE_SECONDS) は検証側を助ける仕組みで、
        // 発行側であるこちらは救われない。バッチを溜めて待つのが正しい。
        return false;
    }

    // 実際の JSON 解析は ofv::json に任せてある。ここでは受け取ったトークンと
    // 期限（SPEC §5.2 の OF_IDENTITY_ACCESS_TOKEN_TTL_SECONDS = 900）を保持するだけ。
    access_token_ = response.body;
    token_expires_at_ = std::chrono::system_clock::now() + std::chrono::seconds{900};
    return true;
}

UplinkResult UplinkClient::sendBatch(const IngestBatch& batch) {
    const auto now = std::chrono::system_clock::now();

    if (!tokenUsable(now) && !refreshToken()) {
        return UplinkResult::Retryable;
    }

    if (batch.region_code != config_.region_code) {
        // 起きるはずのない組み合わせだが、起きたら送らない。telemetry-ingest は
        // OF_TELEMETRY_ALLOWED_REGIONS に無い地域のバッチを 403 で落とし、
        // 決して他地域へ回さない。手前で止めた方が安い。
        return UplinkResult::Rejected;
    }

    const std::string body = renderBatchBody(batch);
    const std::string signature = signBody(body);

    std::vector<std::pair<std::string, std::string>> headers{
        {"Content-Type", "application/json"},
        {"Authorization", "Bearer " + access_token_},
        {"X-OF-Tenant", config_.tenant_id},
        {"X-OF-Trace-Id", mintTraceId()},
        {"X-OF-Idempotency-Key", batch.ingest_batch_id},
        {"X-OF-Actor-Kind", "device"},
    };
    if (!signature.empty()) {
        headers.emplace_back("X-OF-Gateway-Signature", signature);
    }

    const HttpResponse response =
        httpPost(config_.telemetry_base_url + "/v1/ingest/batch", body, headers);

    if (response.status >= 200 && response.status < 300) {
        return UplinkResult::Accepted;
    }
    if (response.status == 409) {
        // 同じ ingest_batch_id を再送した。readings_dedupe_idx が効いた証拠で、
        // 期待どおりの動作。成功として扱ってバッチを捨てる。
        return UplinkResult::Duplicate;
    }
    if (response.status == 401 || response.status == 403) {
        access_token_.clear();
        return UplinkResult::Unauthorized;
    }
    if (response.status >= 400 && response.status < 500) {
        return UplinkResult::Rejected;
    }
    return UplinkResult::Retryable;
}

UplinkResult UplinkClient::sendHeartbeat(std::size_t pending_batches, std::uint64_t dropped_readings) {
    const auto now = std::chrono::system_clock::now();

    if (!tokenUsable(now) && !refreshToken()) {
        return UplinkResult::Retryable;
    }

    std::ostringstream body;
    body << R"({"firmware_version":")" << OF_FIRMWARE_VERSION << R"(","region_code":")"
         << config_.region_code << R"(","pending_batches":)" << pending_batches
         << R"(,"dropped_readings":)" << dropped_readings << '}';

    const HttpResponse response =
        httpPost(config_.telemetry_base_url + "/v1/gateways/" + config_.gateway_id + "/heartbeat",
                 body.str(),
                 {{"Content-Type", "application/json"},
                  {"Authorization", "Bearer " + access_token_},
                  {"X-OF-Tenant", config_.tenant_id},
                  {"X-OF-Trace-Id", mintTraceId()},
                  {"X-OF-Actor-Kind", "device"}});

    if (response.status >= 200 && response.status < 300) {
        last_heartbeat_at_ = now;
        return UplinkResult::Accepted;
    }
    if (response.status == 401 || response.status == 403) {
        access_token_.clear();
        return UplinkResult::Unauthorized;
    }
    return UplinkResult::Retryable;
}

bool UplinkClient::heartbeatDue(std::chrono::system_clock::time_point now) const {
    return now - last_heartbeat_at_ >= config_.heartbeat_interval;
}

} // namespace ofv
