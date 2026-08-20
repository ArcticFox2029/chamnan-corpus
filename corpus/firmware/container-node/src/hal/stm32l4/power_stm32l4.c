/**
 * @file power_stm32l4.c
 * @brief STM32L432 向けの電源管理実装。STOP2 への出入り、RTC アラーム、電池残量推定を担う。
 *
 * ノードの寿命は「起きている時間 × 電流」でほぼ決まる。ここでやっているのは
 * 起きている時間を削ることと、削りすぎて計測を落とさないことの折り合いで、
 * 送信可否の最終判断（@ref of_power_reserve_uplink）もここに置いてある。
 * 無線側の duty cycle 判定とは別物で、両方を通らないと 1 通も出ない。
 *
 * @see firmware/container-node/src/radio/sx1276.c duty cycle 側の判定
 */

#include "of/of_lora.h"
#include "of/of_power.h"

#include <string.h>

/** @brief 1 日に許す通常アップリンク数の既定値。60 秒周期 × 4 レコード束ねで足りる。 */
#define DEFAULT_DAILY_UPLINKS 360u

/** @brief 非常枠。しきい値超過の速報用に必ず残す。 */
#define DEFAULT_EMERGENCY_SLOTS 8u

/** @brief 電池の公称容量（mAh）。LiSOCl2 D セル 1 本。 */
#define BATTERY_NOMINAL_MAH 19000u

/** @brief 満充電相当の開放電圧（mV）と、実質的な終止電圧。 */
#define BATTERY_FULL_MV 3600u
#define BATTERY_EMPTY_MV 2700u

/* HAL の下位。register 直叩きの部分は別ファイルに切り出してある。 */
extern void of_rtc_set_wakeup_ms(uint32_t ms);
extern void of_rtc_clear_wakeup(void);
extern uint32_t of_wake_flags_read_and_clear(void);
extern uint16_t of_adc_read_vbat_mv(void);
extern void of_clock_set_msi_range(uint8_t range);
extern void of_cpu_enter_deepsleep(void);
extern void of_periph_gate(bool enabled);

static of_power_budget_t s_budget;
static of_power_mode_t s_mode = OF_POWER_MODE_RUN;
static of_region_t s_region = OF_REGION_EU_WEST;
static uint32_t s_charge_used_uah; /* 積算消費。放電曲線が平坦な分をこれで補う */
static uint16_t s_last_load_mv;

of_err_t of_power_init(of_region_t region)
{
    if (region >= OF_REGION_COUNT) {
        return OF_ERR_INVALID_ARG;
    }

    s_region = region;
    memset(&s_budget, 0, sizeof(s_budget));
    s_budget.uplinks_remaining_today = DEFAULT_DAILY_UPLINKS;
    s_budget.emergency_remaining = DEFAULT_EMERGENCY_SLOTS;
    s_budget.battery_pct = of_power_battery_pct();
    s_budget.radio_allowed = s_budget.battery_pct > OF_POWER_RADIO_CUTOFF_PCT;
    s_charge_used_uah = 0u;

    return OF_OK;
}

of_err_t of_power_set_mode(of_power_mode_t mode)
{
    switch (mode) {
    case OF_POWER_MODE_RUN:
        of_clock_set_msi_range(11u); /* 48 MHz レンジ。PLL で 80 MHz まで上げる */
        of_periph_gate(true);
        break;
    case OF_POWER_MODE_LPRUN:
        of_periph_gate(true);
        of_clock_set_msi_range(5u); /* 2 MHz */
        break;
    case OF_POWER_MODE_STOP2:
    case OF_POWER_MODE_STANDBY:
        of_periph_gate(false);
        break;
    default:
        return OF_ERR_INVALID_ARG;
    }

    s_mode = mode;
    return OF_OK;
}

uint32_t of_power_enter_stop2(uint32_t ms, uint32_t sources)
{
    uint32_t woke_by;

    if (ms > 3600000u) {
        ms = 3600000u; /* RTC の wakeup カウンタが 1 時間で飽和する */
    }

    /* 無線を落とし忘れたまま STOP2 に入ると 12 mA を引き続ける。ここで
       強制的に sleep に入れるのは保険で、本来は呼び出し側の責務。 */
    of_lora_sleep();

    if ((sources & OF_WAKE_RTC_ALARM) != 0u) {
        of_rtc_set_wakeup_ms(ms);
    }

    (void)of_power_set_mode(OF_POWER_MODE_STOP2);
    of_cpu_enter_deepsleep();

    /* ここから先は復帰後。MSI は既定レンジに戻っているので明示的に上げ直す。 */
    (void)of_power_set_mode(OF_POWER_MODE_RUN);
    of_rtc_clear_wakeup();

    woke_by = of_wake_flags_read_and_clear();
    if (woke_by == 0u) {
        woke_by = OF_WAKE_RTC_ALARM; /* 取りこぼしは時間切れとみなす */
    }

    /* STOP2 の消費は実測 1.1 µA。積算に効くのは µAh 単位なので、
       1 時間眠って 1.1 µAh。切り捨てで良い。 */
    s_charge_used_uah += (ms / 3600000u) * 1u;

    return woke_by & (sources | OF_WAKE_RTC_ALARM);
}

