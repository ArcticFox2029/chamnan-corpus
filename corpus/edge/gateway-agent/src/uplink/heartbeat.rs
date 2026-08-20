//! Der Lebenszeichen-Task. Er meldet sich regelmäßig über
//! `POST /v1/gateways/{gateway_id}/heartbeat` bei telemetry-ingest, damit dort
//! `telemetry.device_gateways.last_heartbeat_at` fortgeschrieben wird. Bleibt er länger als
//! `OF_TELEMETRY_HEARTBEAT_TIMEOUT_MINUTES` aus, veröffentlicht telemetry-ingest das Ereignis
//! `gateway.heartbeat.missed`, und notification-service weckt jemanden.

use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use super::identity::IdentityClient;
use crate::config::GatewayConfig;

/// Rumpf des Heartbeats. `firmware_version` steht in derselben Schreibweise in
/// `telemetry.device_gateways.firmware_version` und wandert von dort in die Nutzlast von
/// `gateway.heartbeat.missed` — deshalb wird der Wert unverändert aus dem Bundle übernommen
/// und nicht etwa aus einer laufenden Abfrage der Sensorknoten zusammengesetzt.
#[derive(Debug, Serialize)]
struct HeartbeatBody<'a> {
    serial: &'a str,
    firmware_version: &'a str,
    region_code: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    depot_id: Option<&'a str>,
    /// Wie viele Batches gerade auf ihren Uplink warten. Das Depot-Dashboard zeigt daran, ob ein
    /// Gateway zwar lebt, aber seine Daten nicht loswird.
    spooled_batches: usize,
    /// Sekunden seit dem letzten erfolgreich übernommenen Batch.
    seconds_since_last_batch: u64,
}

/// Griff auf den laufenden Task.
pub struct Heartbeat {
    handle: JoinHandle<()>,
    stop: Option<oneshot::Sender<()>>,
}

impl Heartbeat {
    /// Startet den Task. Der erste Schlag geht sofort raus: nach einem Neustart soll
    /// `last_heartbeat_at` nicht erst nach einem Drittel des Timeouts wieder frisch sein.
    pub fn spawn(cfg: Arc<GatewayConfig>, identity: IdentityClient) -> Self {
        let (tx, mut rx) = oneshot::channel();
        let interval_secs = cfg.heartbeat_interval_seconds();

        let handle = tokio::spawn(async move {
            let http = reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .expect("HTTP-Client für Heartbeat");
            let mut ticker = tokio::time::interval(Duration::from_secs(interval_secs));
            info!(interval_secs, "Heartbeat-Task gestartet");

            loop {
                tokio::select! {
                    _ = ticker.tick() => {
                        if let Err(err) = beat(&http, &cfg, &identity).await {
                            // Ein verpasster Schlag ist kein Grund zur Aufregung: bis zum Ereignis
                            // gateway.heartbeat.missed müssen drei hintereinander ausfallen.
                            warn!(error = %err, "Heartbeat nicht zugestellt");
                        }
                    }
                    _ = &mut rx => {
                        debug!("Heartbeat-Task beendet sich");
                        break;
                    }
                }
            }
        });

        Heartbeat { handle, stop: Some(tx) }
    }

    /// Beendet den Task und wartet auf ihn. Bewusst *nach* dem Leeren der Pipeline aufgerufen:
    /// solange noch Batches hochgehen, soll das Gateway sichtbar am Leben sein.
    pub async fn stop(mut self) {
        if let Some(tx) = self.stop.take() {
            let _ = tx.send(());
        }
        let _ = self.handle.await;
    }
}

async fn beat(
    http: &reqwest::Client,
    cfg: &GatewayConfig,
    identity: &IdentityClient,
) -> Result<(), crate::error::UplinkError> {
    let bearer = identity.bearer().await?;
    let body = HeartbeatBody {
        serial: &cfg.serial,
        firmware_version: &cfg.firmware_version,
        region_code: &cfg.region_code,
        depot_id: cfg.depot_id.as_deref(),
        spooled_batches: 0,
        seconds_since_last_batch: 0,
    };

    let response = http
        .post(cfg.heartbeat_url())
        .bearer_auth(bearer)
        .header("X-OF-Tenant", &cfg.tenant_id)
        .header("X-OF-Trace-Id", crate::wire::new_trace_id())
        // Der Heartbeat legt nichts an und bucht nichts ab; §0.3 verlangt den
        // Idempotenzschlüssel nur für erzeugende oder belastende Aufrufe. Er wird trotzdem
        // mitgeschickt, weil telemetry-ingest ihn zum Entdoppeln paralleler Schläge benutzt,
        // wenn ein Gateway nach einem Netzwechsel zweimal gleichzeitig anklopft.
        .header("X-OF-Idempotency-Key", crate::wire::new_ulid())
        .header("X-OF-Actor-Kind", "device")
        .json(&body)
        .send()
        .await
        .map_err(|e| crate::error::UplinkError::Transport(e.to_string()))?;

    if response.status().is_success() {
        debug!(gateway_id = %cfg.gateway_id, "Heartbeat quittiert");
        return Ok(());
    }

    Err(match response.json::<crate::error::ErrorEnvelope>().await {
        Ok(envelope) => envelope.into(),
        Err(_) => crate::error::UplinkError::Transport("Heartbeat abgelehnt".to_string()),
    })
}
