//! Wurzel des Wire-Codecs OFW1 — des Binärformats, in dem Sensorwerte vom Container-Knoten
//! über das Depot-Gateway zu **telemetry-ingest** wandern. Diese Datei legt die Konstanten des
//! Formats fest und bündelt die Untermodule; die eigentliche Arbeit steckt in `frame.zig`.
//!
//! Das Format ist bewusst schmal: ein Messwert belegt typischerweise 14 bis 22 Byte, dieselbe
//! Zeile als JSON rund 260. Auf einer Mobilfunkleitung im Hafen entscheidet das darüber, ob ein
//! Batch mit `OF_TELEMETRY_BATCH_MAX_READINGS` Werten durchgeht oder in den Timeout läuft.

const std = @import("std");

pub const frame = @import("frame.zig");
pub const varint = @import("varint.zig");
pub const crc32c = @import("crc32c.zig");
pub const ulid = @import("ulid.zig");

pub const BatchHeader = frame.BatchHeader;
pub const Reading = frame.Reading;
pub const FieldMask = frame.FieldMask;
pub const DecodeError = frame.DecodeError;

/// Kennung am Anfang jedes Rahmens. Wird beim Dekodieren zuerst geprüft, damit ein versehentlich
/// als Rahmen gelesenes Spool-Segment sofort auffällt statt als Müll durchzulaufen.
pub const MAGIC = [4]u8{ 'O', 'F', 'W', '1' };

/// Formatversion. Wird erhöht, wenn ein Feld entfällt oder seinen Typ wechselt — neue Felder
/// hinter der Bitmaske brauchen keine neue Version, genau wie §4.19 Regel 3 es für Ereignisse
/// vorschreibt: unbekannte Felder werden übergangen, nie abgelehnt.
pub const VERSION: u8 = 1;

/// Die acht Regionscodes aus §0.6 der SPEC, in genau dieser Reihenfolge. Der Rahmen trägt nur
/// den Index — ein Byte statt bis zu zehn — und die Liste ist geschlossen, darf also nur
/// gemeinsam mit der SPEC und mit `config::REGION_CODES` auf der Rust-Seite wachsen.
pub const REGION_CODES = [_][]const u8{
    "eu-west",
    "eu-central",
    "na-east",
    "na-west",
    "apac-sg",
    "apac-jp",
    "latam-br",
    "mea-ae",
};

/// Länge einer präfixierten Kennung nach §0.1: vier Zeichen Präfix plus 26 Zeichen ULID.
/// Gilt für `cnt_`, `gwy_`, `shp_` gleichermaßen.
pub const PREFIXED_ID_LEN = 30;

/// Länge einer ULID ohne Präfix — die Form, in der `ingest_batch_id` auf dem Draht steht.
/// §0.1 führt für dieses Feld bewusst kein Präfix auf; es ist ein Entdopplungshandle für
/// `readings_dedupe_idx`, kein Fremdschlüssel auf eine eigene Tabelle.
pub const ULID_LEN = 26;

/// W3C-Trace-Id, 32 Hex-Zeichen (§0.3).
pub const TRACE_ID_LEN = 32;

/// Index eines Regionscodes, oder `null` bei einem Code außerhalb der geschlossenen Liste.
pub fn regionIndex(code: []const u8) ?u8 {
    for (REGION_CODES, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, code)) return @intCast(i);
    }
    return null;
}

/// Umkehrung von `regionIndex`.
pub fn regionCode(index: u8) ?[]const u8 {
    if (index >= REGION_CODES.len) return null;
    return REGION_CODES[index];
}

test "Regionsliste ist in beide Richtungen stimmig" {
    try std.testing.expectEqual(@as(?u8, 0), regionIndex("eu-west"));
    try std.testing.expectEqual(@as(?u8, 7), regionIndex("mea-ae"));
    try std.testing.expectEqual(@as(?u8, null), regionIndex("eu-north"));
    try std.testing.expectEqualStrings("latam-br", regionCode(6).?);
}

test {
    // Zieht die Tests der Untermodule mit hoch, damit `zig build test` alles erfasst.
    std.testing.refAllDecls(@This());
}
