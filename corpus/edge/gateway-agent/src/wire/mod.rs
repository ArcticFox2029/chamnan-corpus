//! Die sichere Rust-Seite des Wire-Codecs. Der Codec selbst liegt in Zig unter `edge/ofwire/`,
//! weil ihn die Sensorknoten in firmware/sensor-node (C11) und dieser Agent Byte für Byte
//! gleich sprechen müssen — zwei Implementierungen desselben Formats waren 2024 der Grund für
//! drei Wochen unerklärliche Prüfsummenfehler auf einer einzigen Firmware-Charge.
//!
//! Hier steht nur die Umhüllung: Puffer bereitstellen, `unsafe` einsperren, Statuscodes in
//! `WireError` übersetzen.

use std::os::raw::{c_int, c_uchar};

use crate::error::WireError;
use crate::pipeline::batcher::Batch;
use crate::telemetry::{Position, SensorFrame, Severity};

/// Die C-ABI der Zig-Bibliothek. Deklariert, nicht generiert: es sind sechs Funktionen, und ein
/// bindgen-Lauf im Build wäre mehr Maschinerie als Nutzen.
extern "C" {
    /// Schätzt die obere Schranke des kodierten Rahmens für `reading_count` Messwerte.
    fn ofwire_batch_bound(reading_count: usize) -> usize;

    /// Kodiert einen Batch. Rückgabe: geschriebene Bytes, oder ein negativer Statuscode.
    fn ofwire_batch_encode(
        out: *mut c_uchar,
        out_len: usize,
        header: *const OfwireBatchHeader,
        readings: *const OfwireReading,
        reading_count: usize,
    ) -> isize;

    /// Liest nur den Kopfteil, ohne die Messwerte zu entpacken. Wird beim Wiedereinlesen des
    /// Spools benutzt, wo nur `ingest_batch_id`, Region und Anzahl interessieren.
    fn ofwire_batch_inspect(
        input: *const c_uchar,
        input_len: usize,
        out_header: *mut OfwireBatchHeader,
    ) -> c_int;

    /// Entpackt den ganzen Batch in einem Durchlauf. Eine wahlfreie Zugriffsfunktion gibt es
    /// nicht: sie müsste je Aufruf von vorne durch die Varints laufen.
    fn ofwire_batch_decode(
        input: *const c_uchar,
        input_len: usize,
        out: *mut OfwireReading,
        out_capacity: usize,
    ) -> isize;

    /// Version der gelinkten Bibliothek; wird beim Start protokolliert.
    fn ofwire_abi_version() -> c_int;

    /// Erzeugt eine ULID (26 Zeichen Crockford-Base32, ohne Präfix) in `out`.
    fn ofwire_ulid_new(out: *mut c_uchar, out_len: usize) -> c_int;

    /// Formatiert Millisekunden seit Epoch als RFC-3339 mit `Z`-Suffix (§0.2).
    fn ofwire_format_rfc3339(millis: i64, out: *mut c_uchar, out_len: usize) -> c_int;
}

/// Spiegelt `ofwire.BatchHeader` aus frame.zig. Die Feldreihenfolge ist Teil der ABI und darf
/// nur zusammen mit der Zig-Seite geändert werden.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct OfwireBatchHeader {
    /// 26 Zeichen ULID plus Nullbyte.
    ingest_batch_id: [c_uchar; 27],
    /// `gwy_` plus 26 Zeichen plus Nullbyte.
    gateway_id: [c_uchar; 31],
    /// Index in die Regionsliste aus §0.6 — ein Byte statt eines Strings, weil die Liste
    /// geschlossen ist.
    region_index: u8,
    /// 32 Hex-Zeichen der W3C-Trace-Id plus Nullbyte.
    trace_id: [c_uchar; 33],
    epoch_ms: i64,
    reading_count: u32,
    /// Bit 0: mindestens ein Messwert hat eine Schwelle gerissen.
    flags: u32,
}

/// Spiegelt `ofwire.Reading`. `has_*` statt `Option`, weil C keine Optionale kennt.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
struct OfwireReading {
    container_id: [c_uchar; 31],
    /// Delta zu `epoch_ms` in Millisekunden.
    offset_ms: i64,
    temperature_centi_c: i16,
    humidity_centi_pct: i16,
    shock_milli_g: i32,
    latitude_e7: i32,
    longitude_e7: i32,
    battery_pct: u8,
    door_open: u8,
    /// Bitmaske der belegten Felder; siehe `ofwire.FieldMask` in frame.zig.
    present: u16,
    severity: u8,
    _padding: [u8; 3],
}

