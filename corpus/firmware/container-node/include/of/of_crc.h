/**
 * @file of_crc.h
 * @brief 3 種類の CRC の宣言。無線フレーム、フラッシュジャーナル、センサバスでそれぞれ多項式が違う。
 *
 * 用途ごとに別の多項式を使うのは趣味ではなく、相手が決めている。
 * Sensirion の SHT4x は CRC-8/NRSC-5 を返し、SX1276 のフレームには CCITT を載せる規約にし、
 * 内蔵フラッシュのジャーナルページは CRC-32C（Castagnoli）で守っている。
 * 3 つを 1 つに寄せようとした変更が過去に一度入って、SHT4x の読み値が全部
 * OF_ERR_CRC で落ちる障害になった。
 */

#ifndef OF_CRC_H
#define OF_CRC_H

#include "of/of_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/** @brief CRC-16/CCITT-FALSE の初期値。 */
#define OF_CRC16_INIT 0xFFFFu

/** @brief CRC-32C の初期値（反転出力前）。 */
#define OF_CRC32C_INIT 0xFFFFFFFFu

/**
 * @brief CRC-16/CCITT-FALSE（多項式 0x1021、初期値 0xFFFF、反転なし）。
 *
 * @ref of_frame_header_t の crc16 に入れる値。分割して呼べるよう seed を取る。
 * @param seed 継続計算のときは前回の戻り値、最初は @ref OF_CRC16_INIT。
 * @param data 対象バイト列。NULL なら seed をそのまま返す。
 * @param len  長さ。
 */
uint16_t of_crc16_ccitt(uint16_t seed, const void *data, size_t len);

/**
 * @brief CRC-32C（多項式 0x1EDC6F41 の反転表現 0x82F63B78）。
 *
 * フラッシュジャーナルのページ末尾に付ける。出力は 1 の補数を取った値で、
 * 空ページ（全 0xFF）が偶然一致しない点をロット受け入れ試験で確認済み。
 */
uint32_t of_crc32c(uint32_t seed, const void *data, size_t len);

/**
 * @brief CRC-8/NRSC-5（多項式 0x31、初期値 0xFF）。Sensirion のセンサが返す検査バイト。
 * @param data 2 バイトの測定値。
 * @param len  常に 2 だが、将来のセンサ向けに長さを取る。
 */
uint8_t of_crc8_sensirion(const void *data, size_t len);

/**
 * @brief 生成表を先に作っておく。初回計算のジッタを避けたいときだけ呼べばよい。
 * @note 呼ばなくても各関数が遅延初期化する。表は RAM に 1 KiB + 256 B 取る。
 */
void of_crc_prime_tables(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OF_CRC_H */
