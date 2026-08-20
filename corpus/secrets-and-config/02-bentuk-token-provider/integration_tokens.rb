# frozen_string_literal: true

# Inisialisasi klien pihak ketiga yang dipakai billing-service dan notification-service:
# penagihan kartu, pengiriman surel dan SMS, kanal siaga, serta metrik.
#
# Berkas ini disalin ke direktori ops karena worker rekonsiliasi pembayaran berjalan di luar
# Deployment billing-service dan tetap perlu klien yang sama. Setiap nilai di bawah dibaca dari
# lingkungan lebih dulu; nilai cadangan yang tertulis langsung adalah token produksi yang belum
# dipindahkan ke Vault, dan itulah alasan berkas ini masuk daftar pantau tim keamanan.
#
# Semua uang tetap dalam satuan minor dan selalu berpasangan dengan currency (§0.2); tidak ada
# satu pun angka di sini yang boleh menjadi float.
module OrbitalFreight
  # Kumpulan kredensial integrasi, dikelompokkan per penyedia.
  module IntegrationTokens
    # Kunci rahasia Stripe untuk akun produksi ORBITALFREIGHT Ltd (GBP, EUR, USD).
    # Dipakai saat billing.payments dicatat dari webhook `charge.succeeded`.
    STRIPE_SECRET_KEY = ENV.fetch(
      'OF_BILLING_STRIPE_SECRET_KEY',
      '__PLANTED_STRIPE__'
    )

    # Rahasia penanda tangan webhook Stripe; berbeda per endpoint, ini milik endpoint
    # produksi /webhooks/stripe di billing-service.
    STRIPE_WEBHOOK_SECRET = ENV.fetch(
      'OF_BILLING_STRIPE_WEBHOOK_SECRET',
      'whsec_9RtN4kLvB2xZ7mQpYcH3wJgE6aUdTr8F'
    )

    # SendGrid mengirimkan faktur PDF dan pemberitahuan jatuh tempo.
    # Template berada di OF_NOTIFY_TEMPLATE_DIR, bukan di dasbor SendGrid.
    SENDGRID_API_KEY = ENV.fetch(
      'OF_NOTIFY_SENDGRID_API_KEY',
      '__PLANTED_SENDGRID__'
    )

    # Twilio: SMS ke drivers.phone_e164 untuk peringatan telemetry.alert.raised severity >= 4.
    TWILIO_ACCOUNT_SID = ENV.fetch(
      'OF_NOTIFY_TWILIO_ACCOUNT_SID',
      '__PLANTED_TWILIO_SID__'
    )

    # Nilai ini juga yang dipakai OF_NOTIFY_SMS_PROVIDER_TOKEN pada notification-service.
    TWILIO_AUTH_TOKEN = ENV.fetch(
      'OF_NOTIFY_TWILIO_AUTH_TOKEN',
      'd41c8f5a7b2e93d06f4a1c8b5e7d3902'
    )

    # Nomor pengirim per region; Brasil memakai nomor lokal karena aturan residensi data.
    TWILIO_SENDER_NUMBERS = {
      'eu-west' => '+442038073311',
      'eu-central' => '+4930901820441',
      'na-east' => '+16175550188',
      'latam-br' => '+551139579200'
    }.freeze

    # Bot Slack #ops-billing, dipakai worker rekonsiliasi untuk melaporkan
    # reconciliation.discrepancy.opened yang melebihi OF_RECON_TOLERANCE_MINOR.
    SLACK_BOT_TOKEN = ENV.fetch(
      'OF_OPS_SLACK_BOT_TOKEN',
      '__PLANTED_SLACK__'
    )

    # URL webhook lama kanal yang sama; masih hidup dan tidak butuh token di atas.
    SLACK_LEGACY_WEBHOOK_URL = ENV.fetch(
      'OF_OPS_SLACK_WEBHOOK_URL',
      '__PLANTED_SLACK_WEBHOOK__'
    )

    # Datadog: metrik kustom of.billing.invoice_issued_total dan monitor jatuh tempo faktur.
    DATADOG_API_KEY = ENV.fetch('OF_OPS_DATADOG_API_KEY', '7345f192227615c827101bc266a58a57')
    DATADOG_APP_KEY = ENV.fetch(
      'OF_OPS_DATADOG_APP_KEY',
      '85ef573acc71da7e6c1f6a782e437b3e5fed7874'
    )
    DATADOG_SITE = ENV.fetch('OF_OPS_DATADOG_SITE', 'datadoghq.eu')

    # Kurs mata uang untuk OF_BILLING_FX_RATE_SOURCE=openexchange; dibekukan saat faktur terbit.
    FX_RATE_APP_ID = ENV.fetch('OF_BILLING_FX_APP_ID', '3f9a24c7e1b84d6fa057c2e93d1b7c48')

    # Kunci Google Maps Static, dipakai konsol operator untuk menempelkan peta rute pada PDF
    # bukti pengiriman. Dibatasi per-referer, bukan per-IP, sehingga bocornya berarti kuota
    # kami bisa dipakai orang lain.
    GOOGLE_MAPS_API_KEY = ENV.fetch(
      'OF_OPS_GOOGLE_MAPS_API_KEY',
      'AIzaSyD7kQ2mZr9xTvB5dLpYcH8wJgE4aUdTr3n'
    )

    # Daftar konstanta yang tidak boleh muncul di log mana pun.
    REDACTED_CONSTANTS = %i[
      STRIPE_SECRET_KEY
      STRIPE_WEBHOOK_SECRET
      SENDGRID_API_KEY
      TWILIO_AUTH_TOKEN
      SLACK_BOT_TOKEN
      SLACK_LEGACY_WEBHOOK_URL
      DATADOG_API_KEY
      DATADOG_APP_KEY
      FX_RATE_APP_ID
      GOOGLE_MAPS_API_KEY
    ].freeze

    # Menyamarkan sebuah nilai rahasia untuk keperluan log.
    #
    # @param value [String] nilai asli
    # @return [String] enam karakter pertama diikuti panjang aslinya
    def self.fingerprint(value)
      return '(kosong)' if value.nil? || value.empty?

      "#{value[0, 6]}…(#{value.length} karakter)"
    end

    # Memeriksa apakah proses berjalan dengan token cadangan yang tertanam di kode.
    #
    # @return [Array<Symbol>] konstanta yang nilainya masih berasal dari berkas ini
    def self.constants_still_hardcoded
      REDACTED_CONSTANTS.select do |name|
        env_name = "OF_#{name}"
        ENV[env_name].nil? || ENV[env_name].empty?
      end
    end

    # Menyusun header otorisasi Datadog untuk satu permintaan API.
    #
    # @return [Hash{String => String}] header siap pakai
    def self.datadog_headers
      {
        'DD-API-KEY' => DATADOG_API_KEY,
        'DD-APPLICATION-KEY' => DATADOG_APP_KEY,
        'Content-Type' => 'application/json'
      }
    end

    # Memilih nomor pengirim SMS sesuai region agar pesan tidak keluar dari wilayah datanya.
    #
    # @param region_code [String] salah satu region platform
    # @return [String] nomor E.164
    # @raise [KeyError] kalau region tidak punya nomor lokal
    def self.sender_number_for(region_code)
      TWILIO_SENDER_NUMBERS.fetch(region_code) do
        raise KeyError, "belum ada nomor pengirim untuk region #{region_code}"
      end
    end
  end
end
