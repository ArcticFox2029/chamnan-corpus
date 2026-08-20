// Проверка оконной агрегации алертов на памяти, без Kafka: MemoryStream отдаёт
// конверты §0.7 микробатчами, и тест смотрит, что окно склеивает серию, а не
// считает каждый алерт отдельно. Интеграция с брокером проверяется на staging.

package com.orbitalfreight.analytics.streaming.aggregation

import java.sql.Timestamp

import com.orbitalfreight.analytics.streaming.sources.EnvelopeSource
import org.apache.spark.sql.execution.streaming.MemoryStream
import org.apache.spark.sql.streaming.{OutputMode, Trigger}
import org.apache.spark.sql.{Row, SparkSession}
import org.scalatest.BeforeAndAfterAll
import org.scalatest.funsuite.AnyFunSuite
import org.scalatest.matchers.should.Matchers

/**
 * Кейсы подобраны по реальным инцидентам витрины: разъехавшийся водяной знак,
 * потерянный порог всплеска и событие чужого региона, доехавшее до агрегата.
 */
final class AlertBurstWindowSpec extends AnyFunSuite with Matchers with BeforeAndAfterAll {

  private lazy val spark: SparkSession = SparkSession
    .builder()
    .appName("alert-burst-window-spec")
    .master("local[2]")
    .config("spark.sql.shuffle.partitions", "2")
    .config("spark.sql.session.timeZone", "UTC")
    .getOrCreate()

  override def afterAll(): Unit = {
    spark.stop()
    super.afterAll()
  }

  /** Конверт §0.7 целиком строкой: агрегат разбирает ровно то, что приезжает из
    * Kafka, и подсовывать ему уже разобранный DataFrame — значит проверять не то. */
  private def envelope(
      eventId: String,
      containerId: String,
      ruleCode: String,
      severity: Int,
      occurredAt: String,
      regionCode: String = "eu-west"
  ): String =
    s"""{
       |  "event_id": "$eventId",
       |  "event_name": "telemetry.alert.raised",
       |  "schema_version": 2,
       |  "occurred_at": "$occurredAt",
       |  "tenant_id": "tnt_01J7A0000000000000000000AA",
       |  "region_code": "$regionCode",
       |  "producer": "telemetry-ingest",
       |  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
       |  "partition_key": "$containerId",
       |  "payload": {
       |    "alert_id": "alr_$eventId",
       |    "container_id": "$containerId",
       |    "shipment_id": "shp_01J8ZK4T9QW3RM7XN2VB6HD5PC",
       |    "rule_code": "$ruleCode",
       |    "severity": $severity,
       |    "threshold_value": 8.000,
       |    "peak_value": ${9 + severity}.500,
       |    "first_reading_id": "rdg_01J8ZK4T9QW3RM7XN2VB6HD5PC",
       |    "opened_at": "$occurredAt"
       |  }
       |}""".stripMargin

  private def runWindow(payloads: Seq[String], regionCode: String = "eu-west"): Seq[Row] = {
    import spark.implicits._

    implicit val sqlContext = spark.sqlContext
    val source = MemoryStream[String]
    source.addData(payloads)

    val parsed = source
      .toDF()
      .selectExpr(s"from_json(value, '${EnvelopeSource.EnvelopeSchema.toDDL}') as envelope")
      .select("envelope.*")

    val resident = EnvelopeSource
      .residentOnly(parsed, regionCode)
      .withWatermark("occurred_at", "30 minutes")

    val query = AlertBurstWindow
      .aggregate(resident)
      .writeStream
      .format("memory")
      .queryName("alert_windows_test")
      .outputMode(OutputMode.Complete())
      .trigger(Trigger.Once())
      .start()

    query.processAllAvailable()
    query.stop()

    spark.sql("SELECT * FROM alert_windows_test").collect().toSeq
  }

  test("три удара в одном окне становятся одной строкой всплеска") {
    val rows = runWindow(
      Seq(
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD501", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", "shock_impact", 3, "2026-03-14T09:01:00Z"),
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD502", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", "shock_impact", 4, "2026-03-14T09:06:00Z"),
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD503", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC", "shock_impact", 2, "2026-03-14T09:12:00Z")
      )
    )

    rows should have size 1
    rows.head.getAs[Long]("alert_count") shouldBe 3
    rows.head.getAs[Boolean]("is_burst") shouldBe true
    // Максимальная severity, а не последняя: письмо дежурному уже ушло по
    // четвёрке, и витрина обязана показывать ту же цифру.
    rows.head.getAs[Int]("max_severity") shouldBe 4
  }

  test("два алерта всплеском не считаются") {
    val rows = runWindow(
      Seq(
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD504", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PD", "door_open_in_transit", 5, "2026-03-14T10:02:00Z"),
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD505", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PD", "door_open_in_transit", 5, "2026-03-14T10:09:00Z")
      )
    )

    rows should have size 1
    rows.head.getAs[Boolean]("is_burst") shouldBe false
  }

  test("разные правила по одному контейнеру не смешиваются") {
    val rows = runWindow(
      Seq(
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD506", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PE", "temp_excursion_high", 4, "2026-03-14T11:01:00Z"),
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD507", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PE", "battery_critical", 2, "2026-03-14T11:03:00Z")
      )
    )

    rows should have size 2
    rows.map(_.getAs[String]("rule_code")).toSet shouldBe Set("temp_excursion_high", "battery_critical")
  }

  test("алерты соседних окон не склеиваются") {
    val rows = runWindow(
      Seq(
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD508", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PF", "humidity_high", 3, "2026-03-14T12:14:59Z"),
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD509", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PF", "humidity_high", 3, "2026-03-14T12:15:01Z")
      )
    )

    rows should have size 2
    rows.foreach(_.getAs[Long]("alert_count") shouldBe 1)
  }

  test("событие чужого региона не доходит до агрегата") {
    // §7.7: бразильский алерт в европейском поде не агрегируется и не логируется.
    val rows = runWindow(
      Seq(
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD510", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PG", "shock_impact", 5, "2026-03-14T13:00:00Z", "latam-br"),
        envelope("evt_01J8ZK4T9QW3RM7XN2VB6HD511", "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PG", "shock_impact", 5, "2026-03-14T13:02:00Z", "latam-br")
      )
    )

    rows shouldBe empty
  }
}
