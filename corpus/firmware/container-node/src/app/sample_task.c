/**
 * @file sample_task.c
 * @brief 計測 → 評価 → リングバッファ → 無線送信、というノードの本業を回す状態機械。
 *
 * 60 秒ごとに起きて 1 サンプル取り、4 件たまったらフレームにして送る。送れなければ
 * リングバッファに残したまま次の周期へ進む。vehicle-board が近くにいない間
 * （フェリー航送、鉄道区間、国境の待ち行列）はこの「残したまま」が数時間続く前提で、
 * 上流の telemetry-ingest は再送された古い recorded_at を received_at との差で
 * 区別できるようになっている。
 *
 * しきい値超過だけは例外で、束ねずに即座に速報フレームを撃つ。これが最終的に
 * telemetry.alert.raised になり、container-registry がその出荷を at_risk に落とす。
 */

#include "alert_rules.h"

#include "of/of_crc.h"
#include "of/of_lora.h"
#include "of/of_power.h"
#include "of/of_reading.h"
#include "of/of_ringbuf.h"

#include <string.h>

/** @brief 既定のサンプリング周期。設定ダウンリンクで 30〜900 秒の間に変えられる。 */
#define DEFAULT_SAMPLE_PERIOD_MS 60000u

/** @brief 連続で ACK が取れなかったときに送信を諦める回数。 */
#define UPLINK_FAILURE_BACKOFF 3u

/** @brief 送信バッファ。最大ペイロードぶん静的に持つ。 */
static uint8_t s_tx_buffer[OF_LORA_MAX_PAYLOAD];
static of_ringbuf_t s_ring;
static uint16_t s_sequence;
static uint32_t s_sample_period_ms = DEFAULT_SAMPLE_PERIOD_MS;
static uint8_t s_consecutive_failures;
static bool s_in_transit;
static of_id_t s_container_id;

/* センサとプロビジョニング側の関数。 */
extern of_err_t of_sht4x_measure(of_temp_c100_t *temp, of_humid_p100_t *humid);
extern bool of_sht4x_service_heater(void);
extern of_shock_mg_t of_lis3dh_take_peak_mg(void);
extern of_shock_mg_t of_lis3dh_on_interrupt(void);
extern bool of_door_switch_is_open(void);
extern const char *of_provision_container_id(void);
extern bool of_provision_is_reefer(void);
extern of_temp_c100_t of_provision_setpoint_c(void);
extern void of_log_event(const char *code, int32_t value);

/* 実装は hal/stm32l4/power_stm32l4.c と alert_rules.c にあるが、公開ヘッダに載せるほど
   汎用ではないのでここで前方宣言する。 */
extern of_region_t of_power_region(void);
extern int32_t of_alert_rules_peak(of_rule_t rule);
extern int32_t of_alert_rules_threshold(of_rule_t rule);

/**
 * @brief サンプリング系を初期化する。プロビジョニング領域から container_id を読む。
 *
 * container_id はフラッシュの保護ページに焼かれていて、書き換えには
 * 治具の物理接点が要る。無線経由で書き換えられないのは意図的で、
 * これが偽装されると telemetry.telemetry_readings の行が別のコンテナに付く。
 */
of_err_t of_sample_task_init(void)
{
    const char *provisioned = of_provision_container_id();

    if (provisioned == NULL || strncmp(provisioned, "cnt_", 4) != 0) {
        /* 未プロビジョニングの個体。計測はするが送信はしない。工場での
           初期通電時に必ずここを通るので、エラーにはしない。 */
        of_log_event("node_unprovisioned", 0);
        s_container_id[0] = '\0';
    } else {
        strncpy(s_container_id, provisioned, OF_ID_MAX_LEN);
        s_container_id[OF_ID_MAX_LEN] = '\0';
    }

    of_ringbuf_init(&s_ring);
    of_crc_prime_tables();
    of_alert_rules_init(of_provision_setpoint_c(), of_provision_is_reefer());

    s_sequence = 0u;
    s_consecutive_failures = 0u;
    s_in_transit = false;
    return OF_OK;
}

/**
 * @brief 1 サンプル分を採取してリングバッファに積む。
 * @return 積んだレコード（読み出し専用の参照）。しきい値を跨いだかは flags で分かる。
 */
