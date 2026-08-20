/*
 * ORBITALFREIGHT container sensor node — entry point
 * SPDX-License-Identifier: LicenseRef-ORBITALFREIGHT-Internal
 */

/**
 * @file main.c
 * @brief 電源投入からメインループまで。周辺の初期化順序と、致命的な故障時の縮退動作を決めている。
 *
 * 縮退の方針は「計測を止めない」こと。無線が死んでもリングバッファには積み続け、
 * 温湿度センサが死んでも衝撃と扉と電池は上げ続ける。全部死んだときだけ
 * ウォッチドッグに任せて再起動する。輸送中のコンテナに手は届かないので、
 * 現地で直せる前提の設計にはできない。
 */

#include "alert_rules.h"

#include "of/of_crc.h"
#include "of/of_lora.h"
#include "of/of_power.h"
#include "of/of_ringbuf.h"
#include "of/of_types.h"

/** @brief 連続再起動をこの回数超えたら、送信を諦めて計測のみのモードに落ちる。 */
#define BOOT_LOOP_THRESHOLD 5u

extern of_err_t of_sht4x_init(void);
extern of_err_t of_lis3dh_init(void);
extern of_err_t of_sample_task_init(void);
extern void of_sample_task_step(uint32_t woke_by);
extern uint32_t of_sample_task_next_sleep_ms(void);
extern of_err_t of_sample_task_apply_config(const uint8_t *frame, size_t len);
extern of_region_t of_provision_region(void);
extern void of_watchdog_init(uint32_t timeout_ms);
extern void of_watchdog_kick(void);
extern void of_board_init(void);
extern void of_log_event(const char *code, int32_t value);
extern uint32_t of_boot_counter_increment(void);

/** @brief 無線が使えるかどうか。init に失敗した個体はここが false のまま動き続ける。 */
static bool s_radio_up;

/**
 * @brief 周辺を順に立ち上げる。失敗しても止まらず、何が生きているかを記録する。
 *
 * 順序には理由がある。電源管理が先でないとクロックが定まらず I2C のタイミングが狂い、
 * 無線は最後でないと初期化中の 90 mA 突入で他の初期化を巻き添えにする。
 */
static void bring_up_peripherals(void)
{
    of_region_t region = of_provision_region();

    of_board_init();
    of_crc_prime_tables();

    if (of_power_init(region) != OF_OK) {
        of_log_event("power_init_failed", (int32_t)region);
    }

    if (of_sht4x_init() != OF_OK) {
        of_log_event("sht4x_init_failed", 0);
    }
    if (of_lis3dh_init() != OF_OK) {
        of_log_event("lis3dh_init_failed", 0);
    }

    s_radio_up = of_lora_init(of_lora_default_plan(region)) == OF_OK;
    if (!s_radio_up) {
        /* SPI か PA の故障。リングバッファに積むだけの縮退運転に入る。
           バッファが一周すれば古いものから消えるが、直近 4 時間ぶんは
           board が現れたときに吸い出せる。 */
        of_log_event("lora_init_failed", 0);
    }
}

/**
 * @brief ダウンリンクを 1 通だけ拾って処理する。定期送信の直後にしか窓は開かない。
 *
 * 受け付けるのは時刻同期と設定更新の 2 種類だけ。ファームウェア更新は
 * この経路では行わない。LoRa の帯域で 200 KiB を流すと数時間かかり、
 * その間の計測が全部落ちるので、更新は depot での有線治具に限っている。
 */
static void service_downlink(void)
{
    uint8_t buf[64];
    of_lora_rx_info_t info;
    int received;
    of_frame_header_t header;
    of_reading_t decoded[OF_FRAME_MAX_RECORDS];
    uint8_t count = 0u;

    if (!s_radio_up) {
        return;
    }

    received = of_lora_receive(buf, sizeof(buf), 300u, &info);
    if (received < (int)OF_FRAME_HEADER_SIZE) {
        return;
    }

    if (of_frame_decode(buf, (size_t)received, decoded, OF_FRAME_MAX_RECORDS, &count, &header) !=
        OF_OK) {
        return;
    }

    switch ((of_frame_kind_t)header.kind) {
    case OF_FRAME_KIND_CONFIG:
        if (of_sample_task_apply_config(&buf[OF_FRAME_HEADER_SIZE],
                                        (size_t)received - OF_FRAME_HEADER_SIZE) == OF_OK) {
            of_log_event("config_applied", info.rssi_dbm);
        }
        break;
    case OF_FRAME_KIND_TIME_SYNC:
        /* RTC 補正。ここで recorded_at の基準が動くので、補正前後で
           sequence が飛ばないことだけは守る（telemetry-ingest の重複排除が
           recorded_at を含むため、飛ぶと同じ計測が二重に入る）。 */
        of_log_event("time_sync_received", info.snr_db);
        break;
    default:
        break;
    }
}

/**
 * @brief エントリポイント。返らない。
 *
 * ループの形は「起きる → 1 サンプル → 必要なら送る → 眠る」だけ。RTOS は載せていない。
 * タスクが 1 本しかないところにスケジューラを入れても、スタックと消費電力が増えるだけだった。
 */
int main(void)
{
    uint32_t boots = of_boot_counter_increment();

    bring_up_peripherals();

    if (boots > BOOT_LOOP_THRESHOLD) {
        /* 再起動を繰り返している。無線の初期化が原因のことが圧倒的に多いので、
           無線を諦めて計測だけ続ける。depot に戻ったときに有線で吸い出せる。 */
        of_log_event("boot_loop_detected", (int32_t)boots);
        s_radio_up = false;
    }

    if (of_sample_task_init() != OF_OK) {
        of_log_event("sample_task_init_failed", 0);
    }

    /* ウォッチドッグはサンプリング周期の 3 倍。1 周期の取りこぼしでは再起動させない。 */
    of_watchdog_init(of_sample_task_next_sleep_ms() * 3u);

    for (;;) {
        uint32_t woke_by;

        of_watchdog_kick();
        of_sample_task_step(0u);
        service_downlink();
        of_lora_sleep();

        woke_by = of_power_enter_stop2(of_sample_task_next_sleep_ms(),
                                       OF_WAKE_RTC_ALARM | OF_WAKE_DOOR_SWITCH |
                                           OF_WAKE_ACCEL_INT1 | OF_WAKE_TAMPER);

        if ((woke_by & OF_WAKE_TAMPER) != 0u) {
            /* 封印破りの疑い。severity 5 相当なので、電池を惜しまず即座に上げる。
               受け側でこれが telemetry.alert.raised になり、notification-service が
               担当者を叩く。 */
            of_log_event("tamper_detected", 0);
            of_sample_task_step(0u);
        } else if ((woke_by & (OF_WAKE_ACCEL_INT1 | OF_WAKE_DOOR_SWITCH)) != 0u) {
            of_sample_task_step(woke_by);
        }
    }
}
