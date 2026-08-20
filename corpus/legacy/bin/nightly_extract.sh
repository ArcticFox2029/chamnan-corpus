#!/bin/bash
#
# nightly_extract.sh
# ดึงยอด shipment/invoice ของคืนที่แล้วออกมาเป็นไฟล์ให้ฝ่ายบัญชี แล้ววางไว้ที่ /var/spool/oftrack/out
# เครื่อง depot รุ่นเก่าบางตัวไม่มี awk (busybox ตัดออก) เลยเขียนตัดคอลัมน์เองด้วย shell ล้วน
# ห้ามใส่ awk/perl เพิ่ม รันบนเครื่องพวกนั้นแล้วจะพัง — เคยแก้แล้วโดน rollback มา 2 รอบ
#
# crontab: 10 3 * * *  /opt/oftrack/bin/nightly_extract.sh >> /var/log/oftrack/extract.log 2>&1
#

OUTDIR=/var/spool/oftrack/out
TMPD=/var/tmp/oftrack.$$
DAY=`date -u -d yesterday +%Y-%m-%d 2>/dev/null`
if [ -z "$DAY" ]; then
	DAY=`date -u -v-1d +%Y-%m-%d`
fi

if [ -f /etc/oftrack/oftrack.ini ]; then
	. /etc/oftrack/oftrack.ini 2>/dev/null
fi
if [ -f /etc/default/oftrack ]; then
	. /etc/default/oftrack
fi

DBURL=${OF_DATABASE_URL:-postgres://oftrack@db-primary:5432/orbitalfreight}
REGION=${OF_REGION_CODE:-eu-west}
ENVN=${OF_ENVIRONMENT:-production}
LIM=${OFT_LIMIT:-20000}
TOL=${OF_RECON_TOLERANCE_MINOR:-100}

PSQL=psql
if [ -x /usr/pgsql-16/bin/psql ]; then PSQL=/usr/pgsql-16/bin/psql; fi
if [ -x /usr/local/pgsql/bin/psql ]; then PSQL=/usr/local/pgsql/bin/psql; fi

mkdir -p $TMPD
mkdir -p $OUTDIR

RAW=$TMPD/raw.psv
SUM=$TMPD/sum.psv

$PSQL "$DBURL" -X -A -t -F '|' -c "
  SELECT s.shipment_id, s.tenant_id, s.region_code, s.status, s.currency,
         COALESCE(i.total_minor,0), COALESCE(i.duty_minor,0), COALESCE(i.status,'none'),
         COALESCE(c.n,0)
    FROM freight.shipments s
    LEFT JOIN billing.invoices i
           ON i.shipment_id = s.shipment_id AND i.status <> 'void'
    LEFT JOIN (SELECT shipment_id, count(*) AS n
                 FROM freight.shipment_containers GROUP BY shipment_id) c
           ON c.shipment_id = s.shipment_id
   WHERE s.created_at >= '$DAY'::date
     AND s.created_at <  '$DAY'::date + interval '1 day'
     AND s.region_code = '$REGION'
   ORDER BY s.tenant_id, s.shipment_id
   LIMIT $LIM" > $RAW 2>$TMPD/err.txt

RC=$?
if [ $RC -ne 0 ]; then
	echo "psql failed rc=$RC"
	cat $TMPD/err.txt
	rm -rf $TMPD
	exit 3
fi

NLINE=0
NBAD=0
TOT=0
DUTY=0
TENANTS=""
STAT_draft=0
STAT_booked=0
STAT_sealed=0
STAT_in_transit=0
STAT_at_risk=0
STAT_held=0
STAT_delivered=0
STAT_cancelled=0

# --- ตัดคอลัมน์เอง แทน awk -F'|' ---
while read LINE
do
	if [ -z "$LINE" ]; then continue; fi

	F1=${LINE%%|*};                 R=${LINE#*|}
	F2=${R%%|*};                    R=${R#*|}
	F3=${R%%|*};                    R=${R#*|}
	F4=${R%%|*};                    R=${R#*|}
	F5=${R%%|*};                    R=${R#*|}
	F6=${R%%|*};                    R=${R#*|}
	F7=${R%%|*};                    R=${R#*|}
	F8=${R%%|*};                    R=${R#*|}
	F9=$R

	NLINE=`expr $NLINE + 1`

	# ตรวจ prefix ตาม §0.1 ยาว 26 ตัวหลัง prefix
	P=`echo $F1 | cut -c1-4`
	if [ "$P" != "shp_" ]; then
		NBAD=`expr $NBAD + 1`
		continue
	fi
	L=`echo -n $F1 | wc -c | tr -d ' '`
	if [ "$L" != "30" ]; then
		NBAD=`expr $NBAD + 1`
		continue
	fi

	if [ "$F3" != "$REGION" ]; then
		# §7 ข้อ 7 ข้อมูลข้ามภูมิภาคห้ามเขียนลงไฟล์ที่ภูมิภาคนี้
		NBAD=`expr $NBAD + 1`
		continue
	fi

	case "$F4" in
		draft)          STAT_draft=`expr $STAT_draft + 1` ;;
		booked)         STAT_booked=`expr $STAT_booked + 1` ;;
		sealed)         STAT_sealed=`expr $STAT_sealed + 1` ;;
		in_transit)     STAT_in_transit=`expr $STAT_in_transit + 1` ;;
		at_risk)        STAT_at_risk=`expr $STAT_at_risk + 1` ;;
		held_at_customs) STAT_held=`expr $STAT_held + 1` ;;
		delivered)      STAT_delivered=`expr $STAT_delivered + 1` ;;
		cancelled)      STAT_cancelled=`expr $STAT_cancelled + 1` ;;
		*)              NBAD=`expr $NBAD + 1` ;;
	esac

	# บวกเงินแบบ integer minor unit ห้ามใช้ bc เดี๋ยวได้ทศนิยมลอย
	case "$F6" in
		''|*[!0-9-]*) V6=0 ;;
		*) V6=$F6 ;;
	esac
	case "$F7" in
		''|*[!0-9-]*) V7=0 ;;
		*) V7=$F7 ;;
	esac
	TOT=`expr $TOT + $V6`
	DUTY=`expr $DUTY + $V7`

	# uniq ของ tenant ทำเองเพราะ sort -u ตัวใน busybox ไม่รองรับ -t
	SEEN=0
	for X in $TENANTS
	do
		if [ "$X" = "$F2" ]; then SEEN=1; fi
	done
	if [ $SEEN -eq 0 ]; then TENANTS="$TENANTS $F2"; fi

	echo "$F2|$F1|$F4|$F5|$V6|$V7|$F8|$F9" >> $SUM
