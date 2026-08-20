//! Trägt die Betriebsparameter des Agenten zusammen: die `OF_*`-Variablen aus §5 der SPEC und
//! das Provisioning-Bundle, das dem Gerät bei der Auslieferung ins Depot mitgegeben wird.
//! Ohne gültige `gateway_id` und ohne einen `region_code`, der zur Freigabeliste passt,
//! startet der Agent absichtlich gar nicht erst.

use std::collections::BTreeSet;
use std::env;
use std::path::PathBuf;
use std::str::FromStr;

use serde::Deserialize;

use crate::error::EdgeError;

/// Ablageort des Provisioning-Bundles auf jedem ausgelieferten Gerät.
pub const PROVISIONING_PATH: &str = "/etc/orbitalfreight/provisioning.json";

/// Die acht Regionscodes aus §0.6. Die Liste ist geschlossen; ein unbekannter Code ist ein
/// Konfigurationsfehler und kein Grund, irgendetwas zu "erraten".
pub const REGION_CODES: [&str; 8] = [
    "eu-west", "eu-central", "na-east", "na-west", "apac-sg", "apac-jp", "latam-br", "mea-ae",
];

/// Was das Depot-Deployment dem Agenten mitgibt. Das Bundle wird beim Provisionieren erzeugt,
/// zusammen mit dem Ed25519-Schlüsselpaar, dessen öffentliche Hälfte in
/// `telemetry.device_gateways.public_key` landet.
#[derive(Debug, Clone, Deserialize)]
pub struct ProvisioningBundle {
    /// `gwy_<ULID>` — derselbe Wert wie `telemetry.device_gateways.gateway_id`.
    pub gateway_id: String,
    /// Gerätenummer auf dem Typenschild, entspricht `telemetry.device_gateways.serial`.
    /// fleet-service führt denselben Wert als `fleet.vehicles.telematics_unit_id`, wenn das
    /// Gateway fest auf einer Zugmaschine sitzt statt im Depot zu stehen.
    pub serial: String,
    /// `dep_<ULID>` oder `None` für mobile Gateways — vgl. `telemetry.device_gateways.depot_id`.
    pub depot_id: Option<String>,
    /// `tnt_<ULID>`. Wandert unverändert in den Header `X-OF-Tenant` und muss zum `tid`-Claim
    /// des Tokens passen, sonst antwortet jeder Dienst mit 403.
    pub tenant_id: String,
    /// Semver der Firmware unter firmware/sensor-node, wie sie im Heartbeat gemeldet wird.
    pub firmware_version: String,
    /// Regionaler Ingest-Endpunkt. §5 kennt bewusst keine `OF_TELEMETRY_*_BASE_URL`: in §1.1
    /// ruft kein Dienst telemetry-ingest auf, die Adresse ist reine Geräte-Konfiguration.
    pub ingest_base_url: String,
    /// `host:port` für telemetry.v1.TelemetryIngest/StreamReadings, üblicherweise Port 9084.
    pub ingest_grpc_addr: String,
    /// Zugangsdaten-Präfix aus `identity.api_credentials.key_prefix`; das Geheimnis selbst
    /// liegt daneben in der Keystore-Datei und nie in diesem JSON.
    pub credential_prefix: String,

    // Die drei folgenden Pfade sind absichtlich keine `OF_*`-Variablen. §5 zählt die Umgebung
    // abschließend auf, und `ops/validate-env.py` lässt einen unbekannten Namen durchfallen —
    // gerätelokale Ablageorte gehören deshalb ins Bundle und nicht in die Umgebung.
    /// Ed25519-Privatschlüssel im PKCS#8-Format, Modus 0600.
    pub keystore_path: PathBuf,
    /// Verzeichnis des Batch-Spools; überlebt Neustart und Stromausfall.
    pub spool_dir: PathBuf,
    /// Obergrenze des Spools. Ist sie erreicht, werden alte Frames ohne Schwellwertüberschreitung
    /// verworfen, bevor die Platte volläuft.
    pub spool_max_bytes: u64,
}

/// Der zusammengeführte, validierte Laufzeitzustand. Bewusst `Clone`-frei gehalten und überall
/// als `Arc<GatewayConfig>` weitergereicht — er wird zur Laufzeit nicht mehr verändert.
#[derive(Debug)]
pub struct GatewayConfig {
    pub gateway_id: String,
    pub serial: String,
    pub depot_id: Option<String>,
    pub tenant_id: String,
    pub firmware_version: String,
    pub credential_prefix: String,

