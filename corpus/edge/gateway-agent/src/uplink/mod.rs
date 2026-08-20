//! Alles, was den Agenten mit **telemetry-ingest** verbindet. Hier wird entschieden, ob ein
//! Batch über `POST /v1/ingest/batch` oder über `telemetry.v1.TelemetryIngest/StreamReadings`
//! geht, wie lange nach einem Fehlschlag gewartet wird und wann ein Batch endgültig aufgegeben ist.
//!
//! Der Agent spricht ausschließlich mit telemetry-ingest und mit identity-service. Er ruft
//! weder container-registry noch geo-service direkt an — die Auflösung `cnt_` → `shp_` über
//! `freight.v1.ContainerLookup/ResolveShipmentForContainer` und die Geofence-Prüfung über
//! `geo.v1.GeoService/PointInFence` passieren serverseitig, wo die Tokens dafür liegen.

use std::sync::Arc;
use std::time::Duration;

use tracing::{debug, info, warn};

mod heartbeat;
mod identity;
mod ingest;
#[cfg(feature = "grpc-stream")]
mod stream;

pub use heartbeat::Heartbeat;
pub use identity::IdentityClient;
pub use ingest::IngestClient;

use crate::config::GatewayConfig;
use crate::crypto::Signer;
use crate::error::{EdgeError, UplinkError};
use crate::pipeline::Spool;

/// Backoff-Kurve. §4.19 schreibt für Kafka-Konsumenten acht Versuche mit exponentiellem Backoff
/// ab 500 ms vor; der Uplink hält sich an dieselbe Staffelung, damit sich ein Depot nach einer
/// Netzunterbrechung genauso verhält wie ein Dienst nach einem Broker-Ausfall.
const BACKOFF_BASE_MS: u64 = 500;
const BACKOFF_MAX: Duration = Duration::from_secs(64);

/// Der Uplink-Task. Er zieht Batches aus dem Spool und gibt sie erst frei, wenn
/// telemetry-ingest quittiert hat.
pub struct Uplink {
    cfg: Arc<GatewayConfig>,
    http: IngestClient,
    #[cfg(feature = "grpc-stream")]
    stream: Option<stream::StreamClient>,
}

impl Uplink {
    /// Baut die Transporte auf. Der gRPC-Strom ist optional: Depots hinter einem Mobilfunk-Router
    /// verlieren die Verbindung zu oft, dort ist der Einzel-POST günstiger als ein ständig
    /// neu aufgebauter Strom.
    pub async fn connect(
        cfg: Arc<GatewayConfig>,
        identity: IdentityClient,
        signer: Signer,
    ) -> Result<Self, EdgeError> {
        let http = IngestClient::new(Arc::clone(&cfg), identity.clone(), signer.clone())?;

        #[cfg(feature = "grpc-stream")]
        let stream = match stream::StreamClient::connect(Arc::clone(&cfg), identity, signer).await {
            Ok(client) => {
                info!(addr = %cfg.ingest_grpc_addr, "gRPC-Strom zu telemetry-ingest steht");
                Some(client)
            }
            Err(err) => {
                warn!(error = %err, "gRPC-Strom nicht verfügbar, es bleibt bei POST /v1/ingest/batch");
                None
            }
        };

        Ok(Uplink {
            cfg,
            http,
            #[cfg(feature = "grpc-stream")]
            stream,
        })
    }

    /// Endlosschleife über den Spool. Sie endet erst, wenn der Spool geschlossen wird — beim
    /// Herunterfahren also nach dem Bündler.
    pub async fn run(self, spool: Spool) {
        let mut consecutive_failures: u32 = 0;

        loop {
            let Some(batch) = spool.peek().await else {
                tokio::time::sleep(Duration::from_millis(250)).await;
                continue;
            };

            // Datenresidenz nach §7 Regel 7: ein Batch aus einer fremden Region darf nicht
            // umgeleitet werden. Er wäre serverseitig ein 403 und würde nur Versuche verbrennen.
            if !self.cfg.allowed_regions.contains(&batch.region_code) {
                spool.discard(&batch.ingest_batch_id, "region_not_allowed").await;
                continue;
            }

            let result = self.send(&batch).await;
            match result {
                Ok(accepted) => {
                    consecutive_failures = 0;
                    spool.commit(&batch.ingest_batch_id).await;
                    debug!(
                        ingest_batch_id = %batch.ingest_batch_id,
                        readings = accepted,
                        trace_id = %batch.trace_id,
                        "Batch von telemetry-ingest übernommen"
                    );
                }
                Err(err) if err.retryable() => {
                    consecutive_failures += 1;
                    let attempts = spool.defer(&batch.ingest_batch_id).await;
                    let wait = backoff(consecutive_failures);
                    warn!(
                        ingest_batch_id = %batch.ingest_batch_id,
                        attempts,
                        error = %err,
                        wait_ms = wait.as_millis(),
                        "Senden fehlgeschlagen, wird wiederholt"
                    );
                    tokio::time::sleep(wait).await;
                }
                Err(err) => {
                    // Nicht wiederholbar: falsche Signatur, unbekanntes Gateway, Batch zu groß.
                    // Der Fehlercode kommt aus der Hülle nach §0.4 und steht so im Log, dass er
                    // sich mit den Logs von telemetry-ingest über die trace_id verbinden lässt.
                    let code = match &err {
                        UplinkError::Rejected { code, .. } => code.clone(),
                        other => other.envelope_code().to_string(),
                    };
                    spool.discard(&batch.ingest_batch_id, &code).await;
                }
            }
        }
    }

    /// Bevorzugt den Strom, fällt aber ohne Aufhebens auf HTTP zurück. Beide Wege schreiben
    /// dieselben Zeilen in dieselbe Partition von `telemetry.telemetry_readings`; welcher
    /// benutzt wurde, ist nur eine Frage der Leitungsqualität.
    async fn send(&self, batch: &crate::pipeline::spool::SpooledBatch) -> Result<usize, UplinkError> {
        #[cfg(feature = "grpc-stream")]
        if let Some(stream) = &self.stream {
            match stream.send(batch).await {
                Ok(n) => return Ok(n),
                Err(err) if err.retryable() => {
                    debug!(error = %err, "Strom gestört, dieser Batch geht über HTTP");
                }
                Err(err) => return Err(err),
            }
        }
        self.http.post_batch(batch).await
    }
}

/// Exponentiell ab 500 ms, gedeckelt bei 64 s, mit ±20 % Streuung. Ohne die Streuung klopfen
/// nach einem regionalen Netzausfall alle Depots einer Region in derselben Sekunde an.
fn backoff(attempt: u32) -> Duration {
    let exp = BACKOFF_BASE_MS.saturating_mul(1u64 << attempt.min(7));
    let capped = Duration::from_millis(exp).min(BACKOFF_MAX);
    let jitter = (capped.as_millis() as u64 / 5).max(1);
    capped + Duration::from_millis(rand::random::<u64>() % jitter)
}
