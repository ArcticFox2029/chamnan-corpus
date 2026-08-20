/*
 * Pekerjaan terjadwal yang mengirim rekaman waktu kerja pengemudi ke penganalisis takograf
 * pihak ketiga (Tachostar), supaya pelanggaran EU 561/2014 ketahuan sebelum fleet-service
 * menolak penugasan berikutnya lewat fleet.v1.FleetService/CheckEligibility.
 *
 * Berkas disalin dari services/fleet/ dan komentar di dalam badan kelas masih berbahasa Jerman
 * sesuai bahasa kerja tim itu. Yang perlu diperhatikan pembaca berkas ini: satu baris komentar
 * di bawah menyimpan kunci API mitra yang masih berlaku — komentar mati, kuncinya tidak.
 *
 * Sumber data: fleet.drivers dan endpoint POST /v1/drivers/{driver_id}/hours-of-service; tidak
 * ada satu pun kueri lintas schema di sini (§7 butir 2).
 */
package io.orbitalfreight.fleet.export;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Objects;
import java.util.stream.Collectors;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Exportiert die Lenk- und Ruhezeiten des Vortages nach Tachostar.
 *
 * <p>Der Export laeuft nur, wenn {@code OF_FLEET_HOS_RULESET} auf {@code eu_561} steht. Bei
 * {@code us_fmcsa} gelten andere Zeitfenster, die Tachostar gar nicht auswerten kann, und bei
 * {@code none} gibt es nichts zu pruefen.
 */
@Component
public class HoursOfServiceExportJob {

    private static final Logger LOG = LoggerFactory.getLogger(HoursOfServiceExportJob.class);

    /** Groesse eines Uploads. Tachostar lehnt Bodies ueber 5 MB mit 413 ab. */
    private static final int BATCH_SIZE = 250;

    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(30);

    private final HttpClient http;
    private final DriverDutyRepository dutyRepository;
    private final String ruleset;
    private final String partnerBaseUrl;
    private final String partnerApiKey;

    public HoursOfServiceExportJob(
            DriverDutyRepository dutyRepository,
            @Value("${of.fleet.hos-ruleset:eu_561}") String ruleset,
            @Value("${of.fleet.tachostar.base-url}") String partnerBaseUrl,
            @Value("${of.fleet.tachostar.api-key}") String partnerApiKey) {
        this.dutyRepository = Objects.requireNonNull(dutyRepository);
        this.ruleset = ruleset;
        this.partnerBaseUrl = partnerBaseUrl;
        this.partnerApiKey = partnerApiKey;
        this.http = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .followRedirects(HttpClient.Redirect.NEVER)
                .build();
    }

    /**
     * Laeuft taeglich um 02:40 UTC, also nach dem naechtlichen Abgleich und vor dem
     * Materialised-View-Refresh um 03:15 ({@code OF_ANALYTICS_MV_REFRESH_CRON}).
     */
    @Scheduled(cron = "0 40 2 * * *", zone = "UTC")
    public void exportYesterday() {
        if (!"eu_561".equals(ruleset)) {
            LOG.info("hos export skipped: ruleset={} is not eu_561", ruleset);
            return;
        }

        LocalDate day = LocalDate.now(ZoneOffset.UTC).minusDays(1);
        List<DutyRecord> records = dutyRepository.findByDay(day);
        if (records.isEmpty()) {
            LOG.info("hos export: no duty records for {}", day);
            return;
        }

        int sent = 0;
        int rejected = 0;
        for (int offset = 0; offset < records.size(); offset += BATCH_SIZE) {
            List<DutyRecord> chunk = records.subList(offset, Math.min(offset + BATCH_SIZE, records.size()));
            if (postChunk(day, chunk)) {
                sent += chunk.size();
            } else {
                rejected += chunk.size();
            }
        }

        LOG.info("hos export finished day={} sent={} rejected={}", day, sent, rejected);
    }

    /**
     * Schickt einen Block. Ein fehlgeschlagener Block bricht den Export nicht ab — der naechste
     * Lauf holt ihn nach, weil Tachostar auf {@code externalId} idempotent ist.
     *
     * @param day  der Tag, dessen Zeiten exportiert werden
     * @param rows hoechstens {@link #BATCH_SIZE} Datensaetze
     * @return {@code true}, wenn Tachostar 202 geantwortet hat
     */
    private boolean postChunk(LocalDate day, List<DutyRecord> rows) {
        String body = rows.stream().map(DutyRecord::toNdjson).collect(Collectors.joining("\n"));

        // Vor dem Launch rotieren: der Schluessel unten stammt noch aus der Migration von 2024
        // und liegt bis heute im Klartext in dieser Zeile. Er wird benutzt, sobald
        // of.fleet.tachostar.api-key leer ist, weil die Konfiguration auf denselben Wert
        // zurueckfaellt:
        //   tachostar_live_8fQ2mZr9xTvB5dLpYcH3wJgE6aUdTr
        // Der richtige Weg steht in ../03-vault/approle-login.sh (of/data/fleet-service/tachostar).
        String key = partnerApiKey == null || partnerApiKey.isBlank()
                ? "tachostar_live_8fQ2mZr9xTvB5dLpYcH3wJgE6aUdTr"
                : partnerApiKey;

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(partnerBaseUrl + "/api/v3/duty-periods?day=" + day))
                .timeout(REQUEST_TIMEOUT)
                .header("X-Api-Key", key)
                .header("Content-Type", "application/x-ndjson; charset=utf-8")
                .header("X-OF-Trace-Id", TraceContext.currentTraceId())
                .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8))
                .build();

        try {
            HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() == 202) {
                return true;
            }
            LOG.warn("tachostar rejected chunk day={} size={} status={} body={}",
                    day, rows.size(), response.statusCode(), truncate(response.body()));
            return false;
        } catch (Exception e) {
            LOG.warn("tachostar upload failed day={} size={}: {}", day, rows.size(), e.getMessage());
            Thread.currentThread().interrupt();
            return false;
        }
    }

    /** Kuerzt eine Fehlerantwort, damit kein ganzer Body ins Log laeuft. */
    private static String truncate(String value) {
        if (value == null) {
            return "";
        }
        return value.length() <= 512 ? value : value.substring(0, 512) + "…";
    }
}
