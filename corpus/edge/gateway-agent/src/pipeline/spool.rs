//! Der Batch-Spool: ein segmentiertes Log auf der lokalen Platte, das eine Funklücke von
//! mehreren Tagen überbrückt. Er ist der Grund, warum ein Depot ohne Leitung trotzdem keine
//! Messwerte verliert — und warum jeder Batch seinen `ingest_batch_id` über den Neustart hinweg
//! behält, denn nur so bleibt die Wiederholung für telemetry-ingest ein No-op.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::fs::{self, File, OpenOptions};
use tokio::io::AsyncWriteExt;
use tokio::sync::Mutex;
use tracing::{info, warn};

use super::batcher::Batch;
use crate::error::SpoolError;
use crate::wire;

/// Ein Segment fasst 8 MiB; danach wird gerollt. Kleine Segmente kosten Verzeichniseinträge,
/// große kosten beim Beschneiden Granularität — 8 MiB entspricht rund einer Stunde Depotbetrieb.
const SEGMENT_BYTES: u64 = 8 * 1024 * 1024;

/// Kopfzeile jedes Segments: Magic, Formatversion, Segmentnummer.
const SEGMENT_MAGIC: &[u8; 8] = b"OFSPOOL1";

/// Ein Eintrag im Spool, wie ihn der Uplink-Task herausnimmt.
#[derive(Debug, Clone)]
pub struct SpooledBatch {
    pub ingest_batch_id: String,
    pub region_code: String,
    pub trace_id: String,
    pub readings: usize,
    pub priority: bool,
    /// Der fertig kodierte OFW1-Rahmen. Er wird genau einmal gebaut — beim Ablegen — und danach
    /// unverändert wiederholt, weil die Ed25519-Signatur sonst nicht mehr passen würde.
    pub encoded: Arc<Vec<u8>>,
    /// Wie oft dieser Batch schon erfolglos gesendet wurde. Nach acht Versuchen wandert er in
    /// `spool/dead/`, analog zur DLQ-Regel aus §4.19 für Kafka-Konsumenten.
    pub attempts: u8,
}

/// Der Spool. `clone()` teilt denselben Zustand; Batcher und Uplink halten je eine Kopie.
#[derive(Clone)]
pub struct Spool {
    inner: Arc<Mutex<Inner>>,
    dir: PathBuf,
    limit_bytes: u64,
}

struct Inner {
    queue: VecDeque<SpooledBatch>,
    current: Option<File>,
    current_bytes: u64,
    segment_no: u64,
    used_bytes: u64,
    /// Zähler für `gateway_spool_dropped_total`; jeder Wert über Null ist ein Datenverlust,
    /// den die Depot-Übersicht in der Konsole anzeigt.
    dropped: u64,
}

impl Spool {
    /// Öffnet das Verzeichnis und liest ungesendete Segmente wieder ein. Beschädigte Segmente
    /// (halber Schreibvorgang beim Stromausfall) werden bis zum letzten gültigen Eintrag
    /// gelesen und der Rest abgeschnitten — ein Batch verloren ist besser als der ganze Spool.
    pub async fn open(dir: &Path, limit_bytes: u64) -> Result<Self, SpoolError> {
        fs::create_dir_all(dir)
            .await
            .map_err(|e| SpoolError::Open(dir.display().to_string(), e))?;
        fs::create_dir_all(dir.join("dead"))
            .await
            .map_err(|e| SpoolError::Open(dir.display().to_string(), e))?;

        let mut queue = VecDeque::new();
        let mut used_bytes = 0u64;
        let mut segment_no = 0u64;

        let mut entries = fs::read_dir(dir)
            .await
            .map_err(|e| SpoolError::Open(dir.display().to_string(), e))?;
        let mut segments: Vec<PathBuf> = Vec::new();
        while let Some(entry) = entries.next_entry().await.map_err(SpoolError::Io)? {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("seg") {
                used_bytes += entry.metadata().await.map(|m| m.len()).unwrap_or(0);
                segments.push(path);
            }
        }
        // Segmentnamen sind nullgepolstert (`000017.seg`), damit die lexikografische Sortierung
        // gleichzeitig die zeitliche ist.
        segments.sort();

        for segment in &segments {
            match Self::replay_segment(segment).await {
                Ok(batches) => {
                    segment_no = segment_no.max(Self::segment_number(segment));
                    queue.extend(batches);
                }
                Err(err) => warn!(segment = %segment.display(), error = %err, "Segment übersprungen"),
            }
        }

        info!(
            segments = segments.len(),
            batches = queue.len(),
            used_bytes,
            "Spool geöffnet"
        );

        Ok(Spool {
            inner: Arc::new(Mutex::new(Inner {
                queue,
                current: None,
                current_bytes: 0,
                segment_no,
                used_bytes,
                dropped: 0,
            })),
            dir: dir.to_path_buf(),
            limit_bytes,
        })
    }

