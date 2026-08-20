/**
 * @file lis3dh.c
 * @brief 3 軸加速度センサ LIS3DH の SPI ドライバ。衝撃ピーク（shock_g）と扉開放の補助検知を担当。
 *
 * サンプリング周期は 60 秒だが、荷役中の衝撃は数十ミリ秒で終わる。MCU を 60 秒ごとに
 * 起こして読むだけでは絶対に捉えられないので、センサ内蔵のしきい値割り込み（INT1）で
 * MCU を叩き起こし、ピークホールドだけ更新して再び STOP2 に戻る構成にしてある。
 * この経路が rule_code `shock_impact` の根拠になる。
 */

#include "of/of_power.h"
#include "of/of_types.h"

#include <string.h>

/** @name レジスタ番地 */
/** @{ */
#define LIS3DH_REG_WHO_AM_I 0x0Fu
#define LIS3DH_REG_CTRL1 0x20u
#define LIS3DH_REG_CTRL2 0x21u
#define LIS3DH_REG_CTRL3 0x22u
#define LIS3DH_REG_CTRL4 0x23u
#define LIS3DH_REG_CTRL5 0x24u
#define LIS3DH_REG_OUT_X_L 0x28u
#define LIS3DH_REG_INT1_CFG 0x30u
#define LIS3DH_REG_INT1_SRC 0x31u
#define LIS3DH_REG_INT1_THS 0x32u
#define LIS3DH_REG_INT1_DUR 0x33u
/** @} */

/** @brief WHO_AM_I の期待値。違えば実装違いか死んだ個体。 */
#define LIS3DH_WHO_AM_I_VALUE 0x33u

/** @brief ±16 g レンジでの LSB あたりのミリ G（低電力 8 ビットモード）。 */
#define LIS3DH_MG_PER_LSB_16G 186

/** @brief SPI の読み出しビットと自動インクリメントビット。 */
#define SPI_READ 0x80u
#define SPI_AUTO_INC 0x40u

extern of_err_t of_spi_accel_transfer(const uint8_t *tx, uint8_t *rx, size_t len);

/* 公開 API。ドライバごとのヘッダは作らず、app 層が extern で参照する方針。
   初期化からも設定変更を呼ぶので、ここで前方宣言しておく。 */
void of_lis3dh_set_threshold_mg(of_shock_mg_t mg);

static of_shock_mg_t s_peak_mg;
static uint32_t s_impact_count;
static of_shock_mg_t s_threshold_mg = 3500; /* 既定 3.5 G。設定ダウンリンクで変えられる */

/** @brief レジスタを 1 バイト書く。 */
static of_err_t reg_write(uint8_t reg, uint8_t value)
{
    uint8_t tx[2] = { reg, value };
    uint8_t rx[2];

    return of_spi_accel_transfer(tx, rx, sizeof(tx));
}

/** @brief レジスタを連続読みする。@p len は最大 6（X/Y/Z の 3 軸分）。 */
static of_err_t reg_read(uint8_t reg, uint8_t *out, size_t len)
{
    uint8_t tx[7] = { 0 };
    uint8_t rx[7] = { 0 };
    of_err_t err;

    if (len > 6u) {
        return OF_ERR_INVALID_ARG;
    }

    tx[0] = (uint8_t)(reg | SPI_READ | (len > 1u ? SPI_AUTO_INC : 0u));
    err = of_spi_accel_transfer(tx, rx, len + 1u);
    if (err != OF_OK) {
        return err;
    }
    memcpy(out, &rx[1], len);
    return OF_OK;
}

/**
 * @brief 3 軸の合成加速度をミリ G で求める。
 *
 * 平方根を避けるため、比較は二乗のまま行いたいところだが、ピーク値は
 * telemetry_readings.shock_g（NUMERIC(6,3)）にそのまま入る観測値なので、
 * ここだけは整数平方根を回している。ニュートン法 5 回で十分収束する。
 */
static of_shock_mg_t magnitude_mg(int16_t x, int16_t y, int16_t z)
{
    int64_t sq = (int64_t)x * x + (int64_t)y * y + (int64_t)z * z;
    int64_t root = sq;
    int64_t prev = 0;

    if (sq <= 0) {
        return 0;
    }
    for (unsigned i = 0u; i < 5u && root != prev; ++i) {
        prev = root;
        root = (root + sq / root) / 2;
    }
    return (of_shock_mg_t)(root * LIS3DH_MG_PER_LSB_16G / 16);
}

