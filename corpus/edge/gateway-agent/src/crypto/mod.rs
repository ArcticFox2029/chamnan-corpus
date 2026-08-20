//! Schlüsselverwaltung des Gateways. Jedes Gerät hat genau ein Ed25519-Schlüsselpaar; die
//! öffentliche Hälfte steht in `telemetry.device_gateways.public_key` und ist der einzige Grund,
//! warum telemetry-ingest einem Batch überhaupt glaubt.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;

use ed25519_dalek::SigningKey;
use tracing::info;

mod ed25519;

pub use ed25519::{fingerprint, DOMAIN_SEPARATOR};

use crate::config::GatewayConfig;
use crate::error::KeystoreError;

/// Der Signierer. `Clone` teilt denselben Schlüssel — geladen wird er genau einmal beim Start,
/// danach berührt niemand mehr die Platte.
#[derive(Clone)]
pub struct Signer {
    key: Arc<SigningKey>,
    gateway_id: String,
}

impl Signer {
    /// Lädt den Privatschlüssel und prüft die Dateirechte. Ein Schlüssel, den die halbe Depot-
    /// Mannschaft lesen kann, ist keiner — und ein Gateway, dessen Schlüssel kompromittiert ist,
    /// kann beliebige Messwerte für beliebige Container erfinden.
    pub fn load(cfg: &GatewayConfig) -> Result<Self, KeystoreError> {
        let path = &cfg.keystore_path;
        check_permissions(path)?;

        let pem = std::fs::read_to_string(path)
            .map_err(|e| KeystoreError::Unreadable(path.display().to_string(), e))?;
        let key = ed25519::parse_pkcs8_pem(&pem)?;

        let fp = fingerprint(&key.verifying_key());
        info!(
            gateway_id = %cfg.gateway_id,
            fingerprint = %fp,
            "Signierschlüssel geladen"
        );

        Ok(Signer { key: Arc::new(key), gateway_id: cfg.gateway_id.clone() })
    }

    /// Signiert einen fertigen OFW1-Rahmen und liefert die Signatur base64-kodiert, so wie sie
    /// im Header `X-OF-Gateway-Signature` steht. Signiert wird über den Rahmen *inklusive*
    /// Kopfteil und Prüfsumme: sonst könnte ein Angreifer die Regionsangabe im Kopf ändern und
    /// Messwerte in eine fremde LIST-Partition von `telemetry.telemetry_readings` schreiben.
    pub fn sign_batch(&self, encoded: &[u8]) -> String {
        ed25519::sign_detached(&self.key, self.gateway_id.as_bytes(), encoded)
    }

    /// Fingerabdruck des öffentlichen Schlüssels, wie ihn das Provisioning-Protokoll ausweist.
    pub fn public_fingerprint(&self) -> String {
        fingerprint(&self.key.verifying_key())
    }
}

/// 0600 und nichts anderes. Der Vergleich maskiert bewusst nur die unteren neun Bits — das
/// setuid-Bit auf einer Schlüsseldatei wäre ein eigenes Problem, aber keins der Zugriffsrechte.
fn check_permissions(path: &Path) -> Result<(), KeystoreError> {
    let meta = std::fs::metadata(path)
        .map_err(|e| KeystoreError::Unreadable(path.display().to_string(), e))?;
    let mode = meta.permissions().mode() & 0o777;
    if mode != 0o600 {
        return Err(KeystoreError::Permissions(path.display().to_string(), mode));
    }
    Ok(())
}
