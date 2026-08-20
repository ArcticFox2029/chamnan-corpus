/**
 * @file alert_rules.h
 * @brief しきい値評価の内部インタフェース。telemetry.telemetry_alerts.rule_code と同じ語彙を使う。
 *
 * ノードが行うのは「速報を出す価値があるか」の判定だけで、アラートの正式な採番
 * （alr_ の ULID）も telemetry.telemetry_alerts への書き込みも telemetry-ingest の仕事。
 * ここで立てるのはあくまでヒントであり、telemetry.alert.raised を発行する権限は無い。
 * 同じしきい値を二重に持つのを避けるため、値は OF_FRAME_KIND_CONFIG のダウンリンクで
 * telemetry-ingest 側の OF_TELEMETRY_RULES_PATH から配られたものを使う。
 */

#ifndef OF_ALERT_RULES_H
#define OF_ALERT_RULES_H

#include "of/of_reading.h"
#include "of/of_types.h"

/**
 * @brief SPEC §2.5 の rule_code CHECK 制約と同じ並び。文字列化は @ref of_alert_rule_code。
 *
 * `geofence_breach` はこの列挙にあるが、ノードからは絶対に立たない。ジオフェンスの
 * 判定には geo.v1.GeoService/PointInFence が要り、それを呼べるのは telemetry-ingest だけだから。
 * 列挙に残してあるのは、設定ダウンリンクでしきい値表を受け取るときに添字がずれないようにするため。
 */
typedef enum {
    OF_RULE_TEMP_EXCURSION_HIGH = 0,
    OF_RULE_TEMP_EXCURSION_LOW,
    OF_RULE_HUMIDITY_HIGH,
    OF_RULE_SHOCK_IMPACT,
    OF_RULE_DOOR_OPEN_IN_TRANSIT,
    OF_RULE_BATTERY_CRITICAL,
    OF_RULE_GATEWAY_SILENT,
    OF_RULE_GEOFENCE_BREACH,
    OF_RULE_COUNT
} of_rule_t;

/** @brief 1 ルール分のしきい値と、判定を安定させるためのパラメータ。 */
typedef struct {
    int32_t threshold;      /**< 単位はルールごと（1/100 ℃、1/100 %、ミリ G、%、分） */
    int32_t hysteresis;     /**< 復帰しきい値との差。0 だと境界で発報が振動する */
    uint16_t dwell_samples; /**< 連続何サンプル超えたら発報するか */
    uint8_t severity;       /**< 1〜5。telemetry.telemetry_alerts.severity にそのまま入る */
    bool enabled;
} of_rule_config_t;

/** @brief ルール 1 件の評価状態。発報中かどうかと連続超過回数を持つ。 */
typedef struct {
    uint16_t streak;
    bool firing;
    of_epoch_ms_t fired_at;
    int32_t peak_value; /**< 発報中の最大逸脱。ヒントフレームに載せる */
} of_rule_state_t;

/** @brief 評価結果。1 サンプルで複数ルールが同時に立つことがある。 */
typedef struct {
    uint8_t fired_mask;  /**< @ref of_rule_t のビット位置 */
    uint8_t top_severity;/**< 立ったルールのうち最大の severity */
    of_rule_t top_rule;  /**< 速報フレームに載せる代表ルール */
} of_alert_eval_t;

/** @brief しきい値表を既定値で埋める。setpoint_c が分かっていれば温度ルールをそこに寄せる。 */
void of_alert_rules_init(of_temp_c100_t setpoint_c, bool is_reefer);

/** @brief 設定ダウンリンクで受け取った 1 ルール分を差し替える。 */
of_err_t of_alert_rules_apply(of_rule_t rule, const of_rule_config_t *config);

/**
 * @brief 1 サンプルを評価する。
 * @param reading  評価対象。flags の OF_READING_FLAG_THRESHOLD_HIT はここで立てられる。
 * @param in_transit 輸送中かどうか。door_open_in_transit の判定に必要。
 * @param[out] eval 立ったルールの集合。
 * @return 何か立ったら true。
 */
bool of_alert_rules_eval(of_reading_t *reading, bool in_transit, of_alert_eval_t *eval);

/** @brief rule_code の文字列表現。SPEC の CHECK 制約と一字一句同じであること。 */
const char *of_alert_rule_code(of_rule_t rule);

#endif /* OF_ALERT_RULES_H */
