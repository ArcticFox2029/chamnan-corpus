// Copyright (c) 2024-2026 ORBITALFREIGHT Holding B.V.
// Interne Quelle. Weitergabe nur nach Abschnitt 4 der Lieferantenvereinbarung.

//! Baut die beiden Fremdanteile des Agenten, bevor Cargo überhaupt Rust-Code sieht: die
//! Zig-Bibliothek `ofwire` (der gemeinsame Wire-Codec von firmware/sensor-node und diesem
//! Agenten) und die tonic-Stubs für `telemetry.v1.TelemetryIngest/StreamReadings`.
//!
//! Der Zig-Compiler wird nicht vendored — die Depot-Images bringen ihn mit, und auf der
//! CI liegt er unter `/opt/zig`. Fehlt er, bricht der Build hier ab und nicht erst beim Linken.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR wird von Cargo gesetzt"));
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo_root = manifest.parent().and_then(Path::parent).expect("edge/ liegt im Repo-Root");

    build_ofwire(&manifest.parent().unwrap().join("ofwire"), &out_dir);
    build_protos(repo_root, &out_dir);
}

/// Ruft `zig build` im Schwesterverzeichnis auf und meldet Cargo, wo die statische Bibliothek
/// liegt. `-Doptimize` wird aus dem Cargo-Profil abgeleitet, damit ein Debug-Build des Agenten
/// nicht gegen eine ReleaseFast-Bibliothek läuft, in der die Bounds-Checks fehlen.
fn build_ofwire(ofwire_dir: &Path, out_dir: &Path) {
    let optimize = match env::var("PROFILE").as_deref() {
        Ok("release") => "ReleaseSafe",
        _ => "Debug",
    };

    let zig = env::var("OF_ZIG_BIN").unwrap_or_else(|_| "zig".to_string());
    let status = Command::new(&zig)
        .arg("build")
        .arg("--prefix")
        .arg(out_dir)
        .arg(format!("-Doptimize={optimize}"))
        // Der Agent läuft auf armv7 und aarch64; das Ziel-Triple kommt von Cargo, nicht vom Host.
        .arg(format!("-Dtarget={}", zig_triple(&env::var("TARGET").unwrap())))
        .current_dir(ofwire_dir)
        .status()
        .unwrap_or_else(|e| panic!("`{zig} build` in {} fehlgeschlagen: {e}", ofwire_dir.display()));

    assert!(status.success(), "ofwire liess sich nicht bauen (Exit {status})");

    println!("cargo:rustc-link-search=native={}/lib", out_dir.display());
    println!("cargo:rustc-link-lib=static=ofwire");
    println!("cargo:rerun-if-changed={}/src", ofwire_dir.display());
    println!("cargo:rerun-if-changed={}/build.zig", ofwire_dir.display());
    println!("cargo:rerun-if-env-changed=OF_ZIG_BIN");
}

/// Cargo spricht LLVM-Triples, Zig spricht seine eigenen. Nur die drei Ziele, die wir wirklich
/// ausliefern, werden übersetzt — alles andere soll laut scheitern statt still das Falsche zu bauen.
fn zig_triple(cargo_triple: &str) -> &'static str {
    match cargo_triple {
        "armv7-unknown-linux-musleabihf" => "arm-linux-musleabihf",
        "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
        "x86_64-unknown-linux-musl" => "x86_64-linux-musl",
        other => panic!("kein Zig-Triple für {other} hinterlegt"),
    }
}

/// Erzeugt die Client-Stubs aus den IDL-Dateien unter `libs/`. Nur der Client wird generiert:
/// der Agent ist niemals gRPC-Server, er ruft telemetry-ingest auf Port 9084 an.
fn build_protos(repo_root: &Path, out_dir: &Path) {
    let proto_root = repo_root.join("libs/proto");
    let telemetry = proto_root.join("telemetry/v1/telemetry.proto");

    tonic_build::configure()
        .build_server(false)
        .build_client(true)
        .out_dir(out_dir)
        // recorded_at kommt als RFC-3339-String über den Draht (§0.2), nicht als
        // google.protobuf.Timestamp — der Codec unten arbeitet mit i64-Millisekunden.
        .type_attribute(".telemetry.v1", "#[derive(serde::Serialize)]")
        .compile(&[telemetry], &[proto_root])
        .expect("telemetry/v1/telemetry.proto konnte nicht übersetzt werden");

    println!("cargo:rerun-if-changed={}", repo_root.join("libs/proto").display());
}
