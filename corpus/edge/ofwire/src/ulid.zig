//! ULID-Erzeugung für den `ingest_batch_id`. Der Wert ist der Entdopplungsschlüssel in
//! `readings_dedupe_idx` auf `telemetry.telemetry_readings` — er muss über einen Neustart des
//! Gateways hinweg eindeutig bleiben und innerhalb einer Millisekunde monoton steigen, sonst
//! ordnet telemetry-ingest zwei Batches derselben Sekunde in der falschen Reihenfolge ein.

const std = @import("std");

/// Crockford-Base32 ohne I, L, O und U — die Buchstaben, die sich beim Abtippen vom Typenschild
/// mit Ziffern verwechseln lassen. Dieselbe Kodierung benutzt jede `xxx_`-Kennung aus §0.1.
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// 26 Zeichen: 10 für die 48-Bit-Zeit, 16 für die 80 Bit Zufall.
pub const TEXT_LEN = 26;

/// Rohform: 16 Byte, wie sie eine ULID binär hat.
pub const Binary = [16]u8;

pub const Error = error{
    BufferTooSmall,
    InvalidCharacter,
    InvalidLength,
};

/// Zustand für die Monotonie innerhalb einer Millisekunde. Ein Depot-Gateway schließt selten
/// zwei Batches in derselben Millisekunde ab, aber beim Leeren des Spools nach einer Funklücke
/// passiert genau das — und ohne diesen Zähler entstünden zwei gleiche `ingest_batch_id`.
var last_ms: u64 = 0;
var last_random: [10]u8 = [_]u8{0} ** 10;

/// Erzeugt eine neue ULID und schreibt sie als 26 Zeichen nach `out`, gefolgt von einem Nullbyte,
/// damit die C-Seite sie direkt weiterreichen kann.
pub fn generate(out: []u8) Error!usize {
    if (out.len < TEXT_LEN + 1) return Error.BufferTooSmall;

    const now_ms: u64 = @intCast(@divFloor(std.time.milliTimestamp(), 1));
    var random: [10]u8 = undefined;

    if (now_ms == last_ms) {
        // Gleiche Millisekunde: den Zufallsteil um eins erhöhen statt neu zu würfeln. So bleibt
        // die lexikografische Ordnung der Kennungen gleich der zeitlichen.
        random = last_random;
        var i: usize = random.len;
        while (i > 0) {
            i -= 1;
            random[i] +%= 1;
            if (random[i] != 0) break;
        }
    } else {
        std.crypto.random.bytes(&random);
    }
    last_ms = now_ms;
    last_random = random;

    var raw: Binary = undefined;
    std.mem.writeInt(u48, raw[0..6], @intCast(now_ms & 0xFFFFFFFFFFFF), .big);
    @memcpy(raw[6..16], &random);

    _ = try encode(&raw, out);
    out[TEXT_LEN] = 0;
    return TEXT_LEN;
}

/// Wandelt die 16 Byte in die 26 Zeichen Crockford-Base32. Gearbeitet wird bitweise von hinten,
/// weil 128 Bit nicht glatt durch 5 teilbar sind — die obersten zwei Bit des ersten Zeichens
/// sind deshalb immer null.
pub fn encode(raw: *const Binary, out: []u8) Error!usize {
    if (out.len < TEXT_LEN) return Error.BufferTooSmall;

    var value: u128 = 0;
    for (raw) |byte| {
        value = (value << 8) | byte;
    }

    var i: usize = TEXT_LEN;
    while (i > 0) {
        i -= 1;
        out[i] = ALPHABET[@intCast(value & 0x1f)];
        value >>= 5;
    }
    return TEXT_LEN;
}

