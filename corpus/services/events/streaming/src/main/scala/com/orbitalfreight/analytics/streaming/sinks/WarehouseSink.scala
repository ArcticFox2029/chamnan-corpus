// Запись результатов оконных агрегаций в витрину OF_ANALYTICS_WAREHOUSE_URI и
// чтение справочников чужих схем ролью of_analytics_ro. Всё, что касается
// расположения файлов, чекпойнтов и партиционирования, собрано здесь, чтобы
// правило резидентности §7.7 проверялось в одном файле, а не в трёх агрегатах.

package com.orbitalfreight.analytics.streaming.sinks

import java.util.Properties

import com.orbitalfreight.analytics.streaming.JobConfig
import org.apache.spark.sql.functions._
import org.apache.spark.sql.streaming.{StreamingQuery, Trigger}
import org.apache.spark.sql.{DataFrame, SaveMode}
import org.slf4j.LoggerFactory

/**
 * Приёмник витрины. Два способа записи, и выбор между ними не стилистический:
 *
 *   - `parquet` — для потоков, которые только дописываются (окна алертов,
 *     завершённые рейсы). Дешёво, идемпотентно по чекпойнту, читается батчем;
 *   - `replaceDailyPartitions` — для сводок, которые пересчитывают уже записанный
 *     день (задержка оплаты меняется, пока идут платежи). Через `foreachBatch` и
 *     динамическую перезапись затронутых партиций `business_date`.
 *
 * Своей таблицы в схеме `analytics` у этих сводок нет намеренно. §2.10 перечисляет
 * сорок базовых таблиц и два представления поимённо, а §7.1 требует сначала внести
 * новое имя в спецификацию и только потом создавать его в базе. Пока этого не
 * сделано, сводки живут в витрине как Parquet, а в PostgreSQL уходит только то,
 * что уже описано, — через `MaterialisedViewRefresher`.
 *
 * Партиционирование всегда начинается с `region_code`. Это не оптимизация, а
 * §7.7: бразильские агрегаты обязаны лежать в бразильском бакете, и путь — то
 * единственное место, где это видно при проверке.
 */
final class WarehouseSink(config: JobConfig) {

  private val log = LoggerFactory.getLogger(getClass)

  /**
   * Append-поток в Parquet.
   *
   * @param dataset   имя набора; из него получаются и путь, и имя чекпойнта
   * @param triggerMs период микробатча; для витрин минуты, не секунды — мелкие
   *                  файлы на объектном хранилище дороже задержки
   */
  def appendParquet(frame: DataFrame, dataset: String, triggerMs: Long = 60000): StreamingQuery = {
    val path = config.outputPathFor(dataset)
    log.info(s"streaming $dataset to $path")

    frame.writeStream
      .format("parquet")
      .outputMode("append")
      .option("path", path)
      .option("checkpointLocation", config.checkpointFor(dataset))
      // Дата в пути, а не только в колонке: ночной batch читает конкретные дни,
      // и без partitionBy он сканировал бы витрину целиком.
      .partitionBy("business_date")
      .trigger(Trigger.ProcessingTime(triggerMs))
      .queryName(s"$dataset-${config.regionCode}")
      .start()
  }

  /**
   * Пересчёт уже записанных дней.
   *
   * `foreachBatch` вызывается как минимум один раз на батч и может быть вызван
   * повторно после сбоя, поэтому запись обязана быть идемпотентной: партиции
   * `business_date`, попавшие в батч, перезаписываются целиком, а не дополняются.
   * `job_run_id` остаётся в строке — по нему при разборе инцидента видно, каким
   * прогоном получено значение, и это единственный способ отличить пересчёт от
   * дубля.
   */
  def replaceDailyPartitions(frame: DataFrame, dataset: String, triggerMs: Long = 300000): StreamingQuery = {
    val path = config.outputPathFor(dataset)

    frame.writeStream
      .outputMode("update")
      .option("checkpointLocation", config.checkpointFor(dataset))
      .trigger(Trigger.ProcessingTime(triggerMs))
      .queryName(s"$dataset-${config.regionCode}")
      .foreachBatch { (batch: DataFrame, batchId: Long) =>
        // Динамический режим трогает только те даты, которые есть в батче.
        // Статический (по умолчанию) снёс бы всю витрину набора — так однажды
        // и пропала недельная история задержек оплаты.
        batch.sparkSession.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

        batch
          .withColumn("job_run_id", lit(s"job_$batchId"))
          .write
          .mode(SaveMode.Overwrite)
          .partitionBy("business_date")
          .parquet(path)
      }
      .start()
  }

  /**
   * Разовая запись справочника, прочитанного через роль `of_analytics_ro`.
   * Используется для `freight.facilities` — таблицы, из которой берётся
   * `unlocode` для строк направления. Читать её потоково незачем: порты не
   * открываются каждую минуту, а join к статике дешевле broadcast-ом.
   */
  def readReferenceTable(spark: org.apache.spark.sql.SparkSession, table: String, columns: Seq[String]): DataFrame =
    spark.read
      .jdbc(config.readOnlyJdbcUrl, table, jdbcProperties)
      .select(columns.map(col): _*)

  private def jdbcProperties: Properties = {
    val properties = new Properties()
    properties.setProperty("driver", "org.postgresql.Driver")
    // URL уже содержит учётные данные и search_path; отдельных переменных с
    // логином и паролем в §5 нет, и заводить их нельзя.
    properties.setProperty("stringtype", "unspecified")
    properties.setProperty("reWriteBatchedInserts", "true")
    properties
  }
}
