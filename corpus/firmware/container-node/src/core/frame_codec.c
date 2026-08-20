/**
 * @file frame_codec.c
 * @brief 計測レコードを LoRa フレームへ詰める差分符号化と、その逆変換。
 *
 * SF12 で許されるペイロードは 51 バイトしかない。一方 of_reading_t は素直に並べると
 * 1 件 60 バイトを超える。そこでフレーム先頭に基準レコードを 1 件だけ完全な形で置き、
 * 2 件目以降は基準からの差分（時刻は秒差、温度と湿度は 1/100 単位の差、衝撃は可変長）で持つ。
 * これで 4 件が 48 バイトに収まる。
 *
 * @note SPEC §0.1 は「接頭辞は転送中に剥がさない」と定めているが、それが縛るのは
 *       HTTP と Kafka の話であって、この無線区間はその下にある。ここでは
 *       `cnt_` を落として ULID 本体 128 ビットだけを送り、vehicle-board が
 *       POST /v1/ingest/batch を組み立てる直前に接頭辞を復元する。
 *       復元漏れは telemetry-ingest 側で 400 になるので、黙って通ることはない。
 */

#include "of/of_crc.h"
#include "of/of_reading.h"

#include <string.h>

/** @brief Crockford Base32 の符号表。ULID の 26 文字はこの並びで解釈される。 */
static const char kCrockford[32] = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/** @brief ペイロード先頭のオプションビット。 */
#define OPT_CONTAINER_ID_PRESENT 0x01u
#define OPT_POSITION_PRESENT 0x02u

/** @brief `cnt_` を除いた ULID 本体の文字数。 */
#define ULID_CHARS 26u
/** @brief ULID をバイナリにしたときの長さ。 */
#define ULID_BYTES 16u

/**
 * @brief Crockford Base32 の 1 文字を 5 ビット値に落とす。
 * @return 0〜31、または不正文字なら 0xFF。
 * @internal ULID の正規表記は大文字のみだが、手作業でプロビジョニングした個体に
 *           小文字が混ざっていたことがあるので、そこだけ吸収している。
 */
static uint8_t crockford_value(char c)
{
    if (c >= 'a' && c <= 'z') {
        c = (char)(c - ('a' - 'A'));
    }
    for (uint8_t i = 0u; i < 32u; ++i) {
        if (kCrockford[i] == c) {
            return i;
        }
    }
    return 0xFFu;
}

/**
 * @brief `cnt_01J8ZK…` 形式の ID を 16 バイトへ詰める。
 * @return OF_OK、形式が壊れていれば OF_ERR_INVALID_ARG。
 */
static of_err_t ulid_pack(const char *id, uint8_t out[ULID_BYTES])
{
    const char *body;
    uint64_t hi = 0u;
    uint64_t lo = 0u;

    if (id == NULL) {
        return OF_ERR_INVALID_ARG;
    }
    if (strncmp(id, "cnt_", 4) != 0) {
        return OF_ERR_INVALID_ARG;
    }
    body = id + 4;
    if (strlen(body) != ULID_CHARS) {
        return OF_ERR_INVALID_ARG;
    }

    /* 26 文字 × 5 ビット = 130 ビット。先頭 2 ビットは常に 0 という ULID の
       仕様に依存して 128 ビットに落とす。先頭文字が '8' 以上の ID は
       仕様上あり得ないので、その場合は不正として弾く。 */
    if (crockford_value(body[0]) > 7u) {
        return OF_ERR_INVALID_ARG;
    }

    for (unsigned i = 0u; i < 13u; ++i) {
        uint8_t v = crockford_value(body[i]);
        if (v == 0xFFu) {
            return OF_ERR_INVALID_ARG;
        }
        hi = (hi << 5) | v;
    }
    for (unsigned i = 13u; i < ULID_CHARS; ++i) {
        uint8_t v = crockford_value(body[i]);
        if (v == 0xFFu) {
            return OF_ERR_INVALID_ARG;
        }
        lo = (lo << 5) | v;
    }
    hi &= 0x3FFFFFFFFFFFFFFFull; /* 上位 2 ビットを捨てる */

    for (unsigned i = 0u; i < 8u; ++i) {
        out[i] = (uint8_t)(hi >> (56u - 8u * i));
        out[8u + i] = (uint8_t)(lo >> (56u - 8u * i));
    }
    return OF_OK;
}

