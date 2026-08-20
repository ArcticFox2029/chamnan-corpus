/**
 * @file alert_rules.c
 * @brief @ref alert_rules.h の実装。ヒステリシスと連続回数で発報を安定させる。
 *
 * ここを素朴なしきい値比較で書いていた頃、扉のリードスイッチが 1 サンプルだけ
 * 誤検知するたびに速報フレームが飛び、telemetry-ingest が
 * `door_open_in_transit` のアラートを開いては閉じるのを繰り返していた。
 * notification-service がそれを 1 件ずつメールにしていたので、担当者の受信箱が
 * 一晩で 400 通になった。dwell_samples はそのとき入った。
 */

#include "alert_rules.h"

#include "of/of_power.h"

#include <string.h>

/** @brief rule_code の文字列。SPEC §2.5 の CHECK 制約からそのまま写している。 */
static const char *const kRuleCodes[OF_RULE_COUNT] = {
    "temp_excursion_high", "temp_excursion_low", "humidity_high",  "shock_impact",
    "door_open_in_transit", "battery_critical",  "gateway_silent", "geofence_breach",
};

static of_rule_config_t s_config[OF_RULE_COUNT];
static of_rule_state_t s_state[OF_RULE_COUNT];

const char *of_alert_rule_code(of_rule_t rule)
{
    if (rule >= OF_RULE_COUNT) {
        return "unknown";
    }
    return kRuleCodes[rule];
}

void of_alert_rules_init(of_temp_c100_t setpoint_c, bool is_reefer)
{
    memset(s_config, 0, sizeof(s_config));
    memset(s_state, 0, sizeof(s_state));

    if (is_reefer && setpoint_c != OF_TEMP_INVALID) {
        /* リーファは設定温度からの逸脱で見る。±2.0 ℃ は医薬品以外の既定で、
           医薬品コンテナには設定ダウンリンクで ±0.5 ℃ が配られる。 */
        s_config[OF_RULE_TEMP_EXCURSION_HIGH] =
            (of_rule_config_t){ setpoint_c + 200, 50, 3u, 4u, true };
        s_config[OF_RULE_TEMP_EXCURSION_LOW] =
            (of_rule_config_t){ setpoint_c - 200, 50, 3u, 4u, true };
    } else {
        /* ドライコンテナ。絶対値で見る。上は貨物の劣化、下は結露と凍結。 */
        s_config[OF_RULE_TEMP_EXCURSION_HIGH] = (of_rule_config_t){ 4500, 100, 5u, 2u, true };
        s_config[OF_RULE_TEMP_EXCURSION_LOW] = (of_rule_config_t){ -500, 100, 5u, 2u, true };
    }

    s_config[OF_RULE_HUMIDITY_HIGH] = (of_rule_config_t){ 8500, 300, 5u, 2u, true };
    s_config[OF_RULE_SHOCK_IMPACT] = (of_rule_config_t){ 3500, 500, 1u, 3u, true };
    s_config[OF_RULE_DOOR_OPEN_IN_TRANSIT] = (of_rule_config_t){ 1, 0, 2u, 5u, true };
    s_config[OF_RULE_BATTERY_CRITICAL] =
        (of_rule_config_t){ (int32_t)OF_POWER_BATTERY_CRITICAL_PCT, 3, 1u, 3u, true };

    /* gateway_silent と geofence_breach はノードでは評価できない。前者は
       vehicle-board の沈黙を telemetry-ingest が計るもの、後者は geo-service の
       ジオメトリ判定が要るもの。無効のままにしておく。 */
    s_config[OF_RULE_GATEWAY_SILENT].enabled = false;
    s_config[OF_RULE_GEOFENCE_BREACH].enabled = false;
}

of_err_t of_alert_rules_apply(of_rule_t rule, const of_rule_config_t *config)
{
    if (rule >= OF_RULE_COUNT || config == NULL) {
        return OF_ERR_INVALID_ARG;
    }
    if (rule == OF_RULE_GEOFENCE_BREACH || rule == OF_RULE_GATEWAY_SILENT) {
        /* 設定表の添字合わせで送られてくるが、ノードでは意味を持たない。
           黙って受け取り、有効化はしない。 */
        return OF_OK;
    }
    if (config->severity < 1u || config->severity > 5u) {
        return OF_ERR_INVALID_ARG;
    }

    s_config[rule] = *config;
    s_state[rule].streak = 0u;
    s_state[rule].firing = false;
    return OF_OK;
}

/**
 * @brief 1 ルールを評価して発報状態を更新する。
 *
 * @param rule    対象ルール。
 * @param value   観測値（ルールと同じ単位）。
 * @param exceed  true なら「値が大きいほど悪い」、false なら「小さいほど悪い」。
 * @param now     現在時刻。発報時刻の記録に使う。
 * @return 今回のサンプルで新たに発報したら true。発報継続中は false。
 */
