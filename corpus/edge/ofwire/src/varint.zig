//! LEB128-Kodierung, ohne die der Rahmen doppelt so groß wäre. Fast jeder Wert im Batch ist
//! klein — Zeitversätze von wenigen Sekunden, Feuchtewerte unter 10 000, Containerindizes unter
//! 400 — und belegt damit ein bis zwei Byte statt vier oder acht.

const std = @import("std");

/// Ein Varint ist nie länger als zehn Byte (70 Bit Nutzlast für einen u64). Alles darüber ist
/// entweder ein beschädigter Rahmen oder ein Angriffsversuch mit einer endlosen Byte-Folge.
pub const MAX_LEN = 10;

pub const Error = error{
    /// Der Rahmen endet mitten in einem Varint.
    Truncated,
    /// Mehr als `MAX_LEN` Fortsetzungsbytes.
    VarintOverflow,
    /// Der Zielpuffer fasst den kodierten Wert nicht.
    BufferTooSmall,
};

/// Ergebnis eines Lesevorgangs: der Wert und wie viele Bytes er belegt hat.
pub fn Decoded(comptime T: type) type {
    return struct {
        value: T,
        len: usize,
    };
}

/// Schreibt `value` als unsigned LEB128 und liefert die Anzahl geschriebener Bytes.
pub fn writeUnsigned(out: []u8, value: u64) Error!usize {
    var remaining = value;
    var i: usize = 0;
    while (true) {
        if (i >= out.len) return Error.BufferTooSmall;
        const byte: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        if (remaining == 0) {
            out[i] = byte;
            return i + 1;
        }
        out[i] = byte | 0x80;
        i += 1;
    }
}

/// Liest ein unsigned LEB128 vom Anfang von `input`.
pub fn readUnsigned(input: []const u8) Error!Decoded(u64) {
    var value: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (i >= MAX_LEN) return Error.VarintOverflow;
        const byte = input[i];
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return .{ .value = value, .len = i + 1 };
        // `shift` läuft bei 63 über; das kann nur passieren, wenn der Rahmen manipuliert ist.
        if (shift >= 63) return Error.VarintOverflow;
        shift += 7;
    }
    return Error.Truncated;
}

/// Zickzack-Abbildung für vorzeichenbehaftete Werte: −1 wird zu 1, 1 zu 2, −2 zu 3. Ohne sie
/// bräuchte jeder negative Zeitversatz — und jede Temperatur unter null — die vollen zehn Byte.
pub fn zigzagEncode(value: i64) u64 {
    const shifted: u64 = @bitCast(value << 1);
    const sign: u64 = @bitCast(value >> 63);
    return shifted ^ sign;
}

pub fn zigzagDecode(value: u64) i64 {
    const half: i64 = @bitCast(value >> 1);
    const mask: i64 = -@as(i64, @intCast(value & 1));
    return half ^ mask;
}

/// Bequemlichkeit für die Aufrufer in frame.zig: signed schreiben.
pub fn writeSigned(out: []u8, value: i64) Error!usize {
    return writeUnsigned(out, zigzagEncode(value));
}

/// Bequemlichkeit für die Aufrufer in frame.zig: signed lesen.
pub fn readSigned(input: []const u8) Error!Decoded(i64) {
    const raw = try readUnsigned(input);
    return .{ .value = zigzagDecode(raw.value), .len = raw.len };
}

/// Wie viele Bytes `value` belegen wird. Wird von `frame.encodedBound` gebraucht, damit der
/// Rust-Aufrufer seinen Puffer vorab richtig bemisst.
pub fn unsignedLen(value: u64) usize {
    var remaining = value;
    var len: usize = 1;
    while (remaining >= 0x80) : (len += 1) {
        remaining >>= 7;
    }
    return len;
}

test "kleine Werte belegen ein Byte" {
    var buf: [MAX_LEN]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try writeUnsigned(&buf, 0));
    try std.testing.expectEqual(@as(usize, 1), try writeUnsigned(&buf, 127));
    try std.testing.expectEqual(@as(usize, 2), try writeUnsigned(&buf, 128));
}

test "Hin- und Rückweg über den gesamten Bereich" {
    var buf: [MAX_LEN]u8 = undefined;
    const proben = [_]u64{ 0, 1, 127, 128, 300, 65535, 1_710_400_000_000, std.math.maxInt(u64) };
    for (proben) |probe| {
        const len = try writeUnsigned(&buf, probe);
        const back = try readUnsigned(buf[0..len]);
        try std.testing.expectEqual(probe, back.value);
        try std.testing.expectEqual(len, back.len);
        try std.testing.expectEqual(len, unsignedLen(probe));
    }
}

test "Zickzack hält negative Zeitversätze klein" {
    var buf: [MAX_LEN]u8 = undefined;
    // −250 ms Versatz: ein Sensor, dessen Uhr leicht vorgeht. Zwei Byte, nicht zehn.
    const len = try writeSigned(&buf, -250);
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqual(@as(i64, -250), (try readSigned(buf[0..len])).value);
}

test "abgeschnittener Varint wird erkannt" {
    const truncated = [_]u8{ 0x80, 0x80 };
    try std.testing.expectError(Error.Truncated, readUnsigned(&truncated));
}

test "endlose Fortsetzungsbytes laufen nicht durch" {
    const evil = [_]u8{0x80} ** 12;
    try std.testing.expectError(Error.VarintOverflow, readUnsigned(&evil));
}
