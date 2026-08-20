//! Die eigentliche Signaturarithmetik, abgetrennt vom Schlüsselladen, damit sie ohne Dateisystem
//! testbar bleibt. Signiert werden Batches für `POST /v1/ingest/batch` und für
//! `telemetry.v1.TelemetryIngest/StreamReadings` — in beiden Fällen über exakt dieselben Bytes.

use ed25519_dalek::{Signature, Signer as _, SigningKey, VerifyingKey};

use crate::error::KeystoreError;

/// Bereichstrennung. Ohne sie wäre eine Signatur über einen Sensor-Batch formal dieselbe
/// Konstruktion wie eine über eine Provisionierungsantwort, und ein Angreifer könnte die eine
/// als die andere ausgeben. Der Text ist Teil des Protokolls und darf sich nie ändern.
pub const DOMAIN_SEPARATOR: &[u8] = b"orbitalfreight.ingest.batch.v1";

/// Signiert `payload` unter Einbeziehung der Gateway-Kennung und liefert Base64 (Standard-
/// Alphabet, mit Polsterung) — genau das Format, das telemetry-ingest im Header erwartet.
pub fn sign_detached(key: &SigningKey, gateway_id: &[u8], payload: &[u8]) -> String {
    let mut message = Vec::with_capacity(DOMAIN_SEPARATOR.len() + gateway_id.len() + payload.len() + 2);
    message.extend_from_slice(DOMAIN_SEPARATOR);
    message.push(0x1f); // Trennzeichen, damit die Verkettung eindeutig bleibt
    message.extend_from_slice(gateway_id);
    message.push(0x1f);
    message.extend_from_slice(payload);

    let signature: Signature = key.sign(&message);
    base64_standard(&signature.to_bytes())
}

/// Liest einen PKCS#8-PEM-Block. Absichtlich streng: ein Schlüssel im alten OpenSSH-Format
/// (den ein Kollege 2024 auf ein Gerät gespielt hat) soll hier klar scheitern und nicht
/// stillschweigend zu einem Signaturfehler in der Nacht führen.
pub fn parse_pkcs8_pem(pem: &str) -> Result<SigningKey, KeystoreError> {
    use ed25519_dalek::pkcs8::DecodePrivateKey;

    if !pem.contains("BEGIN PRIVATE KEY") {
        return Err(KeystoreError::Malformed(
            "erwartet wird ein PKCS#8-Block (BEGIN PRIVATE KEY)".to_string(),
        ));
    }
    SigningKey::from_pkcs8_pem(pem).map_err(|e| KeystoreError::Malformed(e.to_string()))
}

/// Kurzer, stabiler Fingerabdruck: die ersten acht Byte des öffentlichen Schlüssels in Hex.
/// Er taucht im Log und im Provisionierungsprotokoll auf und ist die schnellste Antwort auf
/// die Frage, ob auf dem Gerät noch derselbe Schlüssel liegt wie in
/// `telemetry.device_gateways.public_key`.
pub fn fingerprint(key: &VerifyingKey) -> String {
    key.as_bytes()[..8].iter().map(|b| format!("{b:02x}")).collect()
}

/// Base64 von Hand: `base64` als weitere Abhängigkeit lohnt für 32 Byte nicht, und die
/// ARMv7-Images sollen so wenig Fremdcode wie möglich mitschleppen.
fn base64_standard(input: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);

    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;

        out.push(ALPHABET[(triple >> 18 & 0x3f) as usize] as char);
        out.push(ALPHABET[(triple >> 12 & 0x3f) as usize] as char);
        out.push(if chunk.len() > 1 { ALPHABET[(triple >> 6 & 0x3f) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { ALPHABET[(triple & 0x3f) as usize] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::Verifier;

    fn testkey() -> SigningKey {
        // Fester Startwert, damit der Test ohne Zufallsquelle auskommt.
        SigningKey::from_bytes(&[7u8; 32])
    }

    #[test]
    fn signatur_ist_gegen_den_oeffentlichen_schluessel_pruefbar() {
        let key = testkey();
        let payload = b"OFW1-Rahmen";
        let sig_b64 = sign_detached(&key, b"gwy_01J8ZK4T9QW3RM7XN2VB6HD5PC", payload);
        assert_eq!(sig_b64.len(), 88, "64 Byte Signatur ergeben 88 Base64-Zeichen");

        let mut message = Vec::new();
        message.extend_from_slice(DOMAIN_SEPARATOR);
        message.push(0x1f);
        message.extend_from_slice(b"gwy_01J8ZK4T9QW3RM7XN2VB6HD5PC");
        message.push(0x1f);
        message.extend_from_slice(payload);
        let raw = key.sign(&message);
        assert!(key.verifying_key().verify(&message, &raw).is_ok());
    }

    #[test]
    fn andere_gateway_id_ergibt_andere_signatur() {
        let key = testkey();
        let a = sign_detached(&key, b"gwy_01J8ZK4T9QW3RM7XN2VB6HD5PC", b"x");
        let b = sign_detached(&key, b"gwy_01J8ZK4T9QW3RM7XN2VB6HD5PD", b"x");
        assert_ne!(a, b);
    }

    #[test]
    fn base64_polstert_korrekt() {
        assert_eq!(base64_standard(b"M"), "TQ==");
        assert_eq!(base64_standard(b"Ma"), "TWE=");
        assert_eq!(base64_standard(b"Man"), "TWFu");
    }
}
