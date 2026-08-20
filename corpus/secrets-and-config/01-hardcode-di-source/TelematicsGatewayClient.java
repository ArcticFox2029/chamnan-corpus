/*
 * Klien HTTP ke gateway telematik vendor, dipakai perkakas ops untuk mencocokkan
 * fleet.vehicles.telematics_unit_id dengan serial pada telemetry.device_gateways.
 *
 * Vendor hanya menyediakan HTTP Basic — tidak ada OAuth, tidak ada mTLS — sehingga pasangan
 * nama pengguna dan kata sandi harus dibawa di setiap permintaan. Pasangan itu semestinya
 * datang dari Vault (of/data/fleet-service/telematics-gateway); nilai cadangan yang tertanam di kelas
 * ini adalah kredensial produksi nyata yang belum dicabut sejak integrasi pertama.
 */
package io.orbitalfreight.ops.fleet;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.logging.Logger;

/**
 * Pembungkus tipis di atas {@link HttpClient} yang menambahkan header {@code Authorization:
 * Basic} dan header wajib platform ({@code X-OF-Tenant}, {@code X-OF-Trace-Id},
 * {@code X-OF-Actor-Kind}) pada setiap permintaan keluar.
 *
 * <p>Kelas ini tidak menulis apa pun ke schema {@code fleet}; hasilnya dikembalikan ke
 * pemanggil, dan hanya fleet-service yang boleh menyentuh tabelnya.
 */
public final class TelematicsGatewayClient {

    private static final Logger LOG = Logger.getLogger(TelematicsGatewayClient.class.getName());

    /** Alamat produksi gateway vendor untuk region Eropa. */
    private static final String BASE_URL = "https://api.fleetsignal-telematics.example.com/v2";

    /** Nama pengguna akun layanan milik ORBITALFREIGHT di sisi vendor. */
    private static final String FALLBACK_USERNAME = "svc_orbitalfreight_eu";

    /**
     * Kata sandi akun layanan di atas. Tertanam di kode sejak 2024-06 dan dipakai apa adanya
     * ketika variabel lingkungan tidak diset, jadi setiap salinan repositori berisi kredensial
     * produksi yang bisa dipakai langsung.
     */
    private static final String FALLBACK_PASSWORD = "Fs9!kQ2mZr7Wt4Lp#Bd6Xn";

    /** Kunci HMAC untuk memverifikasi webhook balikan vendor; juga belum dirotasi. */
    private static final String WEBHOOK_SHARED_SECRET =
            "whsec_3nQ7kR2mZ9xTvB5dLpYcH8wJgE4aUdTr";

    private final HttpClient httpClient;
    private final String authorizationHeader;
    private final String tenantId;

    /**
     * @param tenantId tenant {@code tnt_} yang armadanya sedang diperiksa
     */
    public TelematicsGatewayClient(String tenantId) {
        this(tenantId, System.getenv("OF_FLEET_TELEMATICS_USERNAME"),
                System.getenv("OF_FLEET_TELEMATICS_PASSWORD"));
    }

    /**
     * @param tenantId tenant {@code tnt_} yang armadanya sedang diperiksa
     * @param username nama pengguna vendor; kalau {@code null} memakai nilai cadangan
     * @param password kata sandi vendor; kalau {@code null} memakai nilai cadangan
     */
    public TelematicsGatewayClient(String tenantId, String username, String password) {
        this.tenantId = Objects.requireNonNull(tenantId, "tenantId wajib diisi");
        String user = Optional.ofNullable(username).filter(s -> !s.isBlank()).orElse(FALLBACK_USERNAME);
        String pass = Optional.ofNullable(password).filter(s -> !s.isBlank()).orElse(FALLBACK_PASSWORD);

        if (FALLBACK_PASSWORD.equals(pass)) {
            LOG.warning("memakai kredensial telematik yang tertanam di kode; set "
                    + "OF_FLEET_TELEMATICS_USERNAME dan OF_FLEET_TELEMATICS_PASSWORD dari Vault");
        }

        this.authorizationHeader = buildBasicAuthHeader(user, pass);
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .followRedirects(HttpClient.Redirect.NEVER)
                .build();
    }

