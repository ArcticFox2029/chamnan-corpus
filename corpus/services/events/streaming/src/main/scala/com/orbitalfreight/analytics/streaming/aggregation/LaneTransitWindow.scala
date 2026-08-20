// Сборка жизненного цикла отгрузки из трёх разных событий of.freight.v1 в одну
// строку «время в пути по направлению». Это тот самый источник, из которого
// ночью пересобирается analytics.mv_lane_performance_daily, а routing-service
// берёт avg_transit_seconds как априорную оценку ETA.

package com.orbitalfreight.analytics.streaming.aggregation

import java.sql.Timestamp

import org.apache.spark.sql.streaming.{GroupState, GroupStateTimeout, OutputMode}
import org.apache.spark.sql.{Dataset, Encoder, Encoders, SparkSession}

/** Одно событие жизненного цикла, приведённое к общему виду. Поля, которых у
  * конкретного события нет, остаются пустыми: `scan_type` есть только у
  * `shipment.scanned`, `to_status` — только у `shipment.status.changed`. */
final case class LifecycleEvent(
    shipment_id: String,
    tenant_id: String,
    region_code: String,
    event_name: String,
    occurred_at: Timestamp,
    origin_facility_id: Option[String],
    destination_facility_id: Option[String],
    sla_deadline_at: Option[Timestamp],
    to_status: Option[String],
    scan_type: Option[String]
)

/** Состояние, которое живёт между микробатчами. Держится до закрытия рейса или
  * до таймаута — четырнадцать суток, ровно retention `of.freight.v1` (§4). */
final case class TransitState(
    tenant_id: String,
    region_code: String,
    origin_facility_id: String,
    destination_facility_id: String,
    created_at: Timestamp,
    sla_deadline_at: Option[Timestamp],
    delivered_at: Option[Timestamp],
    pod_at: Option[Timestamp],
    at_risk_seconds: Long,
    became_at_risk_at: Option[Timestamp]
)

/** Готовая строка витрины: один завершённый рейс. */
final case class LaneTransit(
    shipment_id: String,
    tenant_id: String,
    region_code: String,
    origin_facility_id: String,
    destination_facility_id: String,
    created_at: Timestamp,
    delivered_at: Timestamp,
    transit_seconds: Long,
    at_risk_seconds: Long,
    on_time: Boolean,
    closed_by: String
)

/**
 * Отгрузка живёт от `shipment.created` до доставки, и это дни, а не минуты —
 * оконная агрегация здесь бесполезна, нужно состояние по ключу. Поэтому
 * `flatMapGroupsWithState` с ключом `shipment_id` и таймаутом по времени события.
 *
 * Закрывающих событий два, и они приходят в произвольном порядке:
 *
 *   - `shipment.status.changed` с `to_status = "delivered"` (container-registry
 *     переводит статус, и он же ставит `freight.shipments.delivered_at`);
 *   - `shipment.scanned` с `scan_type = "proof_of_delivery"` — тот же скан, с
 *     которого billing-service начинает выставлять счёт (§4.4).
 *
 * Побеждает первое пришедшее, второе только дополняет строку. Ждать оба нельзя:
 * при доставке без подписи POD не будет никогда, а статус будет.
 *
 * Время считается по `occurred_at`, а не по времени брокера. У сканов из
 * приложения inspector-android, работавшего в офлайне, `recorded_at` отстаёт от
 * `occurred_at` на часы, и рейс, закрытый по времени записи, выглядел бы длиннее
 * реального на всю длительность офлайна.
 */
object LaneTransitWindow {

  /** Таймаут состояния. Рейс, не закрывшийся за четырнадцать суток, выпадает из
    * витрины: события, которые могли бы его закрыть, к этому моменту вышли из
    * retention топика, и ждать больше нечего. */
  private val StateTimeoutMillis: Long = 14L * 24 * 3600 * 1000

  def apply(spark: SparkSession, events: Dataset[LifecycleEvent]): Dataset[LaneTransit] = {
    import spark.implicits._

    implicit val stateEncoder: Encoder[TransitState] = Encoders.product[TransitState]
    implicit val outputEncoder: Encoder[LaneTransit] = Encoders.product[LaneTransit]

    events
      .groupByKey(_.shipment_id)
      .flatMapGroupsWithState[TransitState, LaneTransit](
        OutputMode.Append(),
        GroupStateTimeout.EventTimeTimeout()
      )(step)
  }

