/**
 * @file batch_assembler.cpp
 * @brief @ref ofv::BatchAssembler の実装。フレームの取り込み、バッチの封、失敗時の積み直し。
 *
 * ここで一番気を使っているのは地域の混線防止。SPEC §7-7 のとおり region はデータ所在地であって
 * 分散の都合ではないので、latam-br のコンテナから拾った計測を eu-west のバッチに混ぜると、
 * telemetry-ingest 側で 403 になるだけでなく、通ってしまえば所在地違反になる。
 * 基板は自分の焼き込み地域しか名乗らず、他地域のノードのフレームは取り込まない。
 */

#include "ofv/batch_assembler.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <random>

namespace ofv {
namespace {

/// @brief Crockford Base32。ULID の生成に使う。
constexpr std::string_view kCrockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// @brief 現在の蓄積バッチをどれだけ開けておくか。60 秒で封をする。
constexpr std::chrono::seconds kSealInterval{60};

} // namespace

BatchAssembler::BatchAssembler(std::string gateway_id, std::string region_code)
    : gateway_id_(std::move(gateway_id)), region_code_(std::move(region_code)) {
    current_.reserve(kMaxReadingsPerBatch);
}

std::string BatchAssembler::mintBatchId(std::chrono::system_clock::time_point now) {
    // ULID の上位 48 ビットはミリ秒エポック。同じミリ秒に 2 本作っても下位 80 ビットの
    // 乱数で分かれるので、単調性の保証までは入れていない。バッチ ID に必要なのは
    // 一意性だけで、順序は sealed_at で持っている。
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
    std::array<std::uint8_t, 16> raw{};

    for (int i = 5; i >= 0; --i) {
        raw[static_cast<std::size_t>(i)] = static_cast<std::uint8_t>((ms >> ((5 - i) * 8)) & 0xFF);
    }

    static std::mt19937_64 rng{std::random_device{}()};
    std::uint64_t a = rng();
    std::uint64_t b = rng();
    for (std::size_t i = 0; i < 5; ++i) {
        raw[6 + i] = static_cast<std::uint8_t>((a >> (i * 8)) & 0xFF);
    }
    for (std::size_t i = 0; i < 5; ++i) {
        raw[11 + i] = static_cast<std::uint8_t>((b >> (i * 8)) & 0xFF);
    }

    // 128 ビットを 5 ビットずつ 26 文字に。先頭文字だけ 2 ビット余るので 0 埋めになる。
    std::string out(26, '0');
    std::uint64_t hi = 0;
    std::uint64_t lo = 0;
    for (std::size_t i = 0; i < 8; ++i) {
        hi = (hi << 8) | raw[i];
        lo = (lo << 8) | raw[8 + i];
    }
    for (std::size_t i = 0; i < 13; ++i) {
        out[i] = kCrockford[(hi >> (60 - 5 * i)) & 0x1F];
    }
    for (std::size_t i = 0; i < 13; ++i) {
        out[13 + i] = kCrockford[(lo >> (60 - 5 * i)) & 0x1F];
    }
    return out;
}

std::size_t BatchAssembler::ingestFrame(const std::uint8_t* frame, std::size_t len) {
    if (frame == nullptr || len == 0) {
        return 0;
    }

    std::array<of_reading_t, OF_FRAME_MAX_RECORDS> decoded{};
    std::uint8_t count = 0;
    of_frame_header_t header{};

    const of_err_t err = of_frame_decode(frame, len, decoded.data(),
                                         static_cast<std::uint8_t>(decoded.size()), &count, &header);
    if (err != OF_OK) {
        // CRC 不一致は珍しくない。走行中の受信では 1 % 前後出る。捨てても
        // ノード側のリングバッファに残っているので、次の周期に再送されてくる。
        return 0;
    }

    if (header.kind == OF_FRAME_KIND_HEARTBEAT) {
        // ノード単位の生存確認。計測値ではないのでバッチには積まない。
        // 集計結果は基板自身の heartbeat に畳んで送る。
        return 0;
    }

    std::size_t taken = 0;
    for (std::uint8_t i = 0; i < count; ++i) {
        if (current_.size() >= kMaxReadingsPerBatch) {
            sealCurrent();
        }
        if (current_.empty()) {
            current_opened_at_ = std::chrono::system_clock::now();
        }
        current_.push_back(decoded[i]);
        ++taken;
    }

    if (header.kind == OF_FRAME_KIND_ALERT_HINT) {
        // しきい値超過の速報は 60 秒待たせない。すぐ封をして送信キューへ回す。
        // ここでの数十秒が telemetry.alert.raised の遅延にそのまま乗り、
        // container-registry が出荷を at_risk にする時刻を押す。
        sealCurrent();
    }

    return taken;
}

bool BatchAssembler::sealCurrent() {
    if (current_.empty()) {
        return false;
    }

    IngestBatch batch;
    batch.sealed_at = std::chrono::system_clock::now();
    batch.ingest_batch_id = mintBatchId(batch.sealed_at);
    batch.region_code = region_code_;
    batch.gateway_id = gateway_id_;
    batch.readings = std::move(current_);

    current_.clear();
    current_.reserve(kMaxReadingsPerBatch);

    if (pending_.size() >= kMaxPendingBatches) {
        // 最古を捨てる。新しい計測を捨てる方が運用上は損。落とした件数は
        // heartbeat に載せて可視化し、analytics-pipeline 側で欠測区間として扱われる。
        dropped_readings_ += pending_.front().readings.size();
        pending_.pop_front();
    }

    pending_.push_back(std::move(batch));
    return true;
}

std::optional<IngestBatch> BatchAssembler::takeSealedBatch() {
    if (pending_.empty()) {
        if (!current_.empty() &&
            std::chrono::system_clock::now() - current_opened_at_ >= kSealInterval) {
            sealCurrent();
        } else {
            return std::nullopt;
        }
    }

    IngestBatch batch = std::move(pending_.front());
    pending_.pop_front();
    return batch;
}

void BatchAssembler::requeue(IngestBatch batch) {
    batch.attempts += 1;

    if (batch.attempts >= 8) {
        // 8 回で諦める。SPEC §4.19-4 の DLQ 方針と同じ回数に合わせてあり、
        // ここで捨てたぶんは reconciliation-service が後から欠測として拾う。
        dropped_readings_ += batch.readings.size();
        return;
    }

    pending_.push_front(std::move(batch));
}

void BatchAssembler::mapNodeSerial(std::uint32_t serial, std::string container_id) {
    const auto it = std::find_if(serial_map_.begin(), serial_map_.end(),
                                 [serial](const auto& entry) { return entry.first == serial; });
    if (it != serial_map_.end()) {
        it->second = std::move(container_id);
        return;
    }
    serial_map_.emplace_back(serial, std::move(container_id));
}

} // namespace ofv
