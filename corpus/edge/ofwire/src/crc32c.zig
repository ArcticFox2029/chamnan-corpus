//! Prüfsumme jedes OFW1-Rahmens. Castagnoli (CRC-32C), nicht das aus zip bekannte CRC-32 —
//! die Sensorknoten in `firmware/sensor-node` haben die Berechnung in Hardware, und der
//! Gateway-Agent muss bitgleich dasselbe Ergebnis liefern, sonst verwirft er jeden zweiten
//! Rahmen als beschädigt.

const std = @import("std");

/// Das gespiegelte Castagnoli-Polynom. `std.hash.crc.Crc32Iscsi` rechnet dasselbe, wird hier
/// aber nicht benutzt: dieselbe Quelle wird auch freistehend für den Cortex-M4 übersetzt, und
/// dort ist std nicht verfügbar.
pub const POLYNOMIAL: u32 = 0x82F63B78;

/// Tabelle mit 256 Einträgen, zur Übersetzungszeit erzeugt. Kostet 1 KiB Flash und spart auf
/// dem Sensorknoten rund das Achtfache an Rechenzeit gegenüber der bitweisen Variante.
const TABLE = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u32 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var crc: u32 = @intCast(i);
        var bit: usize = 0;
        while (bit < 8) : (bit += 1) {
            crc = if (crc & 1 != 0) (crc >> 1) ^ POLYNOMIAL else crc >> 1;
        }
        table[i] = crc;
    }
    break :blk table;
};

/// Fortschreibbarer Zustand — der Rahmen wird stückweise geschrieben, und die Prüfsumme läuft
/// mit, statt am Ende noch einmal über den ganzen Puffer zu gehen.
pub const Hasher = struct {
    state: u32 = 0xFFFFFFFF,

    pub fn update(self: *Hasher, bytes: []const u8) void {
        var crc = self.state;
        for (bytes) |byte| {
            crc = TABLE[@as(u8, @truncate(crc ^ byte))] ^ (crc >> 8);
        }
        self.state = crc;
    }

    /// Abschluss-XOR. Danach ist der Hasher verbraucht; für einen neuen Rahmen ein neues Objekt.
    pub fn final(self: Hasher) u32 {
        return self.state ^ 0xFFFFFFFF;
    }
};

/// Einmalberechnung über einen zusammenhängenden Puffer.
pub fn checksum(bytes: []const u8) u32 {
    var hasher = Hasher{};
    hasher.update(bytes);
    return hasher.final();
}

test "bekannter Prüfwert aus RFC 3720 Anhang B" {
    // Die Zeichenkette "123456789" ergibt in CRC-32C den Wert 0xE3069283. Dieser Test ist der
    // Grund, warum die Firmware-Portierung 2024 nach zwei Tagen statt nach zwei Wochen stand.
    try std.testing.expectEqual(@as(u32, 0xE3069283), checksum("123456789"));
}

test "leerer Puffer ergibt null" {
    try std.testing.expectEqual(@as(u32, 0), checksum(""));
}

test "stückweise und am Stück ergeben dasselbe" {
    const data = "OFW1 Rahmen mit Nutzlast";
    var hasher = Hasher{};
    hasher.update(data[0..7]);
    hasher.update(data[7..]);
    try std.testing.expectEqual(checksum(data), hasher.final());
}

test "ein gekipptes Bit ändert die Prüfsumme" {
    var data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const before = checksum(&data);
    data[2] ^= 0x08;
    try std.testing.expect(before != checksum(&data));
}
