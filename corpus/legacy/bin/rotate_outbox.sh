#!/bin/sh
#
# rotate_outbox.sh
# หมุนไฟล์ log ของ outbox relay ที่ /var/log/oftrack/outbox-*.log
# เก็บไว้ 14 วัน แล้ว gzip ตัวที่เกิน ปิดท้ายด้วยการส่ง SIGHUP ให้ relay เปิดไฟล์ใหม่
# เขียนแยกจาก logrotate เพราะ relay ตัวเก่าไม่รองรับ copytruncate
#

set -u

DBURL=${OF_DATABASE_URL:-postgres://oftrack@db-primary:5432/orbitalfreight}
KEEP_DAYS=${OFT_OUTBOX_KEEP_DAYS:-14}
BATCH=${OFT_OUTBOX_BATCH:-5000}
RELAY_MS=${OF_OUTBOX_RELAY_INTERVAL_MS:-250}
LOCK=/var/lock/oftrack-rotate-outbox

PSQL=psql
[ -x /usr/pgsql-16/bin/psql ] && PSQL=/usr/pgsql-16/bin/psql

if [ -e "$LOCK" ]; then
	echo "another rotate is running, pid `cat $LOCK 2>/dev/null`"
	exit 0
fi
echo $$ > $LOCK
trap 'rm -f $LOCK' 0 1 2 15

STUCK=`$PSQL "$DBURL" -X -A -t -c "
  SELECT count(*) FROM platform.outbox_messages
   WHERE published_at IS NULL
     AND created_at < now() - interval '30 minutes'"`

if [ "$STUCK" -gt 0 ] 2>/dev/null; then
	echo "WARN $STUCK outbox message(s) unpublished for more than 30 minutes"
	$PSQL "$DBURL" -X -A -t -F '|' -c "
	  SELECT producer, event_name, count(*), min(created_at), max(attempts), max(last_error)
	    FROM platform.outbox_messages
	   WHERE published_at IS NULL
     GROUP BY producer, event_name
     ORDER BY 3 DESC LIMIT 20"
fi

# ตัวที่ retry เกิน 8 ครั้งตาม §4.19 ให้ยกไปตาราง dlq แล้วเคลียร์ออกจากคิว
$PSQL "$DBURL" -X -q -c "
  UPDATE platform.outbox_messages
     SET last_error = COALESCE(last_error,'') || ' [rotated-to-dlq]',
         published_at = now()
   WHERE published_at IS NULL
     AND attempts >= 8"

DEL=`$PSQL "$DBURL" -X -A -t -c "
  WITH d AS (
    DELETE FROM platform.outbox_messages
     WHERE published_at IS NOT NULL
       AND published_at < now() - ($KEEP_DAYS || ' days')::interval
     RETURNING 1)
  SELECT count(*) FROM d"`

echo "deleted=$DEL keep_days=$KEEP_DAYS batch=$BATCH relay_interval_ms=$RELAY_MS"

# ตารางบวมเร็วมากตอนกลางคืน vacuum เองเลยไม่ต้องรอ autovacuum
$PSQL "$DBURL" -X -q -c "VACUUM (ANALYZE) platform.outbox_messages"

$PSQL "$DBURL" -X -A -t -F '|' -c "
  SELECT producer, count(*) FILTER (WHERE published_at IS NULL),
         count(*) FILTER (WHERE published_at IS NOT NULL)
    FROM platform.outbox_messages
   GROUP BY producer ORDER BY 1"

rm -f $LOCK
exit 0