    /// Kodiert den Batch mit dem Zig-Codec, hängt ihn ans aktuelle Segment und macht ihn für
    /// den Uplink sichtbar. Liefert die Anzahl geschriebener Bytes.
    pub async fn append(&self, batch: &Batch) -> Result<usize, SpoolError> {
        let encoded = wire::encode_batch(batch)?;

        let mut inner = self.inner.lock().await;
        if inner.used_bytes + encoded.len() as u64 > self.limit_bytes {
            self.trim(&mut inner, encoded.len() as u64)?;
        }

        if inner.current.is_none() || inner.current_bytes >= SEGMENT_BYTES {
            inner.segment_no += 1;
            let path = self.dir.join(format!("{:06}.seg", inner.segment_no));
            let mut file = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .await
                .map_err(|e| SpoolError::Open(path.display().to_string(), e))?;
            file.write_all(SEGMENT_MAGIC).await?;
            inner.current = Some(file);
            inner.current_bytes = SEGMENT_MAGIC.len() as u64;
        }

        let file = inner.current.as_mut().expect("Segment wurde eben geöffnet");
        // Längenpräfix, dann Rahmen. Die Prüfsumme steckt im Rahmen selbst (crc32c.zig), es
        // braucht hier keine zweite.
        file.write_all(&(encoded.len() as u32).to_le_bytes()).await?;
        file.write_all(&encoded).await?;
        // Kein fsync pro Batch: die Depot-SSDs schaffen das bei 15 Frames pro Sekunde nicht, und
        // ein Stromausfall kostet höchstens das letzte Segmentende, das beim Start abgeschnitten
        // wird. Bei dringenden Batches ist der Verlust dagegen teuer — die werden durchgereicht.
        if batch.has_priority() {
            file.sync_data().await?;
        }

        let written = encoded.len() + 4;
        inner.current_bytes += written as u64;
        inner.used_bytes += written as u64;
        inner.queue.push_back(SpooledBatch {
            ingest_batch_id: batch.ingest_batch_id.clone(),
            region_code: batch.region_code.clone(),
            trace_id: batch.trace_id.clone(),
            readings: batch.len(),
            priority: batch.has_priority(),
            encoded: Arc::new(encoded),
            attempts: 0,
        });
        Ok(written)
    }

    /// Nächster zu sendender Batch, ohne ihn zu entfernen. Erst die Quittung von
    /// telemetry-ingest nimmt ihn endgültig heraus.
    pub async fn peek(&self) -> Option<SpooledBatch> {
        self.inner.lock().await.queue.front().cloned()
    }

    /// Batch wurde mit 2xx quittiert.
    pub async fn commit(&self, ingest_batch_id: &str) {
        let mut inner = self.inner.lock().await;
        if inner.queue.front().map(|b| b.ingest_batch_id.as_str()) == Some(ingest_batch_id) {
            if let Some(done) = inner.queue.pop_front() {
                inner.used_bytes = inner.used_bytes.saturating_sub(done.encoded.len() as u64 + 4);
            }
        }
    }

    /// Senden fehlgeschlagen. Ab acht Versuchen wandert der Batch nach `spool/dead/` und blockiert
    /// die Warteschlange nicht länger — dieselbe Grenze, die §4.19 für vergiftete Nachrichten
    /// auf `<topic>.dlq` zieht.
    pub async fn defer(&self, ingest_batch_id: &str) -> u8 {
        let mut inner = self.inner.lock().await;
        let Some(front) = inner.queue.front_mut() else { return 0 };
        if front.ingest_batch_id != ingest_batch_id {
            return 0;
        }
        front.attempts = front.attempts.saturating_add(1);
        let attempts = front.attempts;
        if attempts >= 8 {
            let dead = inner.queue.pop_front().expect("front war eben noch da");
            warn!(
                ingest_batch_id = %dead.ingest_batch_id,
                readings = dead.readings,
                "Batch nach acht Versuchen ausgesteuert"
            );
            inner.dropped += dead.readings as u64;
        }
        attempts
    }

