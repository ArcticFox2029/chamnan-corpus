/**
 * @file container_node_bench.ino
 * @brief 実機のコンテナノードを持ち出せない場所で、車載基板と telemetry-ingest を試験するための
 *        送信専用ベンチ。Feather M0 + RFM95 の市販ボードでノードの振る舞いを模倣する。
 *
 * 量産ファームではない。狙いは 2 つだけで、ひとつは vehicle-board の受信・組み立て・再送を
 * 実際の電波で叩くこと、もうひとつは温度逸脱のシナリオを机の上で再現して
 * telemetry.alert.raised から container-registry の at_risk までの経路を通すこと。
 * フレーム形式は本番と完全に同じ of_frame_encode を使うので、ここで通れば実機でも通る。
 *
 * 使い方: シリアルに `scenario cold` などと打つとその筋書きに切り替わる。
 * 筋書きの一覧は @ref kScenarios を見ること。
 */

#include <RH_RF95.h>
#include <SPI.h>
#include <Wire.h>

extern "C" {
#include "of/of_crc.h"
#include "of/of_reading.h"
}

/** @brief Feather M0 LoRa の配線。基板のシルク印刷どおり。 */
static const int kPinRadioCS = 8;
static const int kPinRadioInt = 3;
static const int kPinRadioReset = 4;

/** @brief 試験用の周波数。EU868 の g1 サブバンド。実験室の遮蔽箱の中でしか使わないこと。 */
static const float kFrequencyMHz = 868.1;

/** @brief ベンチが名乗るコンテナ。db/ のシードデータに入っている試験用の行と一致させてある。 */
static const char kContainerId[] = "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC";

/** @brief 送信周期。実機の 60 秒だと試験にならないので、既定は 5 秒。 */
static unsigned long g_periodMs = 5000;

RH_RF95 g_radio(kPinRadioCS, kPinRadioInt);

/**
 * @brief 試験シナリオ。温度の作り方だけが違う。
 *
 * `cold` と `hot` は container-node 側の temp_excursion_low / temp_excursion_high を
 * 意図的に踏みに行くもので、`normal` は逸脱しないことを確かめる対照群。
 * `flap` はしきい値の周りを往復させて、ヒステリシスが効いているか（速報が
 * 何十通も飛ばないか）を見るためにある。
 */
enum Scenario {
  kScenarioNormal = 0,
  kScenarioCold,
  kScenarioHot,
  kScenarioFlap,
  kScenarioCount
};

static const char *const kScenarios[kScenarioCount] = {"normal", "cold", "hot", "flap"};

static Scenario g_scenario = kScenarioNormal;
static uint16_t g_sequence = 0;
static unsigned long g_lastSendMs = 0;

/**
 * @brief シナリオに応じた温度（1/100 ℃）を作る。
 *
 * 乱数は使わない。再現しない試験は原因の切り分けに使えないので、
 * 連番から決まる決定的な波形にしてある。
 */
static of_temp_c100_t scenarioTemperature(uint16_t seq) {
  switch (g_scenario) {
    case kScenarioCold:
      // 5 分かけて -0.5 ℃ を割り込ませ、そのまま沈める。
      return static_cast<of_temp_c100_t>(400 - static_cast<int32_t>(seq) * 20);
    case kScenarioHot:
      return static_cast<of_temp_c100_t>(2000 + static_cast<int32_t>(seq) * 30);
    case kScenarioFlap:
      // しきい値 45.00 ℃ の直上と直下を交互に。ヒステリシス 1.00 ℃ が
      // 効いていれば、発報は最初の 1 回だけになるはず。
      return static_cast<of_temp_c100_t>((seq % 2 == 0) ? 4520 : 4480);
    case kScenarioNormal:
    default:
      return static_cast<of_temp_c100_t>(1800 + (seq % 5) * 10);
  }
}

/** @brief 湿度は筋書きに依存しない。結露側の試験は別のベンチ（恒温槽）で行う。 */
static of_humid_p100_t scenarioHumidity(uint16_t seq) {
  return static_cast<of_humid_p100_t>(5500 + (seq % 11) * 25);
}

