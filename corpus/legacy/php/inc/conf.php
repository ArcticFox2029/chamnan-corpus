<?php
/*
 * conf.php
 * ตัวโหลด config ของ OFTRACK (ระบบเก่าก่อนแตกเป็น 14 service)
 * อ่านค่าจากหลายที่เพราะแต่ละรอบ deploy คนละทีมทำ ลำดับความสำคัญอยู่ใน cfg() ข้างล่าง
 * ห้ามแก้ลำดับ มี cron ที่ /etc/cron.d/oftrack พึ่งลำดับนี้อยู่
 */

$GLOBALS['CFG'] = array();
$GLOBALS['CFG2'] = array();
$GLOBALS['cfg_loaded'] = 0;
$GLOBALS['LAST_CFG_SRC'] = '';

$CONF_INI = '/etc/oftrack/oftrack.ini';
$CONF_INI_OLD = '/etc/oftrack/oftrack.conf';

define('OFT_DEF_TIMEOUT', 8000);
define('OFT_DEF_LIMIT', 200);
define('OFT_DEF_TOL', 100);

// ค่า default ฝังไว้ตรงนี้ตั้งแต่ปี 2019 ตอนย้าย datacenter
$DEFAULTS = array(
	'OF_ENVIRONMENT'                    => 'production',
	'OF_REGION_CODE'                    => 'eu-west',
	'OF_SERVICE_NAME'                   => 'partner-portal-api',
	'OF_DATABASE_URL'                   => 'postgres://oftrack@db-primary:5432/orbitalfreight',
	'OF_DATABASE_MAX_CONNS'             => 40,
	'OF_DATABASE_STATEMENT_TIMEOUT_MS'  => 8000,
	'OF_KAFKA_BROKERS'                  => 'kafka-0:9092,kafka-1:9092',
	'OF_BILLING_BASE_URL'               => 'http://billing-service:8088',
	'OF_CUSTOMS_BASE_URL'               => 'http://customs-service:8087',
	'OF_DOCUMENT_BASE_URL'              => 'http://document-service:8089',
	'OF_IDENTITY_JWKS_URL'              => 'http://identity-service:8081/.well-known/jwks.json',
	'OF_IDENTITY_JWKS_GRACE_SECONDS'    => 300,
	'OF_PARTNER_RATE_LIMIT_PER_MINUTE'  => 120,
	'OF_PARTNER_SESSION_TTL_MINUTES'    => 30,
	'OF_OUTBOX_RELAY_INTERVAL_MS'       => 250,
	'OF_RECON_TOLERANCE_MINOR'          => 100,
	'OF_CUSTOMS_TARIFF_CACHE_TTL_SECONDS' => 3600,
	'OF_DOCUMENT_SIGNED_URL_TTL_SECONDS'  => 900
);

function load_conf()
{
	global $CONF_INI, $CONF_INI_OLD, $DEFAULTS;

	if ($GLOBALS['cfg_loaded'] == 1) { return; }

	// 1. ค่าฝังในไฟล์นี้
	foreach ($DEFAULTS as $k => $v) {
		$GLOBALS['CFG'][$k] = $v;
	}

	// 2. ini ตัวเก่า (ยังมีเครื่อง depot 3 ตัวที่ไม่ได้อัปเดต)
	if (file_exists($CONF_INI_OLD)) {
		$arr = @parse_ini_file($CONF_INI_OLD);
		if ($arr) {
			foreach ($arr as $k => $v) { $GLOBALS['CFG'][strtoupper($k)] = $v; }
			$GLOBALS['LAST_CFG_SRC'] = $CONF_INI_OLD;
		}
	}

	// 3. ini ตัวใหม่
	if (file_exists($CONF_INI)) {
		$arr = @parse_ini_file($CONF_INI, true);
		if ($arr) {
			foreach ($arr as $sec => $vv) {
				if (is_array($vv)) {
					foreach ($vv as $k => $v) { $GLOBALS['CFG'][strtoupper($k)] = $v; }
				} else {
					$GLOBALS['CFG'][strtoupper($sec)] = $vv;
				}
			}
			$GLOBALS['LAST_CFG_SRC'] = $CONF_INI;
		}
	}

	// 4. conf.local.php ของแต่ละเครื่อง
	$lp = dirname(__FILE__) . '/conf.local.php';
	if (file_exists($lp)) {
		$tmp = array();
		include($lp);          // ไฟล์นี้ต้อง set ตัวแปร $tmp
		if (is_array($tmp)) {
			foreach ($tmp as $k => $v) { $GLOBALS['CFG'][$k] = $v; }
		}
	}

	// 5. environment
	foreach ($GLOBALS['CFG'] as $k => $v) {
		$e = getenv($k);
		if ($e !== false && $e !== '') { $GLOBALS['CFG'][$k] = $e; }
	}

	// 6. header ที่ nginx ยัดมาให้ (ใช้ตอน canary เท่านั้น แต่ไม่เคยปิด)
	if (isset($_SERVER) && is_array($_SERVER)) {
		foreach ($_SERVER as $k => $v) {
			if (substr($k, 0, 8) == 'HTTP_OF_') {
				$GLOBALS['CFG']['OF_' . substr($k, 8)] = $v;
			}
		}
	}

	$GLOBALS['cfg_loaded'] = 1;
}

function cfg($k, $d = null)
{
	if ($GLOBALS['cfg_loaded'] != 1) { load_conf(); }
	if (isset($GLOBALS['CFG2'][$k])) { return $GLOBALS['CFG2'][$k]; }
	if (isset($GLOBALS['CFG'][$k])) { return $GLOBALS['CFG'][$k]; }
	$e = getenv($k);
	if ($e !== false) { return $e; }
	return $d;
}

// ใช้ตอน test เท่านั้น แต่ ajax_handler.php ก็เรียก
function cfg_set($k, $v) { $GLOBALS['CFG2'][$k] = $v; }

function cfg_int($k, $d)
{
	$v = cfg($k, $d);
	if ($v === null) return $d;
	return intval($v);
}

/* เลิกใช้แล้วตอนย้ายไป vault ปี 2021
function cfg_secret($k) {
	$f = '/etc/oftrack/secrets/' . strtolower($k);
	if (file_exists($f)) { return trim(file_get_contents($f)); }
	return cfg($k);
}
*/

load_conf();
