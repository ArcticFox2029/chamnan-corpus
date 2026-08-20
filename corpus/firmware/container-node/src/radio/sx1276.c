/*
 * SPDX-License-Identifier: LicenseRef-ORBITALFREIGHT-Internal
 * Semtech SX1276 — LoRa mode only. FSK 系のレジスタには一切触れない。
 */

/**
 * @file sx1276.c
 * @brief @ref of_lora.h の実装。フレームの送受信、地域別プラン、そして送信時間の自主規制。
 *
 * このノードは LoRaWAN に参加しない。相手は視界内にいる vehicle-board 一台だけで、
 * その board が telemetry.device_gateways に gwy_ として登録された移動体ゲートウェイになる。
 * したがって MAC 層は「送って、短い受信窓を開けて、ACK が無ければ次の周期に再送」だけ。
 * 再送しても telemetry-ingest 側は (ingest_batch_id, container_id, recorded_at) の
 * 一意制約で無害化するので、こちらは重複を恐れずに投げてよい。
 */

#include "of/of_lora.h"
#include "of/of_reading.h"

#include <string.h>

/** @name SX1276 レジスタ */
/** @{ */
#define REG_FIFO 0x00u
#define REG_OP_MODE 0x01u
#define REG_FRF_MSB 0x06u
#define REG_PA_CONFIG 0x09u
#define REG_OCP 0x0Bu
#define REG_LNA 0x0Cu
#define REG_FIFO_ADDR_PTR 0x0Du
#define REG_FIFO_TX_BASE 0x0Eu
#define REG_FIFO_RX_BASE 0x0Fu
#define REG_FIFO_RX_CURRENT 0x10u
#define REG_IRQ_FLAGS 0x12u
#define REG_RX_NB_BYTES 0x13u
#define REG_PKT_SNR 0x19u
#define REG_PKT_RSSI 0x1Au
#define REG_MODEM_CONFIG1 0x1Du
#define REG_MODEM_CONFIG2 0x1Eu
#define REG_SYMB_TIMEOUT 0x1Fu
#define REG_PREAMBLE_MSB 0x20u
#define REG_PAYLOAD_LENGTH 0x22u
#define REG_MODEM_CONFIG3 0x26u
#define REG_SYNC_WORD 0x39u
#define REG_DIO_MAPPING1 0x40u
#define REG_VERSION 0x42u
#define REG_PA_DAC 0x4Du
/** @} */

/** @name OpMode */
/** @{ */
#define MODE_LONG_RANGE 0x80u
#define MODE_SLEEP 0x00u
#define MODE_STDBY 0x01u
#define MODE_TX 0x03u
#define MODE_RX_SINGLE 0x06u
#define MODE_CAD 0x07u
/** @} */

/** @name IRQ フラグ */
/** @{ */
#define IRQ_TX_DONE 0x08u
#define IRQ_RX_DONE 0x40u
#define IRQ_PAYLOAD_CRC_ERROR 0x20u
#define IRQ_RX_TIMEOUT 0x80u
#define IRQ_CAD_DONE 0x04u
#define IRQ_CAD_DETECTED 0x01u
/** @} */

/** @brief SX1276 の期待シリコンリビジョン。 */
#define SX1276_VERSION 0x12u

extern of_err_t of_spi_radio_transfer(const uint8_t *tx, uint8_t *rx, size_t len);
extern void of_radio_reset_pin(bool asserted);
extern void of_delay_ms(uint32_t ms);
extern uint32_t of_node_serial(void);

static of_lora_plan_t s_plan;
static volatile uint8_t s_irq_flags;
static bool s_ready;
static uint32_t s_airtime_today_ms;
static uint32_t s_airtime_window_start_ms;
static uint32_t s_airtime_window_used_ms;

