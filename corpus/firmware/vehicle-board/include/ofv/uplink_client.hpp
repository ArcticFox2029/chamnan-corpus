/*
 * SPDX-License-Identifier: LicenseRef-ORBITALFREIGHT-Internal
 */

/**
 * @file uplink_client.hpp
 * @brief 車載基板から telemetry-ingest への HTTP クライアント。バッチ送出、生存通知、
 *        そして identity-service で取ったトークンの持ち回りを担当する。
 *
 * この基板は device 種別のアクターとして振る舞う。したがって送るリクエストには必ず
 * X-OF-Actor-Kind: device が付き、Authorization は identity-service が
 * API クレデンシャル（cred_）と交換して発行した 15 分 TTL の JWT になる。
 * identity-service に届かない間は JWKS のキャッシュ猶予に頼れないので
 * （猶予はサービス側の検証を助けるものであって、こちらのトークン発行は救わない）、
 * 期限の 3 分前から更新を試み、駄目ならバッチを溜める側に倒す。
 *
 * 受け取った側の telemetry-ingest は、バッチ 1 通ごとに
 * identity.v1.TokenIntrospection/BatchIntrospect でまとめて検証する。こちらが
 * 1 バッチに 1 トークンしか載せないのはそのため。
 */

#ifndef OFV_UPLINK_CLIENT_HPP
#define OFV_UPLINK_CLIENT_HPP

#include <chrono>
#include <cstdint>
#include <string>
#include <string_view>

#include "ofv/batch_assembler.hpp"

namespace ofv {

/// @brief 呼び出し結果。HTTP の細部を上位に漏らさないための最小の分類。
enum class UplinkResult {
    Accepted,      ///< 2xx。バッチは捨ててよい
    Duplicate,     ///< 409。既に取り込み済み。再送の正常系なので成功として扱う
    Rejected,      ///< 4xx。中身が悪い。再送しても直らないので捨ててログに残す
    Unauthorized,  ///< 401/403。トークン更新か、地域違いによる拒否
    Retryable,     ///< 5xx / タイムアウト / 圏外
};

/// @brief 起動時に環境から読む設定。名前は SPEC §5 のとおりで、勝手な別名は作らない。
struct UplinkConfig {
    std::string telemetry_base_url;      ///< 例: http://telemetry-ingest:8084
    std::string identity_base_url;       ///< OF_IDENTITY_JWKS_URL と同じホスト
    std::string tenant_id;               ///< `tnt_` 付き。X-OF-Tenant にそのまま入る
    std::string gateway_id;              ///< `gwy_` 付き
    std::string region_code;             ///< OF_REGION_CODE
    std::string credential_id;           ///< `cred_` 付き。identity-service へ提示する
    std::string signing_key_pem;         ///< Ed25519 秘密鍵。公開鍵は telemetry.device_gateways.public_key
    bool signature_required = true;      ///< OF_TELEMETRY_SIGNATURE_REQUIRED。local 環境以外は必ず true
    std::chrono::minutes heartbeat_interval{5}; ///< OF_TELEMETRY_HEARTBEAT_TIMEOUT_MINUTES より十分短く
};

/**
 * @brief telemetry-ingest への片方向クライアント。
 *
 * container-registry は呼ばない。コンテナから出荷を引くのは
 * freight.v1.ContainerLookup/ResolveShipmentForContainer だが、それを呼ぶのは
 * telemetry-ingest の役目で、基板が横から同じ解決をすると
 * shipment_id の食い違いが起きる。基板は container_id までしか知らないでよい。
 */
class UplinkClient {
public:
    explicit UplinkClient(UplinkConfig config);

    /**
     * @brief バッチを POST /v1/ingest/batch へ送る。
     *
     * ヘッダは X-OF-Tenant / X-OF-Trace-Id / X-OF-Idempotency-Key / X-OF-Actor-Kind の 4 点セット。
     * 冪等キーには ingest_batch_id をそのまま使う。ボディは Ed25519 で署名し、
     * telemetry-ingest は telemetry.device_gateways.public_key で検証する。
     */
    UplinkResult sendBatch(const IngestBatch& batch);

    /**
     * @brief POST /v1/gateways/{gateway_id}/heartbeat を撃つ。
     *
     * これが OF_TELEMETRY_HEARTBEAT_TIMEOUT_MINUTES ぶん途切れると、telemetry-ingest が
     * gateway.heartbeat.missed を publish し、notification-service が担当者に飛ばす。
     * つまりここを止めるのは「基板が壊れた」と宣言するのと同じ意味になる。
     */
    UplinkResult sendHeartbeat(std::size_t pending_batches, std::uint64_t dropped_readings);

    /// @brief 次の heartbeat を撃つべき時刻を過ぎているか。
    bool heartbeatDue(std::chrono::system_clock::time_point now) const;

    /// @brief 現在のアクセストークンが使えるか。期限 3 分前から false になる。
    bool tokenUsable(std::chrono::system_clock::time_point now) const;

    /**
     * @brief identity-service からアクセストークンを取り直す。
     * @return 取れたら true。圏外や 5xx では false を返し、呼び出し側は送信を諦めて溜める。
     */
    bool refreshToken();

private:
    /// @brief バッチ本体を JSON 化する。数値は SPEC §0.2 の単位に戻して出す。
    std::string renderBatchBody(const IngestBatch& batch) const;

    /// @brief 本文に Ed25519 署名を付け、X-OF-Signature 相当のヘッダ値を作る。
    std::string signBody(std::string_view body) const;

    /// @brief 32 桁 16 進の W3C trace-id を作る。バッチごとに 1 本。
    static std::string mintTraceId();

    UplinkConfig config_;
    std::string access_token_;
    std::chrono::system_clock::time_point token_expires_at_{};
    std::chrono::system_clock::time_point last_heartbeat_at_{};
};

} // namespace ofv

#endif // OFV_UPLINK_CLIENT_HPP