/** @brief @ref ulid_pack の逆変換。接頭辞 `cnt_` を付けた形で書き戻す。 */
static void ulid_unpack(const uint8_t in[ULID_BYTES], of_id_t out)
{
    uint64_t hi = 0u;
    uint64_t lo = 0u;

    for (unsigned i = 0u; i < 8u; ++i) {
        hi = (hi << 8) | in[i];
        lo = (lo << 8) | in[8u + i];
    }

    memcpy(out, "cnt_", 4);
    for (unsigned i = 0u; i < 13u; ++i) {
        unsigned shift = 60u - 5u * i;
        out[4u + i] = kCrockford[(hi >> shift) & 0x1Fu];
    }
    for (unsigned i = 13u; i < ULID_CHARS; ++i) {
        unsigned shift = 60u - 5u * (i - 13u);
        out[4u + i] = kCrockford[(lo >> shift) & 0x1Fu];
    }
    out[4u + ULID_CHARS] = '\0';
}

/** @brief 符号付き整数をジグザグ符号化した上で LEB128 で書く。 */
static size_t put_varint(uint8_t *buf, size_t cap, size_t at, int32_t value)
{
    uint32_t zig = (uint32_t)((value << 1) ^ (value >> 31));

    while (at < cap) {
        uint8_t byte = (uint8_t)(zig & 0x7Fu);
        zig >>= 7;
        if (zig != 0u) {
            byte |= 0x80u;
        }
        buf[at++] = byte;
        if (zig == 0u) {
            break;
        }
    }
    return at;
}

/** @brief @ref put_varint の読み出し側。読めなければ at を変えずに false を返す。 */
static bool get_varint(const uint8_t *buf, size_t len, size_t *at, int32_t *out)
{
    uint32_t zig = 0u;
    unsigned shift = 0u;
    size_t pos = *at;

    while (pos < len && shift <= 28u) {
        uint8_t byte = buf[pos++];
        zig |= (uint32_t)(byte & 0x7Fu) << shift;
        if ((byte & 0x80u) == 0u) {
            *at = pos;
            *out = (int32_t)((zig >> 1) ^ (uint32_t)(-(int32_t)(zig & 1u)));
            return true;
        }
        shift += 7u;
    }
    return false;
}

void of_reading_init(of_reading_t *reading, const char *container_id)
{
    if (reading == NULL) {
        return;
    }

    memset(reading, 0, sizeof(*reading));
    if (container_id != NULL) {
        strncpy(reading->container_id, container_id, OF_ID_MAX_LEN);
        reading->container_id[OF_ID_MAX_LEN] = '\0';
    }
    reading->recorded_at = of_now_ms();
    reading->temperature_c = OF_TEMP_INVALID;
    reading->humidity_pct = OF_HUMID_INVALID;
    reading->shock_g = OF_SHOCK_INVALID;
}

