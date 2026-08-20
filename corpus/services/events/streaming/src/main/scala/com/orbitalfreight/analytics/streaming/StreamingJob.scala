package com.orbitalfreight.analytics.streaming

import com.orbitalfreight.analytics.streaming.aggregation.{AlertBurstWindow, LaneTransitWindow, LifecycleEvent, SettlementLagJoin}
import com.orbitalfreight.analytics.streaming.sinks.{MaterialisedViewRefresher, WarehouseSink}
import com.orbitalfreight.analytics.streaming.sources.{EnvelopeSource, EventDeduplicator}
import org.apache.spark.sql.functions._
import org.apache.spark.sql.types._
import org.apache.spark.sql.{Dataset, SparkSession}
import org.slf4j.LoggerFactory

/**
 * Точка входа потоковой половины analytics-pipeline. Задание поднимает три
 * независимых запроса над топиками §4 и складывает их результат в витрину, из
 * которой ночью пересобираются `analytics.mv_lane_performance_daily` и
 * `analytics.mv_container_utilisation_weekly`.
 *
 * Запросы независимы намеренно. У них разный темп (алерты — минуты, рейсы — дни),
 * разный объём состояния и разная цена перезапуска, и общий чекпойнт заставил бы
 * перечитывать телеметрию всякий раз, когда падает соединение по счетам.
 *
 * Чего задание не делает:
 *
 *   - не пишет ни в одну схему, кроме `analytics`. Чужие схемы читаются только
 *     ролью `of_analytics_ro` и только как справочники (§2, §7.2);
 *   - не вызывает синхронно никого, кроме identity-service, container-registry и
 *     geo-service — это весь исходящий список analytics-pipeline в §1.1, и на
 *     потоковом пути из него не нужен никто;
 *   - не открывает расхождений. `analytics.reconciliation_discrepancies`
 *     наполняет reconciliation-service, мы лишь считаем кандидатов.
 */
object StreamingJob {

  private val log = LoggerFactory.getLogger(getClass)

  private val FreightTopic = "of.freight.v1"
  private val TelemetryTopic = "of.telemetry.v1"
  private val CustomsTopic = "of.customs.v1"
  private val BillingTopic = "of.billing.v1"

  def main(args: Array[String]): Unit = {
    val config = JobConfig.fromEnvironment()
    val spark = buildSession(config)

    log.info(s"analytics streaming starting in ${config.regionCode} against ${config.kafkaBrokers}")

    val sink = new WarehouseSink(config)
    val refresher = new MaterialisedViewRefresher(config)

    val queries = Seq(
      startAlertBursts(spark, config, sink),
      startLaneTransits(spark, config, sink),
      startSettlementLag(spark, config, sink)
    )

    // Первый запуск в новом регионе: CONCURRENTLY не работает по представлению,
    // которое ещё ни разу не заполнялось, и деплой падал бы каждую ночь до тех
    // пор, пока кто-нибудь не выполнит обычный REFRESH руками.
    if (refresher.requiresInitialRefresh("analytics.mv_lane_performance_daily")) {
      log.warn("mv_lane_performance_daily has never been populated, running a blocking refresh once")
      refresher.refresh("analytics.mv_lane_performance_daily")
    }

    sys.addShutdownHook {
      // OF_SHUTDOWN_GRACE_SECONDS меньше terminationGracePeriodSeconds пода;
      // за это время запросы обязаны дописать текущий микробатч и закоммитить
      // оффсеты, иначе после перезапуска мы перечитаем их из чекпойнта.
      log.info("shutdown requested, stopping queries gracefully")
      queries.foreach(query => query.stop())
      spark.stop()
    }

    spark.streams.awaitAnyTermination()
  }

  /** Всплески телеметрии. Самый быстрый из трёх запросов: у панели дежурного
    * задержка в минуту уже заметна. */
  private def startAlertBursts(spark: SparkSession, config: JobConfig, sink: WarehouseSink) = {
    val events = EventDeduplicator.distinctEvents(
      EnvelopeSource.stream(spark, config, Seq(TelemetryTopic)),
      TelemetryTopic
    )

    sink.appendParquet(AlertBurstWindow.aggregate(events), "alert_windows", triggerMs = 60000)
  }

