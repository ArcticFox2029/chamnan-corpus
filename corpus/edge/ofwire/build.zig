//! Baut den Wire-Codec in drei Ausprägungen: als Zig-Modul für Tests, als statische Bibliothek
//! mit C-ABI für den Rust-Agenten unter `edge/gateway-agent/` und als freistehende Variante
//! ohne libc für die Sensorknoten in `firmware/sensor-node`. Alle drei übersetzen dieselben
//! Quellen — genau das ist der Grund, warum der Codec überhaupt in Zig geschrieben ist.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Als Modul für alles, was den Codec innerhalb von Zig benutzt — heute nur die Tests und
    // das Werkzeug `ofdump` unter tools/.
    _ = b.addModule("ofwire", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "ofwire",
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Die Bibliothek kommt ohne libc aus: `ofwire_ulid_new` zieht seine Zufallszahlen aus
    // std.crypto.random, und formatiert wird von Hand. Das ist Voraussetzung dafür, dass
    // derselbe Code auf dem Cortex-M4 der Sensorknoten läuft.
    lib.bundle_compiler_rt = true;
    b.installArtifact(lib);

    // Kopfdatei für die C11-Seite. Sie wird zusammen mit der Bibliothek installiert, damit
    // firmware/sensor-node genau die Deklarationen bekommt, die zu dem gebauten Objekt gehören —
    // eine zweite, von Hand gepflegte Kopie im Firmware-Baum ist ausdrücklich unerwünscht.
    lib.installHeader(b.path("src/ofwire.h"), "ofwire.h");

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Einheitentests des Codecs ausführen");
    test_step.dependOn(&run_tests.step);

    // Kreuzprobe gegen aufgezeichnete Rahmen aus dem Feld: `zig build fuzz` läuft die Dateien
    // unter `testdata/` durch den Dekoder. Sie stammen aus echten Depots und enthalten unter
    // anderem den abgeschnittenen Rahmen, der uns im Februar den Spool zerlegt hat.
    const fuzz = b.addTest(.{
        .root_source_file = b.path("src/frame.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .filters = &.{"corpus"},
    });
    const fuzz_step = b.step("fuzz", "Dekoder gegen die aufgezeichneten Rahmen laufen lassen");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz).step);
}
