//! Kodiert und dekodiert den OFW1-Rahmen: einen ganzen Sensor-Batch, so wie er im Rumpf von
//! `POST /v1/ingest/batch` und in den Nachrichten von `telemetry.v1.TelemetryIngest/StreamReadings`
//! steht. Ein Rahmen ist selbsttragend — Kopf, Container-Verzeichnis, Messwerte, Prüfsumme —
//! und wird nach dem Signieren nie wieder angefasst, auch nicht bei einer Wiederholung aus
//! dem Spool des Gateways.

const std = @import("std");
const root = @import("root.zig");
const varint = @import("varint.zig");
const crc32c = @import("crc32c.zig");

pub const DecodeError = error{
    BadMagic,
    UnsupportedVersion,
    ChecksumMismatch,
    Truncated,
    VarintOverflow,
    ValueOutOfRange,
    BufferTooSmall,
    /// Mehr verschiedene Container in einem Batch, als das Verzeichnis fasst.
    DictionaryFull,
};

/// Wie viele verschiedene Container ein Batch enthalten darf. Ein großes Depot bewegt selten
/// mehr als 400 gleichzeitig; die Sensorknoten übersetzen dieselbe Quelle mit
/// `-Dmax-containers=4`, weil dort ein Rahmen immer nur den eigenen Container beschreibt.
pub const MAX_CONTAINERS = 512;

/// Obergrenze der Messwerte in einem Rahmen. Sie liegt über jedem sinnvollen Wert von
/// `OF_TELEMETRY_BATCH_MAX_READINGS` und begrenzt nur die Hilfstabelle, die der Kodierer auf
/// dem Stapel hält. Die freistehende Übersetzung für die Sensorknoten setzt sie auf 32.
pub const MAX_READINGS = 8192;

/// Feste Größe des Kopfteils auf dem Draht. Nicht zu verwechseln mit `@sizeOf(BatchHeader)` —
/// die Struktur unten ist die Speicherform für die C-ABI, diese Zahl die Drahtform.
pub const WIRE_HEADER_LEN =
    root.MAGIC.len + 1 + 1 + 2 + 8 + root.ULID_LEN + root.PREFIXED_ID_LEN + root.TRACE_ID_LEN;

/// Bitmaske der belegten Felder eines Messwerts. Ein Kühlcontainer ohne Türkontakt liefert
/// schlicht kein `door_open` — die Spalte in `telemetry.telemetry_readings` bleibt dann NULL,
/// und nicht etwa `false`. Der Unterschied ist der zwischen "Tür zu" und "keine Ahnung".
pub const FieldMask = struct {
    pub const temperature: u16 = 1 << 0;
    pub const humidity: u16 = 1 << 1;
    pub const shock: u16 = 1 << 2;
    pub const door: u16 = 1 << 3;
    pub const battery: u16 = 1 << 4;
    pub const position: u16 = 1 << 5;
};

/// Speicherform des Kopfteils, Feld für Feld gleich der Rust-Struktur `OfwireBatchHeader` in
/// `edge/gateway-agent/src/wire/mod.rs`. Die Reihenfolge ist Teil der ABI.
pub const BatchHeader = extern struct {
    /// 26 Zeichen ULID plus Nullbyte, ohne Präfix (§0.1 führt für `ingest_batch_id` keines).
    ingest_batch_id: [27]u8,
    /// `gwy_` plus 26 Zeichen plus Nullbyte.
    gateway_id: [31]u8,
    /// Index in `root.REGION_CODES`.
    region_index: u8,
    trace_id: [33]u8,
    epoch_ms: i64,
    reading_count: u32,
    /// Bit 0: mindestens ein Messwert hat eine Schwelle gerissen. telemetry-ingest zieht solche
    /// Batches vor, weil aus ihnen `telemetry.alert.raised` entstehen kann.
    flags: u32,
};

