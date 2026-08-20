package com.orbitalfreight.analytics.streaming.sources

import com.orbitalfreight.analytics.streaming.JobConfig
import org.apache.spark.sql.functions._
import org.apache.spark.sql.types._
import org.apache.spark.sql.{Column, DataFrame, SparkSession}

/**
 * Источник событий для всех оконных агрегаций: подписка на топики §4, разбор
 * конверта §0.7 и отсечение чужого региона. Ни один агрегат не читает Kafka
 * напрямую — иначе схема конверта разъехалась бы по шести файлам.
 *
 * Конверт одинаков во всех топиках, различается только `payload`, поэтому здесь
 * он разбирается до `payload: STRING`, а типизацией полезной нагрузки занимается
 * уже конкретное окно: у `telemetry.alert.raised` и `billing.invoice.settled`
 * общего в payload нет ничего.
 */
object EnvelopeSource {

  /** Схема конверта §0.7. Порядок полей повторяет документ — так проще сверять
    * глазами при очередном изменении спецификации. */
  val EnvelopeSchema: StructType = StructType(
    Seq(
      StructField("event_id", StringType, nullable = false),
      StructField("event_name", StringType, nullable = false),
      StructField("schema_version", IntegerType, nullable = false),
      StructField("occurred_at", TimestampType, nullable = false),
      StructField("tenant_id", StringType, nullable = false),
      StructField("region_code", StringType, nullable = false),
      StructField("producer", StringType, nullable = false),
      StructField("trace_id", StringType, nullable = true),
      StructField("partition_key", StringType, nullable = false),
      // payload остаётся строкой: from_json по конкретной схеме вызывает окно,
      // которому эта схема нужна. Разбор всего payload здесь стоил бы полного
      // разбора JSON телеметрии — а это самый горячий топик платформы, 96 партиций.
      StructField("payload", StringType, nullable = true)
    )
  )

  /**
   * Подписывается на топики и отдаёт разобранный поток конвертов.
   *
   * `startingOffsets` = `earliest` только на холодном старте: при наличии
   * чекпойнта Spark игнорирует эту опцию, и глубина перечитывания определяется
   * `OF_ANALYTICS_BACKFILL_DAYS` плюс retention самого топика (§4).
   *
   * @param topics топики §4, например `Seq("of.telemetry.v1")`
   */
  def stream(spark: SparkSession, config: JobConfig, topics: Seq[String]): DataFrame = {
    val raw = spark.readStream
      .format("kafka")
      .option("kafka.bootstrap.servers", config.kafkaBrokers)
      .option("subscribe", topics.mkString(","))
      .option("startingOffsets", "earliest")
      .option("kafka.group.id", config.consumerGroup)
      // Ограничение на батч: без него первый запуск после недельного простоя
      // затягивает всю telemetry-очередь в один микробатч и падает по памяти.
      .option("maxOffsetsPerTrigger", 500000)
      // failOnDataLoss=false: retention of.telemetry.v1 — семь суток, и при
      // остановке задания дольше этого срока часть оффсетов исчезает законно.
      .option("failOnDataLoss", "false")
      .load()

    val parsed = raw
      .select(
        col("topic"),
        col("partition"),
        col("offset"),
        col("timestamp").as("broker_at"),
        from_json(col("value").cast(StringType), EnvelopeSchema).as("envelope")
      )
      .select(col("topic"), col("partition"), col("offset"), col("broker_at"), col("envelope.*"))

    residentOnly(parsed, config.regionCode)
      // Водяной знак ставится по времени события, а не по времени брокера: между
      // ними у офлайн-сканов из inspector-android бывают часы, и окно, закрытое
      // по broker_at, потеряло бы их целиком.
      .withWatermark("occurred_at", "30 minutes")
  }

  /**
   * Фильтр резидентности §7.7. Событие чужого региона не агрегируется и не
   * логируется; оно просто не доходит до плана запроса.
   */
  def residentOnly(events: DataFrame, regionCode: String): DataFrame =
    events.filter(col("region_code") === lit(regionCode))

  /** Отбор по имени события. Вынесено функцией, чтобы имена §4 не расползались
    * строковыми литералами по агрегациям. */
  def ofType(eventName: String): Column = col("event_name") === lit(eventName)

  /**
   * Разбор `payload` по схеме конкретного события и подъём его полей на верхний
   * уровень. Неизвестные поля payload игнорируются молча — этого требует §4.19.3,
   * и `from_json` со строгой схемой ведёт себя именно так.
   */
  def withPayload(events: DataFrame, payloadSchema: StructType): DataFrame =
    events
      .withColumn("body", from_json(col("payload"), payloadSchema))
      .drop("payload")
      .select(col("*"), col("body.*"))
      .drop("body")
}