of_err_t of_frame_encode(const of_reading_t *records, uint8_t count, of_frame_kind_t kind,
                         uint8_t *out, size_t out_cap, size_t *out_len)
{
    of_frame_header_t header;
    size_t at = OF_FRAME_HEADER_SIZE;
    uint8_t opts = 0u;
    of_err_t err;
    const of_reading_t *base;

    if (records == NULL || out == NULL || out_len == NULL) {
        return OF_ERR_INVALID_ARG;
    }
    if (count == 0u || count > OF_FRAME_MAX_RECORDS) {
        return OF_ERR_INVALID_ARG;
    }
    if (out_cap < OF_FRAME_HEADER_SIZE + 1u) {
        return OF_ERR_NO_SPACE;
    }

    base = &records[0];
    opts |= OPT_CONTAINER_ID_PRESENT;
    if ((base->flags & OF_READING_FLAG_POSITION_VALID) != 0u) {
        opts |= OPT_POSITION_PRESENT;
    }
    out[at++] = opts;

    if (at + ULID_BYTES > out_cap) {
        return OF_ERR_NO_SPACE;
    }
    err = ulid_pack(base->container_id, &out[at]);
    if (err != OF_OK) {
        return err;
    }
    at += ULID_BYTES;

    /* 基準レコード。時刻はミリ秒のままだと 6 バイト要るので、秒に落として 32 ビットで持つ。
       ミリ秒の分解能が要るのは衝撃イベントだけで、そちらは alert_hint フレームが
       別に持っている。 */
    if (at + 12u > out_cap) {
        return OF_ERR_NO_SPACE;
    }
    {
        uint32_t base_sec = (uint32_t)(base->recorded_at / 1000u);
        out[at++] = (uint8_t)(base_sec >> 24);
        out[at++] = (uint8_t)(base_sec >> 16);
        out[at++] = (uint8_t)(base_sec >> 8);
        out[at++] = (uint8_t)base_sec;
        out[at++] = (uint8_t)(base->temperature_c >> 8);
        out[at++] = (uint8_t)base->temperature_c;
        out[at++] = (uint8_t)(base->humidity_pct >> 8);
        out[at++] = (uint8_t)base->humidity_pct;
        out[at++] = base->battery_pct;
        out[at++] = base->flags;
        out[at++] = (uint8_t)(base->sequence >> 8);
        out[at++] = (uint8_t)base->sequence;
    }
    at = put_varint(out, out_cap, at, base->shock_g);

    if ((opts & OPT_POSITION_PRESENT) != 0u) {
        if (at + 8u > out_cap) {
            return OF_ERR_NO_SPACE;
        }
        for (unsigned i = 0u; i < 4u; ++i) {
            out[at++] = (uint8_t)(base->latitude >> (24u - 8u * i));
        }
        for (unsigned i = 0u; i < 4u; ++i) {
            out[at++] = (uint8_t)(base->longitude >> (24u - 8u * i));
        }
    }

    /* 2 件目以降。基準ではなく「直前のレコード」との差分にすると、
       等間隔サンプリングでは dt がほぼ常に 1 バイトに収まる。 */
    for (uint8_t i = 1u; i < count; ++i) {
        const of_reading_t *prev = &records[i - 1u];
        const of_reading_t *cur = &records[i];
        int32_t dt = (int32_t)((int64_t)(cur->recorded_at / 1000u) - (int64_t)(prev->recorded_at / 1000u));

        at = put_varint(out, out_cap, at, dt);
        at = put_varint(out, out_cap, at, (int32_t)cur->temperature_c - (int32_t)prev->temperature_c);
        at = put_varint(out, out_cap, at, (int32_t)cur->humidity_pct - (int32_t)prev->humidity_pct);
        at = put_varint(out, out_cap, at, cur->shock_g - prev->shock_g);
        if (at + 2u > out_cap) {
            return OF_ERR_NO_SPACE;
        }
        out[at++] = cur->battery_pct;
        out[at++] = cur->flags;
    }

    header.magic = OF_FRAME_MAGIC;
    header.version = OF_FRAME_VERSION;
    header.kind = (uint8_t)kind;
    header.node_serial = 0u; /* 送信直前に sx1276.c が焼き込み値で埋める */
    header.sequence = base->sequence;
    header.record_count = count;
    header.payload_len = (uint8_t)(at - OF_FRAME_HEADER_SIZE);
    header.crc16 = 0u;

    memcpy(out, &header, OF_FRAME_HEADER_SIZE);
    header.crc16 = of_crc16_ccitt(OF_CRC16_INIT, out, at);
    memcpy(&out[offsetof(of_frame_header_t, crc16)], &header.crc16, sizeof(header.crc16));

    *out_len = at;
    return OF_OK;
}