/// Speicherform eines Messwerts, gleich `OfwireReading` auf der Rust-Seite. Alle Zahlen sind
/// Festkomma — §0.2 kennt keine Fließkommaspalten, und zwischen Sensor und Datenbank soll
/// nirgends gerundet werden.
pub const Reading = extern struct {
    container_id: [31]u8,
    /// Versatz zu `BatchHeader.epoch_ms` in Millisekunden; darf negativ sein, wenn die Uhr
    /// eines Sensors nachgeht.
    offset_ms: i64,
    /// Hundertstel Grad Celsius → `telemetry.telemetry_readings.temperature_c NUMERIC(5,2)`.
    temperature_centi_c: i16,
    /// Hundertstel Prozent → `humidity_pct NUMERIC(5,2)`.
    humidity_centi_pct: i16,
    /// Tausendstel g → `shock_g NUMERIC(6,3)`.
    shock_milli_g: i32,
    /// Zehnmillionstel Grad → `position geography(Point,4326)`.
    latitude_e7: i32,
    longitude_e7: i32,
    /// Ganze Prozent, 0–100 wie im CHECK der Spalte `battery_pct`.
    battery_pct: u8,
    door_open: u8,
    present: u16,
    /// 0 = Routine, 1 = Schwelle gerissen, 2 = sofort. Rein gatewayseitig; die Einstufung
    /// 1–5 in `telemetry.telemetry_alerts.severity` vergibt telemetry-ingest.
    severity: u8,
    _padding: [3]u8 = .{ 0, 0, 0 },
};

comptime {
    // Diese beiden Zusicherungen sind die eigentliche Schnittstellendokumentation. Weicht das
    // Rust- oder C-Gegenstück ab, liest der Aufrufer verschobene Felder und der Fehler zeigt
    // sich erst als unsinniger Messwert in der Datenbank.
    std.debug.assert(@sizeOf(BatchHeader) == 112);
    std.debug.assert(@sizeOf(Reading) == 64);
}

/// Obere Schranke der Rahmenlänge. Der Aufrufer bemisst danach seinen Puffer; der Rahmen wird
/// fast immer deutlich kürzer, weil die Varints die Regel und nicht die Ausnahme sind.
pub fn encodedBound(reading_count: usize) usize {
    const per_reading =
        varint.MAX_LEN // Containerindex
        + varint.MAX_LEN // Zeitversatz
        + varint.MAX_LEN // Feldmaske
        + 1 // Dringlichkeit
        + varint.MAX_LEN * 6; // sechs mögliche Messfelder
    const dictionary = varint.MAX_LEN + @min(reading_count, MAX_CONTAINERS) * root.PREFIXED_ID_LEN;
    return WIRE_HEADER_LEN + dictionary + varint.MAX_LEN + reading_count * per_reading + 4;
}