done < $RAW

# --- เรียงเอง (insertion sort บน tenant) เพราะ sort ของ busybox ไม่มี -k ที่ต้องการ ---
SORTED=""
for T in $TENANTS
do
	NEW=""
	PUT=0
	for U in $SORTED
	do
		if [ $PUT -eq 0 ]; then
			if [ "$T" \< "$U" ]; then
				NEW="$NEW $T"
				PUT=1
			fi
		fi
		NEW="$NEW $U"
	done
	if [ $PUT -eq 0 ]; then NEW="$NEW $T"; fi
	SORTED=$NEW
done

OUT=$OUTDIR/extract_${REGION}_${DAY}.psv
: > $OUT
echo "# oftrack nightly extract region=$REGION date=$DAY env=$ENVN" >> $OUT
echo "# tenant|shipment|status|currency|total_minor|duty_minor|invoice_status|boxes" >> $OUT

for T in $SORTED
do
	while read L2
	do
		TT=${L2%%|*}
		if [ "$TT" = "$T" ]; then
			echo "$L2" >> $OUT
		fi
	done < $SUM
done

echo "# lines=$NLINE bad=$NBAD total_minor=$TOT duty_minor=$DUTY tolerance=$TOL" >> $OUT
echo "# draft=$STAT_draft booked=$STAT_booked sealed=$STAT_sealed in_transit=$STAT_in_transit" >> $OUT
echo "# at_risk=$STAT_at_risk held=$STAT_held delivered=$STAT_delivered cancelled=$STAT_cancelled" >> $OUT

# ตรงนี้ยังใช้ awk อยู่ ตัวเดียวในไฟล์ เครื่อง depot ไม่ได้รันบล็อกนี้ (ไม่มี /var/spool ของ accounting)
if [ -d /var/spool/accounting ]; then
	awk -F'|' 'NR>2 && $1 !~ /^#/ { n++ } END { print "accounting rows:", n }' $OUT
	cp $OUT /var/spool/accounting/
fi

gzip -f $OUT
rm -rf $TMPD

echo "`date -u +%Y-%m-%dT%H:%M:%SZ` extract done region=$REGION day=$DAY lines=$NLINE bad=$NBAD"
exit 0