  /**
   * Завершённые рейсы. Читает три события `of.freight.v1` и приводит их к общему
   * [[LifecycleEvent]]; всё остальное делает состояние в
   * [[LaneTransitWindow]].
   */
  private def startLaneTransits(spark: SparkSession, config: JobConfig, sink: WarehouseSink) = {
    import spark.implicits._

    val createdSchema = StructType(
      Seq(
        StructField("shipment_id", StringType),
        StructField("tenant_id", StringType),
        StructField("reference", StringType),
        StructField("origin_facility_id", StringType),
        StructField("destination_facility_id", StringType),
        StructField("incoterm", StringType),
        StructField("sla_deadline_at", TimestampType),
        StructField("region_code", StringType),
        StructField("created_by", StringType)
      )
    )

    val statusSchema = StructType(
      Seq(
        StructField("shipment_id", StringType),
        StructField("tenant_id", StringType),
        StructField("from_status", StringType),
        StructField("to_status", StringType),
        StructField("reason_code", StringType),
        StructField("changed_by", StringType),
        StructField("changed_at", TimestampType)
      )
    )

    val scanSchema = StructType(
      Seq(
        StructField("scan_id", StringType),
        StructField("shipment_id", StringType),
        StructField("container_id", StringType),
        StructField("scan_type", StringType),
        StructField("facility_id", StringType),
        StructField("scanned_by_user_id", StringType),
        StructField("occurred_at", TimestampType),
        StructField("recorded_at", TimestampType)
      )
    )

    val freight = EventDeduplicator.distinctEvents(
      EnvelopeSource.stream(spark, config, Seq(FreightTopic)),
      FreightTopic
    )

    val created = EnvelopeSource
      .withPayload(freight.filter(EnvelopeSource.ofType("shipment.created")), createdSchema)
      .select(
        col("shipment_id"),
        col("tenant_id"),
        col("region_code"),
        col("event_name"),
        col("occurred_at"),
        col("origin_facility_id"),
        col("destination_facility_id"),
        col("sla_deadline_at"),
        lit(null).cast(StringType).as("to_status"),
        lit(null).cast(StringType).as("scan_type")
      )

    val statuses = EnvelopeSource
      .withPayload(freight.filter(EnvelopeSource.ofType("shipment.status.changed")), statusSchema)
      .select(
        col("shipment_id"),
        col("tenant_id"),
        col("region_code"),
        col("event_name"),
        col("occurred_at"),
        lit(null).cast(StringType).as("origin_facility_id"),
        lit(null).cast(StringType).as("destination_facility_id"),
        lit(null).cast(TimestampType).as("sla_deadline_at"),
        col("to_status"),
        lit(null).cast(StringType).as("scan_type")
      )

    val scans = EnvelopeSource
      .withPayload(freight.filter(EnvelopeSource.ofType("shipment.scanned")), scanSchema)
      // Только подпись о вручении закрывает рейс; gate_in и gate_out идут
      // десятками и состояние ими двигать незачем.
      .filter(col("scan_type") === lit("proof_of_delivery"))
      .select(
        col("shipment_id"),
        col("tenant_id"),
        col("region_code"),
        col("event_name"),
        // occurred_at скана — время на устройстве, и именно оно правильное:
        // recorded_at у офлайн-сканов отстаёт на часы.
        col("occurred_at"),
        lit(null).cast(StringType).as("origin_facility_id"),
        lit(null).cast(StringType).as("destination_facility_id"),
        lit(null).cast(TimestampType).as("sla_deadline_at"),
        lit(null).cast(StringType).as("to_status"),
        col("scan_type")
      )

    val lifecycle: Dataset[LifecycleEvent] =
      created.unionByName(statuses).unionByName(scans).as[LifecycleEvent]

    val transits = LaneTransitWindow(spark, lifecycle).toDF()

    // UN/LOCODE подтягивается справочником: витрина направлений оперирует
    // кодами портов, а событие несёт только fac_… . Таблица меняется раз в
    // недели, поэтому broadcast, а не потоковое соединение.
    val facilities = sink
      .readReferenceTable(spark, "freight.facilities", Seq("facility_id", "unlocode", "country_code"))
      .cache()

    val enriched = transits
      .join(
        broadcast(facilities.withColumnRenamed("facility_id", "origin_facility_id")
          .withColumnRenamed("unlocode", "origin_unlocode")
          .drop("country_code")),
        Seq("origin_facility_id"),
        "left"
      )
      .join(
        broadcast(facilities.withColumnRenamed("facility_id", "destination_facility_id")
          .withColumnRenamed("unlocode", "destination_unlocode")
          .drop("country_code")),
        Seq("destination_facility_id"),
        "left"
      )
      .withColumn("business_date", to_date(col("created_at")))

    sink.appendParquet(enriched, "lane_transits", triggerMs = 300000)
  }

  /** Задержка оплаты пошлины. Самый медленный запрос: интервал соединения —
    * тридцать суток, и строка без пары появляется только по истечении окна. */
  private def startSettlementLag(spark: SparkSession, config: JobConfig, sink: WarehouseSink) = {
    val customs = EventDeduplicator.distinctEvents(
      EnvelopeSource.stream(spark, config, Seq(CustomsTopic)),
      CustomsTopic
    )

    val billing = EventDeduplicator.distinctEvents(
      EnvelopeSource.stream(spark, config, Seq(BillingTopic)),
      BillingTopic
    )

    val joined = SettlementLagJoin.join(customs, billing)

    sink.replaceDailyPartitions(
      SettlementLagJoin.dailySummary(joined),
      dataset = "settlement_lag_daily",
      triggerMs = 900000
    )
  }

  private def buildSession(config: JobConfig): SparkSession =
    SparkSession
      .builder()
      .appName(s"orbitalfreight-events-streaming-${config.regionCode}")
      .master(config.sparkMaster)
      // Число партиций шаффла под размер кластера: дефолтные двести на регионе
      // размером с apac-jp дают файлы по несколько килобайт.
      .config("spark.sql.shuffle.partitions", "48")
      .config("spark.sql.streaming.stateStore.providerClass",
        "org.apache.spark.sql.execution.streaming.state.RocksDBStateStoreProvider")
      // RocksDB, а не HDFS-провайдер: состояние LaneTransitWindow держит рейсы
      // до четырнадцати суток, и на heap исполнителя оно не помещается.
      .config("spark.sql.streaming.stateStore.rocksdb.changelogCheckpointing.enabled", "true")
      .config("spark.sql.session.timeZone", "UTC")
      .getOrCreate()
}
