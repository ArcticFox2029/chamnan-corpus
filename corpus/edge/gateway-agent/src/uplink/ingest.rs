//! Der HTTP-Weg nach oben: `POST /v1/ingest/batch` bei telemetry-ingest. Setzt die fünf
//! Pflichtheader aus §0.3, hängt die Ed25519-Signatur an und übersetzt eine Fehlerhülle nach
//! §0.4 in die Entscheidung "wiederholen oder wegwerfen".

use std::sync::Arc;
use std::time::Duration;

use serde::Deserialize;
use tracing::debug;

use super::identity::IdentityClient;
use crate::config::GatewayConfig;
use crate::crypto::Signer;
use crate::error::{EdgeError, ErrorEnvelope, UplinkError};
use crate::pipeline::spool::SpooledBatch;

/// Der OFW1-Rahmen geht als `application/vnd.orbitalfreight.ofwire.v1+binary` raus. JSON wäre
/// bei 5 000 Messwerten rund das Zwölffache — auf einer Mobilfunkleitung im Hafen ist das der
/// Unterschied zwischen "geht durch" und "läuft in den Timeout".
const CONTENT_TYPE: &str = "application/vnd.orbitalfreight.ofwire.v1+binary";

/// Ein voller Batch mit `OF_TELEMETRY_BATCH_MAX_READINGS` Messwerten braucht über eine schlechte
/// Leitung bis zu einer halben Minute. Kürzer zu takten erzeugt Wiederholungen, die die Leitung
/// weiter zusetzen.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(45);

/// Erfolgsantwort von `POST /v1/ingest/batch`.
#[derive(Debug, Deserialize)]
struct IngestAccepted {
    /// Wie viele Zeilen tatsächlich in `telemetry.telemetry_readings` geschrieben wurden.
    accepted: usize,
    /// Wie viele der eindeutige Index `readings_dedupe_idx` geschluckt hat. Bei einer
    /// Wiederholung nach einer Funklücke ist das der ganze Batch — und genau so ist es gedacht.
    #[serde(default)]
    duplicates: usize,
    /// Vom Server vergeben; der Agent kennt keine `rdg_`-Kennungen und erfindet auch keine.
    #[serde(default)]
    first_reading_id: Option<String>,
}

pub struct IngestClient {
    cfg: Arc<GatewayConfig>,
    identity: IdentityClient,
    signer: Signer,
    http: reqwest::Client,
}

impl IngestClient {
    pub fn new(
        cfg: Arc<GatewayConfig>,
        identity: IdentityClient,
        signer: Signer,
    ) -> Result<Self, EdgeError> {
        let http = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            // Der OFW1-Rahmen ist bereits varint-gepackt; gzip darüber bringt keine 3 % und
            // kostet auf einem ARMv7 spürbar CPU. Die Antwort darf dagegen komprimiert kommen.
            .gzip(true)
            .tcp_keepalive(Duration::from_secs(30))
            .pool_idle_timeout(Duration::from_secs(90))
            .user_agent(concat!("of-gateway-agentd/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| EdgeError::Config(format!("HTTP-Client nicht baubar: {e}")))?;

        Ok(IngestClient { cfg, identity, signer, http })
    }

    /// Sendet einen Batch und liefert die Anzahl der übernommenen Messwerte.
    pub async fn post_batch(&self, batch: &SpooledBatch) -> Result<usize, UplinkError> {
        let bearer = self.identity.bearer().await?;
        let signature = self.signer.sign_batch(&batch.encoded);

        let response = self
            .http
            .post(self.cfg.ingest_batch_url())
            .bearer_auth(bearer)
            // §0.3: alle fünf Header sind Pflicht. `X-OF-Idempotency-Key` ist der
            // `ingest_batch_id` selbst — derselbe Wert, auf dem serverseitig entdoppelt wird,
            // also kann es hier gar kein zweites, abweichendes Handle geben.
            .header("X-OF-Tenant", self.identity.tenant_id())
            .header("X-OF-Trace-Id", &batch.trace_id)
            .header("X-OF-Idempotency-Key", &batch.ingest_batch_id)
            .header("X-OF-Actor-Kind", "device")
            .header("Content-Type", CONTENT_TYPE)
            // Signatur über genau die Bytes im Rumpf, gegen den öffentlichen Schlüssel in
            // `telemetry.device_gateways.public_key` geprüft.
            .header("X-OF-Gateway-Signature", signature)
            .header("X-OF-Gateway-Id", &self.cfg.gateway_id)
            .body(batch.encoded.as_ref().clone())
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    UplinkError::Timeout { millis: REQUEST_TIMEOUT.as_millis() as u64 }
                } else {
                    UplinkError::Transport(e.to_string())
                }
            })?;

        let status = response.status();
        if status.is_success() {
            let accepted: IngestAccepted = response.json().await.map_err(|e| {
                // 2xx mit unlesbarem Rumpf: der Batch ist beim Server, ein zweiter Versuch würde
                // serverseitig ohnehin entdoppelt. Also als Erfolg werten und nur protokollieren.
                UplinkError::Transport(format!("Antwortrumpf unlesbar: {e}"))
            })?;
            debug!(
                accepted = accepted.accepted,
                duplicates = accepted.duplicates,
                first_reading_id = accepted.first_reading_id.as_deref().unwrap_or("-"),
                "telemetry-ingest hat den Batch übernommen"
            );
            return Ok(accepted.accepted);
        }

        // 429 und 503 tragen laut §0.4 `retryable: true`; die Hülle entscheidet, nicht der Code.
        Err(match response.json::<ErrorEnvelope>().await {
            Ok(envelope) => envelope.into(),
            Err(_) => UplinkError::Transport(format!(
                "telemetry-ingest antwortete {status} ohne verwertbare Fehlerhülle"
            )),
        })
    }
}
