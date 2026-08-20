// SPDX-License-Identifier: LicenseRef-OrbitalFreight-Internal

//! Sammelt einzelne Messwerte zu einem Batch, wie ihn `POST /v1/ingest/batch` erwartet, und
//! entscheidet, wann er zugemacht wird: bei `OF_TELEMETRY_BATCH_MAX_READINGS`, nach Ablauf des
//! Zeitfensters oder sofort, sobald ein Frame eine Schwelle gerissen hat.
//!
//! Der `ingest_batch_id` entsteht genau hier und wird nie wieder verändert — er ist der
//! Entdopplungsschlüssel in `readings_dedupe_idx` und macht jede Wiederholung serverseitig
//! zu einem No-op statt zu einem Duplikat.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::mpsc;
use tokio::time::interval;
use tracing::{debug, info, warn};

use super::{admit, Spool};
use crate::config::GatewayConfig;
use crate::telemetry::{DedupeWindow, RuleSet, SensorFrame, Severity};

/// Regelfenster. Länger zu warten bringt keinen nennenswerten Kompressionsgewinn mehr und
/// verzögert nur die Sichtbarkeit im Konsolen-Dashboard.
const WINDOW: Duration = Duration::from_secs(20);

/// Selbst wenn nur zwei Frames anliegen: nach dieser Zeit geht der Batch raus. Sonst hinge eine
/// vereinzelte Türmeldung stundenlang im Speicher, während telemetry-ingest den Heartbeat
/// weiterhin sieht und alles für in Ordnung hält.
const MAX_AGE: Duration = Duration::from_secs(120);

/// Warum ein Batch geschlossen wurde. Steht als Feld im Log und in der Metrik
/// `gateway_batches_closed_total{reason=…}`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BatchReason {
    /// `OF_TELEMETRY_BATCH_MAX_READINGS` erreicht.
    SizeLimit,
    /// Zeitfenster abgelaufen.
    Window,
    /// Ein Frame mit `Severity::Immediate` — Tür offen, Batterie kritisch.
    Urgent,
    /// Der Agent fährt herunter.
    Shutdown,
}

impl BatchReason {
    pub fn as_str(self) -> &'static str {
        match self {
            BatchReason::SizeLimit => "size_limit",
            BatchReason::Window => "window",
            BatchReason::Urgent => "urgent",
            BatchReason::Shutdown => "shutdown",
        }
    }
}

/// Ein zugemachter Batch, fertig zum Kodieren und Signieren.
#[derive(Debug)]
pub struct Batch {
    /// ULID ohne Präfix. §0.1 führt für `ingest_batch_id` bewusst keines auf — die Spalte ist
    /// ein Entdopplungshandle und kein Fremdschlüssel auf eine eigene Tabelle.
    pub ingest_batch_id: String,
    /// `gwy_<ULID>`, identisch mit `telemetry.device_gateways.gateway_id`.
    pub gateway_id: String,
    /// Einer der acht Codes aus §0.6; telemetry-ingest schreibt danach in die passende
    /// LIST-Partition von `telemetry.telemetry_readings`.
    pub region_code: String,
    /// Bezugszeitpunkt in Millisekunden; alle Frames werden als Delta dazu kodiert.
    pub epoch_ms: i64,
    pub frames: Vec<SensorFrame>,
    pub reason: BatchReason,
    /// W3C-Trace-Id (32 Hex), am Rand erzeugt — §0.3 erlaubt genau das, wenn kein Aufrufer
    /// eine mitbringt. Sie begleitet den Batch bis in die Logs von telemetry-ingest.
    pub trace_id: String,
}

impl Batch {
    pub fn len(&self) -> usize {
        self.frames.len()
    }

    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }

    /// Enthält der Batch mindestens einen Frame, der eine Schwelle gerissen hat? Solche Batches
    /// werden beim Beschneiden eines vollen Spools nie verworfen: nach §4.8 veröffentlicht
    /// telemetry-ingest jede Schwellwertüberschreitung, unabhängig von
    /// `OF_TELEMETRY_PUBLISH_SAMPLE_RATE`, und genau daran hängt `telemetry.alert.raised`.
    pub fn has_priority(&self) -> bool {
        self.frames.iter().any(|f| f.severity != Severity::Routine)
    }
}

