/*
 * SPDX-License-Identifier: LicenseRef-ORBITALFREIGHT-Internal
 */

/**
 * @file crc.c
 * @brief @ref of_crc.h の 3 種類の CRC 実装。表は遅延生成で、フラッシュではなく RAM に置く。
 *
 * 表を定数配列として ROM に焼かないのは、この MCU のフラッシュが 256 KiB しかなく、
 * 地図データ（ジオフェンス判定用の粗いポリゴン）に空きを回したいため。
 * 生成コストは 80 MHz で 40 µs 程度なので、起動時に一度だけ払えば実用上は無視できる。
 */

#include "of/of_crc.h"

/** @brief CRC-16/CCITT-FALSE の生成多項式。 */
#define CRC16_POLY 0x1021u

/** @brief CRC-32C（Castagnoli）の反転表現。右シフト実装に合わせてある。 */
#define CRC32C_POLY_REFLECTED 0x82F63B78u

/** @brief Sensirion のセンサが使う CRC-8 多項式。 */
#define CRC8_POLY 0x31u

static uint16_t s_crc16_table[256];
static uint32_t s_crc32c_table[256];
static uint8_t s_crc8_table[256];
static bool s_tables_ready = false;

/**
 * @brief 3 つの生成表をまとめて作る。
 * @internal 割り込みから CRC を呼ぶ経路はないので、二重初期化の排他は掛けていない。
 *           万一同時に走っても書き込む値は同じで、途中経過を読むこともない。
 */
static void build_tables(void)
{
    for (unsigned i = 0u; i < 256u; ++i) {
        uint16_t c16 = (uint16_t)(i << 8);
        uint32_t c32 = (uint32_t)i;
        uint8_t c8 = (uint8_t)i;

        for (unsigned bit = 0u; bit < 8u; ++bit) {
            c16 = (uint16_t)((c16 & 0x8000u) ? ((c16 << 1) ^ CRC16_POLY) : (c16 << 1));
            c32 = (c32 & 1u) ? ((c32 >> 1) ^ CRC32C_POLY_REFLECTED) : (c32 >> 1);
            c8 = (uint8_t)((c8 & 0x80u) ? ((c8 << 1) ^ CRC8_POLY) : (c8 << 1));
        }

        s_crc16_table[i] = c16;
        s_crc32c_table[i] = c32;
        s_crc8_table[i] = c8;
    }

    s_tables_ready = true;
}

void of_crc_prime_tables(void)
{
    if (!s_tables_ready) {
        build_tables();
    }
}

uint16_t of_crc16_ccitt(uint16_t seed, const void *data, size_t len)
{
    const uint8_t *p = (const uint8_t *)data;
    uint16_t crc = seed;

    if (p == NULL || len == 0u) {
        return seed;
    }
    if (!s_tables_ready) {
        build_tables();
    }

    while (len-- > 0u) {
        crc = (uint16_t)((crc << 8) ^ s_crc16_table[((crc >> 8) ^ *p++) & 0xFFu]);
    }

    return crc;
}

uint32_t of_crc32c(uint32_t seed, const void *data, size_t len)
{
    const uint8_t *p = (const uint8_t *)data;
    uint32_t crc = seed;

    if (p == NULL || len == 0u) {
        return seed;
    }
    if (!s_tables_ready) {
        build_tables();
    }

    while (len-- > 0u) {
        crc = s_crc32c_table[(crc ^ *p++) & 0xFFu] ^ (crc >> 8);
    }

    /* 呼び出し側が分割して呼べるよう、最終補数はここでは取らない。
       ジャーナルページに書く直前に ~crc すること。継続計算のたびに
       補数を取ってしまい、再起動後のページ検証が全滅した実装が過去にある。 */
    return crc;
}

uint8_t of_crc8_sensirion(const void *data, size_t len)
{
    const uint8_t *p = (const uint8_t *)data;
    uint8_t crc = 0xFFu;

    if (p == NULL || len == 0u) {
        return crc;
    }
    if (!s_tables_ready) {
        build_tables();
    }

    while (len-- > 0u) {
        crc = s_crc8_table[crc ^ *p++];
    }

    return crc;
}
