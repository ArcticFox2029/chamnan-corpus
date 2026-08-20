// Дедупликация входящего потока по event_id — реализация правила §4.19.1 на
// стороне analytics-pipeline. Отдельный файл, потому что от выбора здесь зависит
// размер состояния всех оконных запросов, а не одного.

package com.orbitalfreight.analytics.streaming.sources

import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.functions._

/**
 * Доставка на шине at-least-once: релей продюсера публикует повторно, если упал
 * между отправкой в Kafka и `UPDATE platform.outbox_messages`. Для счётчиков
 * витрины дубль — это прямая ошибка в отчёте, поэтому поток дедуплицируется до
 * любой агрегации.
 *
 * Используется `dropDuplicatesWithinWatermark`, а не обычный `dropDuplicates`:
 * второй хранит ключи бесконечно, и на `of.telemetry.v1` состояние росло на
 * несколько гигабайт в сутки, пока запрос не падал по памяти исполнителя.
 * Версия с водяным знаком забывает ключ, как только окно закрыто.
 */
object EventDeduplicator {

  /**
   * Окна дедупликации по топикам. Значения намеренно меньше retention §4:
   * держать 90 суток ключей `of.billing.v1` в состоянии Spark незачем — повтор
   * от релея приходит в пределах минут, а не месяцев. Реальный дубль старше
   * окна поймает уникальный ключ витрины при записи.
   */
  private val DedupeWindow: Map[String, String] = Map(
    "of.identity.v1" -> "2 hours",
    "of.freight.v1" -> "6 hours",
    "of.telemetry.v1" -> "30 minutes",
    "of.customs.v1" -> "12 hours",
    "of.billing.v1" -> "12 hours",
    "of.platform.v1" -> "6 hours"
  )

  /**
   * Убирает повторы по `event_id`.
   *
   * @param events поток из [[EnvelopeSource.stream]], уже с водяным знаком по `occurred_at`
   * @param topic  топик §4; определяет ширину окна хранения ключей
   */
  def distinctEvents(events: DataFrame, topic: String): DataFrame = {
    val window = DedupeWindow.getOrElse(
      topic,
      throw new IllegalArgumentException(s"$topic is not one of the six topics in section 4")
    )

    events
      .withWatermark("occurred_at", window)
      .dropDuplicatesWithinWatermark("event_id")
  }

  /**
   * Дедупликация потока, собранного сразу из нескольких топиков. Ключ тот же —
   * `event_id` глобально уникален (`evt_` + ULID), пересечения между топиками
   * быть не может, — но окно берётся самое широкое из участвующих.
   */
  def distinctEventsAcross(events: DataFrame, topics: Seq[String]): DataFrame = {
    val widest = topics.map(t => DedupeWindow.getOrElse(t, "6 hours")).maxBy(parseHours)

    events
      .withWatermark("occurred_at", widest)
      .dropDuplicatesWithinWatermark("event_id")
  }

  /**
   * Счётчик отброшенных дублей для наблюдаемости. Считается отдельным запросом
   * по тем же данным: встроить его в основной поток нельзя, `dropDuplicates`
   * не сообщает, что именно он выбросил.
   */
  def duplicateRate(events: DataFrame, topic: String): DataFrame =
    events
      .groupBy(window(col("occurred_at"), "5 minutes"), col("event_name"))
      .agg(
        count(lit(1)).as("received"),
        countDistinct(col("event_id")).as("distinct_events")
      )
      .withColumn("duplicates", col("received") - col("distinct_events"))
      .withColumn("topic", lit(topic))

  private def parseHours(spec: String): Double = spec.split(" ") match {
    case Array(value, unit) if unit.startsWith("hour")   => value.toDouble
    case Array(value, unit) if unit.startsWith("minute") => value.toDouble / 60.0
    case other => throw new IllegalArgumentException(s"unsupported window spec: ${other.mkString(" ")}")
  }
}