const of_power_budget_t *of_power_budget(void)
{
    return &s_budget;
}

of_err_t of_power_reserve_uplink(uint32_t airtime_ms, bool emergency)
{
    /* 送信電流は PA_BOOST 14 dBm で約 90 mA。airtime から µAh を出す。
       90 mA × 1 ms = 25 µAh/1000 なので、素直に掛けて割る。 */
    uint32_t cost_uah = (90u * airtime_ms) / 3600u;

    if (!s_budget.radio_allowed && !emergency) {
        return OF_ERR_NO_SPACE;
    }

    if (emergency) {
        if (s_budget.emergency_remaining == 0u) {
            return OF_ERR_NO_SPACE;
        }
        s_budget.emergency_remaining--;
    } else {
        if (s_budget.uplinks_remaining_today == 0u) {
            return OF_ERR_NO_SPACE;
        }
        s_budget.uplinks_remaining_today--;
    }

    s_charge_used_uah += cost_uah;
    s_budget.airtime_used_ms_today += airtime_ms;
    return OF_OK;
}

void of_power_reserve_emergency(uint16_t slots)
{
    s_budget.emergency_remaining = slots;
}

of_battery_pct_t of_power_battery_pct(void)
{
    uint16_t mv = of_adc_read_vbat_mv();
    uint32_t from_voltage;
    uint32_t from_coulomb;
    uint32_t blended;

    s_last_load_mv = mv;

    if (mv >= BATTERY_FULL_MV) {
        from_voltage = 100u;
    } else if (mv <= BATTERY_EMPTY_MV) {
        from_voltage = 0u;
    } else {
        from_voltage = ((uint32_t)(mv - BATTERY_EMPTY_MV) * 100u) / (BATTERY_FULL_MV - BATTERY_EMPTY_MV);
    }

    /* 積算側。µAh を mAh に直してから公称容量で割る。 */
    {
        uint32_t used_mah = s_charge_used_uah / 1000u;

        from_coulomb = (used_mah >= BATTERY_NOMINAL_MAH)
                           ? 0u
                           : ((BATTERY_NOMINAL_MAH - used_mah) * 100u) / BATTERY_NOMINAL_MAH;
    }

    /* LiSOCl2 の放電曲線は 90 % 以上の領域でほぼ水平なので、電圧は終盤しか当てにならない。
       逆に積算は温度で狂う。残量が多いうちは積算を、少なくなったら電圧を重く見る。 */
    if (from_coulomb > 25u) {
        blended = (from_coulomb * 3u + from_voltage) / 4u;
    } else {
        blended = (from_voltage * 3u + from_coulomb) / 4u;
    }

    if (blended > 100u) {
        blended = 100u;
    }

    s_budget.battery_pct = (of_battery_pct_t)blended;
    s_budget.radio_allowed = s_budget.battery_pct > OF_POWER_RADIO_CUTOFF_PCT;
    return s_budget.battery_pct;
}

void of_power_rollover_day(void)
{
    s_budget.uplinks_remaining_today = DEFAULT_DAILY_UPLINKS;
    s_budget.emergency_remaining = DEFAULT_EMERGENCY_SLOTS;
    s_budget.airtime_used_ms_today = 0u;

    /* 残量が細ってきたら 1 日の送信枠自体を絞る。5 年寿命の後半で
       突然沈黙するより、周期を落としてでも生き延びる方が運用に合う。 */
    if (s_budget.battery_pct < 30u) {
        s_budget.uplinks_remaining_today = DEFAULT_DAILY_UPLINKS / 2u;
    }
    if (s_budget.battery_pct < OF_POWER_BATTERY_CRITICAL_PCT) {
        s_budget.uplinks_remaining_today = DEFAULT_DAILY_UPLINKS / 6u;
    }
}

/** @brief 直近に測った端子電圧（mV）。診断フレームに載せる。 */
uint16_t of_power_last_vbat_mv(void)
{
    return s_last_load_mv;
}

/** @brief 現在の動作モード。テストハーネスからの参照用。 */
of_power_mode_t of_power_current_mode(void)
{
    return s_mode;
}

/** @brief プロビジョニングされた地域。無線プランの再取得に使う。 */
of_region_t of_power_region(void)
{
    return s_region;
}
