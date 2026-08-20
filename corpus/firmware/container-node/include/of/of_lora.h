/**
 * @file of_lora.h
 * @brief SX1276 を使った LoRa 無線の公開 API。物理層の設定と、地域ごとの送信規制を担う。
 *
 * ノードから vehicle-board（telemetry.device_gateways では depot_id が NULL の移動体ゲートウェイ）
 * への片方向が主で、ダウンリンクは時刻同期としきい値設定の 2 種類しか受けない。
 * LoRaWAN スタックは載せていない。ネットワークサーバを経由せず、視界内の board に直接届けば
 * 良い設計なので、MAC 層は @ref of_lora_send の ACK 待ちだけで足りている。
 *
 * @see firmware/container-node/src/radio/sx1276.c 実装
 * @see firmware/vehicle-board/src/main.cpp 受信側
 */

#ifndef OF_LORA_H
#define OF_LORA_H

#include "of/of_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/** @brief SX1276 の FIFO 長。これを超えるフレームは物理的に送れない。 */
#define OF_LORA_MAX_PAYLOAD 255u

/** @brief 同期ワード。LoRaWAN のパブリック網（0x34）と衝突しない私設値。 */
#define OF_LORA_SYNC_WORD 0x12u

/** @brief 拡散率。値が大きいほど遠くまで届き、airtime と消費電力が指数的に増える。 */
typedef enum {
    OF_LORA_SF7 = 7,
    OF_LORA_SF8 = 8,
    OF_LORA_SF9 = 9,
    OF_LORA_SF10 = 10,
    OF_LORA_SF11 = 11,
    OF_LORA_SF12 = 12
} of_lora_sf_t;

/** @brief 帯域幅。125 kHz 以外は地域プランで許される場合のみ。 */
typedef enum {
    OF_LORA_BW_125K = 0,
    OF_LORA_BW_250K,
    OF_LORA_BW_500K
} of_lora_bw_t;

/**
 * @brief 地域別の無線プラン。SPEC §0.6 の地域コードとは一対一ではない。
 *
 * 地域コードはデータ所在地の話であって電波法の話ではないので、
 * `eu-west` と `eu-central` は同じ EU868 を使い、`apac-jp` だけ AS923 の
 * 日本向けチャネルとキャリアセンス必須の条件が付く。
 */
typedef struct {
    uint32_t frequency_hz;      /**< 中心周波数 */
    of_lora_sf_t sf;
    of_lora_bw_t bw;
    uint8_t coding_rate;        /**< 4/5 なら 5。5〜8 */
    int8_t tx_power_dbm;        /**< PA_BOOST 経由。地域の EIRP 上限を超えない値 */
    uint16_t duty_cycle_permille; /**< 10 = 1 %。EU868 の g1 サブバンド相当 */
    bool listen_before_talk;    /**< AS923-JP で必須。CAD を送信前に必ず回す */
} of_lora_plan_t;

/** @brief 受信結果に付く品質指標。診断とサンプリング周期の自動調整に使う。 */
typedef struct {
    int16_t rssi_dbm;
    int8_t snr_db;
    uint32_t received_at_uptime_ms;
} of_lora_rx_info_t;

/**
 * @brief 地域に対応する既定プランを引く。
 * @param region 地域コード。
 * @return 静的テーブルへのポインタ。未知の地域では EU868 の最も保守的な設定を返す。
 */
const of_lora_plan_t *of_lora_default_plan(of_region_t region);

/**
 * @brief 無線を初期化する。SPI の疎通確認とチップリビジョンの読み出しを含む。
 * @return SX1276 の RegVersion が 0x12 でなければ OF_ERR_IO。
 */
of_err_t of_lora_init(const of_lora_plan_t *plan);

/**
 * @brief フレームを送信する。送信中は STOP2 に入れないので、呼び出し側で待つ。
 *
 * @param payload   送信バイト列（@ref of_frame_header_t 込み）。
 * @param len       長さ。@ref OF_LORA_MAX_PAYLOAD 以下。
 * @param wait_ack  true なら送信後 RX ウィンドウを開いて board の ACK を待つ。
 * @return OF_OK、ACK が来なければ OF_ERR_TIMEOUT、duty cycle 超過なら OF_ERR_BUSY。
 *
 * @note duty cycle の判定はここで行う。@ref of_power_reserve_uplink とは別の制約で、
 *       片方が通ってももう片方で弾かれることがある（電池はあるが法的に撃てない、が典型）。
 */
of_err_t of_lora_send(const uint8_t *payload, size_t len, bool wait_ack);

/**
 * @brief 受信ウィンドウを開く。時刻同期と設定のダウンリンクを拾うため、送信直後に短く開く。
 * @param timeout_ms 最大待ち時間。
 * @param[out] info  受信品質（NULL 可）。
 * @return 受信長、または負の @ref of_err_t。
 */
int of_lora_receive(uint8_t *buf, size_t cap, uint32_t timeout_ms, of_lora_rx_info_t *info);

/**
 * @brief 指定長のフレームの airtime をミリ秒で見積もる。
 *
 * Semtech のアプリケーションノート AN1200.13 のシンボル計算をそのまま整数演算にしたもの。
 * @ref of_power_reserve_uplink と duty cycle の両方がこの値を入力にする。
 */
uint32_t of_lora_airtime_ms(const of_lora_plan_t *plan, size_t payload_len);

/** @brief 無線を sleep に落とす。STOP2 に入る前に必ず呼ぶこと。 */
void of_lora_sleep(void);

/**
 * @brief DIO0/DIO1 の割り込みハンドラから呼ぶ。ISR コンテキストで動く。
 * @note 内部でフラグを立てるだけで、FIFO の読み出しはタスク側で行う。
 */
void of_lora_irq_handler(void);

/** @brief 今日使った airtime の合計（ミリ秒）。heartbeat に載せる。 */
uint32_t of_lora_airtime_today_ms(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OF_LORA_H */