of_err_t of_frame_decode(const uint8_t *in, size_t in_len, of_reading_t *out, uint8_t out_cap,
                         uint8_t *out_count, of_frame_header_t *header)
{
    of_frame_header_t hdr;
    uint8_t zeroed[OF_FRAME_HEADER_SIZE];
    uint16_t crc;
    size_t at = OF_FRAME_HEADER_SIZE;
    uint8_t opts;
    of_id_t container_id;

    if (in == NULL || out == NULL || out_count == NULL) {
        return OF_ERR_INVALID_ARG;
    }
    if (in_len < OF_FRAME_HEADER_SIZE + 1u) {
        return OF_ERR_INVALID_ARG;
    }

    memcpy(&hdr, in, OF_FRAME_HEADER_SIZE);
    if (hdr.magic != OF_FRAME_MAGIC || hdr.version != OF_FRAME_VERSION) {
        return OF_ERR_UNSUPPORTED;
    }
    if (hdr.record_count > out_cap || hdr.record_count > OF_FRAME_MAX_RECORDS) {
        return OF_ERR_NO_SPACE;
    }

    /* CRC は crc16 フィールドを 0 とみなして計算した値。ヘッダを丸ごと複製して
       そこだけ潰す方が、フィールドごとに飛び飛びで計算するより読みやすい。 */
    memcpy(zeroed, in, OF_FRAME_HEADER_SIZE);
    memset(&zeroed[offsetof(of_frame_header_t, crc16)], 0, sizeof(hdr.crc16));
    crc = of_crc16_ccitt(OF_CRC16_INIT, zeroed, OF_FRAME_HEADER_SIZE);
    crc = of_crc16_ccitt(crc, &in[OF_FRAME_HEADER_SIZE], in_len - OF_FRAME_HEADER_SIZE);
    if (crc != hdr.crc16) {
        return OF_ERR_CRC;
    }

    opts = in[at++];
    if ((opts & OPT_CONTAINER_ID_PRESENT) == 0u || at + ULID_BYTES > in_len) {
        return OF_ERR_INVALID_ARG;
    }
    ulid_unpack(&in[at], container_id);
    at += ULID_BYTES;

    if (at + 12u > in_len) {
        return OF_ERR_INVALID_ARG;
    }
    {
        of_reading_t *r = &out[0];
        uint32_t base_sec;
        int32_t shock;

        memset(r, 0, sizeof(*r));
        memcpy(r->container_id, container_id, sizeof(of_id_t));
        base_sec = ((uint32_t)in[at] << 24) | ((uint32_t)in[at + 1u] << 16) |
                   ((uint32_t)in[at + 2u] << 8) | (uint32_t)in[at + 3u];
        at += 4u;
        r->recorded_at = (of_epoch_ms_t)base_sec * 1000u;
        r->temperature_c = (of_temp_c100_t)(((uint16_t)in[at] << 8) | in[at + 1u]);
        at += 2u;
        r->humidity_pct = (of_humid_p100_t)(((uint16_t)in[at] << 8) | in[at + 1u]);
        at += 2u;
        r->battery_pct = in[at++];
        r->flags = in[at++];
        r->sequence = (uint16_t)(((uint16_t)in[at] << 8) | in[at + 1u]);
        at += 2u;

        if (!get_varint(in, in_len, &at, &shock)) {
            return OF_ERR_INVALID_ARG;
        }
        r->shock_g = shock;

        if ((opts & OPT_POSITION_PRESENT) != 0u) {
            if (at + 8u > in_len) {
                return OF_ERR_INVALID_ARG;
            }
            r->latitude = (of_coord_1e7_t)(((uint32_t)in[at] << 24) | ((uint32_t)in[at + 1u] << 16) |
                                           ((uint32_t)in[at + 2u] << 8) | (uint32_t)in[at + 3u]);
            at += 4u;
            r->longitude = (of_coord_1e7_t)(((uint32_t)in[at] << 24) | ((uint32_t)in[at + 1u] << 16) |
                                            ((uint32_t)in[at + 2u] << 8) | (uint32_t)in[at + 3u]);
            at += 4u;
        }
    }

    for (uint8_t i = 1u; i < hdr.record_count; ++i) {
        const of_reading_t *prev = &out[i - 1u];
        of_reading_t *cur = &out[i];
        int32_t dt = 0;
        int32_t d_temp = 0;
        int32_t d_humid = 0;
        int32_t d_shock = 0;

        if (!get_varint(in, in_len, &at, &dt) || !get_varint(in, in_len, &at, &d_temp) ||
            !get_varint(in, in_len, &at, &d_humid) || !get_varint(in, in_len, &at, &d_shock)) {
            return OF_ERR_INVALID_ARG;
        }
        if (at + 2u > in_len) {
            return OF_ERR_INVALID_ARG;
        }

        *cur = *prev;
        cur->recorded_at = prev->recorded_at + (of_epoch_ms_t)((int64_t)dt * 1000);
        cur->temperature_c = (of_temp_c100_t)((int32_t)prev->temperature_c + d_temp);
        cur->humidity_pct = (of_humid_p100_t)((int32_t)prev->humidity_pct + d_humid);
        cur->shock_g = prev->shock_g + d_shock;
        cur->battery_pct = in[at++];
        cur->flags = in[at++];
        cur->sequence = (uint16_t)(prev->sequence + 1u);
    }

    *out_count = hdr.record_count;
    if (header != NULL) {
        *header = hdr;
    }
    return OF_OK;
}