/// Schreibt den ganzen Batch nach `out` und liefert die tatsächliche Länge.
pub fn encode(
    out: []u8,
    header: *const BatchHeader,
    readings: []const Reading,
) DecodeError!usize {
    if (out.len < encodedBound(readings.len)) return DecodeError.BufferTooSmall;
    if (header.region_index >= root.REGION_CODES.len) return DecodeError.ValueOutOfRange;

    var w = Writer{ .buf = out };

    w.bytes(&root.MAGIC);
    w.byte(root.VERSION);
    w.byte(header.region_index);
    w.u16le(@truncate(header.flags));
    w.i64le(header.epoch_ms);
    w.fixed(header.ingest_batch_id[0..root.ULID_LEN]);
    w.fixed(header.gateway_id[0..root.PREFIXED_ID_LEN]);
    w.fixed(header.trace_id[0..root.TRACE_ID_LEN]);

    // Container-Verzeichnis. Eine Kennung wiegt 30 Byte (§0.1 verbietet, das Präfix unterwegs
    // abzuschneiden); bei 5 000 Messwerten von 300 Containern spart die Tabelle rund 140 KiB
    // gegenüber der Wiederholung je Messwert.
    var dict: [MAX_CONTAINERS]u32 = undefined;
    var dict_len: usize = 0;
    var index_of: [MAX_READINGS]u16 = undefined;
    if (readings.len > MAX_READINGS) return DecodeError.ValueOutOfRange;

    for (readings, 0..) |reading, i| {
        const found = lookup(readings, dict[0..dict_len], &reading.container_id);
        if (found) |slot| {
            index_of[i] = @intCast(slot);
        } else {
            if (dict_len == MAX_CONTAINERS) return DecodeError.DictionaryFull;
            dict[dict_len] = @intCast(i);
            index_of[i] = @intCast(dict_len);
            dict_len += 1;
        }
    }

    try w.uvar(dict_len);
    for (dict[0..dict_len]) |first_use| {
        w.fixed(readings[first_use].container_id[0..root.PREFIXED_ID_LEN]);
    }

    try w.uvar(readings.len);
    for (readings, 0..) |reading, i| {
        try w.uvar(index_of[i]);
        try w.svar(reading.offset_ms);
        try w.uvar(reading.present);
        w.byte(reading.severity);

        // Die Reihenfolge der Felder folgt den Bits von `FieldMask` aufsteigend. Wer hier
        // umsortiert, bricht jeden Rahmen, der noch im Spool eines Depots liegt.
        if (reading.present & FieldMask.temperature != 0) try w.svar(reading.temperature_centi_c);
        if (reading.present & FieldMask.humidity != 0) try w.svar(reading.humidity_centi_pct);
        if (reading.present & FieldMask.shock != 0) try w.svar(reading.shock_milli_g);
        if (reading.present & FieldMask.door != 0) w.byte(reading.door_open);
        if (reading.present & FieldMask.battery != 0) {
            if (reading.battery_pct > 100) return DecodeError.ValueOutOfRange;
            w.byte(reading.battery_pct);
        }
        if (reading.present & FieldMask.position != 0) {
            try w.svar(reading.latitude_e7);
            try w.svar(reading.longitude_e7);
        }
    }

    // Prüfsumme über alles bisher Geschriebene. Sie steht am Ende und nicht im Kopf, damit der
    // Kodierer in einem Durchgang arbeiten kann — auf dem Sensorknoten gibt es keinen Speicher,
    // um den Rahmen zweimal anzufassen.
    const body = out[0..w.pos];
    w.u32le(crc32c.checksum(body));
    return w.pos;
}

/// Liest nur den Kopfteil. Genau das braucht der Gateway-Agent beim Wiedereinlesen seines
/// Spools: er will `ingest_batch_id`, Region und Anzahl wissen, aber den Rahmen keinesfalls
/// verändern — die Ed25519-Signatur gilt für die Bytes, wie sie sind.
pub fn inspect(input: []const u8, out: *BatchHeader) DecodeError!void {
    if (input.len < WIRE_HEADER_LEN + 4) return DecodeError.Truncated;
    if (!std.mem.eql(u8, input[0..4], &root.MAGIC)) return DecodeError.BadMagic;
    if (input[4] != root.VERSION) return DecodeError.UnsupportedVersion;

    const body = input[0 .. input.len - 4];
    const stored = std.mem.readInt(u32, input[input.len - 4 ..][0..4], .little);
    if (crc32c.checksum(body) != stored) return DecodeError.ChecksumMismatch;

    out.* = std.mem.zeroes(BatchHeader);
    out.region_index = input[5];
    if (out.region_index >= root.REGION_CODES.len) return DecodeError.ValueOutOfRange;
    out.flags = std.mem.readInt(u16, input[6..8], .little);
    out.epoch_ms = std.mem.readInt(i64, input[8..16], .little);

    var pos: usize = 16;
    @memcpy(out.ingest_batch_id[0..root.ULID_LEN], input[pos..][0..root.ULID_LEN]);
    pos += root.ULID_LEN;
    @memcpy(out.gateway_id[0..root.PREFIXED_ID_LEN], input[pos..][0..root.PREFIXED_ID_LEN]);
    pos += root.PREFIXED_ID_LEN;
    @memcpy(out.trace_id[0..root.TRACE_ID_LEN], input[pos..][0..root.TRACE_ID_LEN]);
    pos += root.TRACE_ID_LEN;

    // Verzeichnis überspringen, dann steht die Anzahl der Messwerte.
    const dict_len = try readVarint(input, &pos);
    if (dict_len > MAX_CONTAINERS) return DecodeError.ValueOutOfRange;
    pos += dict_len * root.PREFIXED_ID_LEN;
    if (pos > body.len) return DecodeError.Truncated;

    out.reading_count = @intCast(try readVarint(input, &pos));
}

