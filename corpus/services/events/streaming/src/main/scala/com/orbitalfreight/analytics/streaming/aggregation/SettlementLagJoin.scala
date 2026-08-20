package com.orbitalfreight.analytics.streaming.aggregation

import com.orbitalfreight.analytics.streaming.sources.EnvelopeSource
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.functions._
import org.apache.spark.sql.types._

/**
 * Соединение двух потоков вокруг разорванного цикла из §1.2: таможня выпускает
 * декларацию (`customs.declaration.cleared`), а бухгалтерия закрывает счёт
 * (`billing.invoice.settled`), и второе событие — единственный способ, которым
 * customs-service узнаёт об оплате пошлины.
 *
 * Метрика, ради которой всё это считается, — задержка между выпуском и оплатой.
 * Она видна только снаружи обоих сервисов: billing-service не знает, когда
 * декларация вышла, customs-service не знает, когда пришли деньги, и связать два
 * факта может лишь тот, кто читает обе очереди. Именно поэтому агрегат живёт в
 * analytics-pipeline, а не в одном из них.
 *
 * Отдельно важен второй выход соединения — выпущенные декларации, к которым за
 * тридцать суток не пришла оплата. Мы их только считаем и кладём в витрину;
 * расхождение `cleared_without_payment` открывает reconciliation-service своим
 * ночным трёхсторонним сверением, и дублировать его здесь нельзя: у дискрепансии
 * один владелец и одна таблица `analytics.reconciliation_discrepancies`.
 */
object SettlementLagJoin {

  /** payload §4.13 `customs.declaration.cleared`. */
  val ClearedSchema: StructType = StructType(
    Seq(
      StructField("declaration_id", StringType),
      StructField("shipment_id", StringType),
      StructField("mrn", StringType),
      StructField("cleared_at", TimestampType),
      StructField("assessed_duty_minor", LongType),
      StructField("assessed_vat_minor", LongType),
      StructField("currency", StringType),
      StructField("inspection_performed", BooleanType),
      StructField("decision_document_id", StringType)
    )
  )

  /** payload §4.15 `billing.invoice.settled`. `declaration_id` здесь может быть
    * пустым: внутренние перевозки без таможенной части счёт всё равно получают. */
  val SettledSchema: StructType = StructType(
    Seq(
      StructField("invoice_id", StringType),
      StructField("tenant_id", StringType),
      StructField("shipment_id", StringType),
      StructField("declaration_id", StringType),
      StructField("total_minor", LongType),
      StructField("currency", StringType),
      StructField("settled_at", TimestampType),
      StructField("final_payment_id", StringType)
    )
  )

  /** Горизонт ожидания оплаты. Тридцать суток — это типичный
    * `OF_BILLING_DEFAULT_PAYMENT_TERMS_DAYS` плюс запас на выходные банка. */
  private val JoinWindow = "30 days"

  /**
   * Соединяет выпуск и оплату по `declaration_id`.
   *
   * Соединение левое внешнее: строки без пары нужны так же, как строки с парой.
   * Spark отдаёт неполную строку только после того, как водяной знак прошёл
   * границу интервала, — то есть ровно через тридцать суток после выпуска, а не
   * в момент, когда оплаты «ещё нет».
   */
  def join(customsEvents: DataFrame, billingEvents: DataFrame): DataFrame = {
    val cleared = EnvelopeSource
      .withPayload(customsEvents.filter(EnvelopeSource.ofType("customs.declaration.cleared")), ClearedSchema)
      .select(
        col("tenant_id"),
        col("region_code"),
        col("declaration_id"),
        col("shipment_id").as("cleared_shipment_id"),
        col("mrn"),
        col("cleared_at"),
        col("assessed_duty_minor"),
        col("assessed_vat_minor"),
        col("currency").as("duty_currency"),
        col("inspection_performed"),
        col("occurred_at").as("cleared_event_at")
      )
      .withWatermark("cleared_at", JoinWindow)

    val settled = EnvelopeSource
      .withPayload(billingEvents.filter(EnvelopeSource.ofType("billing.invoice.settled")), SettledSchema)
      .select(
        col("declaration_id").as("settled_declaration_id"),
        col("invoice_id"),
        col("total_minor"),
        col("currency").as("invoice_currency"),
        col("settled_at"),
        col("final_payment_id")
      )
      // Счёт без декларации к этому соединению отношения не имеет; он попадёт в
      // витрину выручки, которую считает батчевая половина analytics-pipeline.
      .filter(col("settled_declaration_id").isNotNull)
      .withWatermark("settled_at", JoinWindow)

    cleared
      .join(
        settled,
        expr(
          """
          declaration_id = settled_declaration_id
            AND settled_at >= cleared_at
            AND settled_at <= cleared_at + INTERVAL 30 DAYS
          """
        ),
        "leftOuter"
      )
      .select(
        col("tenant_id"),
        col("region_code"),
        col("declaration_id"),
        col("cleared_shipment_id").as("shipment_id"),
        col("mrn"),
        col("cleared_at"),
        col("settled_at"),
        col("invoice_id"),
        col("final_payment_id"),
        col("assessed_duty_minor"),
        col("assessed_vat_minor"),
        col("total_minor"),
        col("duty_currency"),
        col("invoice_currency"),
        col("inspection_performed"),
        // Задержка в секундах, а не в днях: агрегировать по дням витрина умеет
        // сама, а обратно из округлённых суток точность не восстановить.
        when(col("settled_at").isNotNull, unix_timestamp(col("settled_at")) - unix_timestamp(col("cleared_at")))
          .as("settlement_lag_seconds"),
        col("settled_at").isNull.as("unsettled"),
        to_date(col("cleared_at")).as("business_date")
      )
  }

  /**
   * Дневная сводка по задержке оплаты: медиана, 95-й процентиль и доля
   * неоплаченных. Валюта в группировке обязательна — складывать `total_minor`
   * разных валют нельзя, минорная единица у них разная (§0.2, §7.4).
   */
  def dailySummary(joined: DataFrame): DataFrame =
    joined
      .groupBy(col("tenant_id"), col("region_code"), col("business_date"), col("duty_currency"))
      .agg(
        count(lit(1)).as("declarations_cleared"),
        sum(when(col("unsettled"), lit(1)).otherwise(lit(0))).as("still_unsettled"),
        sum(col("assessed_duty_minor")).as("assessed_duty_minor"),
        sum(when(col("unsettled"), col("assessed_duty_minor")).otherwise(lit(0L))).as("unsettled_duty_minor"),
        percentile_approx(col("settlement_lag_seconds"), lit(0.5), lit(1000)).as("median_lag_seconds"),
        percentile_approx(col("settlement_lag_seconds"), lit(0.95), lit(1000)).as("p95_lag_seconds"),
        max(col("settlement_lag_seconds")).as("max_lag_seconds")
      )

  /**
   * Кандидаты в расхождение `cleared_without_payment`. Витрина, а не действие:
   * открыть дискрепансию имеет право только reconciliation-service, а он читает
   * `analytics.reconciliation_discrepancies` как собственную таблицу и
   * публикует `reconciliation.discrepancy.opened` сам.
   */
  def unsettledAfterWindow(joined: DataFrame): DataFrame =
    joined
      .filter(col("unsettled"))
      .select(
        col("tenant_id"),
        col("region_code"),
        col("shipment_id"),
        col("declaration_id"),
        col("mrn"),
        col("cleared_at"),
        col("assessed_duty_minor").as("expected_minor"),
        col("duty_currency").as("currency"),
        lit("cleared_without_payment").as("candidate_kind"),
        col("business_date")
      )
}