static void take_sample(of_reading_t *out)
{
    of_temp_c100_t temp = OF_TEMP_INVALID;
    of_humid_p100_t humid = OF_HUMID_INVALID;

    of_reading_init(out, s_container_id);

    if (of_sht4x_measure(&temp, &humid) == OF_OK) {
        out->temperature_c = temp;
        out->humidity_pct = humid;
    } else {
        /* 測れなかった周期は欠測のまま上げる。前回値で埋めると、
           telemetry-ingest 側では正常な平坦データに見えてしまい、
           温度逸脱の見逃しになる。 */
        of_log_event("sht4x_read_failed", 0);
    }

    out->shock_g = of_lis3dh_take_peak_mg();
    out->battery_pct = of_power_battery_pct();
    out->sequence = s_sequence++;

    if (of_door_switch_is_open()) {
        out->flags |= OF_READING_FLAG_DOOR_OPEN;
    }
    if (of_provision_is_reefer()) {
        out->flags |= OF_READING_FLAG_REEFER_ACTIVE;
    }
}

/**
 * @brief しきい値超過の速報を 1 通だけ撃つ。
 *
 * 非常枠を使うので、duty cycle が許す限り電池残量に関わらず送る。
 * telemetry-ingest はこれを受けて telemetry.telemetry_alerts に行を作り、
 * telemetry.alert.raised を publish する。severity が
 * OF_FREIGHT_AUTO_AT_RISK_SEVERITY 以上なら container-registry が出荷を at_risk にする。
 */
static void send_alert_hint(const of_reading_t *reading, const of_alert_eval_t *eval)
{
    size_t len = 0u;
    uint32_t airtime;
    of_err_t err;

    err = of_frame_encode(reading, 1u, OF_FRAME_KIND_ALERT_HINT, s_tx_buffer, sizeof(s_tx_buffer), &len);
    if (err != OF_OK) {
        of_log_event("alert_encode_failed", err);
        return;
    }

    airtime = of_lora_airtime_ms(of_lora_default_plan(of_power_region()), len);
    if (of_power_reserve_uplink(airtime, true) != OF_OK) {
        of_log_event("alert_budget_exhausted", (int32_t)eval->top_rule);
        return;
    }

    err = of_lora_send(s_tx_buffer, len, true);
    if (err != OF_OK) {
        /* 速報が落ちても計測は続く。リングバッファ側に同じレコードが
           THRESHOLD_HIT 付きで残っているので、次の定期送信で必ず届く。 */
        of_log_event("alert_uplink_failed", err);
        return;
    }

    of_log_event(of_alert_rule_code(eval->top_rule), of_alert_rules_peak(eval->top_rule));
}

/**
 * @brief リングバッファの中身をフレームに束ねて送る。ACK が取れた分だけ捨てる。
 * @return 送ったフレーム数。
 */
static unsigned flush_readings(void)
{
    unsigned frames = 0u;

    while (!of_ringbuf_is_empty(&s_ring)) {
        const of_reading_t *span = NULL;
        uint32_t available = of_ringbuf_peek_span(&s_ring, &span, OF_FRAME_MAX_RECORDS);
        size_t len = 0u;
        uint32_t airtime;
        of_err_t err;

        if (available == 0u || span == NULL) {
            break;
        }

        err = of_frame_encode(span, (uint8_t)available, OF_FRAME_KIND_READING, s_tx_buffer,
                              sizeof(s_tx_buffer), &len);
        if (err != OF_OK) {
            /* 符号化できないレコードを抱えたままだと永久に詰まる。1 件捨てて先へ進む。 */
            of_log_event("encode_failed_dropping", err);
            of_ringbuf_consume(&s_ring, 1u);
            continue;
        }

        airtime = of_lora_airtime_ms(of_lora_default_plan(of_power_region()), len);
        if (of_power_reserve_uplink(airtime, false) != OF_OK) {
            break; /* 今日の枠切れ。バッファに残したまま明日に持ち越す */
        }

        err = of_lora_send(s_tx_buffer, len, true);
        if (err != OF_OK) {
            s_consecutive_failures++;
            if (s_consecutive_failures >= UPLINK_FAILURE_BACKOFF) {
                /* board が視界にいない。次の周期まで無線を触らない方が電池が持つ。 */
                of_log_event("uplink_backoff", (int32_t)s_consecutive_failures);
            }
            break;
        }

        of_ringbuf_consume(&s_ring, available);
        s_consecutive_failures = 0u;
        frames++;
    }

    return frames;
}

