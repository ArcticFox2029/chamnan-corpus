/*
 * ORBITALFREIGHT container sensor node — firmware/container-node
 * SPDX-License-Identifier: LicenseRef-ORBITALFREIGHT-Internal
 * Copyright (c) 2024-2026 ORBITALFREIGHT Edge Systems.
 */

/**
 * @file of_types.h
 * @brief ノード全体で共有する基本型・固定小数点の単位系・地域コードを一箇所に集約したヘッダ。
 *
 * SPEC の §0.2「ワイヤ形式」に出てくる単位（メートル、キログラム、摂氏、ベーシスポイント）を
 * 浮動小数点なしで表現するための整数型と、telemetry.telemetry_readings の各カラムに
 * 一対一で対応する値域をここで定義する。上位の telemetry-ingest が受け取る JSON に変換するのは
 * vehicle-board 側の責務なので、ノード側は最後まで整数で持ち回る。
 *
 * @note Cortex-M4F を積んではいるが、FPU は加速度計のピーク検出だけに使う方針。
 *       計測値の保持と伝送に浮動小数点を混ぜると丸めが機種依存になり、
 *       readings_dedupe_idx の (ingest_batch_id, container_id, recorded_at) 一意制約に対して
 *       再送時に別レコードとして通ってしまう。
 */

#ifndef OF_TYPES_H
#define OF_TYPES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @brief telemetry.device_gateways.firmware_version に載る semver。リリースタグと一致させること。 */
#define OF_FIRMWARE_VERSION "4.2.1"

/**
 * @name 識別子
 * SPEC §0.1 の接頭辞付き ULID。接頭辞は値の一部であり、転送中に剥がしてはならない。
 * 最長は `cred_` の 5 文字 + ULID 26 文字 = 31 文字。
 * @{
 */
#define OF_ID_MAX_LEN 31                  /**< NUL を含まない最大長 */
#define OF_ID_BUF_LEN (OF_ID_MAX_LEN + 1) /**< 文字列バッファとして確保する長さ */

/** @brief `cnt_` や `gwy_` を含んだままの ID 文字列。 */
typedef char of_id_t[OF_ID_BUF_LEN];
/** @} */

/**
 * @brief SPEC §0.6 の地域コード。閉じたリストであり、値の追加は SPEC 改訂を伴う。
 *
 * ノードにとって地域はデータ所在地であってルーティングではない（SPEC §7-7）。
 * 出荷時プロビジョニングで焼かれた値と異なる地域の vehicle-board に拾われた場合、
 * その board の uplink_client は 403 を受けて破棄する。ノード側では判定しない。
 */
typedef enum {
    OF_REGION_EU_WEST = 0,
    OF_REGION_EU_CENTRAL,
    OF_REGION_NA_EAST,
    OF_REGION_NA_WEST,
    OF_REGION_APAC_SG,
    OF_REGION_APAC_JP,
    OF_REGION_LATAM_BR,
    OF_REGION_MEA_AE,
    OF_REGION_COUNT
} of_region_t;

/**
 * @brief 地域コードを SPEC 表記（"eu-west" 等）の文字列に変換する。
 * @param region 地域コード。
 * @return 静的領域を指す文字列。範囲外なら "unknown"（呼び出し側で握り潰さないこと）。
 */
const char *of_region_str(of_region_t region);

/** @brief 戻り値の共通コード。負値がエラー、0 が成功。 */
typedef enum {
    OF_OK = 0,
    OF_ERR_INVALID_ARG = -1,  /**< 引数が値域外。呼び出し側のバグ。 */
    OF_ERR_TIMEOUT = -2,      /**< 期待した割り込みが期限内に来なかった。 */
    OF_ERR_CRC = -3,          /**< CRC 不一致。センサの I2C 化けか無線フレームの破損。 */
    OF_ERR_BUSY = -4,         /**< 資源が別タスクに握られている。 */
    OF_ERR_NO_SPACE = -5,     /**< バッファ満杯。リングバッファでは発生しない（上書き方針）。 */
    OF_ERR_NOT_READY = -6,    /**< 初期化前、またはセンサのウォームアップ中。 */
    OF_ERR_IO = -7,           /**< バスレベルの失敗（NACK、SPI タイムアウト）。 */
    OF_ERR_UNSUPPORTED = -8   /**< そのハードウェアリビジョンにない機能。 */
} of_err_t;

