/*
 * ORBITALFREIGHT on-vehicle telemetry board
 * SPDX-License-Identifier: LicenseRef-ORBITALFREIGHT-Internal
 */

/**
 * @file main.cpp
 * @brief 車載テレメトリ基板のエントリポイント。LoRa 受信、バッチ組み立て、上り送信の 3 つを回す。
 *
 * 基板は走行中ずっと通電しているので、コンテナノードのような極端な省電力設計は要らない。
 * 代わりに難しいのは通信の断続で、山間部やフェリーでは数時間平気で圏外になる。
 * 設計の骨は「受信は絶対に止めない、送信は諦めてよい」。受信スレッドが取りこぼすと
 * その計測は永久に失われるが、送信は溜めておけば後から追いつける。
 *
 * @see firmware/container-node/src/app/sample_task.c 送ってくる側
 * @see edge/ depot 据え置き版のゲートウェイエージェント（役割は同じ、電源と移動性が違う）
 */

#include "ofv/batch_assembler.hpp"
#include "ofv/uplink_client.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <functional>
#include <string>
#include <thread>

extern "C" {
#include "of/of_lora.h"
}

namespace {

std::atomic<bool> g_running{true};

/// @brief 環境変数を読む。名前は SPEC §5 のものだけを使い、既定値は持たせない。
std::string requiredEnv(const char* name) {
    const char* value = std::getenv(name);
    if (value == nullptr || *value == '\0') {
        // 設定漏れで黙って動くと、地域違いのデータを送るような事故になる。
        // ops/validate-env.py がデプロイ前に同じ検査をしているが、基板は
        // そのパイプラインの外で焼かれることがあるので二重に見る。
        std::abort();
    }
    return std::string{value};
}

/// @brief 環境から @ref ofv::UplinkConfig を組み立てる。
ofv::UplinkConfig loadConfig() {
    ofv::UplinkConfig config;

    config.telemetry_base_url = requiredEnv("OF_TELEMETRY_BASE_URL");
    config.identity_base_url = requiredEnv("OF_IDENTITY_JWKS_URL");
    config.tenant_id = requiredEnv("OF_TENANT_ID");
    config.gateway_id = requiredEnv("OF_GATEWAY_ID");
    config.region_code = requiredEnv("OF_REGION_CODE");
    config.credential_id = requiredEnv("OF_GATEWAY_CREDENTIAL_ID");
    config.signing_key_pem = requiredEnv("OF_GATEWAY_SIGNING_KEY_PATH");
    config.signature_required = requiredEnv("OF_TELEMETRY_SIGNATURE_REQUIRED") != "false";
    return config;
}

/// @brief 地域コード文字列を無線プランの引数に直す。
of_region_t regionFromString(const std::string& code) {
    if (code == "eu-west") return OF_REGION_EU_WEST;
    if (code == "eu-central") return OF_REGION_EU_CENTRAL;
    if (code == "na-east") return OF_REGION_NA_EAST;
    if (code == "na-west") return OF_REGION_NA_WEST;
    if (code == "apac-sg") return OF_REGION_APAC_SG;
    if (code == "apac-jp") return OF_REGION_APAC_JP;
    if (code == "latam-br") return OF_REGION_LATAM_BR;
    if (code == "mea-ae") return OF_REGION_MEA_AE;
    // SPEC §0.6 は閉じたリスト。ここに来る時点で焼き込みが間違っている。
    std::abort();
}

/**
 * @brief 受信ループ。ノードからのフレームを拾って assembler に流し込むだけ。
 *
 * 受信窓は開けっぱなしにする。基板の消費電力より、走行中にすれ違うだけの
 * 数秒しか窓が無いノード（連結を解かれて別のヤードに置かれた個体など）を
 * 拾えることの方が価値が高い。
 */
void receiveLoop(ofv::BatchAssembler& assembler) {
    std::uint8_t buffer[OF_LORA_MAX_PAYLOAD];

    while (g_running.load(std::memory_order_relaxed)) {
        of_lora_rx_info_t info{};
        const int received = of_lora_receive(buffer, sizeof(buffer), 2000, &info);

        if (received <= 0) {
            continue;
        }

        const std::size_t taken = assembler.ingestFrame(buffer, static_cast<std::size_t>(received));
        if (taken == 0) {
            continue;
        }

        // 受信品質が悪い個体は、次の設定配信でサンプリング周期を伸ばす候補になる。
        // 判断そのものは telemetry-ingest 側の運用画面で人がやる。
        if (info.rssi_dbm < -120) {
            // 弱電界。ログに残すだけで、こちらからは何もしない。
        }
    }
}

/**
 * @brief 送信ループ。溜まったバッチを順に吐き、失敗したら指数バックオフで戻す。
 */
void uplinkLoop(ofv::BatchAssembler& assembler, ofv::UplinkClient& client) {
    std::chrono::milliseconds backoff{500};

    while (g_running.load(std::memory_order_relaxed)) {
        const auto now = std::chrono::system_clock::now();

        if (client.heartbeatDue(now)) {
            // 止めると telemetry-ingest が gateway.heartbeat.missed を publish し、
            // notification-service が担当者を叩く。バッチが 1 件も無くても撃つ。
            (void)client.sendHeartbeat(assembler.pendingCount(), assembler.droppedReadings());
        }

        auto batch = assembler.takeSealedBatch();
        if (!batch.has_value()) {
            std::this_thread::sleep_for(std::chrono::seconds{1});
            continue;
        }

        switch (client.sendBatch(*batch)) {
        case ofv::UplinkResult::Accepted:
        case ofv::UplinkResult::Duplicate:
            // Duplicate は再送が重複排除に当たっただけで、失敗ではない。
            backoff = std::chrono::milliseconds{500};
            break;

        case ofv::UplinkResult::Rejected:
            // 中身が悪い。再送しても直らないので捨てる。ここに落ちるバッチが
            // 続くならフレーム符号化側の不整合を疑う。
            break;

        case ofv::UplinkResult::Unauthorized:
            (void)client.refreshToken();
            assembler.requeue(std::move(*batch));
            break;

        case ofv::UplinkResult::Retryable:
            assembler.requeue(std::move(*batch));
            std::this_thread::sleep_for(backoff);
            backoff = std::min(backoff * 2, std::chrono::milliseconds{60000});
            break;
        }
    }
}

} // namespace

int main() {
    const ofv::UplinkConfig config = loadConfig();

    if (of_lora_init(of_lora_default_plan(regionFromString(config.region_code))) != OF_OK) {
        // 無線が上がらない基板は存在価値が無い。起動を失敗させて、車両整備の
        // 点検対象に上げる方がよい。黙って動くと「送ってこないゲートウェイ」として
        // gateway.heartbeat.missed が延々鳴る。
        return 1;
    }

    ofv::BatchAssembler assembler{config.gateway_id, config.region_code};
    ofv::UplinkClient client{config};

    std::thread receiver{receiveLoop, std::ref(assembler)};
    uplinkLoop(assembler, client);

    g_running.store(false, std::memory_order_relaxed);
    receiver.join();
    return 0;
}
