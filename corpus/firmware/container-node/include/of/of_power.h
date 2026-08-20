/*
 * ORBITALFREIGHT container sensor node — power subsystem
 * SPDX-License-Identifier: LicenseRef-ORBITALFREIGHT-Internal
 */

/**
 * @file of_power.h
 * @brief 電源モードの遷移、残量推定、そして「あと何回送れるか」を決める電力予算の API。
 *
 * ノードは一次電池（LiSOCl2 19 Ah）で 5 年もたせる前提なので、消費電流の 9 割以上は
 * LoRa の送信と MCU の起動時間で決まる。ここはその 2 つを削るためだけの層で、
 * サンプリング周期を伸ばす判断も、しきい値超過時に予算を無視して即送する判断も、
 * すべて @ref of_power_budget_t を通す。
 *
 * 残量が @ref OF_POWER_BATTERY_CRITICAL_PCT を割ると、app 層が rule_code
 * `battery_critical` のアラートヒントを立てる。実際に telemetry.telemetry_alerts に
 * 行を書いて telemetry.alert.raised を出すのは telemetry-ingest であって、ノードではない。
 */

#ifndef OF_POWER_H
#define OF_POWER_H

#include "of/of_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/** @brief この残量を割ったら battery_critical のヒントを立てる。SPEC の rule_code に対応。 */
#define OF_POWER_BATTERY_CRITICAL_PCT 15u

/** @brief 無線を完全に諦めて計測だけ続ける残量。ここから先は store-and-forward のみ。 */
#define OF_POWER_RADIO_CUTOFF_PCT 5u

/**
 * @brief STM32L4 の低電力モードのうち、この設計で実際に使う 4 つ。
 *
 * STOP1 は使わない。STOP2 との消費差が実測 0.9 µA しかなく、周辺の
 * 復帰条件を 2 通り維持する保守コストに見合わなかった。
 */
typedef enum {
    OF_POWER_MODE_RUN = 0,   /**< 80 MHz。センサ読み出しと符号化のときだけ */
    OF_POWER_MODE_LPRUN,     /**< 2 MHz。I2C 待ちで居座るときの既定 */
    OF_POWER_MODE_STOP2,     /**< SRAM 保持、RTC 稼働。サンプリング間の通常状態（実測 1.1 µA） */
    OF_POWER_MODE_STANDBY    /**< 出荷モード。プロビジョニング前と、電池交換待ちのとき */
} of_power_mode_t;

/** @brief STOP2 からの復帰要因。ビット和で指定する。 */
typedef enum {
    OF_WAKE_RTC_ALARM = 1u << 0,  /**< サンプリング周期の満了 */
    OF_WAKE_DOOR_SWITCH = 1u << 1,/**< 扉リードスイッチの変化。デバウンス前 */
    OF_WAKE_ACCEL_INT1 = 1u << 2, /**< LIS3DH のしきい値割り込み（衝撃） */
    OF_WAKE_RADIO_DIO0 = 1u << 3, /**< SX1276 の TxDone / RxDone */
    OF_WAKE_TAMPER = 1u << 4      /**< 筐体開封検知。封印破りの証跡になるので必ず送る */
} of_wake_source_t;

/**
 * @brief 電力予算。1 日単位でリセットされ、送信のたびに減る。
 *
 * uplinks_remaining_today を使い切っても、しきい値超過フレームは
 * @ref of_power_reserve_emergency の枠から出す。温度逸脱の速報を電池のために
 * 握り潰すのは本末転倒なので、非常枠は常に 8 通確保している。
 */
typedef struct {
    uint16_t uplinks_remaining_today; /**< 通常枠の残り */
    uint16_t emergency_remaining;     /**< 非常枠の残り。日跨ぎでリセット */
    uint32_t airtime_used_ms_today;   /**< 送信時間の累計。地域の duty cycle 規制の分母 */
    of_battery_pct_t battery_pct;     /**< 直近の推定残量 */
    bool radio_allowed;               /**< 残量が @ref OF_POWER_RADIO_CUTOFF_PCT を上回るか */
} of_power_budget_t;

/**
 * @brief 電源サブシステムを初期化する。VBAT の ADC 較正はここで 1 度だけ行う。
 * @param region 地域コード。duty cycle の上限がこれで決まる。
 */
of_err_t of_power_init(of_region_t region);

/**
 * @brief 指定ミリ秒だけ STOP2 で眠る。指定した復帰要因のいずれかで早く目覚める。
 *
 * @param ms      最大スリープ時間。RTC のカウンタ幅から 1 時間で頭打ちにしている。
 * @param sources @ref of_wake_source_t のビット和。
 * @return 実際に起こした要因のビット和。時間切れなら OF_WAKE_RTC_ALARM のみ。
 *
 * @note 呼ぶ前に SX1276 を sleep に落としておくこと。RX continuous のまま STOP2 に
 *       入ると 12 mA を引き続けて、電池が 3 週間で終わる。実機で 1 度やった。
 */
uint32_t of_power_enter_stop2(uint32_t ms, uint32_t sources);

/** @brief 動作モードを切り替える。クロック設定の変更を伴うので I2C 転送中は呼べない。 */
of_err_t of_power_set_mode(of_power_mode_t mode);

/** @brief 現在の電力予算のスナップショットを返す。 */
const of_power_budget_t *of_power_budget(void);

/**
 * @brief 送信 1 回分を予算から引く。
 * @param airtime_ms 予想 airtime。@ref of_lora_airtime_ms の戻り値をそのまま渡す。
 * @param emergency  true なら非常枠から引く。
 * @return 予算が足りれば OF_OK、足りなければ OF_ERR_NO_SPACE。
 */
of_err_t of_power_reserve_uplink(uint32_t airtime_ms, bool emergency);

/** @brief 非常枠を明示的に確保し直す。設定ダウンリンクで枠数を変えたときに呼ぶ。 */
void of_power_reserve_emergency(uint16_t slots);

/**
 * @brief 電池残量を推定して返す。
 *
 * LiSOCl2 は放電曲線がほぼ平坦なので、開放電圧だけでは残量が読めない。
 * 送信中の電圧降下（内部抵抗の増加）と積算電流の両方を見る素朴なモデルで、
 * 実測との誤差は 20 % 以下の領域で ±4 ポイント程度。
 */
of_battery_pct_t of_power_battery_pct(void);

/** @brief 日次のリセット。RTC の 00:00 UTC アラームから呼ばれる。 */
void of_power_rollover_day(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OF_POWER_H */
