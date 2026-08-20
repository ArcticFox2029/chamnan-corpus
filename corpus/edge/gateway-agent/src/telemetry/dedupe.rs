//! Hält ein gleitendes Fenster bereits gesehener Messungen, damit ein Sensor, der seinen
//! Puffer nach einer Funklücke komplett noch einmal ausspuckt, nicht denselben Wert dreimal
//! in denselben Batch bringt. Das ist die Vorstufe zu `readings_dedupe_idx` auf
//! `telemetry.telemetry_readings` — nur eben schon vor der Funkstrecke.

use std::collections::{HashMap, VecDeque};

use super::frame::SensorFrame;

/// Ein Container meldet alle 30 Sekunden; zwei Stunden Rückschau reichen für jede Funklücke,
/// die noch als "Lücke" und nicht als "Ausfall" durchgeht.
const WINDOW_MS: i64 = 2 * 60 * 60 * 1000;

/// Obergrenze, damit ein Depot mit 400 Containern das Fenster nicht ins Unendliche wachsen
/// lässt. Erreicht der Ringpuffer sie, fällt der jeweils älteste Eintrag heraus — schlimmstenfalls
/// entsteht dadurch ein Duplikat, das der eindeutige Index serverseitig ohnehin schluckt.
const MAX_ENTRIES: usize = 200_000;

/// Sichtfenster über `(container_id, recorded_at_ms)`.
pub struct DedupeWindow {
    seen: HashMap<(String, i64), ()>,
    order: VecDeque<(String, i64)>,
    /// Zähler für die Metrik `gateway_frames_deduplicated_total`.
    dropped: u64,
}

impl DedupeWindow {
    pub fn new() -> Self {
        DedupeWindow {
            seen: HashMap::with_capacity(8192),
            order: VecDeque::with_capacity(8192),
            dropped: 0,
        }
    }

    /// `true`, wenn der Frame neu ist und weiterverarbeitet werden soll. Bereits gesehene
    /// Frames werden gezählt und still verworfen — eine Warnung pro Duplikat würde nach einer
    /// Funklücke das halbe Log füllen.
    pub fn admit(&mut self, frame: &SensorFrame) -> bool {
        let (container, recorded_at) = frame.dedupe_key();
        let key = (container.to_string(), recorded_at);

        if self.seen.contains_key(&key) {
            self.dropped += 1;
            return false;
        }

        self.seen.insert(key.clone(), ());
        self.order.push_back(key);
        self.evict(recorded_at);
        true
    }

    /// Entfernt alles, was älter als `WINDOW_MS` ist, gemessen an der jüngsten gesehenen
    /// Sensoruhr — nicht an der Systemuhr. Ein Gateway, das nach einem Stromausfall mit einer
    /// zurückgesetzten RTC hochkommt, würde sonst sein ganzes Fenster in einem Rutsch leeren.
    fn evict(&mut self, newest_ms: i64) {
        let horizon = newest_ms - WINDOW_MS;
        while let Some(front) = self.order.front() {
            if front.1 < horizon || self.order.len() > MAX_ENTRIES {
                let stale = self.order.pop_front().expect("front war eben noch da");
                self.seen.remove(&stale);
            } else {
                break;
            }
        }
    }

    pub fn dropped_total(&self) -> u64 {
        self.dropped
    }

    pub fn tracked(&self) -> usize {
        self.seen.len()
    }
}

impl Default for DedupeWindow {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::telemetry::frame::Severity;

    fn frame(container: &str, ms: i64) -> SensorFrame {
        SensorFrame {
            container_id: container.to_string(),
            recorded_at_ms: ms,
            temperature_centi_c: Some(410),
            humidity_centi_pct: None,
            shock_milli_g: None,
            door_open: Some(false),
            battery_pct: Some(88),
            position: None,
            severity: Severity::Routine,
        }
    }

    #[test]
    fn wiederholung_desselben_frames_wird_verworfen() {
        let mut w = DedupeWindow::new();
        let f = frame("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", 1_710_400_000_000);
        assert!(w.admit(&f));
        assert!(!w.admit(&f));
        assert_eq!(w.dropped_total(), 1);
    }

    #[test]
    fn gleiche_uhrzeit_verschiedene_container_sind_kein_duplikat() {
        let mut w = DedupeWindow::new();
        assert!(w.admit(&frame("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", 42_000)));
        assert!(w.admit(&frame("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PD", 42_000)));
        assert_eq!(w.tracked(), 2);
    }

    #[test]
    fn alte_eintraege_fallen_aus_dem_fenster() {
        let mut w = DedupeWindow::new();
        let alt = frame("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", 1_000_000);
        assert!(w.admit(&alt));
        assert!(w.admit(&frame("cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", 1_000_000 + WINDOW_MS + 1)));
        // Der alte Eintrag ist heraus, dieselbe Uhrzeit gilt wieder als neu.
        assert!(w.admit(&alt));
    }
}