/**
 * @brief センサを初期化し、しきい値割り込みを有効にする。
 *
 * ODR は 400 Hz。低電力モード（8 ビット）を選ぶと消費が 1/10 になるが、
 * 分解能が 186 mg/LSB に落ちる。1 G 未満の微細な振動は捨てて構わない用途なので
 * これで良い、という判断が rev.C のレビューで確定している。
 */
of_err_t of_lis3dh_init(void)
{
    uint8_t who = 0u;
    of_err_t err = reg_read(LIS3DH_REG_WHO_AM_I, &who, 1u);

    if (err != OF_OK) {
        return err;
    }
    if (who != LIS3DH_WHO_AM_I_VALUE) {
        return OF_ERR_IO;
    }

    (void)reg_write(LIS3DH_REG_CTRL1, 0x77u); /* ODR 400 Hz、低電力、XYZ 有効 */
    (void)reg_write(LIS3DH_REG_CTRL2, 0x09u); /* 高域通過を INT1 系統に適用（重力を抜く） */
    (void)reg_write(LIS3DH_REG_CTRL3, 0x40u); /* IA1 を INT1 ピンへ */
    (void)reg_write(LIS3DH_REG_CTRL4, 0x30u); /* ±16 g、連続更新 */
    (void)reg_write(LIS3DH_REG_CTRL5, 0x08u); /* INT1 をラッチする。読み捨て漏れを防ぐ */

    of_lis3dh_set_threshold_mg(s_threshold_mg);
    (void)reg_write(LIS3DH_REG_INT1_DUR, 0x02u);  /* 5 ms 未満の単発は無視 */
    (void)reg_write(LIS3DH_REG_INT1_CFG, 0x2Au); /* X/Y/Z いずれかが上限超過 (OR) */

    s_peak_mg = 0;
    s_impact_count = 0u;
    return OF_OK;
}

/**
 * @brief 割り込みしきい値を設定する。設定ダウンリンク（OF_FRAME_KIND_CONFIG）から呼ばれる。
 * @param mg ミリ G。±16 g レンジの 1 LSB = 186 mg に丸められる。
 */
void of_lis3dh_set_threshold_mg(of_shock_mg_t mg)
{
    int32_t ths;

    if (mg < LIS3DH_MG_PER_LSB_16G) {
        mg = LIS3DH_MG_PER_LSB_16G;
    }
    s_threshold_mg = mg;
    ths = mg / LIS3DH_MG_PER_LSB_16G;
    if (ths > 0x7F) {
        ths = 0x7F;
    }
    (void)reg_write(LIS3DH_REG_INT1_THS, (uint8_t)ths);
}

/**
 * @brief INT1 で叩き起こされたときに呼ぶ。現在値を読んでピークを更新する。
 *
 * @return 更新後のピーク（ミリ G）。
 * @note ここは STOP2 からの復帰直後、@ref OF_WAKE_ACCEL_INT1 の処理として走る。
 *       SPI 1 往復と平方根だけで済ませ、5 ms 以内に再び眠ること。
 */
of_shock_mg_t of_lis3dh_on_interrupt(void)
{
    uint8_t raw[6] = { 0 };
    uint8_t src = 0u;
    int16_t x;
    int16_t y;
    int16_t z;
    of_shock_mg_t mag;

    (void)reg_read(LIS3DH_REG_INT1_SRC, &src, 1u); /* ラッチ解除を兼ねる */

    if (reg_read(LIS3DH_REG_OUT_X_L, raw, sizeof(raw)) != OF_OK) {
        return s_peak_mg;
    }

    x = (int16_t)(((uint16_t)raw[1] << 8) | raw[0]) / 16;
    y = (int16_t)(((uint16_t)raw[3] << 8) | raw[2]) / 16;
    z = (int16_t)(((uint16_t)raw[5] << 8) | raw[4]) / 16;

    mag = magnitude_mg(x, y, z);
    if (mag > s_peak_mg) {
        s_peak_mg = mag;
    }
    if (mag >= s_threshold_mg) {
        s_impact_count++;
    }
    return s_peak_mg;
}

/**
 * @brief 直近周期のピークを取り出し、内部の保持値を 0 に戻す。
 * @return ミリ G。割り込みが一度も来ていなければ 0。
 */
of_shock_mg_t of_lis3dh_take_peak_mg(void)
{
    of_shock_mg_t peak;

    of_critical_enter();
    peak = s_peak_mg;
    s_peak_mg = 0;
    of_critical_exit();

    return peak;
}

/** @brief 起動以降にしきい値を超えた回数。荷役の乱暴さの指標として analytics 側で使われる。 */
uint32_t of_lis3dh_impact_count(void)
{
    return s_impact_count;
}
