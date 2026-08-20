/**
 * @file ringbuf.c
 * @brief @ref of_ringbuf.h の実装。割り込み側の書き込みとタスク側の読み出しが競合しても
 *        レコードが裂けないように、インデックスの更新順序だけで整合性を取っている。
 *
 * 排他は「上書きが起きるときの tail 前進」の一瞬にしか掛けない。通常の push は
 * スロットを埋めてから head を進めるだけで、消費者から見て head が進んだ時点では
 * 中身が完全に書き終わっている。この順序を入れ替えると、消費者が半分書けた
 * レコードを LoRa フレームに詰めることになる。
 */

#include "of/of_ringbuf.h"

#include <string.h>

/** @brief 2 の冪容量を前提にした剰余。 */
#define RB_MASK (OF_RINGBUF_CAPACITY - 1u)

void of_ringbuf_init(of_ringbuf_t *rb)
{
    if (rb == NULL) {
        return;
    }
    memset(rb, 0, sizeof(*rb));
}

uint32_t of_ringbuf_count(const of_ringbuf_t *rb)
{
    if (rb == NULL) {
        return 0u;
    }
    /* head と tail は単調増加のまま持ち、参照時にマスクする。差分を取るだけで
       件数が出るので、満杯と空を区別するための余分なフラグが要らない。 */
    return (uint32_t)(rb->head - rb->tail);
}

bool of_ringbuf_is_empty(const of_ringbuf_t *rb)
{
    return of_ringbuf_count(rb) == 0u;
}

bool of_ringbuf_push_overwrite(of_ringbuf_t *rb, const of_reading_t *reading)
{
    bool dropped = false;

    if (rb == NULL || reading == NULL) {
        return false;
    }

    if (of_ringbuf_count(rb) >= OF_RINGBUF_CAPACITY) {
        /* 満杯。最古を 1 件捨てる。ここだけは消費者と同じ tail を触るので排他が要る。 */
        of_critical_enter();
        if ((uint32_t)(rb->head - rb->tail) >= OF_RINGBUF_CAPACITY) {
            rb->tail++;
            rb->dropped++;
            dropped = true;
        }
        of_critical_exit();
    }

    rb->slots[rb->head & RB_MASK] = *reading;

    /* スロットを埋めきってから head を公開する。この 1 行が消費者に対する
       release 相当になっている。Cortex-M4 の単一コアなので明示のバリアは要らない。 */
    rb->head++;

    {
        uint32_t depth = of_ringbuf_count(rb);
        if (depth > rb->high_water) {
            rb->high_water = depth;
        }
    }

    return dropped;
}

of_err_t of_ringbuf_pop(of_ringbuf_t *rb, of_reading_t *out)
{
    if (rb == NULL || out == NULL) {
        return OF_ERR_INVALID_ARG;
    }
    if (of_ringbuf_is_empty(rb)) {
        return OF_ERR_NOT_READY;
    }

    *out = rb->slots[rb->tail & RB_MASK];
    rb->tail++;
    return OF_OK;
}

uint32_t of_ringbuf_peek_span(of_ringbuf_t *rb, const of_reading_t **span, uint32_t max)
{
    uint32_t available;
    uint32_t start;
    uint32_t until_wrap;

    if (rb == NULL || span == NULL || max == 0u) {
        return 0u;
    }

    available = of_ringbuf_count(rb);
    if (available == 0u) {
        *span = NULL;
        return 0u;
    }

    start = rb->tail & RB_MASK;
    until_wrap = OF_RINGBUF_CAPACITY - start;

    if (available > max) {
        available = max;
    }
    if (available > until_wrap) {
        /* 折り返しを跨ぐ分は返さない。呼び出し側は 2 回に分けて詰めればよく、
           フレームあたり 4 レコードしか入らない以上、実際にはほぼ起きない。 */
        available = until_wrap;
    }

    *span = &rb->slots[start];
    return available;
}

void of_ringbuf_consume(of_ringbuf_t *rb, uint32_t count)
{
    uint32_t held;

    if (rb == NULL || count == 0u) {
        return;
    }

    held = of_ringbuf_count(rb);
    if (count > held) {
        count = held;
    }
    rb->tail += count;
}

uint32_t of_ringbuf_take_dropped(of_ringbuf_t *rb)
{
    uint32_t value;

    if (rb == NULL) {
        return 0u;
    }

    of_critical_enter();
    value = rb->dropped;
    rb->dropped = 0u;
    of_critical_exit();

    return value;
}
