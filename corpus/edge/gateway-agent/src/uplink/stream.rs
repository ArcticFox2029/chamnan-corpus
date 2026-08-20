//! Der gRPC-Weg nach oben: `telemetry.v1.TelemetryIngest/StreamReadings`. Für Depots mit
//! fester Leitung ist der Client-Strom deutlich günstiger als ein POST je Batch, weil
//! TLS-Handshake und Tokenprüfung nur einmal je Verbindung anfallen.
//!
//! Fällt der Strom aus, ist das kein Fehler, sondern der Normalfall — der Aufrufer schiebt den
//! Batch dann über `IngestClient::post_batch` hinaus. Der `ingest_batch_id` bleibt derselbe,
//! also entsteht auch bei doppeltem Versand keine zweite Zeile.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::Mutex;
use tonic::metadata::MetadataValue;
use tonic::transport::{Channel, Endpoint};
use tonic::Request;
use tracing::debug;

use super::identity::IdentityClient;
use crate::config::GatewayConfig;
use crate::crypto::Signer;
use crate::error::UplinkError;
use crate::pipeline::spool::SpooledBatch;

/// Die von tonic-build erzeugten Stubs; siehe build.rs.
pub mod pb {
    include!(concat!(env!("OUT_DIR"), "/telemetry.v1.rs"));
}

/// Nach dieser Zeit ohne Datenverkehr wird der Strom aktiv erneuert. Manche Mobilfunk-NATs
/// vergessen eine stille Verbindung nach zwei Minuten, ohne ein RST zu schicken — der Agent
/// merkt das sonst erst, wenn der nächste Batch ins Leere läuft.
const IDLE_RECYCLE: Duration = Duration::from_secs(90);

pub struct StreamClient {
    cfg: Arc<GatewayConfig>,
    identity: IdentityClient,
    signer: Signer,
    channel: Mutex<Channel>,
}

impl StreamClient {
    pub async fn connect(
        cfg: Arc<GatewayConfig>,
        identity: IdentityClient,
        signer: Signer,
    ) -> Result<Self, UplinkError> {
        let endpoint = Endpoint::from_shared(format!("http://{}", cfg.ingest_grpc_addr))
            .map_err(|e| UplinkError::Transport(format!("ungültige gRPC-Adresse: {e}")))?
            .keep_alive_while_idle(true)
            .http2_keep_alive_interval(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(60));

        let channel = endpoint
            .connect()
            .await
            .map_err(|e| UplinkError::Transport(e.to_string()))?;

        Ok(StreamClient { cfg, identity, signer, channel: Mutex::new(channel) })
    }

    /// Schiebt einen Batch als Folge von `Reading`-Nachrichten durch den Client-Strom. Der Server
    /// antwortet erst am Ende mit einer Zusammenfassung — dieselbe Semantik wie beim POST, nur
    /// ohne den Rahmen ein zweites Mal über die Leitung zu schicken.
    pub async fn send(&self, batch: &SpooledBatch) -> Result<usize, UplinkError> {
        let bearer = self.identity.bearer().await?;
        let signature = self.signer.sign_batch(&batch.encoded);
        let channel = self.channel.lock().await.clone();
        let mut client = pb::telemetry_ingest_client::TelemetryIngestClient::new(channel);

        // Ein einzelner Rahmen pro Strom-Nachricht: der Server dekodiert ihn mit derselben
        // Zig-Bibliothek, die ihn hier gebaut hat, und spart sich das Umpacken nach Protobuf.
        let outbound = futures_util::stream::iter(vec![pb::ReadingBatch {
            ingest_batch_id: batch.ingest_batch_id.clone(),
            gateway_id: self.cfg.gateway_id.clone(),
            region_code: batch.region_code.clone(),
            payload: batch.encoded.as_ref().clone(),
            signature: signature.clone(),
        }]);

        let mut request = Request::new(outbound);
        let meta = request.metadata_mut();
        // gRPC-Metadaten tragen dieselben Namen wie die HTTP-Header aus §0.3, nur kleingeschrieben.
        meta.insert("x-of-tenant", value(self.identity.tenant_id())?);
        meta.insert("x-of-trace-id", value(&batch.trace_id)?);
        meta.insert("x-of-idempotency-key", value(&batch.ingest_batch_id)?);
        meta.insert("x-of-actor-kind", value("device")?);
        meta.insert("authorization", value(&format!("Bearer {bearer}"))?);

        let response = client
            .stream_readings(request)
            .await
            .map_err(|status| map_status(status))?
            .into_inner();

        debug!(
            accepted = response.accepted,
            duplicates = response.duplicates,
            "Strom-Batch übernommen"
        );
        Ok(response.accepted as usize)
    }

    pub fn idle_recycle() -> Duration {
        IDLE_RECYCLE
    }
}

fn value(raw: &str) -> Result<MetadataValue<tonic::metadata::Ascii>, UplinkError> {
    raw.parse()
        .map_err(|_| UplinkError::Transport(format!("Metadatenwert nicht ASCII: {raw}")))
}

/// Übersetzt einen gRPC-Status in unsere Fehlerarten. Die Fehlerhülle aus §0.4 reist bei gRPC
/// in `google.rpc.Status.details`; wo sie fehlt, entscheidet der Statuscode über die Wiederholung.
fn map_status(status: tonic::Status) -> UplinkError {
    use tonic::Code;
    match status.code() {
        Code::Unavailable | Code::ResourceExhausted | Code::Aborted => {
            UplinkError::Transport(status.message().to_string())
        }
        Code::DeadlineExceeded => UplinkError::Timeout { millis: 60_000 },
        Code::Unauthenticated | Code::PermissionDenied => UplinkError::Rejected {
            code: "gateway_not_authorised".to_string(),
            http_status: 403,
            retryable: false,
            trace_id: String::new(),
        },
        other => UplinkError::Rejected {
            code: format!("grpc_{}", other.description().to_lowercase().replace(' ', "_")),
            http_status: 400,
            retryable: false,
            trace_id: String::new(),
        },
    }
}