/// Was `inspect_batch` zurückgibt.
#[derive(Debug, Clone)]
pub struct BatchHead {
    pub ingest_batch_id: String,
    pub region_code: String,
    pub trace_id: String,
    pub reading_count: usize,
    pub priority: bool,
}

/// Kodiert einen Batch in einen OFW1-Rahmen.
pub fn encode_batch(batch: &Batch) -> Result<Vec<u8>, WireError> {
    let region_index = region_index(&batch.region_code).ok_or(WireError::ValueOutOfRange)?;

    let mut header = OfwireBatchHeader {
        ingest_batch_id: [0; 27],
        gateway_id: [0; 31],
        region_index,
        trace_id: [0; 33],
        epoch_ms: batch.epoch_ms,
        reading_count: batch.frames.len() as u32,
        flags: u32::from(batch.has_priority()),
    };
    copy_cstr(&mut header.ingest_batch_id, &batch.ingest_batch_id)?;
    copy_cstr(&mut header.gateway_id, &batch.gateway_id)?;
    copy_cstr(&mut header.trace_id, &batch.trace_id)?;

    let readings: Vec<OfwireReading> = batch
        .frames
        .iter()
        .map(|f| {
            let mut r = OfwireReading::default();
            let _ = copy_cstr(&mut r.container_id, &f.container_id);
            r.offset_ms = f.recorded_at_ms - batch.epoch_ms;
            r.severity = match f.severity {
                Severity::Routine => 0,
                Severity::Threshold => 1,
                Severity::Immediate => 2,
            };
            let mut present = 0u16;
            if let Some(t) = f.temperature_centi_c {
                r.temperature_centi_c = t;
                present |= 1 << 0;
            }
            if let Some(h) = f.humidity_centi_pct {
                r.humidity_centi_pct = h;
                present |= 1 << 1;
            }
            if let Some(s) = f.shock_milli_g {
                r.shock_milli_g = s;
                present |= 1 << 2;
            }
            if let Some(d) = f.door_open {
                r.door_open = u8::from(d);
                present |= 1 << 3;
            }
            if let Some(b) = f.battery_pct {
                r.battery_pct = b;
                present |= 1 << 4;
            }
            if let Some(p) = f.position {
                r.latitude_e7 = p.latitude_e7;
                r.longitude_e7 = p.longitude_e7;
                present |= 1 << 5;
            }
            r.present = present;
            r
        })
        .collect();

    // SAFETY: `out` ist mindestens so groß wie die von der Bibliothek selbst berechnete Schranke,
    // `readings` lebt bis zum Ende des Aufrufs, und `reading_count` stimmt mit der Länge überein.
    let bound = unsafe { ofwire_batch_bound(readings.len()) };
    let mut out = vec![0u8; bound];
    let written = unsafe {
        ofwire_batch_encode(
            out.as_mut_ptr(),
            out.len(),
            &header,
            readings.as_ptr(),
            readings.len(),
        )
    };

    if written < 0 {
        return Err(status_to_error(written as c_int));
    }
    out.truncate(written as usize);
    Ok(out)
}

/// Liest den Kopfteil eines gespoolten Rahmens.
pub fn inspect_batch(encoded: &[u8]) -> Result<BatchHead, WireError> {
    let mut header = OfwireBatchHeader {
        ingest_batch_id: [0; 27],
        gateway_id: [0; 31],
        region_index: 0,
        trace_id: [0; 33],
        epoch_ms: 0,
        reading_count: 0,
        flags: 0,
    };

    // SAFETY: Nur-Lese-Zugriff auf einen Slice bekannter Länge; `header` ist voll initialisiert.
    let status = unsafe { ofwire_batch_inspect(encoded.as_ptr(), encoded.len(), &mut header) };
    if status < 0 {
        return Err(status_to_error(status));
    }

    let region_code = crate::config::REGION_CODES
        .get(header.region_index as usize)
        .copied()
        .ok_or(WireError::ValueOutOfRange)?;

    Ok(BatchHead {
        ingest_batch_id: read_cstr(&header.ingest_batch_id),
        region_code: region_code.to_string(),
        trace_id: read_cstr(&header.trace_id),
        reading_count: header.reading_count as usize,
        priority: header.flags & 1 != 0,
    })
}

/// Neue ULID ohne Präfix — für `ingest_batch_id` und für Idempotenzschlüssel.
pub fn new_ulid() -> String {
    let mut buf = [0u8; 27];
    // SAFETY: Puffer ist 27 Byte groß, die Bibliothek schreibt 26 Zeichen plus Nullbyte.
    let status = unsafe { ofwire_ulid_new(buf.as_mut_ptr(), buf.len()) };
    debug_assert!(status >= 0, "ULID-Erzeugung kann nur bei zu kleinem Puffer scheitern");
    read_cstr(&buf)
}