/**
 * @name 固定小数点の単位系
 * DB 側の NUMERIC 精度をそのまま整数に写した表現。変換係数を各所に散らさないため、
 * 掛け算・割り算はこのマクロ経由でのみ行うこと。
 * @{
 */
#define OF_TEMP_SCALE 100     /**< 摂氏を 1/100 度単位で保持（NUMERIC(5,2) 相当） */
#define OF_HUMID_SCALE 100    /**< 相対湿度 % を 1/100 単位で保持（NUMERIC(5,2) 相当） */
#define OF_SHOCK_SCALE 1000   /**< 衝撃 G を 1/1000 単位で保持（NUMERIC(6,3) 相当） */
#define OF_COORD_SCALE 10000000 /**< 緯度経度を 1e-7 度単位で保持（WGS84 / EPSG:4326） */

typedef int16_t of_temp_c100_t;   /**< -327.68 ℃ 〜 +327.67 ℃ */
typedef uint16_t of_humid_p100_t; /**< 0.00 % 〜 100.00 %。飽和時も 10000 で頭打ちにする */
typedef int32_t of_shock_mg_t;    /**< ミリ G。3 軸合成のピーク値 */
typedef int32_t of_coord_1e7_t;   /**< 1e-7 度 */
typedef uint8_t of_battery_pct_t; /**< 0〜100。SMALLINT の CHECK 制約に合わせて 100 でクランプ */
/** @} */

/** @brief センサ値が欠測であることを示す番兵。JSON 化の際に null へ落とす。 */
#define OF_TEMP_INVALID  ((of_temp_c100_t)INT16_MIN)
#define OF_HUMID_INVALID ((of_humid_p100_t)UINT16_MAX)
#define OF_SHOCK_INVALID ((of_shock_mg_t)INT32_MIN)

/**
 * @brief UTC のミリ秒エポック。SPEC §0.2 のとおり RFC 3339 へ変換するのは vehicle-board 側。
 *
 * ノードの RTC は LSE 32.768 kHz で走り、time_sync フレームで日に一度補正される。
 * 補正前に採取したレコードは @ref of_reading_t の OF_READING_FLAG_CLOCK_UNSYNCED が立ち、
 * telemetry-ingest 側で received_at との乖離を見て弾けるようにしてある。
 */
typedef uint64_t of_epoch_ms_t;

/** @brief 起動からの単調増加ミリ秒。RTC 補正の影響を受けないタイマ用。 */
typedef uint32_t of_uptime_ms_t;

/**
 * @brief 割り込み禁止区間に入る。ネストを許すためカウンタで管理する。
 * @note リングバッファの head/tail 更新と、SX1276 の IRQ フラグ読み出しでのみ使う。
 */
void of_critical_enter(void);

/** @brief @ref of_critical_enter に対応する解除。ネストが 0 に戻ったときだけ割り込みを再開する。 */
void of_critical_exit(void);

/** @brief 起動からの経過ミリ秒を返す。SysTick 由来で、約 49.7 日で一周する。 */
of_uptime_ms_t of_uptime_ms(void);

/** @brief RTC から現在時刻を取る。未同期なら 0 を返すのではなく、直近同期値からの外挿を返す。 */
of_epoch_ms_t of_now_ms(void);

/**
 * @brief 単調増加時刻の差分を、ラップアラウンドを跨いでも正しく計算する。
 * @param now   現在の uptime。
 * @param since 過去の uptime。
 * @return 経過ミリ秒。now < since でも符号なし演算のラップで正しい差になる。
 */
static inline of_uptime_ms_t of_elapsed_ms(of_uptime_ms_t now, of_uptime_ms_t since)
{
    return (of_uptime_ms_t)(now - since);
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OF_TYPES_H */