/// Rückweg, für den Fall, dass ein Spool-Segment auf Zeitstempel hin durchsucht wird.
pub fn decode(text: []const u8) Error!Binary {
    if (text.len != TEXT_LEN) return Error.InvalidLength;

    var value: u128 = 0;
    for (text) |c| {
        const digit = charValue(c) orelse return Error.InvalidCharacter;
        value = (value << 5) | digit;
    }

    var raw: Binary = undefined;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        raw[i] = @intCast(value & 0xff);
        value >>= 8;
    }
    return raw;
}

/// Zeitanteil in Millisekunden seit Epoch. Nützlich beim Aufräumen alter Spool-Segmente, ohne
/// den ganzen Rahmen zu dekodieren.
pub fn timestampMillis(raw: *const Binary) u64 {
    return std.mem.readInt(u48, raw[0..6], .big);
}

/// Prüft eine präfixierte Kennung nach §0.1, etwa `cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC`. Das Präfix
/// wird dabei ausdrücklich nicht abgeschnitten — es ist Teil des Wertes und bleibt es auf dem
/// gesamten Weg bis in die Datenbank.
pub fn hasValidPrefixedForm(id: []const u8, prefix: []const u8) bool {
    if (id.len != prefix.len + TEXT_LEN) return false;
    if (!std.mem.startsWith(u8, id, prefix)) return false;
    for (id[prefix.len..]) |c| {
        if (charValue(c) == null) return false;
    }
    return true;
}

fn charValue(c: u8) ?u128 {
    // Crockford erlaubt Kleinbuchstaben und behandelt I/L als 1 und O als 0. Wir nehmen das
    // beim Lesen an, erzeugen aber ausschließlich die kanonische Großschreibung.
    const upper = std.ascii.toUpper(c);
    return switch (upper) {
        '0', 'O' => 0,
        '1', 'I', 'L' => 1,
        '2'...'9' => upper - '0',
        'A'...'H' => upper - 'A' + 10,
        'J', 'K' => upper - 'J' + 18,
        'M', 'N' => upper - 'M' + 20,
        'P'...'T' => upper - 'P' + 22,
        'V'...'Z' => upper - 'V' + 27,
        else => null,
    };
}

test "erzeugte Kennung hat die richtige Form" {
    var buf: [TEXT_LEN + 1]u8 = undefined;
    _ = try generate(&buf);
    try std.testing.expectEqual(@as(u8, 0), buf[TEXT_LEN]);
    for (buf[0..TEXT_LEN]) |c| {
        try std.testing.expect(charValue(c) != null);
    }
}

test "zwei Kennungen derselben Millisekunde steigen monoton" {
    var a: [TEXT_LEN + 1]u8 = undefined;
    var b: [TEXT_LEN + 1]u8 = undefined;
    _ = try generate(&a);
    _ = try generate(&b);
    try std.testing.expect(std.mem.order(u8, a[0..TEXT_LEN], b[0..TEXT_LEN]) == .lt);
}

test "Hin- und Rückweg" {
    const raw: Binary = .{ 1, 143, 92, 200, 17, 0, 0xAB, 0xCD, 0xEF, 1, 2, 3, 4, 5, 6, 7 };
    var text: [TEXT_LEN]u8 = undefined;
    _ = try encode(&raw, &text);
    const back = try decode(&text);
    try std.testing.expectEqualSlices(u8, &raw, &back);
}

test "präfixierte Kennungen aus §0.1" {
    try std.testing.expect(hasValidPrefixedForm("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", "cnt_"));
    try std.testing.expect(hasValidPrefixedForm("gwy_01J8ZK4T9QW3RM7XN2VB6HD5PC", "gwy_"));
    // Falsches Präfix: eine Sendung ist kein Container, auch wenn die ULID stimmt.
    try std.testing.expect(!hasValidPrefixedForm("shp_01J8ZK4T9QW3RM7XN2VB6HD5PC", "cnt_"));
    // Ein U ist in Crockford nicht vorgesehen.
    try std.testing.expect(!hasValidPrefixedForm("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PU", "cnt_"));
}
