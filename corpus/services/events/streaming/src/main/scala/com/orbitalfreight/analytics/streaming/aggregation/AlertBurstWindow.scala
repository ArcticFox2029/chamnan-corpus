package com.orbitalfreight.analytics.streaming.aggregation

import com.orbitalfreight.analytics.streaming.sources.EnvelopeSource
import org.apache.spark.sql.functions._
import org.apache.spark.sql.types._
import org.apache.spark.sql.DataFrame

/**
 * Оконная агрегация `telemetry.alert.raised`: пятнадцатиминутные тумблинг-окна по
 * контейнеру и правилу, из которых видно не отдельный алерт, а серию. Серия —
 * это то, что интересует людей: один `shock_impact` на рейс бывает у любого
 * контейнера, три подряд означают, что груз роняют.
 *
 * Результат ложится в витрину и попадает в поле `excursion_alerts` витрины
 * `analytics.mv_lane_performance_daily`, которую ночью пересобирает батчевая
 * половина analytics-pipeline. Само событие публикует telemetry-ingest, и
 * потребителей у него пятеро (§4.9) — мы лишь один из них и ни на что не влияем:
 * в `at_risk` отгрузку переводит container-registry, а не эта агрегация.
 */
object AlertBurstWindow {

  /** Схема payload события §4.9. `threshold_value` и `peak_value` — это
    * `NUMERIC(10,3)` из `telemetry.telemetry_alerts`, поэтому Decimal, а не
    * Double: единица измерения зависит от `rule_code`, и терять третий знак
    * на температуре рефрижератора нельзя. */
  val PayloadSchema: StructType = StructType(
    Seq(
      StructField("alert_id", StringType),
      StructField("container_id", StringType),
      StructField("shipment_id", StringType),
      StructField("rule_code", StringType),
      StructField("severity", IntegerType),
      StructField("threshold_value", DecimalType(10, 3)),
      StructField("peak_value", DecimalType(10, 3)),
      StructField("first_reading_id", StringType),
      StructField("opened_at", TimestampType)
    )
  )

  /** Ширина окна. Пятнадцать минут — компромисс: короче, и серия из трёх ударов
    * на плохой дороге распадается по разным окнам; длиннее, и витрина перестаёт
    * различать два независимых инцидента за час. */
  private val WindowDuration = "15 minutes"

  /** Начиная с этого числа алертов в окне серия считается всплеском. */
  private val BurstThreshold = 3

  /**
   * Считает окна по (tenant_id, container_id, rule_code).
   *
   * Группировка включает `tenant_id`, хотя `container_id` глобально уникален:
   * так строка витрины остаётся самодостаточной, и отчёту не нужен join к
   * `freight.containers` в чужой схеме ради одного столбца.
   */
  def aggregate(events: DataFrame): DataFrame = {
    val alerts = EnvelopeSource.withPayload(
      events.filter(EnvelopeSource.ofType("telemetry.alert.raised")),
      PayloadSchema
    )

    alerts
      .groupBy(
        window(col("occurred_at"), WindowDuration),
        col("tenant_id"),
        col("region_code"),
        col("container_id"),
        col("rule_code")
      )
      .agg(
        count(lit(1)).as("alert_count"),
        max(col("severity")).as("max_severity"),
        max(col("peak_value")).as("worst_peak_value"),
        // Порог одинаков внутри правила, но берём первый, а не min: изменение
        // OF_TELEMETRY_RULES_PATH посреди окна иначе выглядело бы как аномалия.
        first(col("threshold_value")).as("threshold_value"),
        min(col("occurred_at")).as("first_alert_at"),
        max(col("occurred_at")).as("last_alert_at"),
        // shipment_id в событии может быть пустым: telemetry-ingest резолвит его
        // через freight.v1.ContainerLookup/ResolveShipmentForContainer, и для
        // контейнера, лежащего на депо вне рейса, ответа там нет.
        countDistinct(col("shipment_id")).as("shipments_touched"),
        collect_set(col("alert_id")).as("alert_ids")
      )
      .withColumn("window_start", col("window.start"))
      .withColumn("window_end", col("window.end"))
      .withColumn("business_date", to_date(col("window.start")))
      .withColumn("is_burst", col("alert_count") >= lit(BurstThreshold))
      .drop("window")
  }

  /**
   * Только всплески — узкий поток для дежурной панели в веб-консоли. Отдельный
   * запрос, а не фильтр над общим: у панели свой чекпойнт и свой темп триггера,
   * и она не должна ждать записи полной витрины.
   */
  def bursts(events: DataFrame): DataFrame =
    aggregate(events)
      .filter(col("is_burst"))
      // Порядок внутри микробатча не гарантирован, сортировка нужна только для
      // читаемости паркета: панель всё равно сортирует сама.
      .select(
        col("tenant_id"),
        col("region_code"),
        col("container_id"),
        col("rule_code"),
        col("max_severity"),
        col("alert_count"),
        col("worst_peak_value"),
        col("threshold_value"),
        col("first_alert_at"),
        col("last_alert_at"),
        col("business_date")
      )
}
