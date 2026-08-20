/**
 * @file of_reading.h
 * @brief 1 回のサンプリング結果を表すレコード構造体と、LoRa で運ぶフレームの物理レイアウト。
 *
 * ここで定義する of_reading_t の各フィールドは telemetry.telemetry_readings のカラムと
 * 一対一に対応する。vehicle-board が POST /v1/ingest/batch の JSON を組み立てるとき、
 * 変換表を別に持たなくて済むようにするためで、カラムを増やすときは SPEC §2.5 →
 * このヘッダ → batch_assembler の順に直す。
 *
 * @see firmware/vehicle-board/include/ofv/batch_assembler.hpp
 * @see services/telemetry-ingest — 受け側のスキーマとバリデーション
 */

#ifndef OF_READING_H
#define OF_READING_H

#include "of/of_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/** @brief 1 フレームに詰め込めるレコード数。SF12 での最大ペイロード 51 バイトから逆算した値。 */
#define OF_FRAME_MAX_RECORDS 4

/** @brief LoRa フレームの先頭に置くマジック。異種ネットワークの混信を安く弾くため。 */
#define OF_FRAME_MAGIC 0x4F46u /* 'O','F' */

/** @brief フレームフォーマットのバージョン。受信側は未知の値を黙って捨てる。 */
#define OF_FRAME_VERSION 3

/**
 * @brief of_reading_t.flags のビット定義。
 *
 * door_open は telemetry.telemetry_readings.door_open にそのまま入る。
 * 位置情報は GNSS を積んだリーファ用ノードにしか無いので、無効時は position を null にする。
 */
typedef enum {
    OF_READING_FLAG_DOOR_OPEN = 1u << 0,      /**< 扉開放。リードスイッチのデバウンス後の確定値 */
    OF_READING_FLAG_POSITION_VALID = 1u << 1, /**< lat/lon が有効。GNSS 未搭載機では常に 0 */
    OF_READING_FLAG_CLOCK_UNSYNCED = 1u << 2, /**< time_sync 前に採取。recorded_at の信頼度が低い */
    OF_READING_FLAG_THRESHOLD_HIT = 1u << 3,  /**< しきい値を跨いだ。§4.8 のサンプリングを迂回して必ず送る */
    OF_READING_FLAG_REEFER_ACTIVE = 1u << 4,  /**< 冷凍機が運転中。setpoint_c との比較を有効にする */
    OF_READING_FLAG_RETRANSMIT = 1u << 5      /**< 再送分。重複排除に頼るので中身は初回と完全に同一 */
} of_reading_flag_t;

/**
 * @brief 1 サンプル分の計測値。
 *
 * container_id を毎レコードに持たせているのは、1 台の vehicle-board が
 * 複数コンテナのノードを同時に拾う構成（連結トレーラ、鉄道ワゴン）があるため。
 * gateway_id はノードが知らない値なので入っていない。付けるのは vehicle-board。
 */
typedef struct {
    of_id_t container_id;        /**< `cnt_` 付き ULID。プロビジョニング時に焼かれる */
    of_epoch_ms_t recorded_at;   /**< センサ側の時計。received_at は telemetry-ingest が打つ */
    of_temp_c100_t temperature_c;
    of_humid_p100_t humidity_pct;
    of_shock_mg_t shock_g;       /**< 直近サンプリング周期内の 3 軸合成ピーク */
    of_coord_1e7_t latitude;
    of_coord_1e7_t longitude;
    of_battery_pct_t battery_pct;
    uint8_t flags;               /**< @ref of_reading_flag_t のビット和 */
    uint16_t sequence;           /**< ノード内の巡回連番。欠測区間の検出に使う */
} of_reading_t;

