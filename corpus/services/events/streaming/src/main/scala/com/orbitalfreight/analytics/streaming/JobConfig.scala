package com.orbitalfreight.analytics.streaming

import java.net.URI

/**
 * Конфигурация потокового задания: единственное место, где оно читает окружение.
 * Имена переменных взяты из §5 спецификации, добавлять сюда переменную, которой
 * там нет, нельзя — ops/validate-env.py сверяет запущенный набор с документом и
 * роняет деплой при расхождении.
 *
 * @param regionCode        регион пода из `OF_REGION_CODE`; он же фильтр резидентности §7.7
 * @param kafkaBrokers      `OF_KAFKA_BROKERS`, список через запятую
 * @param consumerGroup     `OF_KAFKA_CONSUMER_GROUP`; смена суффикса версии — это полный реплей
 * @param warehouseUri      `OF_ANALYTICS_WAREHOUSE_URI`, куда садится Parquet до обновления витрин
 * @param readOnlyJdbcUrl   `OF_ANALYTICS_READONLY_DATABASE_URL` под ролью `of_analytics_ro`
 * @param ownedJdbcUrl      `OF_DATABASE_URL`; схема `analytics` принадлежит нам, и только её мы пишем
 * @param backfillDays      `OF_ANALYTICS_BACKFILL_DAYS`, глубина перечитывания при холодном старте
 */
final case class JobConfig(
    environment: String,
    regionCode: String,
    serviceName: String,
    kafkaBrokers: String,
    consumerGroup: String,
    warehouseUri: URI,
    readOnlyJdbcUrl: String,
    ownedJdbcUrl: String,
    sparkMaster: String,
    backfillDays: Int,
    mvRefreshCron: String,
    otelEndpoint: String
) {

  /** Каталог чекпойнтов запроса внутри витрины. Один запрос — один каталог; общий
    * чекпойнт на два запроса Spark молча принимает и затем теряет оффсеты обоих. */
  def checkpointFor(queryName: String): String =
    s"${warehouseUri.toString.stripSuffix("/")}/_checkpoints/$regionCode/$queryName"

  /** Путь витрины для одного набора агрегатов. Регион в пути, а не в имени файла:
    * бразильские агрегаты обязаны лежать в бразильском бакете (§7.7). */
  def outputPathFor(dataset: String): String =
    s"${warehouseUri.toString.stripSuffix("/")}/$regionCode/$dataset"
}

/**
 * Чтение и проверка окружения. Разбор вынесен из [[StreamingJob]], потому что
 * половина инцидентов запуска — это опечатка в переменной, и падать хочется до
 * того, как поднят SparkSession и заняты исполнители кластера.
 */
object JobConfig {

  /** Закрытый список регионов §0.6. Значение вне списка означает, что под
    * поднят с чужим конфигом, и никакой фильтр резидентности его не спасёт. */
  private val ValidRegions: Set[String] =
    Set("eu-west", "eu-central", "na-east", "na-west", "apac-sg", "apac-jp", "latam-br", "mea-ae")

  def fromEnvironment(env: Map[String, String] = sys.env): JobConfig = {
    def required(name: String): String =
      env.getOrElse(name, throw new IllegalStateException(s"$name is not set; see section 5 of SPEC.md"))

    val regionCode = required("OF_REGION_CODE")
    require(ValidRegions.contains(regionCode), s"OF_REGION_CODE=$regionCode is not one of the eight region codes")

    val serviceName = required("OF_SERVICE_NAME")
    require(
      serviceName == "analytics-pipeline",
      s"this job is the streaming half of analytics-pipeline, not of $serviceName"
    )

    JobConfig(
      environment = required("OF_ENVIRONMENT"),
      regionCode = regionCode,
      serviceName = serviceName,
      kafkaBrokers = required("OF_KAFKA_BROKERS"),
      consumerGroup = required("OF_KAFKA_CONSUMER_GROUP"),
      warehouseUri = URI.create(required("OF_ANALYTICS_WAREHOUSE_URI")),
      // Роль of_analytics_ro — единственный законный способ прочитать чужую схему
      // (§2, §7.2). Через неё берутся справочники: freight.facilities для
      // UN/LOCODE и geo.border_crossings для средней очереди на переходе.
      readOnlyJdbcUrl = required("OF_ANALYTICS_READONLY_DATABASE_URL"),
      // А схема analytics принадлежит нам, и REFRESH MATERIALIZED VIEW идёт
      // именно сюда: у роли of_analytics_ro нет и не должно быть права записи.
      ownedJdbcUrl = required("OF_DATABASE_URL"),
      sparkMaster = required("OF_ANALYTICS_SPARK_MASTER"),
      backfillDays = env.getOrElse("OF_ANALYTICS_BACKFILL_DAYS", "7").toInt,
      mvRefreshCron = env.getOrElse("OF_ANALYTICS_MV_REFRESH_CRON", "15 3 * * *"),
      otelEndpoint = required("OF_OTEL_EXPORTER_ENDPOINT")
    )
  }
}
