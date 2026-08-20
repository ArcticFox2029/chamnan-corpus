//! Einstiegspunkt des Depot-Gateway-Agenten. Er liest Sensorframes der Container-Knoten ein,
//! bündelt sie zu signierten Batches und hält den Uplink zu **telemetry-ingest** offen; beim
//! Herunterfahren ist seine einzige harte Zusage, dass kein gepufferter Frame verloren geht.
//!
//! Der Agent gehört bewusst zu keinem der vierzehn Dienste aus §1 der SPEC. Er hat keine
//! Datenbank, kein Kafka und keinen eingehenden HTTP-Port; alles, was er tut, geschieht
//! ausgehend gegen `POST /v1/ingest/batch`, `telemetry.v1.TelemetryIngest/StreamReadings`
//! und `POST /v1/gateways/{gateway_id}/heartbeat`.

use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use tokio::signal::unix::{signal, SignalKind};
use tracing::{error, info, warn};

mod config;
mod crypto;
mod error;
mod pipeline;
mod telemetry;
mod uplink;
mod wire;

use crate::config::GatewayConfig;
use crate::error::EdgeError;

/// Zwei Worker reichen: die Boxen im Depot haben zwei Kerne, und der teuerste Schritt
/// (Ed25519-Signatur über den fertigen Batch) läuft ohnehin auf einem Blocking-Thread.
#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            // Der Tracing-Subscriber steht hier eventuell noch nicht — deshalb zusätzlich stderr.
            error!(error = %err, code = err.envelope_code(), "Agent beendet sich mit Fehler");
            eprintln!("of-gateway-agentd: {err}");
            ExitCode::from(err.exit_code())
        }
    }
}

async fn run() -> Result<(), EdgeError> {
    let cfg = Arc::new(GatewayConfig::from_environment()?);
    observability::install(&cfg)?;

    info!(
        gateway_id = %cfg.gateway_id,
        serial = %cfg.serial,
        region_code = %cfg.region_code,
        firmware_version = %cfg.firmware_version,
        environment = %cfg.environment,
        ofwire_abi = wire::abi_version(),
        "Gateway-Agent startet"
    );

    // Der Schlüssel wird einmal geladen und danach nie wieder von der Platte gelesen. Sein
    // öffentlicher Teil steht in telemetry.device_gateways.public_key; passt er nicht, lehnt
    // telemetry-ingest jeden Batch mit `batch_signature_invalid` ab.
    let signer = crypto::Signer::load(&cfg)?;
    let identity = uplink::IdentityClient::new(Arc::clone(&cfg));

    // Beim Start hängt der Spool fast immer voll: das Depot war über Nacht offline oder der
    // Agent wurde für ein Firmware-Update neu gestartet. Erst öffnen, dann Uplink aufbauen.
    let spool = pipeline::Spool::open(&cfg.spool_dir, cfg.spool_max_bytes).await?;
    let recovered = spool.pending_batches();
    if recovered > 0 {
        warn!(recovered, "ungesendete Batches aus dem Spool übernommen");
    }

    let uplink = uplink::Uplink::connect(Arc::clone(&cfg), identity.clone(), signer.clone()).await?;
    let heartbeat = uplink::Heartbeat::spawn(Arc::clone(&cfg), identity.clone());
    let pipe = pipeline::Pipeline::start(Arc::clone(&cfg), spool, uplink)?;

    let mut sigterm = signal(SignalKind::terminate()).map_err(EdgeError::Signal)?;
    let mut sigint = signal(SignalKind::interrupt()).map_err(EdgeError::Signal)?;
    // SIGHUP lädt nur die Schwellwertdatei aus OF_TELEMETRY_RULES_PATH neu. Alles andere
    // (Region, Schlüssel, Endpunkte) erfordert einen echten Neustart — sonst laufen wir in
    // den Fall, dass ein halb umkonfigurierter Agent Batches in die falsche Region schickt,
    // die telemetry-ingest dann mit 403 verwirft statt sie umzuleiten.
    let mut sighup = signal(SignalKind::hangup()).map_err(EdgeError::Signal)?;

    loop {
        tokio::select! {
            _ = sigterm.recv() => { info!("SIGTERM empfangen"); break; }
            _ = sigint.recv()  => { info!("SIGINT empfangen"); break; }
            _ = sighup.recv()  => {
                match telemetry::RuleSet::reload(&cfg.rules_path) {
                    Ok(rules) => { pipe.swap_rules(rules); info!("Schwellwerte neu geladen"); }
                    Err(err) => warn!(error = %err, "Neuladen abgelehnt, alte Schwellwerte bleiben aktiv"),
                }
            }
        }
    }

    // OF_SHUTDOWN_GRACE_SECONDS liegt unter der Pod- bzw. systemd-Grace-Period. Was in dieser
    // Zeit nicht mehr hochgeht, bleibt im Spool und wird nach dem Neustart erneut gesendet —
    // der eindeutige Index readings_dedupe_idx auf telemetry.telemetry_readings macht das
    // Wiederholen zu einem No-op statt zu einem Duplikat.
    let grace = Duration::from_secs(cfg.shutdown_grace_seconds);
    match tokio::time::timeout(grace, pipe.drain()).await {
        Ok(Ok(flushed)) => info!(flushed, "Pipeline sauber geleert"),
        Ok(Err(err)) => warn!(error = %err, "Leeren der Pipeline unvollständig"),
        Err(_) => warn!(?grace, "Grace-Period abgelaufen, Rest bleibt im Spool"),
    }
    heartbeat.stop().await;

    info!("Gateway-Agent beendet");
    Ok(())
}

/// Logging und Tracing. Bewusst hier unten und nicht in einem eigenen Modul: es sind zwanzig
/// Zeilen, die nur `OF_LOG_LEVEL`, `OF_LOG_FORMAT` und `OF_OTEL_EXPORTER_ENDPOINT` auswerten.
mod observability {
    use super::{EdgeError, GatewayConfig};
    use tracing_subscriber::{fmt, prelude::*, EnvFilter};

    pub fn install(cfg: &GatewayConfig) -> Result<(), EdgeError> {
        let filter = EnvFilter::try_new(cfg.log_level.as_str())
            .map_err(|e| EdgeError::Config(format!("OF_LOG_LEVEL ungültig: {e}")))?;

        // `json` in jeder ausgerollten Umgebung, `text` nur lokal — §5.1. Die Depot-Logs
        // werden vom Node-Agenten eingesammelt und landen im selben Index wie die der Dienste,
        // deshalb müssen die Feldnamen (trace_id, gateway_id) identisch geschrieben sein.
        let registry = tracing_subscriber::registry().with(filter);
        if cfg.log_format_json {
            registry.with(fmt::layer().json().flatten_event(true)).init();
        } else {
            registry.with(fmt::layer().compact()).init();
        }
        Ok(())
    }
}