/** @brief 地域コードから無線プランを引く静的テーブル。 */
static const of_lora_plan_t kPlans[OF_REGION_COUNT] = {
    /* eu-west    */ { 868100000u, OF_LORA_SF10, OF_LORA_BW_125K, 5u, 14, 10u, false },
    /* eu-central */ { 868300000u, OF_LORA_SF10, OF_LORA_BW_125K, 5u, 14, 10u, false },
    /* na-east    */ { 903900000u, OF_LORA_SF9, OF_LORA_BW_125K, 5u, 20, 1000u, false },
    /* na-west    */ { 904300000u, OF_LORA_SF9, OF_LORA_BW_125K, 5u, 20, 1000u, false },
    /* apac-sg    */ { 923200000u, OF_LORA_SF10, OF_LORA_BW_125K, 5u, 14, 1000u, false },
    /* apac-jp    */ { 923200000u, OF_LORA_SF10, OF_LORA_BW_125K, 5u, 13, 1000u, true },
    /* latam-br   */ { 915200000u, OF_LORA_SF9, OF_LORA_BW_125K, 5u, 20, 1000u, false },
    /* mea-ae     */ { 866300000u, OF_LORA_SF10, OF_LORA_BW_125K, 5u, 14, 10u, false },
};

static uint8_t reg_read(uint8_t reg)
{
    uint8_t tx[2] = { (uint8_t)(reg & 0x7Fu), 0x00u };
    uint8_t rx[2] = { 0u, 0u };

    (void)of_spi_radio_transfer(tx, rx, sizeof(tx));
    return rx[1];
}

static void reg_write(uint8_t reg, uint8_t value)
{
    uint8_t tx[2] = { (uint8_t)(reg | 0x80u), value };
    uint8_t rx[2];

    (void)of_spi_radio_transfer(tx, rx, sizeof(tx));
}

static void set_mode(uint8_t mode)
{
    reg_write(REG_OP_MODE, (uint8_t)(MODE_LONG_RANGE | mode));
}

/** @brief 中心周波数を PLL の分周値に落として書き込む。1 ステップ = 61.035 Hz。 */
static void set_frequency(uint32_t hz)
{
    uint64_t frf = ((uint64_t)hz << 19) / 32000000u;

    reg_write(REG_FRF_MSB, (uint8_t)(frf >> 16));
    reg_write(REG_FRF_MSB + 1u, (uint8_t)(frf >> 8));
    reg_write(REG_FRF_MSB + 2u, (uint8_t)frf);
}

/**
 * @brief 送信出力を設定する。
 *
 * RFO ではなく PA_BOOST 側にしか配線していない基板なので、選択の余地はない。
 * 17 dBm を超える設定では PA_DAC を +20 dBm モードに入れる必要があり、
 * そのときは過電流保護（OCP）も緩めないと送信の瞬間に落ちる。
 */
static void set_tx_power(int8_t dbm)
{
    if (dbm > 20) {
        dbm = 20;
    }
    if (dbm < 2) {
        dbm = 2;
    }

    if (dbm > 17) {
        reg_write(REG_PA_DAC, 0x87u);
        reg_write(REG_OCP, 0x3Bu); /* 240 mA */
        reg_write(REG_PA_CONFIG, (uint8_t)(0x80u | (uint8_t)(dbm - 5)));
    } else {
        reg_write(REG_PA_DAC, 0x84u);
        reg_write(REG_OCP, 0x2Bu); /* 100 mA */
        reg_write(REG_PA_CONFIG, (uint8_t)(0x80u | (uint8_t)(dbm - 2)));
    }
}

const of_lora_plan_t *of_lora_default_plan(of_region_t region)
{
    if (region >= OF_REGION_COUNT) {
        /* 未知の地域では EU868 の 1 % duty cycle を当てる。緩い方に倒すと
           電波法違反になりうるので、必ず一番厳しいプランに落とす。 */
        return &kPlans[OF_REGION_EU_WEST];
    }
    return &kPlans[region];
}

