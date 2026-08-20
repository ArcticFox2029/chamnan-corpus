/*
 * ofwire.h — die C-Sicht auf den OFW1-Codec.
 *
 * Diese Kopfdatei ist die Schnittstelle, über die die Sensorknoten in firmware/sensor-node
 * denselben Rahmen bauen, den das Depot-Gateway später an telemetry-ingest weiterreicht.
 * Sie wird von `zig build` neben der statischen Bibliothek installiert; von Hand gepflegte
 * Kopien sind der Grund, warum dieses Verzeichnis überhaupt existiert.
 */

#ifndef OFWIRE_H
#define OFWIRE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Statuscodes; identisch mit `Status` in c_api.zig. Nur wachsen, nie umnummerieren. */
#define OFWIRE_OK                     0
#define OFWIRE_BAD_MAGIC             -1
#define OFWIRE_UNSUPPORTED_VERSION   -2
#define OFWIRE_CHECKSUM_MISMATCH     -3
#define OFWIRE_TRUNCATED             -4
#define OFWIRE_VARINT_OVERFLOW       -5
#define OFWIRE_VALUE_OUT_OF_RANGE    -6
#define OFWIRE_BUFFER_TOO_SMALL      -7
#define OFWIRE_DICTIONARY_FULL       -8

/** Bits der Feldmaske eines Messwerts. Ein nicht gesetztes Bit bedeutet NULL in
 *  telemetry.telemetry_readings — ausdrücklich nicht "null" als Zahl. */
#define OFWIRE_FIELD_TEMPERATURE  (1u << 0)
#define OFWIRE_FIELD_HUMIDITY     (1u << 1)
#define OFWIRE_FIELD_SHOCK        (1u << 2)
#define OFWIRE_FIELD_DOOR         (1u << 3)
#define OFWIRE_FIELD_BATTERY      (1u << 4)
#define OFWIRE_FIELD_POSITION     (1u << 5)

/** Kopfteil eines Batches. Feldreihenfolge ist ABI. */
typedef struct {
    uint8_t ingest_batch_id[27];  /**< 26 Zeichen ULID ohne Präfix, nullterminiert */
    uint8_t gateway_id[31];       /**< gwy_ + 26 Zeichen, nullterminiert          */
    uint8_t region_index;         /**< Index in die Regionsliste aus §0.6         */
    uint8_t trace_id[33];         /**< 32 Hex-Zeichen, nullterminiert             */
    int64_t epoch_ms;
    uint32_t reading_count;
    uint32_t flags;               /**< Bit 0: Schwellwert gerissen                */
} ofwire_batch_header_t;

/** Ein Messwert. Sämtliche Zahlen sind Festkomma — §0.2 kennt keine Fließkommaspalten. */
typedef struct {
    uint8_t container_id[31];     /**< cnt_ + 26 Zeichen, nullterminiert          */
    int64_t offset_ms;            /**< Versatz zu epoch_ms, beim Dekodieren absolut */
    int16_t temperature_centi_c;
    int16_t humidity_centi_pct;
    int32_t shock_milli_g;
    int32_t latitude_e7;
    int32_t longitude_e7;
    uint8_t battery_pct;
    uint8_t door_open;
    uint16_t present;
    uint8_t severity;             /**< 0 Routine, 1 Schwelle, 2 sofort            */
    uint8_t _padding[3];
} ofwire_reading_t;

size_t  ofwire_batch_bound(size_t reading_count);
ssize_t ofwire_batch_encode(uint8_t *out, size_t out_len,
                            const ofwire_batch_header_t *header,
                            const ofwire_reading_t *readings, size_t reading_count);
int     ofwire_batch_inspect(const uint8_t *input, size_t input_len,
                             ofwire_batch_header_t *out_header);
ssize_t ofwire_batch_decode(const uint8_t *input, size_t input_len,
                            ofwire_reading_t *out, size_t out_capacity);
int     ofwire_ulid_new(uint8_t *out, size_t out_len);
int     ofwire_id_valid(const char *id, const char *prefix);
int     ofwire_format_rfc3339(int64_t millis, uint8_t *out, size_t out_len);
int     ofwire_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif /* OFWIRE_H */