/** @brief シリアルから来た 1 行を処理する。`scenario <名前>` と `period <ミリ秒>` だけ。 */
static void handleSerialLine(const String &line) {
  if (line.startsWith("scenario ")) {
    const String name = line.substring(9);
    for (int i = 0; i < kScenarioCount; ++i) {
      if (name == kScenarios[i]) {
        g_scenario = static_cast<Scenario>(i);
        g_sequence = 0;  // 筋書きを変えたら波形も最初から
        Serial.print(F("scenario -> "));
        Serial.println(kScenarios[i]);
        return;
      }
    }
    Serial.println(F("unknown scenario"));
    return;
  }

  if (line.startsWith("period ")) {
    const long ms = line.substring(7).toInt();
    if (ms >= 500 && ms <= 600000) {
      g_periodMs = static_cast<unsigned long>(ms);
      Serial.print(F("period -> "));
      Serial.println(g_periodMs);
    } else {
      Serial.println(F("period out of range"));
    }
    return;
  }

  Serial.println(F("commands: scenario <normal|cold|hot|flap>, period <ms>"));
}

void setup() {
  Serial.begin(115200);
  while (!Serial && millis() < 5000) {
    // USB が来るまで少し待つ。来なければ待たずに進む（電源だけ挿した運用のため）。
  }

  pinMode(kPinRadioReset, OUTPUT);
  digitalWrite(kPinRadioReset, HIGH);
  delay(10);
  digitalWrite(kPinRadioReset, LOW);
  delay(10);
  digitalWrite(kPinRadioReset, HIGH);
  delay(10);

  if (!g_radio.init()) {
    Serial.println(F("RFM95 init failed"));
    while (true) {
      delay(1000);
    }
  }

  g_radio.setFrequency(kFrequencyMHz);
  g_radio.setTxPower(14, false);
  // 実機の既定と同じ SF10 / BW125 / CR4-5。ここを変えると airtime が変わり、
  // vehicle-board 側の受信率の比較ができなくなる。
  g_radio.setSpreadingFactor(10);
  g_radio.setSignalBandwidth(125000);
  g_radio.setCodingRate4(5);

  of_crc_prime_tables();

  Serial.println(F("ORBITALFREIGHT container node bench ready"));
  Serial.print(F("container_id = "));
  Serial.println(kContainerId);
}

void loop() {
  if (Serial.available() > 0) {
    const String line = Serial.readStringUntil('\n');
    handleSerialLine(line);
  }

  if (millis() - g_lastSendMs < g_periodMs) {
    return;
  }
  g_lastSendMs = millis();

  of_reading_t reading;
  of_reading_init(&reading, kContainerId);
  reading.recorded_at = static_cast<of_epoch_ms_t>(millis());
  reading.temperature_c = scenarioTemperature(g_sequence);
  reading.humidity_pct = scenarioHumidity(g_sequence);
  reading.shock_g = (g_sequence % 17 == 0) ? 4200 : 120;  // たまに衝撃を混ぜる
  reading.battery_pct = static_cast<of_battery_pct_t>(100 - (g_sequence / 40));
  reading.sequence = g_sequence++;

  if (g_scenario == kScenarioFlap && (g_sequence % 8) == 0) {
    // 扉開放も往復させる。door_open_in_transit の dwell_samples が
    // 効いていれば、こちらも発報は抑えられる。
    reading.flags |= OF_READING_FLAG_DOOR_OPEN;
  }

  uint8_t frame[64];
  size_t frameLen = 0;

  if (of_frame_encode(&reading, 1, OF_FRAME_KIND_READING, frame, sizeof(frame), &frameLen) != OF_OK) {
    Serial.println(F("encode failed"));
    return;
  }

  g_radio.send(frame, static_cast<uint8_t>(frameLen));
  g_radio.waitPacketSent();

  Serial.print(F("sent seq="));
  Serial.print(reading.sequence);
  Serial.print(F(" temp="));
  Serial.print(reading.temperature_c);
  Serial.print(F(" len="));
  Serial.println(static_cast<int>(frameLen));
}