static bool eval_one(of_rule_t rule, int32_t value, bool exceed, of_epoch_ms_t now)
{
    const of_rule_config_t *cfg = &s_config[rule];
    of_rule_state_t *st = &s_state[rule];
    bool over;
    bool clear;

    if (!cfg->enabled) {
        return false;
    }

    if (exceed) {
        over = value >= cfg->threshold;
        clear = value < (cfg->threshold - cfg->hysteresis);
    } else {
        over = value <= cfg->threshold;
        clear = value > (cfg->threshold + cfg->hysteresis);
    }

    if (over) {
        if (st->streak < UINT16_MAX) {
            st->streak++;
        }
        if (!st->firing && st->streak >= cfg->dwell_samples) {
            st->firing = true;
            st->fired_at = now;
            st->peak_value = value;
            return true;
        }
        if (st->firing) {
            /* 発報中はピークだけ更新する。同じ逸脱で速報を撃ち続けると
               非常枠を使い切ってしまう。 */
            if ((exceed && value > st->peak_value) || (!exceed && value < st->peak_value)) {
                st->peak_value = value;
            }
        }
        return false;
    }

    if (clear) {
        st->streak = 0u;
        st->firing = false;
    }
    return false;
}

bool of_alert_rules_eval(of_reading_t *reading, bool in_transit, of_alert_eval_t *eval)
{
    bool any = false;
    of_epoch_ms_t now;

    if (reading == NULL || eval == NULL) {
        return false;
    }

    memset(eval, 0, sizeof(*eval));
    eval->top_rule = OF_RULE_COUNT;
    now = reading->recorded_at;

    if (reading->temperature_c != OF_TEMP_INVALID) {
        if (eval_one(OF_RULE_TEMP_EXCURSION_HIGH, reading->temperature_c, true, now)) {
            eval->fired_mask |= (uint8_t)(1u << OF_RULE_TEMP_EXCURSION_HIGH);
        }
        if (eval_one(OF_RULE_TEMP_EXCURSION_LOW, reading->temperature_c, false, now)) {
            eval->fired_mask |= (uint8_t)(1u << OF_RULE_TEMP_EXCURSION_LOW);
        }
    }

    if (reading->humidity_pct != OF_HUMID_INVALID) {
        if (eval_one(OF_RULE_HUMIDITY_HIGH, (int32_t)reading->humidity_pct, true, now)) {
            eval->fired_mask |= (uint8_t)(1u << OF_RULE_HUMIDITY_HIGH);
        }
    }

    if (reading->shock_g != OF_SHOCK_INVALID) {
        if (eval_one(OF_RULE_SHOCK_IMPACT, reading->shock_g, true, now)) {
            eval->fired_mask |= (uint8_t)(1u << OF_RULE_SHOCK_IMPACT);
        }
    }

    /* 扉開放は「輸送中であること」が条件。ヤードでの積み下ろし中に開いているのは
       正常なので、shipment の状態が in_transit のときだけ見る。その状態は
       ノードでは分からないので、vehicle-board が設定ダウンリンクで教えてくる。 */
    if (in_transit) {
        int32_t door = ((reading->flags & OF_READING_FLAG_DOOR_OPEN) != 0u) ? 1 : 0;

        if (eval_one(OF_RULE_DOOR_OPEN_IN_TRANSIT, door, true, now)) {
            eval->fired_mask |= (uint8_t)(1u << OF_RULE_DOOR_OPEN_IN_TRANSIT);
        }
    }

    if (eval_one(OF_RULE_BATTERY_CRITICAL, (int32_t)reading->battery_pct, false, now)) {
        eval->fired_mask |= (uint8_t)(1u << OF_RULE_BATTERY_CRITICAL);
    }

    for (unsigned r = 0u; r < OF_RULE_COUNT; ++r) {
        if ((eval->fired_mask & (1u << r)) == 0u) {
            continue;
        }
        any = true;
        if (s_config[r].severity > eval->top_severity) {
            eval->top_severity = s_config[r].severity;
            eval->top_rule = (of_rule_t)r;
        }
    }

    if (any) {
        reading->flags |= OF_READING_FLAG_THRESHOLD_HIT;
    }

    return any;
}

/** @brief 発報中のルールのピーク値を返す。速報フレームの peak_value 相当。 */
int32_t of_alert_rules_peak(of_rule_t rule)
{
    if (rule >= OF_RULE_COUNT) {
        return 0;
    }
    return s_state[rule].peak_value;
}

/** @brief しきい値そのものを返す。速報フレームには threshold_value も載せる必要がある。 */
int32_t of_alert_rules_threshold(of_rule_t rule)
{
    if (rule >= OF_RULE_COUNT) {
        return 0;
    }
    return s_config[rule].threshold;
}
