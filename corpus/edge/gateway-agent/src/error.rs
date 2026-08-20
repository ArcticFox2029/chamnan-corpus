//! Sämtliche Fehlerarten des Agenten an einer Stelle, samt der Übersetzung in die
//! `code`-Werte der Fehlerhülle aus §0.4. Wichtig ist hier vor allem die Frage, die jede
//! Fehlervariante beantworten muss: darf der Batch wiederholt werden oder ist er verloren?

use std::fmt;
use std::io;

use serde::Deserialize;
use thiserror::Error;

/// Oberster Fehlertyp; alles, was aus `main` herausfällt, ist eine dieser Varianten.
#[derive(Debug, Error)]
pub enum EdgeError {
    #[error("Konfiguration: {0}")]
    Config(String),

    #[error("Signalbehandlung konnte nicht installiert werden: {0}")]
    Signal(#[source] io::Error),

    #[error("Schlüsselspeicher: {0}")]
    Keystore(#[from] KeystoreError),

    #[error("Spool: {0}")]
    Spool(#[from] SpoolError),

    #[error("Uplink: {0}")]
    Uplink(#[from] UplinkError),

    #[error("Wire-Codec: {0}")]
    Wire(#[from] WireError),

    #[error("Schwellwertdatei: {0}")]
    Rules(String),
}

impl EdgeError {
    /// Der `code`-Wert, unter dem dieser Fehler in strukturierten Logs auftaucht. Die Schreibweise
    /// ist snake_case wie in §0.4, damit die Depot-Logs im selben Dashboard filterbar sind wie
    /// die Antworten von telemetry-ingest.
    pub fn envelope_code(&self) -> &'static str {
        match self {
            EdgeError::Config(_) => "gateway_config_invalid",
            EdgeError::Signal(_) => "gateway_signal_setup_failed",
            EdgeError::Keystore(_) => "gateway_keystore_unusable",
            EdgeError::Spool(_) => "gateway_spool_failure",
            EdgeError::Uplink(e) => e.envelope_code(),
            EdgeError::Wire(_) => "gateway_frame_malformed",
            EdgeError::Rules(_) => "gateway_rules_invalid",
        }
    }

    /// systemd unterscheidet nur zwischen "neu starten" und "aufgeben". Konfigurations- und
    /// Schlüsselfehler wiederholen sich beim Neustart identisch, also melden wir 78 (EX_CONFIG)
    /// und lassen `Restart=on-failure` das Gerät in Ruhe.
    pub fn exit_code(&self) -> u8 {
        match self {
            EdgeError::Config(_) | EdgeError::Keystore(_) => 78,
            _ => 1,
        }
    }
}

#[derive(Debug, Error)]
pub enum KeystoreError {
    #[error("{0} nicht lesbar: {1}")]
    Unreadable(String, #[source] io::Error),

    #[error("{0} hat Modus {1:o}, erwartet wird 0600")]
    Permissions(String, u32),

    #[error("kein gültiger PKCS#8-Ed25519-Schlüssel: {0}")]
    Malformed(String),

    /// Der öffentliche Teil im Bundle passt nicht zum privaten Schlüssel auf der Platte. In dem
    /// Fall würde telemetry-ingest jeden Batch gegen `telemetry.device_gateways.public_key`
    /// prüfen und ablehnen — besser gar nicht erst senden.
    #[error("Schlüsselpaar passt nicht zusammen (Fingerabdruck {found}, erwartet {expected})")]
    Mismatch { expected: String, found: String },
}

#[derive(Debug, Error)]
pub enum SpoolError {
    #[error("Spool-Verzeichnis {0} konnte nicht geöffnet werden: {1}")]
    Open(String, #[source] io::Error),

    #[error("Segment {segment} ist ab Byte {offset} beschädigt")]
    Corrupt { segment: String, offset: u64 },

    #[error("Spool ist voll ({used} von {limit} Byte)")]
    Full { used: u64, limit: u64 },

    #[error("Schreibfehler: {0}")]
    Io(#[from] io::Error),

    /// Der Batch ließ sich gar nicht erst kodieren — praktisch immer eine Kennung, die nicht
    /// dem Muster aus §0.1 entspricht, oder ein Regionscode außerhalb von §0.6.
    #[error("Batch nicht kodierbar: {0}")]
    Encode(#[from] WireError),
}

/// Fehler des Uplinks. Die Trennung zwischen `Transport` und `Rejected` ist die wichtigste im
/// ganzen Agenten: Transportfehler kommen zurück in den Spool, fachliche Ablehnungen nicht.
#[derive(Debug, Error)]
pub enum UplinkError {
    #[error("Verbindung zu telemetry-ingest fehlgeschlagen: {0}")]
    Transport(String),

    #[error("Zeitüberschreitung nach {millis} ms")]
    Timeout { millis: u64 },

    /// identity-service ist nicht erreichbar und das zwischengespeicherte JWKS ist älter als
    /// `OF_IDENTITY_JWKS_GRACE_SECONDS`. Nach §1.2 werden credential-scoped Aufrufe dann
    /// vollständig verweigert — und der Agent ruft ausschließlich credential-scoped auf.
    #[error("Token nicht erneuerbar, JWKS-Gnadenfrist von {grace_seconds}s abgelaufen")]
    IdentityUnavailable { grace_seconds: u64 },

    /// Eine Antwort mit Fehlerhülle nach §0.4.
    #[error("telemetry-ingest hat abgelehnt: {code} (HTTP {http_status})")]
    Rejected {
        code: String,
        http_status: u16,
        retryable: bool,
        trace_id: String,
    },
}

impl UplinkError {
    /// Steuert das Backoff. §4.19 gibt für Kafka-Konsumenten acht Versuche mit exponentiellem
    /// Backoff ab 500 ms vor; der Uplink hält sich an dieselbe Kurve, damit ein Depot nach einer
    /// Netzunterbrechung nicht in derselben Sekunde wie alle anderen wieder anklopft.
    pub fn retryable(&self) -> bool {
        match self {
            UplinkError::Transport(_) | UplinkError::Timeout { .. } => true,
            UplinkError::IdentityUnavailable { .. } => true,
            UplinkError::Rejected { retryable, .. } => *retryable,
        }
    }

    pub fn envelope_code(&self) -> &'static str {
        match self {
            UplinkError::Transport(_) => "gateway_uplink_transport",
            UplinkError::Timeout { .. } => "gateway_uplink_timeout",
            UplinkError::IdentityUnavailable { .. } => "gateway_identity_unavailable",
            // Der fachliche Code steht im Feld `code`; für die Metrik reicht der Oberbegriff.
            UplinkError::Rejected { .. } => "gateway_batch_rejected",
        }
    }
}

/// Die Fehlerhülle aus §0.4, so wie wir sie brauchen. `fields` wird bewusst nur als Rohtext
/// mitgeführt: der Agent kann eine Feldangabe ohnehin nicht reparieren, sie gehört ins Log.
#[derive(Debug, Deserialize)]
pub struct ErrorEnvelope {
    pub error: ErrorBody,
}

#[derive(Debug, Deserialize)]
pub struct ErrorBody {
    pub code: String,
    pub http_status: u16,
    pub message: String,
    pub trace_id: String,
    pub retryable: bool,
    #[serde(default)]
    pub fields: Vec<serde_json::Value>,
}

impl From<ErrorEnvelope> for UplinkError {
    fn from(env: ErrorEnvelope) -> Self {
        UplinkError::Rejected {
            code: env.error.code,
            http_status: env.error.http_status,
            retryable: env.error.retryable,
            trace_id: env.error.trace_id,
        }
    }
}

/// Fehler aus der Zig-Bibliothek. Die Varianten spiegeln `ofwire.DecodeError` eins zu eins;
/// die Zuordnung passiert in `wire::status_to_error`.
#[derive(Debug, Error, Clone, Copy, PartialEq, Eq)]
pub enum WireError {
    #[error("Magic-Bytes passen nicht, das ist kein OFW1-Rahmen")]
    BadMagic,
    #[error("Formatversion wird nicht unterstützt")]
    UnsupportedVersion,
    #[error("Prüfsumme stimmt nicht")]
    ChecksumMismatch,
    #[error("Rahmen endet mitten im Feld")]
    Truncated,
    #[error("Varint länger als zehn Byte")]
    VarintOverflow,
    #[error("Feldwert liegt außerhalb des erlaubten Bereichs")]
    ValueOutOfRange,
    #[error("Zielpuffer zu klein")]
    BufferTooSmall,
}

/// Kurzform für Logzeilen: `frame_decode_failed reason=checksum_mismatch`.
impl WireError {
    pub fn reason(self) -> &'static str {
        match self {
            WireError::BadMagic => "bad_magic",
            WireError::UnsupportedVersion => "unsupported_version",
            WireError::ChecksumMismatch => "checksum_mismatch",
            WireError::Truncated => "truncated",
            WireError::VarintOverflow => "varint_overflow",
            WireError::ValueOutOfRange => "value_out_of_range",
            WireError::BufferTooSmall => "buffer_too_small",
        }
    }
}

impl fmt::Display for ErrorBody {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} [{}] trace={}", self.message, self.code, self.trace_id)
    }
}
