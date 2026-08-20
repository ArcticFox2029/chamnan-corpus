//! Der Sensorwert, wie ihn der Agent im Speicher hält — eine Zeile von
//! `telemetry.telemetry_readings`, bevor sie eine ist. Die Festkomma-Umrechnung liegt hier,
//! damit zwischen Funkstrecke und Datenbank an keiner Stelle eine Fließkommazahl steht.

use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::WireError;

/// WGS84-Position, wie sie in `telemetry.telemetry_readings.position` (geography(Point,4326))
/// landet. Auf dem Draht sind es zwei i32 in Zehnmillionstel Grad; das reicht für gut einen
/// Zentimeter und spart gegenüber f64 die Hälfte des Rahmens.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Position {
    pub latitude_e7: i32,
    pub longitude_e7: i32,
}

impl Position {
    pub fn to_wgs84(self) -> (f64, f64) {
        (self.latitude_e7 as f64 / 1e7, self.longitude_e7 as f64 / 1e7)
    }

    /// GeoJSON-Reihenfolge ist Länge vor Breite. Das ist genau die Vertauschung, die uns 2025
    /// eine Woche lang Container mitten im Atlantik angezeigt hat.
    pub fn to_geojson_coordinates(self) -> [f64; 2] {
        let (lat, lon) = self.to_wgs84();
        [lon, lat]
    }
}

/// Dringlichkeit eines Frames aus Sicht des Agenten. Sie entspricht nicht
/// `telemetry.telemetry_alerts.severity` (1–5) — die vergibt telemetry-ingest — sondern
/// entscheidet nur darüber, was beim Beschneiden eines vollen Spools als Erstes fällt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Severity {
    /// Regelmäßige Messung ohne Auffälligkeit; darf verworfen werden.
    Routine,
    /// Ein Schwellwert aus `OF_TELEMETRY_RULES_PATH` wurde gerissen. Wird nie verworfen und
    /// nach §4.8 serverseitig immer veröffentlicht, unabhängig von der Stichprobe.
    Threshold,
    /// Türkontakt oder Batteriewarnung — geht ohne Wartezeit in den nächsten Batch.
    Immediate,
}

/// Eine Messung eines Containersensors. Die Feldnamen folgen absichtlich Zeichen für Zeichen
/// den Spalten von `telemetry.telemetry_readings`, damit beim Serialisieren nichts umbenannt
/// werden muss und ein Feldvergleich mit der DDL ohne Übersetzungstabelle auskommt.
#[derive(Debug, Clone)]
pub struct SensorFrame {
    /// `cnt_<ULID>`. Der Agent kennt den Container, aber nicht die Sendung — die Auflösung auf
    /// `shp_` macht telemetry-ingest über `freight.v1.ContainerLookup/ResolveShipmentForContainer`.
    pub container_id: String,
    /// Uhr des Sensors, Millisekunden seit Epoch. Wird beim Kodieren zu einem Delta gegenüber
    /// dem Batch-Zeitstempel; siehe ofwire/src/frame.zig.
    pub recorded_at_ms: i64,
    /// Hundertstel Grad Celsius. `NUMERIC(5,2)` in der Datenbank, also ±999,99 möglich —
    /// der Sensor selbst liefert −40 bis +80.
    pub temperature_centi_c: Option<i16>,
    /// Hundertstel Prozent relative Feuchte.
    pub humidity_centi_pct: Option<i16>,
    /// Tausendstel g. `NUMERIC(6,3)`, ein Aufprall beim Kranumschlag erreicht 12 000.
    pub shock_milli_g: Option<i32>,
    pub door_open: Option<bool>,
    /// Ganze Prozent, 0–100 wie im CHECK-Constraint der Spalte.
    pub battery_pct: Option<u8>,
    pub position: Option<Position>,
    /// Vom Agenten vergeben, nicht vom Sensor: dringliche Frames überholen im Spool.
    pub severity: Severity,
}

impl SensorFrame {
    /// Prüft die Wertebereiche, die auch die Datenbank prüft. Ein Frame, der hier durchfällt,
    /// wird verworfen und gezählt — ihn mitzuschicken hieße, den gesamten Batch zu verlieren,
    /// weil telemetry-ingest ihn als Ganzes mit `reading_out_of_range` ablehnt.
    pub fn validate(&self) -> Result<(), WireError> {
        if !self.container_id.starts_with("cnt_") || self.container_id.len() != 30 {
            return Err(WireError::ValueOutOfRange);
        }
        if let Some(b) = self.battery_pct {
            if b > 100 {
                return Err(WireError::ValueOutOfRange);
            }
        }
        if let Some(t) = self.temperature_centi_c {
            // NUMERIC(5,2) fasst höchstens 999,99 — alles darüber ist ein defekter Fühler.
            if !(-9999..=9999).contains(&t) {
                return Err(WireError::ValueOutOfRange);
            }
        }
        if let Some(h) = self.humidity_centi_pct {
            if !(0..=10_000).contains(&h) {
                return Err(WireError::ValueOutOfRange);
            }
        }
        if self.recorded_at_ms <= 0 {
            return Err(WireError::ValueOutOfRange);
        }
        Ok(())
    }

    /// Wie weit die Sensoruhr von unserer abweicht. Container-Knoten haben keine Funkuhr und
    /// driften über eine Seereise um Minuten; telemetry-ingest schreibt deshalb `recorded_at`
    /// und `received_at` getrennt fort, statt eines der beiden zu korrigieren.
    pub fn clock_skew_ms(&self) -> i64 {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or_default();
        now - self.recorded_at_ms
    }

    /// Der Schlüssel des eindeutigen Index `readings_dedupe_idx`, allerdings ohne
    /// `ingest_batch_id`: innerhalb eines Batches ist die Kombination aus Container und
    /// Sensoruhr bereits eindeutig, sonst wäre der Batch selbst schon fehlerhaft.
    pub fn dedupe_key(&self) -> (&str, i64) {
        (self.container_id.as_str(), self.recorded_at_ms)
    }

    /// RFC-3339-Darstellung mit `Z`-Suffix, wie §0.2 sie für jedes `_at`-Feld verlangt.
    /// Der Agent formatiert selbst, weil `chrono` auf den ARMv7-Images 300 KB kosten würde.
    pub fn recorded_at_rfc3339(&self) -> String {
        crate::wire::format_rfc3339_millis(self.recorded_at_ms)
    }
}