/// W3C-Trace-Id: 32 Hex-Zeichen (§0.3). Am Rand erzeugt, weil kein Aufrufer eine mitbringt.
pub fn new_trace_id() -> String {
    let hi: u64 = rand::random();
    let lo: u64 = rand::random();
    format!("{hi:016x}{lo:016x}")
}

/// RFC 3339 mit Millisekunden und `Z`, wie §0.2 es für jedes `_at`-Feld vorschreibt.
pub fn format_rfc3339_millis(millis: i64) -> String {
    let mut buf = [0u8; 32];
    // SAFETY: 32 Byte reichen für "2026-03-14T09:21:44.118Z" plus Nullbyte.
    let status = unsafe { ofwire_format_rfc3339(millis, buf.as_mut_ptr(), buf.len()) };
    if status < 0 {
        return String::new();
    }
    read_cstr(&buf)
}

/// Entpackt einen Rahmen zurück in Messwerte. Der Agent braucht das im Betrieb nicht — er
/// dekodiert nie, was er selbst kodiert hat — aber das Werkstattwerkzeug `ofdump` und die
/// Regressionstests lesen damit aufgezeichnete Rahmen aus dem Feld.
pub fn decode_batch(encoded: &[u8]) -> Result<Vec<SensorFrame>, WireError> {
    let head = inspect_batch(encoded)?;
    let mut raw = vec![OfwireReading::default(); head.reading_count];

    // SAFETY: `raw` hat genau `reading_count` Plätze, und die Bibliothek schreibt höchstens so
    // viele — bei mehr liefert sie `BufferTooSmall` statt zu überschreiben.
    let written = unsafe {
        ofwire_batch_decode(encoded.as_ptr(), encoded.len(), raw.as_mut_ptr(), raw.len())
    };
    if written < 0 {
        return Err(status_to_error(written as c_int));
    }
    raw.truncate(written as usize);

    Ok(raw
        .into_iter()
        .map(|r| SensorFrame {
            container_id: read_cstr(&r.container_id),
            // Der Dekodierer löst den Versatz bereits zum absoluten Zeitstempel auf.
            recorded_at_ms: r.offset_ms,
            temperature_centi_c: (r.present & (1 << 0) != 0).then_some(r.temperature_centi_c),
            humidity_centi_pct: (r.present & (1 << 1) != 0).then_some(r.humidity_centi_pct),
            shock_milli_g: (r.present & (1 << 2) != 0).then_some(r.shock_milli_g),
            door_open: (r.present & (1 << 3) != 0).then_some(r.door_open != 0),
            battery_pct: (r.present & (1 << 4) != 0).then_some(r.battery_pct),
            position: (r.present & (1 << 5) != 0).then_some(Position {
                latitude_e7: r.latitude_e7,
                longitude_e7: r.longitude_e7,
            }),
            severity: match r.severity {
                2 => Severity::Immediate,
                1 => Severity::Threshold,
                _ => Severity::Routine,
            },
        })
        .collect())
}

/// ABI-Version der gelinkten Zig-Bibliothek.
pub fn abi_version() -> i32 {
    // SAFETY: parameterlos, ohne Seiteneffekt.
    unsafe { ofwire_abi_version() }
}

/// Index eines Regionscodes in der geschlossenen Liste aus §0.6.
fn region_index(code: &str) -> Option<u8> {
    crate::config::REGION_CODES
        .iter()
        .position(|c| *c == code)
        .map(|i| i as u8)
}

fn copy_cstr(dst: &mut [u8], src: &str) -> Result<(), WireError> {
    if src.len() + 1 > dst.len() {
        return Err(WireError::BufferTooSmall);
    }
    dst[..src.len()].copy_from_slice(src.as_bytes());
    dst[src.len()] = 0;
    Ok(())
}

fn read_cstr(raw: &[u8]) -> String {
    let end = raw.iter().position(|b| *b == 0).unwrap_or(raw.len());
    String::from_utf8_lossy(&raw[..end]).into_owned()
}

/// Die Statuscodes stammen aus `ofwire.status` in c_api.zig und sind dort dieselbe Tabelle.
fn status_to_error(status: c_int) -> WireError {
    match status {
        -1 => WireError::BadMagic,
        -2 => WireError::UnsupportedVersion,
        -3 => WireError::ChecksumMismatch,
        -4 => WireError::Truncated,
        -5 => WireError::VarintOverflow,
        -6 => WireError::ValueOutOfRange,
        _ => WireError::BufferTooSmall,
    }
}
