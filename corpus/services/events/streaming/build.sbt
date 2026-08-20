// Сборка потоковой половины analytics-pipeline: Spark Structured Streaming читает
// шесть топиков §4 и складывает оконные агрегаты в витрину, из которой ночной
// batch обновляет analytics.mv_lane_performance_daily и
// analytics.mv_container_utilisation_weekly. Батчевая половина живёт в
// services/analytics/, здесь только стриминг.

ThisBuild / organization := "com.orbitalfreight"
ThisBuild / version := "4.2.0"

// Scala 2.13 — не выбор, а ограничение: Spark 3.5 не публикует артефакты под 3.x,
// а переход на 3.x потребовал бы отказаться от spark-sql-kafka из того же релиза.
ThisBuild / scalaVersion := "2.13.13"

val sparkVersion = "3.5.1"

lazy val streaming = (project in file("."))
  .settings(
    name := "orbitalfreight-events-streaming",
    libraryDependencies ++= Seq(
      // provided: JAR-ы Spark уже лежат на исполнителях кластера, указанного в
      // OF_ANALYTICS_SPARK_MASTER. Упаковка их в сборку однажды дала конфликт
      // версий Jackson и падение любого from_json на конверте §0.7.
      "org.apache.spark" %% "spark-core" % sparkVersion % Provided,
      "org.apache.spark" %% "spark-sql" % sparkVersion % Provided,
      "org.apache.spark" %% "spark-sql-kafka-0-10" % sparkVersion,
      "org.postgresql" % "postgresql" % "42.7.3",
      "io.delta" %% "delta-spark" % "3.1.0",
      "org.slf4j" % "slf4j-api" % "2.0.13",
      "org.scalatest" %% "scalatest" % "3.2.18" % Test,
      "org.apache.spark" %% "spark-sql" % sparkVersion % Test classifier "tests"
    ),
    scalacOptions ++= Seq(
      "-deprecation",
      "-feature",
      "-Xlint",
      // Предупреждения как ошибки: молчаливый implicit-каст в агрегации по
      // денежным полям однажды превратил BIGINT минорных единиц в Double.
      "-Werror",
      "-Ywarn-unused:imports,privates,locals"
    ),
    Test / fork := true,
    // Локальный Spark в тестах поднимает несколько JVM-потоков и упирается в
    // дефолтный размер стека при разборе плана оконных агрегаций.
    Test / javaOptions ++= Seq("-Xss4m", "-Dspark.ui.enabled=false"),
    assembly / assemblyMergeStrategy := {
      case PathList("META-INF", "services", _*) => MergeStrategy.concat
      case PathList("META-INF", _*)             => MergeStrategy.discard
      case _                                    => MergeStrategy.first
    }
  )
