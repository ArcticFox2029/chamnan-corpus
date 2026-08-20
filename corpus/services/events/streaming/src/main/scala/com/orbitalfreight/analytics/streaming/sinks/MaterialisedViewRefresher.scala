package com.orbitalfreight.analytics.streaming.sinks

import java.sql.{Connection, DriverManager}

import com.orbitalfreight.analytics.streaming.JobConfig
import org.slf4j.LoggerFactory

/**
 * Обновление двух материализованных представлений схемы `analytics`:
 * `mv_lane_performance_daily` и `mv_container_utilisation_weekly`. Обе
 * принадлежат analytics-pipeline и, кроме него, их не пересобирает никто.
 *
 * Обновление идёт `CONCURRENTLY` — веб-консоль и routing-service читают эти
 * представления круглосуточно, а обычный `REFRESH` берёт эксклюзивную блокировку
 * на всё время пересборки. Именно ради `CONCURRENTLY` в §2.9 у каждого
 * представления заведён уникальный индекс: без него команда просто не выполнится.
 *
 * Расписание задаёт `OF_ANALYTICS_MV_REFRESH_CRON` (`15 3 * * *`), но сам крон
 * живёт в `infra/`; этот класс умеет только выполнить обновление и отчитаться.
 * Потоковое задание вызывает его вне расписания в одном случае — после
 * бэкфилла, когда витрина заведомо разошлась с представлением.
 */
final class MaterialisedViewRefresher(config: JobConfig) {

  private val log = LoggerFactory.getLogger(getClass)

  /** Числовой ключ advisory-блокировки. Подов analytics-pipeline в регионе
    * несколько, и два одновременных CONCURRENTLY по одному представлению
    * PostgreSQL выполняет последовательно, удерживая соединения впустую. */
  private val LockKey: Long = 0x0F4A17E5L

  private val Views = Seq(
    "analytics.mv_lane_performance_daily",
    "analytics.mv_container_utilisation_weekly"
  )

  /**
   * Обновляет оба представления. Возвращает длительность каждого обновления —
   * значения уходят в метрики: рост времени пересборки `mv_lane_performance_daily`
   * первым сигнализирует, что `freight.shipments` перерос текущие индексы.
   */
  def refreshAll(): Map[String, Long] =
    withLock {
      Views.map { view =>
        val startedAt = System.currentTimeMillis()
        refresh(view)
        val elapsed = System.currentTimeMillis() - startedAt
        log.info(s"refreshed $view in ${elapsed}ms")
        view -> elapsed
      }.toMap
    }

  /**
   * Одно представление. Выделено отдельно, потому что после бэкфилла
   * пересобирать недельную витрину контейнеров обычно не нужно — её источник
   * `freight.shipment_containers` бэкфилл не трогает.
   */
  def refresh(view: String): Unit =
    withConnection { connection =>
      val statement = connection.createStatement()
      try {
        // Таймаут на само обновление: если представление не пересобралось за
        // двадцать минут, ночное окно закончилось, и лучше упасть с внятной
        // ошибкой, чем держать нагрузку на кластер в рабочие часы.
        statement.execute("SET LOCAL statement_timeout = '20min'")
        statement.execute(s"REFRESH MATERIALIZED VIEW CONCURRENTLY $view")
      } finally statement.close()
    }

  /** Пуст ли ещё ни разу не заполненный вид. `CONCURRENTLY` не работает по
    * представлению, которое никогда не обновлялось обычным способом, — это
    * ровно тот случай, когда падает первый деплой в новом регионе. */
  def requiresInitialRefresh(view: String): Boolean =
    withConnection { connection =>
      val statement = connection.prepareStatement(
        "SELECT NOT relispopulated FROM pg_class WHERE oid = ?::regclass"
      )
      try {
        statement.setString(1, view)
        val rs = statement.executeQuery()
        rs.next() && rs.getBoolean(1)
      } finally statement.close()
    }

  private def withLock[T](body: => T): T =
    withConnection { connection =>
      val acquire = connection.prepareStatement("SELECT pg_try_advisory_lock(?)")
      acquire.setLong(1, LockKey)
      val rs = acquire.executeQuery()
      val acquired = rs.next() && rs.getBoolean(1)
      acquire.close()

      if (!acquired) {
        // Другой под уже обновляет. Это не ошибка: результат один и тот же,
        // и ждать освобождения смысла нет.
        log.info("another analytics-pipeline pod holds the refresh lock, skipping")
        Map.empty[String, Long].asInstanceOf[T]
      } else {
        try body
        finally {
          val release = connection.prepareStatement("SELECT pg_advisory_unlock(?)")
          release.setLong(1, LockKey)
          release.execute()
          release.close()
        }
      }
    }

  private def withConnection[T](body: Connection => T): T = {
    val connection = DriverManager.getConnection(config.ownedJdbcUrl)
    try body(connection)
    finally connection.close()
  }
}