/** @brief フレーム種別。ペイロードの解釈がこれで決まる。 */
typedef enum {
    OF_FRAME_KIND_READING = 1,   /**< 計測値の束。通常のアップリンク */
    OF_FRAME_KIND_ALERT_HINT = 2,/**< しきい値超過の速報。ingest 側の判定を待たずに即送する */
    OF_FRAME_KIND_HEARTBEAT = 3, /**< 生存通知。vehicle-board が自分の heartbeat に畳み込む */
    OF_FRAME_KIND_TIME_SYNC = 4, /**< ダウンリンク。RTC 補正値を運ぶ */
    OF_FRAME_KIND_CONFIG = 5     /**< ダウンリンク。しきい値とサンプリング周期の更新 */
} of_frame_kind_t;

/**
 * @brief 無線フレームの固定長ヘッダ。バイト順はリトルエンディアン、詰め物なし。
 *
 * crc16 はこのヘッダ（crc16 自身を 0 とみなす）とペイロード全体に対して計算する。
 * LoRa 自体の CRC は物理層のビット化けしか見ないので、FIFO の読み書きで壊れた
 * ケースを掴むために別途持っている。実際、SPI クロックを 8 MHz に上げた
 * リビジョン B の初期ロットでこれが効いた。
 */
typedef struct __attribute__((packed)) {
    uint16_t magic;      /**< @ref OF_FRAME_MAGIC */
    uint8_t version;     /**< @ref OF_FRAME_VERSION */
    uint8_t kind;        /**< @ref of_frame_kind_t */
    uint32_t node_serial;/**< 出荷時シリアル。telemetry.device_gateways.serial とは別物 */
    uint16_t sequence;   /**< フレーム連番。ACK 照合に使う */
    uint8_t record_count;/**< 続くレコード数。0 は heartbeat のみ許される */
    uint8_t payload_len; /**< ヘッダを除いた長さ */
    uint16_t crc16;      /**< CRC-16/CCITT-FALSE。@ref of_crc16_ccitt */
} of_frame_header_t;

/** @brief ヘッダ長。パディングが入っていないことを翻訳時に確かめる。 */
#define OF_FRAME_HEADER_SIZE 14u
_Static_assert(sizeof(of_frame_header_t) == OF_FRAME_HEADER_SIZE,
               "frame header must stay packed at 14 bytes");

/**
 * @brief レコード列をフレームに符号化する。
 *
 * container_id は毎レコードではなくフレーム先頭に 1 度だけ載せ、以降のレコードは
 * 先頭レコードからの差分（時刻は delta、温度は差分、位置は下位ビットのみ）で持つ。
 * SF12 の 51 バイト制限に 4 レコードを収めるにはこれが必要だった。
 *
 * @param records   符号化するレコード列。全て同じ container_id であること。
 * @param count     レコード数。1〜@ref OF_FRAME_MAX_RECORDS。
 * @param kind      フレーム種別。
 * @param out       出力バッファ。
 * @param out_cap   出力バッファ長。
 * @param[out] out_len 実際に書いた長さ。
 * @return OF_OK、または OF_ERR_INVALID_ARG / OF_ERR_NO_SPACE。
 */
of_err_t of_frame_encode(const of_reading_t *records, uint8_t count, of_frame_kind_t kind,
                         uint8_t *out, size_t out_cap, size_t *out_len);

/**
 * @brief フレームを復号する。CRC 不一致なら OF_ERR_CRC を返して何も書かない。
 *
 * vehicle-board 側もこの実装を extern "C" でそのまま呼ぶ。符号化と復号を
 * 別言語で二重実装すると、差分符号化のオフバイワンが片側だけに入る。
 *
 * @param in        受信バイト列。
 * @param in_len    受信長。
 * @param[out] out  復号先。最大 @ref OF_FRAME_MAX_RECORDS 件。
 * @param out_cap   out の要素数。
 * @param[out] out_count 復号できた件数。
 * @param[out] header 復号したヘッダ（NULL 可）。
 */
of_err_t of_frame_decode(const uint8_t *in, size_t in_len, of_reading_t *out, uint8_t out_cap,
                         uint8_t *out_count, of_frame_header_t *header);

/**
 * @brief レコードを既定値で初期化する。センサが 1 つも応答しなかった場合でも
 *        battery_pct と recorded_at だけは埋まった状態にしておく。
 */
void of_reading_init(of_reading_t *reading, const char *container_id);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OF_READING_H */