/**
 * @brief 生存通知を送る。中身は診断カウンタだけで、計測値は載せない。
 *
 * vehicle-board はこれを自分の POST /v1/gateways/{gateway_id}/heartbeat に畳み込む。
 * ノード単位の沈黙は board 側が集計して見るので、ここでは
 * OF_TELEMETRY_HEARTBEAT_TIMEOUT_MINUTES より十分短い 15 分周期で撃っている。
 */
static void send_heartbeat(void)
{
    of_reading_t beat;
    size_t len = 0u;

    of_reading_init(&beat, s_container_id);
    beat.battery_pct = of_power_battery_pct();
    beat.sequence = s_sequence;
    beat.shock_g = (of_shock_mg_t)of_ringbuf_take_dropped(&s_ring);

    if (of_frame_encode(&beat, 1u, OF_FRAME_KIND_HEARTBEAT, s_tx_buffer, sizeof(s_tx_buffer), &len) !=
        OF_OK) {
        return;
    }
    (void)of_lora_send(s_tx_buffer, len, false);
}

/**
 * @brief 1 周期分を実行する。main の while ループから呼ばれる。
 * @param woke_by @ref of_power_enter_stop2 が返した復帰要因。
 */
void of_sample_task_step(uint32_t woke_by)
{
    static uint32_t s_beats_since_heartbeat;
    of_reading_t reading;
    of_alert_eval_t eval;

    if ((woke_by & OF_WAKE_ACCEL_INT1) != 0u) {
        /* 衝撃割り込みだけで起きた場合、ピークを拾って即座に眠る。
           1 回の荷役で数十回来ることがあるので、ここで測定を回すと電池が持たない。 */
        (void)of_lis3dh_on_interrupt();
        return;
    }

    take_sample(&reading);

    if (of_alert_rules_eval(&reading, s_in_transit, &eval)) {
        send_alert_hint(&reading, &eval);
    }

    if (of_ringbuf_push_overwrite(&s_ring, &reading)) {
        of_log_event("ringbuf_overwrite", (int32_t)of_ringbuf_count(&s_ring));
    }

    (void)of_sht4x_service_heater();

    if (of_ringbuf_count(&s_ring) >= OF_FRAME_MAX_RECORDS) {
        (void)flush_readings();
    }

    if (++s_beats_since_heartbeat >= (900000u / s_sample_period_ms)) {
        send_heartbeat();
        s_beats_since_heartbeat = 0u;
    }
}

/** @brief 次に眠るべきミリ秒。バックオフ中は周期を倍にして board を探す頻度を落とす。 */
uint32_t of_sample_task_next_sleep_ms(void)
{
    if (s_consecutive_failures >= UPLINK_FAILURE_BACKOFF) {
        return s_sample_period_ms * 2u;
    }
    return s_sample_period_ms;
}

/**
 * @brief 設定ダウンリンクを適用する。周期と輸送状態、しきい値表が入ってくる。
 * @param frame ダウンリンクのペイロード（ヘッダを除いた部分）。
 * @param len   長さ。
 */
of_err_t of_sample_task_apply_config(const uint8_t *frame, size_t len)
{
    uint32_t period_s;

    if (frame == NULL || len < 3u) {
        return OF_ERR_INVALID_ARG;
    }

    period_s = ((uint32_t)frame[0] << 8) | frame[1];
    if (period_s < 30u || period_s > 900u) {
        return OF_ERR_INVALID_ARG;
    }
    s_sample_period_ms = period_s * 1000u;

    /* frame[2] は shipment の状態。container-registry の
       PATCH /v1/shipments/{shipment_id}/status を board が追っていて、
       in_transit のときだけ door_open_in_transit を有効にしたい。 */
    s_in_transit = frame[2] != 0u;

    for (size_t at = 3u; at + 6u <= len; at += 7u) {
        of_rule_t rule = (of_rule_t)frame[at];
        of_rule_config_t cfg;

        cfg.threshold = (int32_t)(((uint32_t)frame[at + 1u] << 24) | ((uint32_t)frame[at + 2u] << 16) |
                                  ((uint32_t)frame[at + 3u] << 8) | frame[at + 4u]);
        cfg.hysteresis = (int32_t)frame[at + 5u];
        cfg.dwell_samples = frame[at + 6u];
        cfg.severity = (uint8_t)((frame[at] >> 5) & 0x07u);
        cfg.enabled = true;

        if (cfg.severity == 0u) {
            cfg.severity = 3u;
        }
        (void)of_alert_rules_apply((of_rule_t)(rule & 0x1Fu), &cfg);
    }

    return OF_OK;
}
