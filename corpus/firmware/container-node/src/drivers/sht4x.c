/**
 * @file sht4x.c
 * @brief 温湿度センサ SHT45 の I2C ドライバ。telemetry_readings.temperature_c と humidity_pct の出所。
 *
 * リーファコンテナでは freight.containers.setpoint_c との差がそのまま
 * `temp_excursion_high` / `temp_excursion_low` の判定材料になるので、
 * 測定そのものより「信用できない値を出さないこと」を優先している。
 * CRC が合わない読み値は捨て、再試行しても駄目なら欠測（OF_TEMP_INVALID）として上げる。
 * 補間して埋めるようなことは絶対にしない。ingest 側で null として扱われる方が、
 * それらしい嘘の温度が telemetry.telemetry_readings に残るより百倍ましだから。
 */

#include "of/of_crc.h"
#include "of/of_types.h"

#include <string.h>

/** @brief SHT45 のスレーブアドレス（ADDR ピンは GND 固定）。 */
#define SHT4X_ADDR 0x44u

/** @brief 高精度・ヒータ無しの一発測定コマンド。 */
#define SHT4X_CMD_MEASURE_HIGH 0xFDu

/** @brief 200 mW のヒータを 1 秒。結露時の湿度張り付きを剥がすために使う。 */
#define SHT4X_CMD_HEATER_200MW_1S 0x39u

/** @brief ソフトリセット。 */
#define SHT4X_CMD_RESET 0x94u

/** @brief 高精度測定の変換時間。データシート上の最大値 8.3 ms に余裕を足した値。 */
#define SHT4X_CONVERSION_MS 10u

/** @brief 結露判定に使う湿度しきい値。これを 3 回連続で超えたらヒータを焚く。 */
#define SHT4X_HEATER_TRIGGER_P100 9800u

/* HAL 側の I2C プリミティブ。hal/stm32l4 に実装がある。 */
extern of_err_t of_i2c_write(uint8_t addr, const uint8_t *data, size_t len);
extern of_err_t of_i2c_read(uint8_t addr, uint8_t *data, size_t len);
extern void of_delay_ms(uint32_t ms);

static uint8_t s_saturated_streak = 0u;
static uint32_t s_crc_failures = 0u;

/**
 * @brief 生カウントを 1/100 ℃ に変換する。
 *
 * データシートの T = -45 + 175 * raw / 65535 を、64 ビット整数で先に掛けてから割る形にした。
 * 先に割ると 0.3 ℃ 近い量子化誤差が出て、setpoint ±0.5 ℃ の医薬品コンテナで
 * 誤検知が出る。
 */
static of_temp_c100_t raw_to_temp_c100(uint16_t raw)
{
    int64_t scaled = ((int64_t)raw * 17500) / 65535;
    return (of_temp_c100_t)(scaled - 4500);
}

/** @brief 生カウントを 1/100 % に変換し、0〜10000 にクランプする。 */
static of_humid_p100_t raw_to_humid_p100(uint16_t raw)
{
    int64_t scaled = ((int64_t)raw * 12500) / 65535 - 600;

    /* データシート上、素の変換式は -6 %〜119 % を返しうる。DB 側の
       NUMERIC(5,2) には入るが、telemetry-ingest の humidity_high ルールが
       100 超えを異常値として扱うので、ここで潰しておく。 */
    if (scaled < 0) {
        scaled = 0;
    }
    if (scaled > 10000) {
        scaled = 10000;
    }
    return (of_humid_p100_t)scaled;
}

/**
 * @brief センサを初期化する。存在確認としてリセットを 1 回撃つ。
 * @return I2C が NACK を返せば OF_ERR_IO。基板実装ミスの一次切り分けはここで付く。
 */
of_err_t of_sht4x_init(void)
{
    const uint8_t cmd = SHT4X_CMD_RESET;
    of_err_t err = of_i2c_write(SHT4X_ADDR, &cmd, 1u);

    if (err != OF_OK) {
        return err;
    }
    of_delay_ms(2u); /* ソフトリセット後の待ち。データシート指定は 1 ms */
    s_saturated_streak = 0u;
    s_crc_failures = 0u;
    return OF_OK;
}

/**
 * @brief 温湿度を 1 回測定する。
 *
 * @param[out] temp  1/100 ℃。取得できなければ @ref OF_TEMP_INVALID。
 * @param[out] humid 1/100 %。取得できなければ @ref OF_HUMID_INVALID。
 * @return OF_OK / OF_ERR_IO / OF_ERR_CRC。
 *
 * @note 呼び出し側は OF_ERR_CRC を欠測として扱い、その周期のレコードは
 *       温湿度だけ null で上げる。1 サンプル落とすだけなら sequence の連番は保たれる。
 */
of_err_t of_sht4x_measure(of_temp_c100_t *temp, of_humid_p100_t *humid)
{
    const uint8_t cmd = SHT4X_CMD_MEASURE_HIGH;
    uint8_t rx[6];
    of_err_t err;

    if (temp == NULL || humid == NULL) {
        return OF_ERR_INVALID_ARG;
    }

    *temp = OF_TEMP_INVALID;
    *humid = OF_HUMID_INVALID;

    err = of_i2c_write(SHT4X_ADDR, &cmd, 1u);
    if (err != OF_OK) {
        return err;
    }

    of_delay_ms(SHT4X_CONVERSION_MS);

    err = of_i2c_read(SHT4X_ADDR, rx, sizeof(rx));
    if (err != OF_OK) {
        return err;
    }

    /* 2 バイトごとに CRC-8 が付く。片方だけ壊れることが実際にあるので、
       まとめてではなく個別に見る。 */
    if (of_crc8_sensirion(&rx[0], 2u) != rx[2] || of_crc8_sensirion(&rx[3], 2u) != rx[5]) {
        s_crc_failures++;
        return OF_ERR_CRC;
    }

    *temp = raw_to_temp_c100((uint16_t)((rx[0] << 8) | rx[1]));
    *humid = raw_to_humid_p100((uint16_t)((rx[3] << 8) | rx[4]));

    if (*humid >= SHT4X_HEATER_TRIGGER_P100) {
        if (s_saturated_streak < 255u) {
            s_saturated_streak++;
        }
    } else {
        s_saturated_streak = 0u;
    }

    return OF_OK;
}

/**
 * @brief 結露が続いているなら短時間ヒータを焚く。
 *
 * 消費電力が跳ねる（200 mW × 1 秒）ので、3 周期連続で 98 % を超えたときだけ。
 * 冷凍から常温への戻りで湿度が張り付いたまま返ってこなくなる個体が
 * ロット単位で存在し、これを入れるまで humidity_high の誤報が止まらなかった。
 *
 * @return 実際に焚いたら true。
 */
bool of_sht4x_service_heater(void)
{
    const uint8_t cmd = SHT4X_CMD_HEATER_200MW_1S;

    if (s_saturated_streak < 3u) {
        return false;
    }
    if (of_i2c_write(SHT4X_ADDR, &cmd, 1u) != OF_OK) {
        return false;
    }

    of_delay_ms(1100u);
    s_saturated_streak = 0u;
    return true;
}

/** @brief 起動以降の CRC 失敗回数。heartbeat の診断カウンタに載せる。 */
uint32_t of_sht4x_crc_failures(void)
{
    return s_crc_failures;
}