/// Fortlaufender Dekodierer. telemetry-ingest liest damit den ganzen Batch in einem Durchlauf;
/// eine wahlfreie `readingAt`-Funktion gibt es bewusst nicht mehr, weil sie für jeden Zugriff
/// von vorne laufen musste und ein Batch mit 5 000 Werten quadratisch teuer wurde.
pub const Decoder = struct {
    input: []const u8,
    pos: usize,
    dict_start: usize,
    dict_len: usize,
    remaining: u32,
    epoch_ms: i64,

    /// Prüft Magic, Version und Prüfsumme und stellt sich auf den ersten Messwert.
    pub fn init(input: []const u8) DecodeError!Decoder {
        var header: BatchHeader = undefined;
        try inspect(input, &header);

        var pos: usize = WIRE_HEADER_LEN;
        const dict_len = try readVarint(input, &pos);
        const dict_start = pos;
        pos += dict_len * root.PREFIXED_ID_LEN;
        const count = try readVarint(input, &pos);

        return .{
            .input = input,
            .pos = pos,
            .dict_start = dict_start,
            .dict_len = dict_len,
            .remaining = @intCast(count),
            .epoch_ms = header.epoch_ms,
        };
    }

    /// Nächster Messwert, oder `null` am Ende. `offset_ms` wird dabei bereits zum absoluten
    /// Zeitstempel aufgelöst — die Aufrufer wollen `recorded_at`, nicht das Delta.
    pub fn next(self: *Decoder) DecodeError!?Reading {
        if (self.remaining == 0) return null;
        self.remaining -= 1;

        var reading = std.mem.zeroes(Reading);

        const container_index = try readVarint(self.input, &self.pos);
        if (container_index >= self.dict_len) return DecodeError.ValueOutOfRange;
        const id_at = self.dict_start + container_index * root.PREFIXED_ID_LEN;
        @memcpy(
            reading.container_id[0..root.PREFIXED_ID_LEN],
            self.input[id_at..][0..root.PREFIXED_ID_LEN],
        );

        const offset = try readSvarint(self.input, &self.pos);
        reading.offset_ms = self.epoch_ms + offset;
        reading.present = @intCast(try readVarint(self.input, &self.pos));
        reading.severity = try readByte(self.input, &self.pos);

        if (reading.present & FieldMask.temperature != 0) {
            reading.temperature_centi_c = @intCast(try readSvarint(self.input, &self.pos));
        }
        if (reading.present & FieldMask.humidity != 0) {
            reading.humidity_centi_pct = @intCast(try readSvarint(self.input, &self.pos));
        }
        if (reading.present & FieldMask.shock != 0) {
            reading.shock_milli_g = @intCast(try readSvarint(self.input, &self.pos));
        }
        if (reading.present & FieldMask.door != 0) {
            reading.door_open = try readByte(self.input, &self.pos);
        }
        if (reading.present & FieldMask.battery != 0) {
            reading.battery_pct = try readByte(self.input, &self.pos);
            if (reading.battery_pct > 100) return DecodeError.ValueOutOfRange;
        }
        if (reading.present & FieldMask.position != 0) {
            reading.latitude_e7 = @intCast(try readSvarint(self.input, &self.pos));
            reading.longitude_e7 = @intCast(try readSvarint(self.input, &self.pos));
        }
        return reading;
    }
};

/// Sucht eine Containerkennung im bisherigen Verzeichnis. Lineare Suche mit `memcmp`: bei
/// höchstens 512 Einträgen ist eine Hashtabelle teurer als der Vergleich selbst, und sie
/// bräuchte einen Allocator, den die freistehende Übersetzung nicht hat.
fn lookup(readings: []const Reading, dict: []const u32, needle: *const [31]u8) ?usize {
    for (dict, 0..) |first_use, slot| {
        if (std.mem.eql(u8, &readings[first_use].container_id, needle)) return slot;
    }
    return null;
}

fn readVarint(input: []const u8, pos: *usize) DecodeError!usize {
    const decoded = varint.readUnsigned(input[pos.*..]) catch |err| return mapVarintError(err);
    pos.* += decoded.len;
    return @intCast(decoded.value);
}

