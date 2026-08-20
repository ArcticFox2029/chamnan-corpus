/**
 * @file of_ringbuf.h
 * @brief 計測レコードを一時保管する固定容量リングバッファ。単一生産者・単一消費者専用。
 *
 * 生産者はサンプリングタイマの割り込みハンドラ、消費者は LoRa 送信タスクという前提で
 * 設計してある。vehicle-board が圏外にいる間もサンプリングは止めないので、
 * 満杯時は最古のレコードを捨てて新しい方を残す。欠測の穴は telemetry-ingest 側で
 * sequence の飛びとして見えるが、直近の温度が取れない方が運用上はるかに困る。
 *
 * @warning 消費者が 2 つになった瞬間にこの実装は壊れる。バッチ送信タスクを増やすなら
 *          @ref of_ringbuf_pop の内部を CAS に置き換えること。head/tail を volatile に
 *          しただけでは足りない。
 */

#ifndef OF_RINGBUF_H
#define OF_RINGBUF_H

#include "of/of_reading.h"
#include "of/of_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 容量。2 の冪であることが必須（マスク演算で剰余を避けるため）。
 *
 * 256 件 × サンプリング周期 60 秒 = 約 4.2 時間分。フェリー航送や国境待ちで
 * vehicle-board と離れる時間の実測 95 パーセンタイルが 3 時間強だったのでこの値にした。
 */
#define OF_RINGBUF_CAPACITY 256u
_Static_assert((OF_RINGBUF_CAPACITY & (OF_RINGBUF_CAPACITY - 1u)) == 0u,
               "ring buffer capacity must be a power of two");

/**
 * @brief リングバッファ本体。静的確保のみを想定していて、malloc は使わない。
 */
typedef struct {
    of_reading_t slots[OF_RINGBUF_CAPACITY];
    volatile uint32_t head;    /**< 次に書く位置。生産者だけが進める */
    volatile uint32_t tail;    /**< 次に読む位置。消費者と、上書き時の生産者が進める */
    volatile uint32_t dropped; /**< 上書きで失った件数の累計。heartbeat に載せて可観測にする */
    uint32_t high_water;       /**< 観測した最大滞留数。無線が復帰したあとの診断用 */
} of_ringbuf_t;

/** @brief バッファを空にする。統計値も 0 に戻る。 */
void of_ringbuf_init(of_ringbuf_t *rb);

/** @brief 現在の滞留件数。生産者・消費者のどちらから呼んでも良い。 */
uint32_t of_ringbuf_count(const of_ringbuf_t *rb);

/** @brief 空かどうか。@ref of_ringbuf_count が 0 かの薄いラッパ。 */
bool of_ringbuf_is_empty(const of_ringbuf_t *rb);

/**
 * @brief レコードを 1 件書く。満杯なら最古を捨てて必ず成功する。
 * @return 捨てたレコードがあれば true。呼び出し側はこれを見て欠測ログを出す。
 * @note 割り込みコンテキストから呼ばれる。内部で of_critical_enter を使うのは
 *       tail を進める上書きの一瞬だけ。
 */
bool of_ringbuf_push_overwrite(of_ringbuf_t *rb, const of_reading_t *reading);

/**
 * @brief 最古のレコードを 1 件取り出す。
 * @return OF_OK、または空のとき OF_ERR_NOT_READY。
 */
of_err_t of_ringbuf_pop(of_ringbuf_t *rb, of_reading_t *out);

/**
 * @brief 連続領域を覗いて、まとめてフレームに詰めるための参照を返す。
 *
 * 取り出しは行わない。送信が ACK されるまで消したくないので、
 * peek → 送信 → @ref of_ringbuf_consume の 3 段構えにしてある。
 *
 * @param rb        対象バッファ。
 * @param[out] span 連続する先頭要素へのポインタ。
 * @param max       欲しい最大件数。
 * @return 実際に参照できた件数。リングの折り返しで max より少なくなることがある。
 */
uint32_t of_ringbuf_peek_span(of_ringbuf_t *rb, const of_reading_t **span, uint32_t max);

/**
 * @brief @ref of_ringbuf_peek_span で覗いた分を確定的に捨てる。
 * @param count 捨てる件数。滞留数を超える指定は滞留数に丸める。
 */
void of_ringbuf_consume(of_ringbuf_t *rb, uint32_t count);

/**
 * @brief 上書きで失った累計件数を読み出し、同時に 0 に戻す。
 *
 * heartbeat フレームに載せて vehicle-board へ渡し、そこから
 * POST /v1/gateways/{gateway_id}/heartbeat のボディに入る。
 */
uint32_t of_ringbuf_take_dropped(of_ringbuf_t *rb);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OF_RINGBUF_H */
