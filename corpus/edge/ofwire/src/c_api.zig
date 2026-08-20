//! Die C-ABI der Codec-Bibliothek — die einzige Fläche, über die der Rust-Agent unter
//! `edge/gateway-agent/` und die C11-Firmware unter `firmware/sensor-node` den Codec erreichen.
//! Alles hier ist bewusst stumpf: keine Allokation, keine Fehlerobjekte, nur Zeiger, Längen und
//! negative Statuscodes.
//!
//! Wer eine Signatur in dieser Datei ändert, ändert damit auch `wire/mod.rs` auf der Rust-Seite
//! und `ofwire.h` — die drei bilden ein Paket, und `build.zig` erzeugt die Kopfdatei mit.

const std = @import("std");
const root = @import("root.zig");
const frame = @import("frame.zig");
const ulid = @import("ulid.zig");

/// Statuscodes. Dieselbe Tabelle steht in `status_to_error` auf der Rust-Seite; sie darf nur
/// wachsen, nie umnummeriert werden, weil ein Gateway im Feld eine ältere Bibliothek gegen
/// einen neueren Agenten linken kann.
pub const Status = enum(c_int) {
    ok = 0,
    bad_magic = -1,
    unsupported_version = -2,
    checksum_mismatch = -3,
    truncated = -4,
    varint_overflow = -5,
    value_out_of_range = -6,
    buffer_too_small = -7,
    dictionary_full = -8,
};

fn statusFor(err: frame.DecodeError) c_int {
    return @intFromEnum(switch (err) {
        error.BadMagic => Status.bad_magic,
        error.UnsupportedVersion => Status.unsupported_version,
        error.ChecksumMismatch => Status.checksum_mismatch,
        error.Truncated => Status.truncated,
        error.VarintOverflow => Status.varint_overflow,
        error.ValueOutOfRange => Status.value_out_of_range,
        error.BufferTooSmall => Status.buffer_too_small,
        error.DictionaryFull => Status.dictionary_full,
    });
}

/// Obere Schranke der Rahmenlänge für `reading_count` Messwerte. Der Aufrufer bemisst danach
/// seinen Puffer, bevor er `ofwire_batch_encode` ruft.
export fn ofwire_batch_bound(reading_count: usize) usize {
    return frame.encodedBound(reading_count);
}

/// Kodiert einen Batch. Rückgabe: geschriebene Bytes, oder ein negativer `Status`.
export fn ofwire_batch_encode(
    out: [*]u8,
    out_len: usize,
    header: *const frame.BatchHeader,
    readings: [*]const frame.Reading,
    reading_count: usize,
) isize {
    const written = frame.encode(out[0..out_len], header, readings[0..reading_count]) catch |err| {
        return statusFor(err);
    };
    return @intCast(written);
}

/// Liest den Kopfteil eines Rahmens, ohne die Messwerte zu entpacken. Der Gateway-Agent ruft
/// genau das beim Wiedereinlesen seines Spools — er will wissen, was in dem Rahmen steckt,
/// aber ihn unter keinen Umständen neu bauen: die Ed25519-Signatur gilt für die Bytes, wie sie
/// auf der Platte liegen.
export fn ofwire_batch_inspect(
    input: [*]const u8,
    input_len: usize,
    out_header: *frame.BatchHeader,
) c_int {
    frame.inspect(input[0..input_len], out_header) catch |err| return statusFor(err);
    return 0;
}

/// Entpackt den ganzen Batch in einem Durchlauf. Rückgabe: Anzahl geschriebener Messwerte, oder
/// ein negativer `Status`. Eine wahlfreie Zugriffsfunktion gibt es absichtlich nicht — sie
/// müsste je Aufruf von vorne laufen und machte einen Batch mit 5 000 Werten quadratisch teuer.
export fn ofwire_batch_decode(
    input: [*]const u8,
    input_len: usize,
    out: [*]frame.Reading,
    out_capacity: usize,
) isize {
    var decoder = frame.Decoder.init(input[0..input_len]) catch |err| return statusFor(err);
    var written: usize = 0;
    while (decoder.next() catch |err| return statusFor(err)) |reading| {
        if (written == out_capacity) return @intFromEnum(Status.buffer_too_small);
        out[written] = reading;
        written += 1;
    }
    return @intCast(written);
}

/// Erzeugt eine ULID (26 Zeichen Crockford-Base32 plus Nullbyte) für `ingest_batch_id` und für
/// Idempotenzschlüssel nach §0.3.
export fn ofwire_ulid_new(out: [*]u8, out_len: usize) c_int {
    _ = ulid.generate(out[0..out_len]) catch return @intFromEnum(Status.buffer_too_small);
    return 0;
}

/// Prüft eine präfixierte Kennung nach §0.1. `prefix` ist nullterminiert, etwa `"cnt_"`.
/// Rückgabe 1 für gültig, 0 für ungültig — kein Statuscode, das hier ist eine Frage, keine
/// Operation.
export fn ofwire_id_valid(id: [*:0]const u8, prefix: [*:0]const u8) c_int {
    const id_slice = std.mem.span(id);
    const prefix_slice = std.mem.span(prefix);
    return if (ulid.hasValidPrefixedForm(id_slice, prefix_slice)) 1 else 0;
}

/// Formatiert Millisekunden seit Epoch als RFC 3339 mit `Z`-Suffix — die einzige Zeitdarstellung,
/// die §0.2 auf dem Draht zulässt. Ohne libc und ohne `strftime`, weil dieselbe Funktion auch
/// auf dem Sensorknoten läuft.
export fn ofwire_format_rfc3339(millis: i64, out: [*]u8, out_len: usize) c_int {
    if (out_len < 25) return @intFromEnum(Status.buffer_too_small);

    const seconds = @divFloor(millis, 1000);
    const sub_ms: u32 = @intCast(@mod(millis, 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();

    const written = std.fmt.bufPrint(out[0..out_len], "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
        sub_ms,
    }) catch return @intFromEnum(Status.buffer_too_small);

    out[written.len] = 0;
    return 0;
}

/// Version der Bibliothek, damit ein Agent beim Start protokollieren kann, gegen welchen Codec
/// er tatsächlich gelinkt ist. Formatversion des Rahmens ist davon unabhängig — siehe
/// `root.VERSION`.
export fn ofwire_abi_version() c_int {
    return 1;
}

test "Statuscodes decken jeden Dekodierfehler ab" {
    // Verhindert, dass eine neue Variante von DecodeError ohne Statuscode durchrutscht: das
    // Switch oben ist erschöpfend, also scheitert schon die Übersetzung. Der Test hält nur die
    // Zuordnung der Zahlen fest, auf die sich die Rust-Seite verlässt.
    try std.testing.expectEqual(@as(c_int, -1), statusFor(error.BadMagic));
    try std.testing.expectEqual(@as(c_int, -3), statusFor(error.ChecksumMismatch));
    try std.testing.expectEqual(@as(c_int, -7), statusFor(error.BufferTooSmall));
}

test "Zeitstempel entspricht dem Beispiel aus der SPEC" {
    var buf: [32]u8 = undefined;
    // 2026-03-14T09:21:44.118Z — derselbe Zeitpunkt wie im Beispiel der Ereignishülle in §0.7.
    try std.testing.expectEqual(@as(c_int, 0), ofwire_format_rfc3339(1_773_480_104_118, &buf, buf.len));
    try std.testing.expectEqualStrings("2026-03-14T09:21:44.118Z", std.mem.sliceTo(&buf, 0));
}
