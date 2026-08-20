//! Verdrahtet den Weg eines Messwerts vom Funkempfänger bis zum Uplink: Entdoppeln,
//! Einstufen, Bündeln, auf Platte sichern, senden, quittieren. Der Spool sitzt bewusst
//! *vor* dem Uplink — was einmal auf der Platte liegt, geht auch dann noch raus, wenn das
//! Depot mitten in der Nacht die Leitung verliert.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

pub mod batcher;
pub mod spool;

pub use batcher::{Batch, Batcher, BatchReason};
pub use spool::Spool;

use crate::config::GatewayConfig;
use crate::error::EdgeError;
use crate::telemetry::{DedupeWindow, RuleSet, SensorFrame, Severity};
use crate::uplink::Uplink;

/// Tiefe der Eingangswarteschlange. Ein volles Depot erzeugt rund 15 Frames pro Sekunde; 4096
/// Plätze puffern also gut vier Minuten Rückstau, bevor der Funkempfänger Gegendruck spürt.
const INGRESS_CAPACITY: usize = 4096;

/// Die laufende Pipeline. Sie besitzt ihre Tasks und wird beim Herunterfahren über `drain()`
/// geleert; `Drop` allein bricht nur ab, ohne zu leeren.
pub struct Pipeline {
    ingress: mpsc::Sender<SensorFrame>,
    rules: Arc<Mutex<RuleSet>>,
    batcher_task: JoinHandle<()>,
    uplink_task: JoinHandle<()>,
    accepted: Arc<AtomicU64>,
}

impl Pipeline {
    /// Startet beide Tasks. Der Batcher bündelt und schreibt in den Spool, der Uplink-Task
    /// liest aus dem Spool und sendet — sie teilen sich keinen Speicher außer der Spool-Datei,
    /// damit ein Absturz des einen den anderen nicht um seine Daten bringt.
    pub fn start(cfg: Arc<GatewayConfig>, spool: Spool, uplink: Uplink) -> Result<Self, EdgeError> {
        let rules = Arc::new(Mutex::new(RuleSet::reload(&cfg.rules_path).unwrap_or_else(|err| {
            // Beim Start ohne Regelwerk zu scheitern hieße, dass ein Tippfehler in der YAML das
            // ganze Depot blind macht. Ohne Regeln ist jeder Frame `Routine` — Messwerte fließen
            // weiter, nur die Vorstufung fehlt.
            warn!(error = %err, "Schwellwertdatei unbrauchbar, Agent läuft ohne Vorstufung an");
            RuleSet::default()
        })));

        let (tx, rx) = mpsc::channel::<SensorFrame>(INGRESS_CAPACITY);
        let accepted = Arc::new(AtomicU64::new(0));

        let batcher = Batcher::new(Arc::clone(&cfg), spool.clone());
        let batcher_task = tokio::spawn(batcher.run(rx, Arc::clone(&rules), Arc::clone(&accepted)));
        let uplink_task = tokio::spawn(uplink.run(spool));

        info!(capacity = INGRESS_CAPACITY, "Pipeline läuft");
        Ok(Pipeline { ingress: tx, rules, batcher_task, uplink_task, accepted })
    }

    /// Nimmt einen frisch dekodierten Frame an. Gibt `false` zurück, wenn die Warteschlange voll
    /// ist — der Aufrufer (der Funkempfänger) verwirft dann Routine-Frames und behält dringende.
    pub fn try_submit(&self, frame: SensorFrame) -> bool {
        match self.ingress.try_send(frame) {
            Ok(()) => true,
            Err(mpsc::error::TrySendError::Full(f)) => {
                debug!(container_id = %f.container_id, "Eingang voll, Frame abgewiesen");
                false
            }
            Err(mpsc::error::TrySendError::Closed(_)) => false,
        }
    }

    /// Tauscht das Regelwerk zur Laufzeit aus (SIGHUP). Bereits gebündelte Batches behalten die
    /// Einstufung, mit der sie gebaut wurden.
    pub fn swap_rules(&self, rules: RuleSet) {
        let mut guard = self.rules.lock().expect("Regelwerk-Mutex vergiftet");
        *guard = rules;
    }

    /// Schließt den Eingang, wartet auf den letzten Batch und lässt den Uplink senden, was noch
    /// geht. Liefert die Anzahl der tatsächlich bestätigten Messwerte.
    pub async fn drain(self) -> Result<u64, EdgeError> {
        drop(self.ingress);
        let _ = self.batcher_task.await;
        let _ = self.uplink_task.await;
        Ok(self.accepted.load(Ordering::Relaxed))
    }
}

/// Entdoppeln und Einstufen in einem Schritt — die beiden Operationen brauchen denselben
/// Frame und laufen im selben Task, damit das Fenster ohne Sperre auskommt.
pub(crate) fn admit(
    window: &mut DedupeWindow,
    rules: &RuleSet,
    mut frame: SensorFrame,
) -> Option<SensorFrame> {
    if frame.validate().is_err() {
        return None;
    }
    if !window.admit(&frame) {
        return None;
    }
    frame.severity = rules.classify(&frame);
    if frame.severity != Severity::Routine {
        debug!(container_id = %frame.container_id, severity = ?frame.severity, "Frame vorgestuft");
    }
    Some(frame)
}