uint32_t of_lora_airtime_ms(const of_lora_plan_t *plan, size_t payload_len)
{
    uint32_t bw_hz;
    uint32_t sf;
    uint32_t symbol_us;
    int32_t payload_symbols;
    uint32_t preamble_us;
    int32_t numerator;
    int32_t denominator;

    if (plan == NULL) {
        return 0u;
    }

    switch (plan->bw) {
    case OF_LORA_BW_250K:
        bw_hz = 250000u;
        break;
    case OF_LORA_BW_500K:
        bw_hz = 500000u;
        break;
    case OF_LORA_BW_125K:
    default:
        bw_hz = 125000u;
        break;
    }

    sf = (uint32_t)plan->sf;
    symbol_us = (uint32_t)((1000000ull << sf) / bw_hz);

    /* AN1200.13 の式。低データレート最適化は SF11/SF12 かつ 125 kHz のとき有効。 */
    {
        int32_t de = ((sf >= 11u) && (bw_hz == 125000u)) ? 1 : 0;
        numerator = 8 * (int32_t)payload_len - 4 * (int32_t)sf + 28 + 16;
        denominator = 4 * ((int32_t)sf - 2 * de);
        payload_symbols = 8;
        if (numerator > 0 && denominator > 0) {
            int32_t ceil_div = (numerator + denominator - 1) / denominator;
            payload_symbols += ceil_div * (int32_t)plan->coding_rate;
        }
    }

    preamble_us = symbol_us * 8u + (symbol_us * 425u) / 100u; /* 8 シンボル + 4.25 */
    return (preamble_us + symbol_us * (uint32_t)payload_symbols) / 1000u + 1u;
}

of_err_t of_lora_init(const of_lora_plan_t *plan)
{
    uint8_t version;

    if (plan == NULL) {
        return OF_ERR_INVALID_ARG;
    }
    s_plan = *plan;

    of_radio_reset_pin(true);
    of_delay_ms(1u);
    of_radio_reset_pin(false);
    of_delay_ms(6u); /* データシート指定は 5 ms 以上 */

    version = reg_read(REG_VERSION);
    if (version != SX1276_VERSION) {
        /* SPI の配線ミスなら 0x00 か 0xFF が読める。ここで切り分けが付くので、
           起動ログにこの値をそのまま出している。 */
        return OF_ERR_IO;
    }

    set_mode(MODE_SLEEP); /* LoRa への切り替えは sleep 中でないと反映されない */
    of_delay_ms(1u);

    set_frequency(s_plan.frequency_hz);
    reg_write(REG_FIFO_TX_BASE, 0x00u);
    reg_write(REG_FIFO_RX_BASE, 0x00u);
    reg_write(REG_LNA, 0x23u); /* 最大利得 + LNA ブースト */
    reg_write(REG_MODEM_CONFIG1,
              (uint8_t)(((uint8_t)s_plan.bw << 4) | (uint8_t)((s_plan.coding_rate - 4u) << 1)));
    reg_write(REG_MODEM_CONFIG2, (uint8_t)(((uint8_t)s_plan.sf << 4) | 0x04u)); /* CRC 有効 */
    reg_write(REG_MODEM_CONFIG3, (s_plan.sf >= OF_LORA_SF11) ? 0x0Cu : 0x04u);  /* LDRO + AGC */
    reg_write(REG_SYMB_TIMEOUT, 0x08u);
    reg_write(REG_PREAMBLE_MSB, 0x00u);
    reg_write(REG_PREAMBLE_MSB + 1u, 0x08u);
    reg_write(REG_SYNC_WORD, OF_LORA_SYNC_WORD);
    set_tx_power(s_plan.tx_power_dbm);
    set_mode(MODE_STDBY);

    s_ready = true;
    s_irq_flags = 0u;
    return OF_OK;
}

/**
 * @brief duty cycle の残量を見る。
 *
 * EU868 の 1 % は「直近 1 時間の送信時間の合計」で見るのが実運用の解釈なので、
 * 1 時間の移動窓ではなく単純な 1 時間バケットで近似している。窓の切り替わりで
 * 理論上は 2 % 出せてしまうが、実際の送信間隔（最短でも 60 秒）ではそこまで詰められない。
 */