fn readSvarint(input: []const u8, pos: *usize) DecodeError!i64 {
    const decoded = varint.readSigned(input[pos.*..]) catch |err| return mapVarintError(err);
    pos.* += decoded.len;
    return decoded.value;
}

fn readByte(input: []const u8, pos: *usize) DecodeError!u8 {
    if (pos.* >= input.len) return DecodeError.Truncated;
    defer pos.* += 1;
    return input[pos.*];
}

fn mapVarintError(err: varint.Error) DecodeError {
    return switch (err) {
        varint.Error.Truncated => DecodeError.Truncated,
        varint.Error.VarintOverflow => DecodeError.VarintOverflow,
        varint.Error.BufferTooSmall => DecodeError.BufferTooSmall,
    };
}

/// Kleiner Schreibhelfer. Er prüft die Puffergrenze nicht bei jedem Feld — `encode` hat sie
/// eingangs gegen `encodedBound` abgeglichen, und der Bound ist großzügig gerechnet.
const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn byte(self: *Writer, value: u8) void {
        self.buf[self.pos] = value;
        self.pos += 1;
    }

    fn bytes(self: *Writer, value: []const u8) void {
        @memcpy(self.buf[self.pos..][0..value.len], value);
        self.pos += value.len;
    }

    /// Feste Länge, aber ohne Nullbyte: die Kennungen stehen im Rahmen als reine ASCII-Folge.
    fn fixed(self: *Writer, value: []const u8) void {
        self.bytes(value);
    }

    fn u16le(self: *Writer, value: u16) void {
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], value, .little);
        self.pos += 2;
    }

    fn u32le(self: *Writer, value: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], value, .little);
        self.pos += 4;
    }

    fn i64le(self: *Writer, value: i64) void {
        std.mem.writeInt(i64, self.buf[self.pos..][0..8], value, .little);
        self.pos += 8;
    }

    fn uvar(self: *Writer, value: anytype) DecodeError!void {
        const written = varint.writeUnsigned(self.buf[self.pos..], @intCast(value)) catch
            return DecodeError.BufferTooSmall;
        self.pos += written;
    }

    fn svar(self: *Writer, value: anytype) DecodeError!void {
        const written = varint.writeSigned(self.buf[self.pos..], @intCast(value)) catch
            return DecodeError.BufferTooSmall;
        self.pos += written;
    }
};

// --- Tests ------------------------------------------------------------------------------

fn testHeader() BatchHeader {
    var h = std.mem.zeroes(BatchHeader);
    @memcpy(h.ingest_batch_id[0..26], "01J8ZK4T9QW3RM7XN2VB6HD5PC");
    @memcpy(h.gateway_id[0..30], "gwy_01J8ZK4T9QW3RM7XN2VB6HD5PC");
    @memcpy(h.trace_id[0..32], "4bf92f3577b34da6a3ce929d0e0e4736");
    h.region_index = 0; // eu-west
    h.epoch_ms = 1_710_400_000_000;
    h.reading_count = 2;
    h.flags = 1;
    return h;
}

fn testReading(container: *const [30]u8, offset_ms: i64, temp: i16) Reading {
    var r = std.mem.zeroes(Reading);
    @memcpy(r.container_id[0..30], container);
    r.offset_ms = offset_ms;
    r.temperature_centi_c = temp;
    r.humidity_centi_pct = 6150;
    r.battery_pct = 87;
    r.door_open = 0;
    r.severity = 0;
    r.present = FieldMask.temperature | FieldMask.humidity | FieldMask.battery | FieldMask.door;
    return r;
}

test "Rahmen übersteht Hin- und Rückweg" {
    const header = testHeader();
    const readings = [_]Reading{
        testReading("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", 0, -1850),
        testReading("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PD", 30_000, 412),
    };

    var buf: [4096]u8 = undefined;
    const len = try encode(&buf, &header, &readings);
    try std.testing.expect(len < encodedBound(readings.len));

    var decoder = try Decoder.init(buf[0..len]);
    const first = (try decoder.next()).?;
    try std.testing.expectEqualStrings(
        "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC",
        first.container_id[0..30],
    );
    // Kühlgut bei −18,50 °C: die Festkommazahl kommt unverändert zurück.
    try std.testing.expectEqual(@as(i16, -1850), first.temperature_centi_c);
    try std.testing.expectEqual(header.epoch_ms, first.offset_ms);

    const second = (try decoder.next()).?;
    try std.testing.expectEqual(header.epoch_ms + 30_000, second.offset_ms);
    try std.testing.expectEqual(@as(?Reading, null), try decoder.next());
}

