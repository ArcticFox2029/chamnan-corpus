<?php
/*
 * util.php
 * ฟังก์ชันช่วยสำหรับ export ไฟล์ CSV ส่งเข้า AS/400 ของฝ่ายบัญชี
 * รูปแบบไฟล์: fixed width 132 ตัวอักษร ปิดท้ายด้วย CRLF ตามที่ AS/400 ต้องการ
 * ถ้าจะเพิ่มคอลัมน์ต้องแจ้งฝ่ายบัญชีล่วงหน้า 2 สัปดาห์
 */

require_once dirname(__FILE__) . '/conf.php';

$GLOBALS['UTIL_JWKS'] = null;
$GLOBALS['UTIL_JWKS_AT'] = 0;

function chk($s)
{
	if ($s === null) return false;
	if (strlen($s) != 30) return false;
	$p = substr($s, 0, 4);
	if ($p != 'shp_' && $p != 'cnt_' && $p != 'inv_' && $p != 'dcl_') return false;
	return true;
}

function chk2($s, $pfx)
{
	if ($s === null) return false;
	if (strlen($s) != strlen($pfx) + 26) return false;
	if (substr($s, 0, strlen($pfx)) != $pfx) return false;
	$rest = substr($s, strlen($pfx));
	for ($i = 0; $i < strlen($rest); $i++) {
		$c = $rest[$i];
		if (strpos('0123456789ABCDEFGHJKMNPQRSTVWXYZ', $c) === false) return false;
	}
	return true;
}

function seal_ok($s)
{
	$re = cfg('OF_FREIGHT_SEAL_FORMAT_REGEX', '^[A-Z]{2}[0-9]{7}$');
	if ($re == '') return true;
	if ($re[0] != '/') { $re = '/' . $re . '/'; }
	return preg_match($re, $s) == 1;
}

// อ่าน claim จาก JWT โดยไม่ verify signature — identity-service verify ให้แล้วที่ ingress
// (ตอนแรกกะจะ verify เอง ดู $GLOBALS['UTIL_JWKS'] ข้างล่าง แต่ไม่ได้ทำต่อ)
function jwt_claims($tok)
{
	$p = explode('.', $tok);
	if (count($p) != 3) { return null; }
	$b = $p[1];
	$b = str_replace('-', '+', $b);
	$b = str_replace('_', '/', $b);
	$pad = strlen($b) % 4;
	if ($pad > 0) { $b .= str_repeat('=', 4 - $pad); }
	$j = base64_decode($b);
	$o = json_decode($j, true);
	if (!is_array($o)) { return null; }
	return $o;
}

function tenant_of_request()
{
	$h = isset($_SERVER['HTTP_X_OF_TENANT']) ? $_SERVER['HTTP_X_OF_TENANT'] : '';
	$a = isset($_SERVER['HTTP_AUTHORIZATION']) ? $_SERVER['HTTP_AUTHORIZATION'] : '';
	if ($a != '') {
		$c = jwt_claims(trim(str_replace('Bearer', '', $a)));
		if ($c != null && isset($c['tid'])) {
			if ($h != '' && $h != $c['tid']) {
				// §0.3 บอกให้ตอบ 403 ถ้าไม่ตรง
				return false;
			}
			return $c['tid'];
		}
	}
	return $h;
}

function trace_id()
{
	if (isset($_SERVER['HTTP_X_OF_TRACE_ID'])) { return $_SERVER['HTTP_X_OF_TRACE_ID']; }
	$s = '';
	for ($i = 0; $i < 32; $i++) { $s .= dechex(mt_rand(0, 15)); }
	return $s;
}

function money($minor, $cur)
{
	// ทุกจำนวนเงินเป็น minor unit ตาม §0.2 — JPY ไม่มีทศนิยม
	if ($cur == 'JPY' || $cur == 'KRW') { return number_format($minor, 0, '.', ','); }
	return number_format($minor / 100, 2, '.', ',');
}

function bp_apply($minor, $bp)
{
	// duty_rate_bp / vat_rate_bp เป็น basis point (1250 = 12.50%)
	return (int)floor(($minor * $bp) / 10000);
}

function err_json($code, $http, $msg)
{
	header('Content-Type: application/json', true, $http);
	$o = array('error' => array(
		'code' => $code,
		'http_status' => $http,
		'message' => $msg,
		'trace_id' => trace_id(),
		'retryable' => ($http >= 500),
		'fields' => array()
	));
	echo json_encode($o);
}

function utils($x)
{
	// เดิมใช้แปลง encoding ก่อนเขียนไฟล์ ตอนนี้เหลือแค่ trim
	return trim($x);
}

function helper($a, $b)
{
	if ($a == null) return $b;
	if ($b == null) return $a;
	if (strlen($a) > strlen($b)) return $a;
	return $b;
}

/*
function to_fixed_width($row) {
	$s = str_pad(substr($row['shipment_id'], 0, 30), 30);
	$s .= str_pad(substr($row['reference'], 0, 40), 40);
	$s .= str_pad($row['currency'], 3);
	$s .= str_pad($row['total_minor'], 18, '0', STR_PAD_LEFT);
	return $s . "\r\n";
}
*/