/// Der Bündler selbst.
pub struct Batcher {
    cfg: Arc<GatewayConfig>,
    spool: Spool,
}

impl Batcher {
    pub fn new(cfg: Arc<GatewayConfig>, spool: Spool) -> Self {
        Batcher { cfg, spool }
    }

    /// Läuft, bis der Eingang geschlossen wird. Danach wird noch einmal geleert und der Task
    /// endet — deshalb wartet `Pipeline::drain` zuerst auf ihn und erst dann auf den Uplink.
    pub async fn run(
        self,
        mut rx: mpsc::Receiver<SensorFrame>,
        rules: Arc<Mutex<RuleSet>>,
        accepted: Arc<AtomicU64>,
    ) {
        let mut window = DedupeWindow::new();
        let mut pending: Vec<SensorFrame> = Vec::with_capacity(self.cfg.batch_max_readings.min(4096));
        let mut opened_at = Instant::now();
        let mut ticker = interval(WINDOW);
        // Der erste Tick kommt sofort; ihn zu überspringen erspart einen leeren Batch beim Start.
        ticker.tick().await;

        loop {
            let reason = tokio::select! {
                frame = rx.recv() => match frame {
                    None => break,
                    Some(frame) => {
                        let admitted = {
                            let guard = rules.lock().expect("Regelwerk-Mutex vergiftet");
                            admit(&mut window, &guard, frame)
                        };
                        let Some(frame) = admitted else { continue };

                        let urgent = frame.severity == Severity::Immediate;
                        if pending.is_empty() {
                            opened_at = Instant::now();
                        }
                        pending.push(frame);

                        if pending.len() >= self.cfg.batch_max_readings {
                            Some(BatchReason::SizeLimit)
                        } else if urgent {
                            Some(BatchReason::Urgent)
                        } else if opened_at.elapsed() >= MAX_AGE {
                            Some(BatchReason::Window)
                        } else {
                            None
                        }
                    }
                },
                _ = ticker.tick() => {
                    if pending.is_empty() { None } else { Some(BatchReason::Window) }
                }
            };

            if let Some(reason) = reason {
                self.close(&mut pending, reason, &accepted).await;
            }
        }

        if !pending.is_empty() {
            self.close(&mut pending, BatchReason::Shutdown, &accepted).await;
        }
        info!(
            deduplicated = window.dropped_total(),
            tracked = window.tracked(),
            "Bündler beendet"
        );
    }

    /// Macht den Batch zu, schreibt ihn in den Spool und leert den Zwischenspeicher. Ab hier
    /// gehört der Batch der Platte; scheitert das Schreiben, ist er verloren, und das ist
    /// bewusst der einzige Verlustpfad im Agenten.
    async fn close(&self, pending: &mut Vec<SensorFrame>, reason: BatchReason, accepted: &AtomicU64) {
        if pending.is_empty() {
            return;
        }
        let frames = std::mem::take(pending);
        let count = frames.len();
        let epoch_ms = frames.iter().map(|f| f.recorded_at_ms).min().unwrap_or_default();

        let batch = Batch {
            ingest_batch_id: crate::wire::new_ulid(),
            gateway_id: self.cfg.gateway_id.clone(),
            region_code: self.cfg.region_code.clone(),
            epoch_ms,
            frames,
            reason,
            trace_id: crate::wire::new_trace_id(),
        };

        match self.spool.append(&batch).await {
            Ok(bytes) => {
                accepted.fetch_add(count as u64, Ordering::Relaxed);
                debug!(
                    ingest_batch_id = %batch.ingest_batch_id,
                    readings = count,
                    bytes,
                    reason = reason.as_str(),
                    trace_id = %batch.trace_id,
                    "Batch im Spool abgelegt"
                );
            }
            Err(err) => warn!(
                error = %err,
                readings = count,
                reason = reason.as_str(),
                "Batch konnte nicht gesichert werden und ist verloren"
            ),
        }
    }
}