test "Verzeichnis speichert wiederholte Container nur einmal" {
    const header = testHeader();
    const id = "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC";
    var readings: [64]Reading = undefined;
    for (&readings, 0..) |*r, i| {
        r.* = testReading(id, @intCast(i * 30_000), 405);
    }

    var buf: [8192]u8 = undefined;
    const len = try encode(&buf, &header, &readings);
    // 64 Messwerte, aber nur eine Kennung im Verzeichnis: der Rahmen bleibt weit unter dem,
    // was 64 × 30 Byte Kennungen allein kosten würden.
    try std.testing.expect(len < 64 * 30);
}

test "gekipptes Bit fällt in der Prüfsumme auf" {
    const header = testHeader();
    const readings = [_]Reading{testReading("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", 0, 400)};
    var buf: [1024]u8 = undefined;
    const len = try encode(&buf, &header, &readings);

    buf[WIRE_HEADER_LEN + 3] ^= 0x10;
    var out: BatchHeader = undefined;
    try std.testing.expectError(DecodeError.ChecksumMismatch, inspect(buf[0..len], &out));
}

test "fremdes Magic wird nicht als Rahmen gelesen" {
    var out: BatchHeader = undefined;
    const nonsense = [_]u8{0xAB} ** 200;
    try std.testing.expectError(DecodeError.BadMagic, inspect(&nonsense, &out));
}

test "abgeschnittener Rahmen aus dem Spool" {
    const header = testHeader();
    const readings = [_]Reading{testReading("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", 0, 400)};
    var buf: [1024]u8 = undefined;
    const len = try encode(&buf, &header, &readings);

    var out: BatchHeader = undefined;
    // Genau der Fall, den ein Stromausfall mitten im Schreiben erzeugt.
    try std.testing.expectError(DecodeError.ChecksumMismatch, inspect(buf[0 .. len - 3], &out));
}

test "unbekannter Regionsindex wird abgelehnt" {
    var header = testHeader();
    header.region_index = 9; // §0.6 kennt nur acht
    const readings = [_]Reading{testReading("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", 0, 400)};
    var buf: [1024]u8 = undefined;
    try std.testing.expectError(DecodeError.ValueOutOfRange, encode(&buf, &header, &readings));
}

test "Batterie über 100 Prozent ist ein Sensordefekt, kein Messwert" {
    const header = testHeader();
    var reading = testReading("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", 0, 400);
    reading.battery_pct = 137;
    var buf: [1024]u8 = undefined;
    try std.testing.expectError(
        DecodeError.ValueOutOfRange,
        encode(&buf, &header, &[_]Reading{reading}),
    );
}

test "corpus: aufgezeichnete Rahmen aus dem Feld" {
    // Läuft über `zig build fuzz`. Die Dateien unter testdata/ stammen aus echten Depots:
    // ein voller Batch aus Rotterdam, ein Rahmen mit 400 verschiedenen Containern, und der
    // abgeschnittene Rahmen aus Santos, an dem der Spool im Februar hängengeblieben ist.
    var dir = std.fs.cwd().openDir("testdata", .{ .iterate = true }) catch return;
    defer dir.close();

    var buf: [1 << 20]u8 = undefined;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ofw")) continue;

        const raw = try dir.readFile(entry.name, &buf);
        var header: BatchHeader = undefined;

        // Ein beschädigter Rahmen muss einen Fehler liefern, nicht abstürzen und schon gar
        // nicht Messwerte erfinden — mehr verlangt dieser Durchlauf nicht.
        inspect(raw, &header) catch continue;

        var decoder = try Decoder.init(raw);
        var seen: u32 = 0;
        while (try decoder.next()) |reading| {
            try std.testing.expect(reading.battery_pct <= 100);
            try std.testing.expect(std.mem.startsWith(u8, &reading.container_id, "cnt_"));
            seen += 1;
        }
        try std.testing.expectEqual(header.reading_count, seen);
    }
}