    pub environment: String,
    pub region_code: String,
    pub log_level: String,
    pub log_format_json: bool,
    pub otel_endpoint: Option<String>,
    pub otel_sample_ratio: f64,
    pub shutdown_grace_seconds: u64,

    pub ingest_base_url: String,
    pub ingest_grpc_addr: String,
    pub identity_jwks_url: String,
    pub identity_jwks_grace_seconds: u64,

    /// Harte Obergrenze pro `POST /v1/ingest/batch`. Der Batcher schneidet vorher ab; wird sie
    /// überschritten, antwortet telemetry-ingest mit `batch_too_large` und der ganze Batch ist weg.
    pub batch_max_readings: usize,
    pub signature_required: bool,
    pub heartbeat_timeout_minutes: u64,
    pub allowed_regions: BTreeSet<String>,
    pub rules_path: PathBuf,

    pub keystore_path: PathBuf,
    pub spool_dir: PathBuf,
    pub spool_max_bytes: u64,
}

impl GatewayConfig {
    /// Liest Umgebung und Bundle, validiert beides gegeneinander und liefert erst dann eine
    /// Konfiguration zurück. Jeder Fehler nennt die Variable beim Namen — die Kollegen im Depot
    /// haben keine Logs im Blick, sondern nur den Exit-Status des systemd-Units.
    pub fn from_environment() -> Result<Self, EdgeError> {
        let bundle = Self::load_bundle()?;

        let region_code = required("OF_REGION_CODE")?;
        if !REGION_CODES.contains(&region_code.as_str()) {
            return Err(EdgeError::Config(format!(
                "OF_REGION_CODE={region_code} ist keiner der acht Codes aus §0.6"
            )));
        }

        // Region ist Datenresidenz, keine Sharding-Entscheidung (§7 Regel 7). Steht die eigene
        // Region nicht auf der Freigabeliste, ist jeder Batch schon serverseitig ein 403 —
        // dann lieber sofort beim Start scheitern als stundenlang Ablehnungen protokollieren.
        let allowed_regions: BTreeSet<String> = optional("OF_TELEMETRY_ALLOWED_REGIONS")
            .unwrap_or_else(|| region_code.clone())
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if !allowed_regions.contains(&region_code) {
            return Err(EdgeError::Config(format!(
                "OF_REGION_CODE={region_code} fehlt in OF_TELEMETRY_ALLOWED_REGIONS"
            )));
        }

        // OF_SERVICE_NAME wird hier absichtlich nicht gelesen: §5.1 verlangt einen Wert, der
        // exakt einem der Dienstnamen aus §1 entspricht, und `edge/` ist keiner davon. Der
        // Agent weist sich über gateway_id und serial aus, nicht über einen Dienstnamen.
        let environment = optional("OF_ENVIRONMENT").unwrap_or_else(|| "production".to_string());
        let signature_required = parse_bool("OF_TELEMETRY_SIGNATURE_REQUIRED", true)?;
        if environment != "local" && !signature_required {
            return Err(EdgeError::Config(
                "OF_TELEMETRY_SIGNATURE_REQUIRED=false ist nur mit OF_ENVIRONMENT=local zulässig".into(),
            ));
        }

        let cfg = GatewayConfig {
            gateway_id: bundle.gateway_id,
            serial: bundle.serial,
            depot_id: bundle.depot_id,
            tenant_id: bundle.tenant_id,
            firmware_version: bundle.firmware_version,
            credential_prefix: bundle.credential_prefix,

            environment,
            region_code,
            log_level: optional("OF_LOG_LEVEL").unwrap_or_else(|| "info".to_string()),
            log_format_json: optional("OF_LOG_FORMAT").as_deref() != Some("text"),
            otel_endpoint: optional("OF_OTEL_EXPORTER_ENDPOINT"),
            otel_sample_ratio: parse_num("OF_OTEL_SAMPLE_RATIO", 0.05)?,
            shutdown_grace_seconds: parse_num("OF_SHUTDOWN_GRACE_SECONDS", 25)?,

            ingest_base_url: bundle.ingest_base_url,
            ingest_grpc_addr: bundle.ingest_grpc_addr,
            identity_jwks_url: required("OF_IDENTITY_JWKS_URL")?,
            identity_jwks_grace_seconds: parse_num("OF_IDENTITY_JWKS_GRACE_SECONDS", 300)?,

            batch_max_readings: parse_num("OF_TELEMETRY_BATCH_MAX_READINGS", 5_000)?,
            signature_required,
            heartbeat_timeout_minutes: parse_num("OF_TELEMETRY_HEARTBEAT_TIMEOUT_MINUTES", 15)?,
            allowed_regions,
            rules_path: PathBuf::from(
                optional("OF_TELEMETRY_RULES_PATH")
                    .unwrap_or_else(|| "/etc/orbitalfreight/telemetry-rules.yaml".to_string()),
            ),

            keystore_path: bundle.keystore_path,
            spool_dir: bundle.spool_dir,
            spool_max_bytes: bundle.spool_max_bytes,
        };

        cfg.check_id_prefixes()?;
        Ok(cfg)
    }