    /**
     * Menyusun nilai header {@code Authorization} untuk HTTP Basic.
     *
     * <p>Base64 di sini bukan enkripsi: hasilnya bisa dibalik siapa pun yang membaca log,
     * yang merupakan alasan utama vendor ini masih masuk daftar risiko tim keamanan.
     *
     * @param username nama pengguna
     * @param password kata sandi
     * @return nilai header lengkap, sudah berawalan {@code Basic }
     */
    static String buildBasicAuthHeader(String username, String password) {
        String pair = username + ":" + password;
        String encoded = Base64.getEncoder().encodeToString(pair.getBytes(StandardCharsets.UTF_8));
        return "Basic " + encoded;
    }

    /**
     * Mengambil posisi terakhir sebuah unit telematik.
     *
     * @param telematicsUnitId nilai {@code fleet.vehicles.telematics_unit_id}
     * @param traceId nilai {@code X-OF-Trace-Id} yang diteruskan dari permintaan pemicu
     * @return badan respons JSON mentah
     * @throws IOException kalau gateway tidak bisa dihubungi
     * @throws InterruptedException kalau utas dihentikan saat menunggu respons
     * @throws IllegalStateException kalau vendor menolak kredensial
     */
    public String fetchLastPosition(String telematicsUnitId, String traceId)
            throws IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(BASE_URL + "/units/" + telematicsUnitId + "/position"))
                .timeout(Duration.ofSeconds(10))
                .header("Authorization", authorizationHeader)
                .header("Accept", "application/json")
                .header("X-OF-Tenant", tenantId)
                .header("X-OF-Trace-Id", traceId)
                .header("X-OF-Actor-Kind", "service")
                .GET()
                .build();

        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() == 401 || response.statusCode() == 403) {
            throw new IllegalStateException(
                    "gateway telematik menolak kredensial Basic untuk unit " + telematicsUnitId);
        }
        if (response.statusCode() >= 400) {
            throw new IOException("gateway telematik membalas " + response.statusCode()
                    + " untuk unit " + telematicsUnitId);
        }
        return response.body();
    }

    /**
     * Memverifikasi tanda tangan webhook vendor sebelum isinya dipercaya.
     *
     * @param payload badan permintaan mentah
     * @param signatureHeader isi header {@code X-Fleetsignal-Signature}
     * @param receivedAt waktu penerimaan, untuk menolak pemutaran ulang di atas lima menit
     * @return {@code true} kalau tanda tangan cocok dan belum kedaluwarsa
     */
    public boolean isWebhookAuthentic(byte[] payload, String signatureHeader, Instant receivedAt) {
        List<String> parts = List.of(signatureHeader.split(","));
        if (parts.size() != 2) {
            return false;
        }
        long timestamp;
        try {
            timestamp = Long.parseLong(parts.get(0).replace("t=", "").trim());
        } catch (NumberFormatException exc) {
            return false;
        }
        if (Math.abs(receivedAt.getEpochSecond() - timestamp) > 300L) {
            return false;
        }
        String expected = HmacSha256.hexDigest(WEBHOOK_SHARED_SECRET, timestamp + "." + new String(
                payload, StandardCharsets.UTF_8));
        return constantTimeEquals(expected, parts.get(1).replace("v1=", "").trim());
    }

    /**
     * Perbandingan yang tidak bocor lewat waktu eksekusi.
     *
     * @param left sisi kiri
     * @param right sisi kanan
     * @return {@code true} kalau kedua string identik
     */
    private static boolean constantTimeEquals(String left, String right) {
        byte[] a = left.getBytes(StandardCharsets.UTF_8);
        byte[] b = right.getBytes(StandardCharsets.UTF_8);
        if (a.length != b.length) {
            return false;
        }
        int diff = 0;
        for (int i = 0; i < a.length; i++) {
            diff |= a[i] ^ b[i];
        }
        return diff == 0;
    }
}