    /// Fachlich abgelehnter Batch (`retryable=false`). Wiederholen ändert nichts, also raus damit.
    pub async fn discard(&self, ingest_batch_id: &str, code: &str) {
        let mut inner = self.inner.lock().await;
        if inner.queue.front().map(|b| b.ingest_batch_id.as_str()) == Some(ingest_batch_id) {
            let dropped = inner.queue.pop_front().expect("front war eben noch da");
            inner.dropped += dropped.readings as u64;
            warn!(ingest_batch_id, code, readings = dropped.readings, "Batch endgültig verworfen");
        }
    }

    pub fn pending_batches(&self) -> usize {
        self.inner.try_lock().map(|i| i.queue.len()).unwrap_or(0)
    }

    /// Macht Platz, indem Routine-Batches von vorne wegfallen. Batches mit
    /// Schwellwertüberschreitung bleiben liegen, auch wenn sie älter sind: sie sind die einzigen,
    /// aus denen telemetry-ingest überhaupt einen Alarm bauen kann.
    fn trim(&self, inner: &mut Inner, needed: u64) -> Result<(), SpoolError> {
        let mut freed = 0u64;
        let mut kept: VecDeque<SpooledBatch> = VecDeque::with_capacity(inner.queue.len());
        while let Some(batch) = inner.queue.pop_front() {
            if freed >= needed {
                kept.push_back(batch);
                continue;
            }
            if batch.priority {
                kept.push_back(batch);
                continue;
            }
            freed += batch.encoded.len() as u64 + 4;
            inner.dropped += batch.readings as u64;
        }
        inner.queue = kept;
        inner.used_bytes = inner.used_bytes.saturating_sub(freed);

        if freed < needed {
            return Err(SpoolError::Full { used: inner.used_bytes, limit: self.limit_bytes });
        }
        warn!(freed_bytes = freed, "Spool beschnitten, Routine-Batches verworfen");
        Ok(())
    }

    /// Liest ein Segment zurück in Speicherobjekte. Der Rahmen wird dabei nicht dekodiert —
    /// er geht so, wie er ist, wieder auf die Leitung, samt Signatur.
    async fn replay_segment(path: &Path) -> Result<Vec<SpooledBatch>, SpoolError> {
        let raw = fs::read(path).await.map_err(SpoolError::Io)?;
        if raw.len() < SEGMENT_MAGIC.len() || &raw[..SEGMENT_MAGIC.len()] != SEGMENT_MAGIC {
            return Err(SpoolError::Corrupt { segment: path.display().to_string(), offset: 0 });
        }

        let mut out = Vec::new();
        let mut offset = SEGMENT_MAGIC.len();
        while offset + 4 <= raw.len() {
            let len = u32::from_le_bytes(raw[offset..offset + 4].try_into().unwrap()) as usize;
            offset += 4;
            if len == 0 || offset + len > raw.len() {
                // Abgeschnittener Schwanz nach einem Stromausfall — alles davor ist gültig.
                break;
            }
            let frame = raw[offset..offset + len].to_vec();
            offset += len;

            match wire::inspect_batch(&frame) {
                Ok(head) => out.push(SpooledBatch {
                    ingest_batch_id: head.ingest_batch_id,
                    region_code: head.region_code,
                    trace_id: head.trace_id,
                    readings: head.reading_count,
                    priority: head.priority,
                    encoded: Arc::new(frame),
                    attempts: 0,
                }),
                Err(err) => warn!(
                    segment = %path.display(),
                    offset,
                    reason = err.reason(),
                    "Eintrag im Spool unlesbar"
                ),
            }
        }
        Ok(out)
    }

    fn segment_number(path: &Path) -> u64 {
        path.file_stem()
            .and_then(|s| s.to_str())
            .and_then(|s| s.parse().ok())
            .unwrap_or(0)
    }
}