static bool duty_cycle_allows(uint32_t airtime_ms)
{
    uint32_t now = of_uptime_ms();
    uint32_t budget_ms;

    if (of_elapsed_ms(now, s_airtime_window_start_ms) >= 3600000u) {
        s_airtime_window_start_ms = now;
        s_airtime_window_used_ms = 0u;
    }

    budget_ms = (3600000u / 1000u) * s_plan.duty_cycle_permille;
    return (s_airtime_window_used_ms + airtime_ms) <= budget_ms;
}

/**
 * @brief 送信前のキャリアセンス。AS923-JP のプランでのみ実行する。
 * @return チャネルが空いていれば true。
 */
static bool channel_clear(void)
{
    uint32_t deadline;

    if (!s_plan.listen_before_talk) {
        return true;
    }

    s_irq_flags = 0u;
    reg_write(REG_IRQ_FLAGS, 0xFFu);
    set_mode(MODE_CAD);

    deadline = of_uptime_ms() + 50u;
    while (of_uptime_ms() < deadline) {
        uint8_t flags = reg_read(REG_IRQ_FLAGS);
        if ((flags & IRQ_CAD_DONE) != 0u) {
            reg_write(REG_IRQ_FLAGS, 0xFFu);
            set_mode(MODE_STDBY);
            return (flags & IRQ_CAD_DETECTED) == 0u;
        }
    }

    set_mode(MODE_STDBY);
    return false;
}

of_err_t of_lora_send(const uint8_t *payload, size_t len, bool wait_ack)
{
    uint32_t airtime;
    uint32_t deadline;
    of_frame_header_t header;

    if (!s_ready) {
        return OF_ERR_NOT_READY;
    }
    if (payload == NULL || len == 0u || len > OF_LORA_MAX_PAYLOAD) {
        return OF_ERR_INVALID_ARG;
    }

    airtime = of_lora_airtime_ms(&s_plan, len);
    if (!duty_cycle_allows(airtime)) {
        return OF_ERR_BUSY;
    }
    if (!channel_clear()) {
        return OF_ERR_BUSY;
    }

    set_mode(MODE_STDBY);
    reg_write(REG_FIFO_ADDR_PTR, 0x00u);

    /* ヘッダの node_serial は符号化時には空のまま来る。焼き込み値を知っているのは
       この層だけなので、FIFO に積む直前に埋める。 */
    memcpy(&header, payload, OF_FRAME_HEADER_SIZE);
    header.node_serial = of_node_serial();

    {
        uint8_t tx[2];
        uint8_t rx[2];
        const uint8_t *hdr_bytes = (const uint8_t *)&header;

        for (size_t i = 0u; i < OF_FRAME_HEADER_SIZE; ++i) {
            tx[0] = (uint8_t)(REG_FIFO | 0x80u);
            tx[1] = hdr_bytes[i];
            (void)of_spi_radio_transfer(tx, rx, 2u);
        }
        for (size_t i = OF_FRAME_HEADER_SIZE; i < len; ++i) {
            tx[0] = (uint8_t)(REG_FIFO | 0x80u);
            tx[1] = payload[i];
            (void)of_spi_radio_transfer(tx, rx, 2u);
        }
    }

    reg_write(REG_PAYLOAD_LENGTH, (uint8_t)len);
    reg_write(REG_DIO_MAPPING1, 0x40u); /* DIO0 = TxDone */
    reg_write(REG_IRQ_FLAGS, 0xFFu);
    s_irq_flags = 0u;
    set_mode(MODE_TX);

    deadline = of_uptime_ms() + airtime + 200u;
    while ((s_irq_flags & IRQ_TX_DONE) == 0u) {
        if (of_uptime_ms() > deadline) {
            set_mode(MODE_STDBY);
            return OF_ERR_TIMEOUT;
        }
    }

    reg_write(REG_IRQ_FLAGS, 0xFFu);
    set_mode(MODE_STDBY);

    s_airtime_window_used_ms += airtime;
    s_airtime_today_ms += airtime;

    if (wait_ack) {
        uint8_t ack[OF_FRAME_HEADER_SIZE + 4u];
        int received = of_lora_receive(ack, sizeof(ack), 800u, NULL);

        if (received < (int)OF_FRAME_HEADER_SIZE) {
            return OF_ERR_TIMEOUT;
        }
    }

    return OF_OK;
}

