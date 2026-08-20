//! Die fachliche Mitte des Agenten: was ein Sensorwert ist, wie er entdoppelt wird und ab
//! welcher Schwelle er es eilig hat. Geschrieben wird hier nichts — `telemetry.telemetry_readings`
//! und `telemetry.telemetry_alerts` gehören telemetry-ingest, der Agent liefert nur zu.
//!
//! Was aus einem Messwert wird, nachdem ihn der Agent losgeschickt hat — der Grund, warum ein
//! vorgestufter Frame im Spool Vorrang hat:
//!
//! 1. telemetry-ingest schreibt ihn nach `telemetry.telemetry_readings`, in die LIST-Partition
//!    seiner Region.
//! 2. Jeder zwanzigste Messwert je Container (`OF_TELEMETRY_PUBLISH_SAMPLE_RATE`) und
//!    ausnahmslos jeder, der eine Schwelle gerissen hat, geht als `telemetry.reading.recorded`
//!    auf `of.telemetry.v1`. container-registry hält damit
//!    `freight.containers.last_reading_at` warm, analytics-pipeline füttert seine Aggregate.
//! 3. Reißt der Wert eine Schwelle, entsteht eine Zeile in `telemetry.telemetry_alerts` und
//!    daraus `telemetry.alert.raised`. Erst darüber kippt container-registry die Sendung nach
//!    `at_risk` — telemetry-ingest ruft container-registry dafür ausdrücklich nicht an.
//!
//! Ein verworfener Routine-Frame kostet also eine Datenpunktlücke. Ein verworfener
//! Schwellwert-Frame kostet einen Alarm, den niemand je sieht.
pub mod dedupe;
pub mod frame;
pub mod rules;

pub use dedupe::DedupeWindow;
pub use frame::{Position, SensorFrame, Severity};
pub use rules::{RuleSet, TriggeredRule};

/// Die acht `rule_code`-Werte aus dem CHECK-Constraint auf `telemetry.telemetry_alerts`.
/// Der Agent *wertet* sie aus, um dringende Frames vorzuziehen, aber er eröffnet keine Alarme:
/// `alr_`-Zeilen und das Ereignis `telemetry.alert.raised` entstehen ausschließlich in
/// telemetry-ingest. Wer das hier ändert, baut einen zweiten Alarmpfad — und damit zwei
/// Wahrheiten über denselben Container.
pub const RULE_CODES: [&str; 8] = [
    "temp_excursion_high",
    "temp_excursion_low",
    "humidity_high",
    "shock_impact",
    "door_open_in_transit",
    "battery_critical",
    "gateway_silent",
    "geofence_breach",
];

/// `gateway_silent` und `geofence_breach` kann ein Gateway prinzipiell nicht selbst feststellen:
/// das eine bemerkt nur, wer auf den Heartbeat wartet, das andere braucht
/// `geo.v1.GeoService/PointInFence`, und geo-service ist vom Depot aus nicht erreichbar.
pub fn is_locally_detectable(rule_code: &str) -> bool {
    !matches!(rule_code, "gateway_silent" | "geofence_breach")
}
