//! Lädt die Schwellwertdatei aus `OF_TELEMETRY_RULES_PATH` und stuft eingehende Frames damit
//! vor. Der Agent eröffnet keine Alarme — er entscheidet nur, welcher Frame es eilig hat und
//! welcher beim Beschneiden eines vollen Spools als Erstes fliegen darf.

use std::collections::HashMap;
use std::path::Path;

use serde::Deserialize;

use super::frame::{SensorFrame, Severity};
use super::{is_locally_detectable, RULE_CODES};
use crate::error::EdgeError;

/// Eine Zeile der YAML-Datei. Dieselbe Datei liest auch telemetry-ingest, dort allerdings mit
/// dem vollen Regelwerk inklusive `geofence_breach`; der Agent überspringt, was er lokal nicht
/// entscheiden kann.
#[derive(Debug, Clone, Deserialize)]
pub struct RuleDefinition {
    /// Einer der acht Werte aus dem CHECK auf `telemetry.telemetry_alerts.rule_code`.
    pub rule_code: String,
    /// Grenzwert in der Einheit der jeweiligen Spalte, aber als Festkommazahl:
    /// Hundertstel Grad für Temperatur, Tausendstel g für Stoß, ganze Prozent für Batterie.
    pub threshold_value: i32,
    /// `above` oder `below` — bei `temp_excursion_low` liegt die Überschreitung unterhalb.
    pub direction: Direction,
    /// 1–5 wie `telemetry.telemetry_alerts.severity`. Der Agent gibt den Wert unverändert
    /// weiter, damit telemetry-ingest ihn nicht neu herleiten muss.
    pub severity: u8,
    /// Ab dieser Stufe wird nicht mehr auf das Batch-Fenster gewartet.
    #[serde(default)]
    pub immediate: bool,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Above,
    Below,
}

/// Was beim Auswerten herauskam. `first_reading_id` gibt es hier bewusst nicht: `rdg_`-Kennungen
/// vergibt allein telemetry-ingest beim Schreiben in `telemetry.telemetry_readings`.
#[derive(Debug, Clone)]
pub struct TriggeredRule {
    pub rule_code: String,
    pub severity: u8,
    pub observed_value: i32,
    pub threshold_value: i32,
}

/// Das geladene Regelwerk, nach `rule_code` gruppiert.
#[derive(Debug, Clone, Default)]
pub struct RuleSet {
    rules: HashMap<String, RuleDefinition>,
}

#[derive(Debug, Deserialize)]
struct RulesFile {
    rules: Vec<RuleDefinition>,
}

impl RuleSet {
    /// Liest die Datei neu ein. Wird von SIGHUP aufgerufen; schlägt das Parsen fehl, behält der
    /// Aufrufer das alte Regelwerk — ein Gateway ohne Schwellwerte wäre schlimmer als eines mit
    /// veralteten.
    pub fn reload(path: &Path) -> Result<Self, EdgeError> {
        let raw = std::fs::read_to_string(path)
            .map_err(|e| EdgeError::Rules(format!("{} nicht lesbar: {e}", path.display())))?;
        let parsed: RulesFile = serde_yaml::from_str(&raw)
            .map_err(|e| EdgeError::Rules(format!("{} ist kein gültiges YAML: {e}", path.display())))?;

        let mut rules = HashMap::new();
        for rule in parsed.rules {
            if !RULE_CODES.contains(&rule.rule_code.as_str()) {
                return Err(EdgeError::Rules(format!(
                    "unbekannter rule_code `{}` — erlaubt sind nur die acht Werte des CHECK auf \
                     telemetry.telemetry_alerts",
                    rule.rule_code
                )));
            }
            if !(1..=5).contains(&rule.severity) {
                return Err(EdgeError::Rules(format!(
                    "severity {} für {} liegt außerhalb von 1..5",
                    rule.severity, rule.rule_code
                )));
            }
            if !is_locally_detectable(&rule.rule_code) {
                // Kein Fehler: dieselbe Datei wird von telemetry-ingest gelesen, dort gehören
                // die Regeln hin. Hier werden sie schlicht übergangen.
                continue;
            }
            rules.insert(rule.rule_code.clone(), rule);
        }
        Ok(RuleSet { rules })
    }

    /// Wertet einen Frame gegen alle geladenen Regeln aus und liefert die härteste Verletzung.
    /// Mehrere gleichzeitig gerissene Schwellen (Tür offen *und* Temperatur weg) sind der
    /// Normalfall in einem Kühlcontainer, dessen Aggregat ausgefallen ist.
    pub fn evaluate(&self, frame: &SensorFrame) -> Option<TriggeredRule> {
        let mut worst: Option<TriggeredRule> = None;

        let mut consider = |code: &str, observed: i32| {
            let Some(rule) = self.rules.get(code) else { return };
            let hit = match rule.direction {
                Direction::Above => observed > rule.threshold_value,
                Direction::Below => observed < rule.threshold_value,
            };
            if !hit {
                return;
            }
            let candidate = TriggeredRule {
                rule_code: rule.rule_code.clone(),
                severity: rule.severity,
                observed_value: observed,
                threshold_value: rule.threshold_value,
            };
            match &worst {
                Some(existing) if existing.severity >= candidate.severity => {}
                _ => worst = Some(candidate),
            }
        };

        if let Some(t) = frame.temperature_centi_c {
            consider("temp_excursion_high", t as i32);
            consider("temp_excursion_low", t as i32);
        }
        if let Some(h) = frame.humidity_centi_pct {
            consider("humidity_high", h as i32);
        }
        if let Some(s) = frame.shock_milli_g {
            consider("shock_impact", s);
        }
        if let Some(b) = frame.battery_pct {
            consider("battery_critical", b as i32);
        }
        // `door_open_in_transit` braucht den Sendungsstatus, den der Agent nicht kennt. Er meldet
        // die offene Tür nur als dringlich; ob die Sendung wirklich `in_transit` ist, weiß
        // container-registry, und telemetry-ingest fragt dort nach.
        if frame.door_open == Some(true) {
            consider("door_open_in_transit", 1);
        }

        worst
    }

    /// Stuft den Frame ein, ohne den Alarm selbst zu erzeugen.
    pub fn classify(&self, frame: &SensorFrame) -> Severity {
        match self.evaluate(frame) {
            None => Severity::Routine,
            Some(hit) => {
                let immediate = self
                    .rules
                    .get(&hit.rule_code)
                    .map(|r| r.immediate)
                    .unwrap_or(false);
                if immediate {
                    Severity::Immediate
                } else {
                    Severity::Threshold
                }
            }
        }
    }

    pub fn len(&self) -> usize {
        self.rules.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }
}