int of_lora_receive(uint8_t *buf, size_t cap, uint32_t timeout_ms, of_lora_rx_info_t *info)
{
    uint32_t deadline;
    uint8_t flags;
    uint8_t length;
    uint8_t current;

    if (!s_ready) {
        return (int)OF_ERR_NOT_READY;
    }
    if (buf == NULL || cap == 0u) {
        return (int)OF_ERR_INVALID_ARG;
    }

    reg_write(REG_DIO_MAPPING1, 0x00u); /* DIO0 = RxDone */
    reg_write(REG_IRQ_FLAGS, 0xFFu);
    s_irq_flags = 0u;
    reg_write(REG_FIFO_ADDR_PTR, 0x00u);
    set_mode(MODE_RX_SINGLE);

    deadline = of_uptime_ms() + timeout_ms;
    for (;;) {
        flags = reg_read(REG_IRQ_FLAGS);
        if ((flags & (IRQ_RX_DONE | IRQ_RX_TIMEOUT)) != 0u) {
            break;
        }
        if (of_uptime_ms() > deadline) {
            set_mode(MODE_STDBY);
            return (int)OF_ERR_TIMEOUT;
        }
    }

    if ((flags & IRQ_RX_DONE) == 0u || (flags & IRQ_PAYLOAD_CRC_ERROR) != 0u) {
        reg_write(REG_IRQ_FLAGS, 0xFFu);
        set_mode(MODE_STDBY);
        return (flags & IRQ_PAYLOAD_CRC_ERROR) != 0u ? (int)OF_ERR_CRC : (int)OF_ERR_TIMEOUT;
    }

    length = reg_read(REG_RX_NB_BYTES);
    if ((size_t)length > cap) {
        length = (uint8_t)cap;
    }
    current = reg_read(REG_FIFO_RX_CURRENT);
    reg_write(REG_FIFO_ADDR_PTR, current);

    for (uint8_t i = 0u; i < length; ++i) {
        buf[i] = reg_read(REG_FIFO);
    }

    if (info != NULL) {
        int8_t snr_raw = (int8_t)reg_read(REG_PKT_SNR);

        info->snr_db = (int8_t)(snr_raw / 4);
        /* 高周波側モジュールなので RSSI のオフセットは -157 dBm。
           SNR が負のときはデータシートどおり SNR 分を足し戻す。 */
        info->rssi_dbm = (int16_t)(-157 + (int16_t)reg_read(REG_PKT_RSSI));
        if (info->snr_db < 0) {
            info->rssi_dbm = (int16_t)(info->rssi_dbm + info->snr_db);
        }
        info->received_at_uptime_ms = of_uptime_ms();
    }

    reg_write(REG_IRQ_FLAGS, 0xFFu);
    set_mode(MODE_STDBY);
    return (int)length;
}

void of_lora_sleep(void)
{
    if (!s_ready) {
        return;
    }
    set_mode(MODE_SLEEP);
}

void of_lora_irq_handler(void)
{
    /* ISR。SPI を回すと数百 µs 掛かるので、ここではフラグだけ立てて
       実際の読み出しはタスク側に任せる。 */
    s_irq_flags |= reg_read(REG_IRQ_FLAGS);
}

uint32_t of_lora_airtime_today_ms(void)
{
    return s_airtime_today_ms;
}

/** @brief 日次ロールオーバー。@ref of_power_rollover_day から呼ばれる。 */
void of_lora_rollover_day(void)
{
    s_airtime_today_ms = 0u;
}
