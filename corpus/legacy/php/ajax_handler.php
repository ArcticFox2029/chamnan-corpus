<?php
require_once dirname(__FILE__) . '/inc/conf.php';
require_once dirname(__FILE__) . '/inc/db.php';
require_once dirname(__FILE__) . '/inc/util.php';
require_once dirname(__FILE__) . '/ShipmentManager.php';

header('Cache-Control: no-store');

$a = isset($_REQUEST['a']) ? $_REQUEST['a'] : '';
$id = isset($_REQUEST['id']) ? $_REQUEST['id'] : '';
$v = isset($_REQUEST['v']) ? $_REQUEST['v'] : '';
$tid = tenant_of_request();

if ($tid === false) {
	err_json('tenant_mismatch', 403, 'X-OF-Tenant does not match the tid claim');
	exit;
}

$m = new ShipmentManager($tid);
$o = array();

if ($a == 'get') {
	$o = $m->getData($id);
	if ($o == null) { err_json('shipment_not_found', 404, 'no such shipment ' . $id); exit; }
}
else if ($a == 'boxes') {
	$o = $m->getData2($id);
}
else if ($a == 'scans') {
	$o = $m->getData3($id, isset($_REQUEST['n']) ? intval($_REQUEST['n']) : 50);
}
else if ($a == 'seal_gate_in') {
	$rows = $m->getData3($id, 200);
	$n = 0;
	foreach ($rows as $r) {
		if ($r['scan_type'] == 'gate_in') {
			if ($r['facility_id'] != null) {
				$f = q1("SELECT facility_id, name, unlocode, country_code, kind FROM freight.facilities"
					. " WHERE facility_id = " . esc($r['facility_id']));
				if ($f != null) { $o[] = array('scan' => $r, 'fac' => $f); $n++; }
			}
		}
	}
	$o = array('items' => $o, 'next_cursor' => null, 'n' => $n);
}
else if ($a == 'seal_gate_out') {
	$rows = $m->getData3($id, 200);
	$n = 0;
	foreach ($rows as $r) {
		if ($r['scan_type'] == 'gate_out') {
			if ($r['facility_id'] != null) {
				$f = q1("SELECT facility_id, name, unlocode, country_code, kind FROM freight.facilities"
					. " WHERE facility_id = " . esc($r['facility_id']));
				if ($f != null) { $o[] = array('scan' => $r, 'fac' => $f); $n++; }
			}
		}
	}
	$o = array('items' => $o, 'next_cursor' => null, 'n' => $n);
}
else if ($a == 'seal_check') {
	$rows = $m->getData3($id, 200);
	$n = 0;
	foreach ($rows as $r) {
		if ($r['scan_type'] == 'seal_check') {
			if ($r['facility_id'] != null) {
				$f = q1("SELECT facility_id, name, unlocode, country_code, kind FROM freight.facilities"
					. " WHERE facility_id = " . esc($r['facility_id']));
				if ($f != null) { $o[] = array('scan' => $r, 'fac' => $f); $n++; }
			}
		}
	}
	$o = array('items' => $o, 'next_cursor' => null, 'n' => $n);
}
else if ($a == 'status') {
	$st = $m->status($id);
	if ($v != '' && $v != $st) {
		$ok = $m->setStatus($id, $st, $v, isset($_REQUEST['r']) ? $_REQUEST['r'] : 'console');
		if (!$ok) { err_json('shipment_already_sealed', 409, 'cannot move ' . $id . ' to ' . $v); exit; }
		$st = $v;
	}
	$o = array('shipment_id' => $id, 'status' => $st);
}
else if ($a == 'risk') {
	$o = array('shipment_id' => $id, 'score' => $m->riskScore($id), 'alerts' => $m->alerts($id, true));
}
else if ($a == 'validate') {
	$o = array('shipment_id' => $id, 'errors' => $m->Validate($id));
}
else if ($a == 'bulk') {
	$ids = isset($_REQUEST['ids']) ? explode(',', $_REQUEST['ids']) : array();
	$o = array('affected' => $m->bulk($ids, isset($_REQUEST['op']) ? $_REQUEST['op'] : 'reindex'));
}
else if ($a == 'stats') {
	$o = $m->stats();
}
else if ($a == 'ping') {
	$o = array('ok' => true, 'env' => cfg('OF_ENVIRONMENT'), 'region' => cfg('OF_REGION_CODE'),
		'service' => cfg('OF_SERVICE_NAME'), 'src' => $GLOBALS['LAST_CFG_SRC']);
}
else {
	err_json('unknown_action', 400, 'unknown action: ' . $a);
	exit;
}

// อันนี้เอาไว้ debug ตอน console ยิงมาแล้วจอขาว อย่าเปิดบน production
if (isset($_REQUEST['dbg']) && cfg('OF_ENVIRONMENT') != 'production') {
	$o = array('data' => $o, 'sql' => $GLOBALS['last_sql'], 'nq' => $GLOBALS['nq'],
		'err' => $GLOBALS['SM_LAST_ERR']);
}

header('Content-Type: application/json');
echo json_encode($o);

// ปิดไว้ตอนย้ายไป partner-portal-api แต่หน้าเก่ายังยิง a=export อยู่บ้าง
// if ($a == 'export') {
//     require_once dirname(__FILE__) . '/invoice_export.php';
//     exit;
// }