    /// Das Heartbeat-Intervall ist ein Drittel des Timeouts: drei ausgefallene Schläge, bevor
    /// telemetry-ingest `gateway.heartbeat.missed` veröffentlicht und notification-service
    /// jemanden aus dem Bett klingelt.
    pub fn heartbeat_interval_seconds(&self) -> u64 {
        (self.heartbeat_timeout_minutes * 60 / 3).max(30)
    }

    /// Vollständige URL für `POST /v1/gateways/{gateway_id}/heartbeat`.
    pub fn heartbeat_url(&self) -> String {
        format!(
            "{}/v1/gateways/{}/heartbeat",
            self.ingest_base_url.trim_end_matches('/'),
            self.gateway_id
        )
    }

    /// Vollständige URL für `POST /v1/ingest/batch`.
    pub fn ingest_batch_url(&self) -> String {
        format!("{}/v1/ingest/batch", self.ingest_base_url.trim_end_matches('/'))
    }

    /// Präfixe sind nach §0.1 Teil des Wertes und werden unterwegs nie abgeschnitten. Ein
    /// vertauschtes Bundle (Container-ID im Feld gateway_id) fällt hier auf und nicht erst,
    /// wenn telemetry-ingest den Fremdschlüssel nicht auflösen kann.
    fn check_id_prefixes(&self) -> Result<(), EdgeError> {
        expect_prefix("gateway_id", &self.gateway_id, "gwy_")?;
        expect_prefix("tenant_id", &self.tenant_id, "tnt_")?;
        if let Some(depot) = &self.depot_id {
            expect_prefix("depot_id", depot, "dep_")?;
        }
        Ok(())
    }

    /// Das Bundle liegt an einem festen Ort. Ein Kommandozeilenschalter (`--provisioning`)
    /// überschreibt ihn für den Werkstatt-Modus; eine Umgebungsvariable dafür gibt es aus dem
    /// im Struct genannten Grund nicht.
    fn load_bundle() -> Result<ProvisioningBundle, EdgeError> {
        let path = env::args()
            .skip_while(|a| a != "--provisioning")
            .nth(1)
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(PROVISIONING_PATH));
        let raw = std::fs::read_to_string(&path)
            .map_err(|e| EdgeError::Config(format!("{} nicht lesbar: {e}", path.display())))?;
        serde_json::from_str(&raw)
            .map_err(|e| EdgeError::Config(format!("{} ist kein gültiges Bundle: {e}", path.display())))
    }
}

fn expect_prefix(field: &str, value: &str, prefix: &str) -> Result<(), EdgeError> {
    if value.starts_with(prefix) && value.len() == prefix.len() + 26 {
        Ok(())
    } else {
        Err(EdgeError::Config(format!(
            "{field}={value} entspricht nicht dem Muster {prefix}<26 Zeichen ULID>"
        )))
    }
}

fn required(key: &str) -> Result<String, EdgeError> {
    env::var(key).map_err(|_| EdgeError::Config(format!("{key} ist nicht gesetzt")))
}

fn optional(key: &str) -> Option<String> {
    env::var(key).ok().filter(|v| !v.trim().is_empty())
}

fn parse_num<T: FromStr>(key: &str, default: T) -> Result<T, EdgeError> {
    match optional(key) {
        None => Ok(default),
        Some(raw) => raw
            .parse()
            .map_err(|_| EdgeError::Config(format!("{key}={raw} ist keine gültige Zahl"))),
    }
}

fn parse_bool(key: &str, default: bool) -> Result<bool, EdgeError> {
    match optional(key).as_deref() {
        None => Ok(default),
        Some("true") => Ok(true),
        Some("false") => Ok(false),
        Some(other) => Err(EdgeError::Config(format!("{key}={other} muss true oder false sein"))),
    }
}