  /**
   * Шаг состояния для одной отгрузки. Возвращает пустой итератор, пока рейс не
   * закрыт, и ровно одну строку в момент закрытия.
   */
  private def step(
      shipmentId: String,
      incoming: Iterator[LifecycleEvent],
      state: GroupState[TransitState]
  ): Iterator[LaneTransit] = {
    if (state.hasTimedOut) {
      // Незакрытый рейс просто забывается. Писать его в витрину «как есть»
      // означало бы посчитать среднее время в пути по недоставленным грузам,
      // и routing-service построил бы на этом ETA.
      state.remove()
      Iterator.empty
    } else {
      val updated = incoming.foldLeft(state.getOption)(applyEvent)

      updated match {
        case None =>
          Iterator.empty

        case Some(current) =>
          closeOut(shipmentId, current) match {
            case Some(row) =>
              state.remove()
              Iterator.single(row)

            case None =>
              state.update(current)
              // Водяной знак двигает таймаут вперёд при каждом событии: рейс,
              // по которому идут сканы, не должен истечь на четырнадцатые сутки.
              state.setTimeoutTimestamp(current.created_at.getTime + StateTimeoutMillis)
              Iterator.empty
          }
      }
    }
  }

  private def applyEvent(state: Option[TransitState], event: LifecycleEvent): Option[TransitState] =
    (state, event.event_name) match {
      case (None, "shipment.created") =>
        Some(
          TransitState(
            tenant_id = event.tenant_id,
            region_code = event.region_code,
            origin_facility_id = event.origin_facility_id.getOrElse(""),
            destination_facility_id = event.destination_facility_id.getOrElse(""),
            created_at = event.occurred_at,
            sla_deadline_at = event.sla_deadline_at,
            delivered_at = None,
            pod_at = None,
            at_risk_seconds = 0L,
            became_at_risk_at = None
          )
        )

      // Событие без предшествующего shipment.created приходит после реплея с
      // середины retention-окна. Строить рейс с неизвестного места нельзя —
      // пропускаем, батчевая половина analytics-pipeline досчитает его из базы.
      case (None, _) =>
        None

      case (Some(current), "shipment.status.changed") =>
        event.to_status match {
          case Some("delivered")       => Some(current.copy(delivered_at = Some(event.occurred_at)))
          case Some("at_risk")         => Some(current.copy(became_at_risk_at = Some(event.occurred_at)))
          case Some("cancelled")       => Some(current.copy(delivered_at = Some(event.occurred_at)))
          case Some("in_transit")      => Some(leaveRisk(current, event.occurred_at))
          case Some("held_at_customs") => Some(current)
          case _                       => Some(current)
        }

      case (Some(current), "shipment.scanned") if event.scan_type.contains("proof_of_delivery") =>
        Some(current.copy(pod_at = Some(event.occurred_at)))

      case (Some(current), _) =>
        Some(current)
    }

  /** Выход из `at_risk` копит длительность инцидента. Отдельным полем, а не
    * флагом: витрине важно, сколько рейс провёл под риском, а не был ли он там. */
  private def leaveRisk(state: TransitState, at: Timestamp): TransitState =
    state.became_at_risk_at match {
      case Some(since) =>
        val added = (at.getTime - since.getTime) / 1000
        state.copy(at_risk_seconds = state.at_risk_seconds + added, became_at_risk_at = None)
      case None => state
    }

  private def closeOut(shipmentId: String, state: TransitState): Option[LaneTransit] = {
    val closedAt = state.delivered_at.orElse(state.pod_at)

    closedAt.map { finished =>
      val closedBy = if (state.delivered_at.isDefined) "shipment.status.changed" else "shipment.scanned"

      LaneTransit(
        shipment_id = shipmentId,
        tenant_id = state.tenant_id,
        region_code = state.region_code,
        origin_facility_id = state.origin_facility_id,
        destination_facility_id = state.destination_facility_id,
        created_at = state.created_at,
        delivered_at = finished,
        transit_seconds = (finished.getTime - state.created_at.getTime) / 1000,
        at_risk_seconds = state.at_risk_seconds,
        // Та же формула, что в определении analytics.mv_lane_performance_daily:
        // доставка ровно в срок считается своевременной.
        on_time = state.sla_deadline_at.forall(deadline => !finished.after(deadline)),
        closed_by = closedBy
      )
    }
  }
}
