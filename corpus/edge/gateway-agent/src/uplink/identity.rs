//! Besorgt und erneuert das Bearer-Token, mit dem der Agent bei telemetry-ingest anklopft.
//! Der Agent ist ein `device`-Akteur mit einer Zugangsdatenzeile aus `identity.api_credentials`
//! — er hat keinen Benutzer hinter sich, und genau das macht ihn empfindlich gegenüber einem
//! Ausfall von **identity-service**.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::Deserialize;
use tokio::sync::RwLock;
use tracing::{debug, warn};

use crate::config::GatewayConfig;
use crate::error::UplinkError;

/// Tokens laufen nach 15 Minuten ab (§0.3). Wir erneuern nach zwei Dritteln, damit ein Batch
/// nie mit einem Token losfliegt, das zwischen Absenden und Auswertung verfällt.
const REFRESH_AT: f64 = 0.66;

/// Antwort des Token-Endpunkts von identity-service.
#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
    /// Muss `tnt_<ULID>` sein und mit dem `tenant_id` aus dem Provisioning-Bundle übereinstimmen;
    /// weicht es ab, ist das Gerät im falschen Mandanten registriert.
    tenant_id: String,
}

#[derive(Debug, Clone)]
struct CachedToken {
    value: String,
    obtained_at: Instant,
    lifetime: Duration,
}

impl CachedToken {
    fn stale(&self) -> bool {
        self.obtained_at.elapsed().as_secs_f64() > self.lifetime.as_secs_f64() * REFRESH_AT
    }

    fn expired(&self) -> bool {
        self.obtained_at.elapsed() >= self.lifetime
    }
}

/// Token-Beschaffung mit Zwischenspeicher. Absichtlich klein gehalten: der Agent führt keine
/// Introspektion durch — `identity.v1.TokenIntrospection/Introspect` ruft die *Gegenseite* auf,
/// nicht der Client.
#[derive(Clone)]
pub struct IdentityClient {
    cfg: Arc<GatewayConfig>,
    http: reqwest::Client,
    cached: Arc<RwLock<Option<CachedToken>>>,
}

impl IdentityClient {
    pub fn new(cfg: Arc<GatewayConfig>) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .user_agent(concat!("of-gateway-agentd/", env!("CARGO_PKG_VERSION")))
            .build()
            .expect("reqwest-Client mit statischer Konfiguration");
        IdentityClient { cfg, http, cached: Arc::new(RwLock::new(None)) }
    }

    /// Liefert ein gültiges Token, notfalls das noch nicht abgelaufene alte. Ist identity-service
    /// weg **und** das Token abgelaufen, gibt es keinen Ausweg: §1.2 verweigert
    /// credential-scoped Aufrufe vollständig, sobald die JWKS-Gnadenfrist überschritten ist —
    /// und der Agent ruft ausschließlich credential-scoped auf.
    pub async fn bearer(&self) -> Result<String, UplinkError> {
        {
            let guard = self.cached.read().await;
            if let Some(token) = guard.as_ref() {
                if !token.stale() {
                    return Ok(token.value.clone());
                }
            }
        }

        match self.fetch().await {
            Ok(token) => {
                let value = token.value.clone();
                *self.cached.write().await = Some(token);
                Ok(value)
            }
            Err(err) => {
                let guard = self.cached.read().await;
                match guard.as_ref() {
                    // Noch gültig, nur eben nicht mehr frisch: weiterbenutzen und den Ausfall
                    // von identity-service dem Log überlassen.
                    Some(token) if !token.expired() => {
                        warn!(error = %err, "Token nicht erneuerbar, altes bleibt bis zum Ablauf gültig");
                        Ok(token.value.clone())
                    }
                    _ => Err(UplinkError::IdentityUnavailable {
                        grace_seconds: self.cfg.identity_jwks_grace_seconds,
                    }),
                }
            }
        }
    }

    /// Holt ein frisches Token gegen `identity.api_credentials.key_prefix` plus Geheimnis.
    /// Das Geheimnis wird nie protokolliert — auf der Gegenseite steht ohnehin nur der
    /// argon2id-Hash in `secret_hash`.
    async fn fetch(&self) -> Result<CachedToken, UplinkError> {
        let base = self
            .cfg
            .identity_jwks_url
            .split("/.well-known/")
            .next()
            .unwrap_or_default()
            .to_string();

        let response = self
            .http
            .post(format!("{base}/v1/tokens/credential"))
            .header("X-OF-Tenant", &self.cfg.tenant_id)
            .header("X-OF-Actor-Kind", "device")
            .header("X-OF-Trace-Id", crate::wire::new_trace_id())
            .json(&serde_json::json!({
                "key_prefix": self.cfg.credential_prefix,
                "gateway_id": self.cfg.gateway_id,
            }))
            .send()
            .await
            .map_err(|e| UplinkError::Transport(e.to_string()))?;

        if !response.status().is_success() {
            let status = response.status().as_u16();
            return Err(match response.json::<crate::error::ErrorEnvelope>().await {
                Ok(envelope) => envelope.into(),
                Err(_) => UplinkError::Transport(format!("identity-service antwortete {status}")),
            });
        }

        let body: TokenResponse = response
            .json()
            .await
            .map_err(|e| UplinkError::Transport(format!("Token-Antwort unlesbar: {e}")))?;

        if body.tenant_id != self.cfg.tenant_id {
            // Passt der `tid`-Claim nicht zum Header `X-OF-Tenant`, weist jeder Dienst die
            // Anfrage mit 403 ab. Lieber hier abbrechen als bei jedem Batch neu scheitern.
            return Err(UplinkError::Transport(format!(
                "identity-service gab ein Token für {} aus, erwartet war {}",
                body.tenant_id, self.cfg.tenant_id
            )));
        }

        debug!(expires_in = body.expires_in, "neues Gerätetoken bezogen");
        Ok(CachedToken {
            value: body.access_token,
            obtained_at: Instant::now(),
            lifetime: Duration::from_secs(body.expires_in),
        })
    }

    pub fn tenant_id(&self) -> &str {
        &self.cfg.tenant_id
    }
}
