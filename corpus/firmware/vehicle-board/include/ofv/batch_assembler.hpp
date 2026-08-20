/**
 * @file batch_assembler.hpp
 * @brief 車載テレメトリ基板が、複数のコンテナノードから拾った計測値を 1 つの取り込みバッチに束ねる層。
 *
 * この基板は telemetry.device_gateways に depot_id が NULL の行として登録される移動体ゲートウェイで、
 * depot に据え置かれる edge/ のゲートウェイエージェントと役割は同じ。違うのは、圏外を走る時間が
 * 支配的なことと、電源が車両のバッテリだということ。したがってここでの主題は
 * 「いつ送るか」ではなく「送れない間どう溜め、復帰したときどう重複させずに吐き出すか」になる。
 *
 * バッチは telemetry-ingest の POST /v1/ingest/batch にそのまま渡る。重複排除は向こうの
 * readings_dedupe_idx (region_code, ingest_batch_id, container_id, recorded_at) が引き受けるので、
 * 再送で同じ ingest_batch_id を使い回すのは仕様どおりの正しい動作であって、手抜きではない。
 */

#ifndef OFV_BATCH_ASSEMBLER_HPP
#define OFV_BATCH_ASSEMBLER_HPP

#include <chrono>
#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

extern "C" {
#include "of/of_reading.h"
}

namespace ofv {

/// @brief 1 バッチに詰められるレコード数の上限。telemetry-ingest の OF_TELEMETRY_BATCH_MAX_READINGS と揃える。
inline constexpr std::size_t kMaxReadingsPerBatch = 500;

/// @brief 送信待ちのバッチをいくつまで抱えるか。これを超えたら最も古いバッチから捨てる。
inline constexpr std::size_t kMaxPendingBatches = 64;

/**
 * @brief 送信可能な状態まで組み上がった 1 バッチ。
 *
 * ingest_batch_id は SPEC §0.1 の接頭辞付き ID ではない。あの表に載っていないからで、
 * 素の ULID 26 文字をそのまま使う。X-OF-Idempotency-Key にも同じ値を入れるので、
 * 再送は telemetry-ingest 側で 24 時間まで冪等に潰れる。
 */
struct IngestBatch {
    std::string ingest_batch_id;              ///< 素の ULID。生成は @ref BatchAssembler::mintBatchId
    std::string region_code;                  ///< SPEC §0.6 のいずれか。基板の焼き込み値
    std::string gateway_id;                   ///< `gwy_` 付き。telemetry.device_gateways.gateway_id
    std::vector<of_reading_t> readings;       ///< 送る計測値。container_id はレコードごとに異なりうる
    std::chrono::system_clock::time_point sealed_at; ///< 封をした時刻。再送の順序付けに使う
    std::uint32_t attempts = 0;               ///< 送信試行回数。バックオフの指数部
};

/**
 * @brief ノードから届いたフレームを解いて、バッチに積み上げる。
 *
 * スレッド安全ではない。無線受信スレッドが 1 本、送信スレッドが 1 本という構成で、
 * 両者の受け渡しは @ref takeSealedBatch の戻り値の所有権移動だけで行っている。
 */
class BatchAssembler {
public:
    /**
     * @param gateway_id  この基板の `gwy_` ID。プロビジョニング時に telemetry-ingest へ登録済みのもの。
     * @param region_code 焼き込まれた地域コード。異なる地域のバッチを作らせないための鍵。
     */
    BatchAssembler(std::string gateway_id, std::string region_code);

    /**
     * @brief 受信済みの LoRa フレームを取り込む。
     *
     * フレームの復号は container-node と同じ C 実装（of_frame_decode）を extern "C" で呼ぶ。
     * 符号化と復号を言語ごとに書き直すと差分符号化のずれが片側にだけ入るため。
     *
     * @param frame 受信バイト列（ヘッダ込み）。
     * @return 取り込んだレコード数。CRC 不一致や未知バージョンなら 0。
     */
    std::size_t ingestFrame(const std::uint8_t* frame, std::size_t len);

    /**
     * @brief 現在の蓄積バッチに封をして、送信キューへ移す。
     *
     * 呼ばれる契機は 3 つ。レコード数が @ref kMaxReadingsPerBatch に達したとき、
     * 前回の封から 60 秒経ったとき、そして通信が復帰した瞬間。
     *
     * @return 封をしたバッチがあれば true。空なら何もせず false。
     */
    bool sealCurrent();

    /**
     * @brief 送信すべきバッチを 1 つ取り出す。所有権は呼び出し側へ移る。
     * @return 送信待ちが無ければ std::nullopt。
     */
    std::optional<IngestBatch> takeSealedBatch();

    /**
     * @brief 送信に失敗したバッチを戻す。試行回数を増やし、キューの先頭に置き直す。
     *
     * 順序を保つのは、telemetry-ingest 側の重複排除が recorded_at を鍵に含むためではなく、
     * container-registry が telemetry.reading.recorded を消費して
     * freight.containers.last_reading_at を更新するときに、古い値で上書きされると困るから。
     */
    void requeue(IngestBatch batch);

    /// @brief 送信待ちのバッチ数。車両の HMI に「未送信 n 件」として出している。
    std::size_t pendingCount() const noexcept { return pending_.size(); }

    /// @brief 溢れて捨てた累計レコード数。heartbeat の診断値に載せる。
    std::uint64_t droppedReadings() const noexcept { return dropped_readings_; }

    /// @brief ノードのシリアルから container_id への対応表を更新する。設定配信で降ってくる。
    void mapNodeSerial(std::uint32_t serial, std::string container_id);

private:
    /// @brief 26 文字の ULID を作る。時刻上位 48 ビット + 乱数 80 ビット。
    static std::string mintBatchId(std::chrono::system_clock::time_point now);

    std::string gateway_id_;
    std::string region_code_;
    std::vector<of_reading_t> current_;
    std::chrono::system_clock::time_point current_opened_at_{};
    std::deque<IngestBatch> pending_;
    std::vector<std::pair<std::uint32_t, std::string>> serial_map_;
    std::uint64_t dropped_readings_ = 0;
};

} // namespace ofv

#endif // OFV_BATCH_ASSEMBLER_HPP
