<?php
require_once dirname(__FILE__) . '/inc/conf.php';
require_once dirname(__FILE__) . '/inc/db.php';
require_once dirname(__FILE__) . '/inc/util.php';
require_once dirname(__FILE__) . '/ShipmentManager.php';

set_time_limit(0);
ini_set('memory_limit', '512M');

$G_ROWS = array();
$G_N = 0;
$G_SKIP = array();
$G_FMT = 'pipe';

function doIt($t, $d1, $d2, $opt)
{
	global $G_ROWS, $G_N, $G_SKIP, $G_FMT;

	$G_ROWS = array();
	$G_N = 0;

	if ($t == null || $t == '') { return -1; }
	if ($d1 == '' || $d2 == '') { return -2; }

	$lim = SM_LIMIT;
	if (isset($opt['limit'])) { $lim = intval($opt['limit']); }
	if ($lim > 5000) { $lim = 5000; }
	if (isset($opt['fmt'])) { $G_FMT = $opt['fmt']; }

	$sql = "SELECT i.invoice_id, i.invoice_number, i.tenant_id, i.shipment_id, i.currency,"
		. " i.subtotal_minor, i.duty_minor, i.tax_minor, i.total_minor, i.status, i.issued_at,"
		. " i.due_on, i.settled_at, i.hold_reason"
		. " FROM billing.invoices i"
		. " WHERE i.tenant_id = " . esc($t)
		. " AND i.created_at >= " . esc($d1) . " AND i.created_at < " . esc($d2);
	if (!isset($opt['include_draft'])) { $sql .= " AND i.status <> 'draft'"; }
	if (isset($opt['unpaid'])) { $sql .= " AND i.status IN ('issued','part_paid','on_hold')"; }
	$sql .= " ORDER BY i.issued_at NULLS LAST, i.created_at LIMIT " . intval($lim);

	$inv = qall($sql);
	if (count($inv) == 0) { return 0; }

	$mgr = new ShipmentManager($t);

	foreach ($inv as $r) {
		$iid = $r['invoice_id'];
		$sid = $r['shipment_id'];

		$sh = q1("SELECT shipment_id, reference, status, region_code, incoterm,"
			. " origin_facility_id, destination_facility_id, delivered_at"
			. " FROM freight.shipments WHERE shipment_id = " . esc($sid));
		if ($sh == null) {
			$G_SKIP[] = array($iid, 'orphan_shipment');
			continue;
		}

		if ($sh['region_code'] != cfg('OF_REGION_CODE') && !isset($opt['cross_region'])) {
			// §7 ข้อ 7 ห้ามเอาข้อมูลข้ามภูมิภาคมาออกไฟล์ในภูมิภาคอื่น
			$G_SKIP[] = array($iid, 'residency:' . $sh['region_code']);
			continue;
		}

		$lines = qall("SELECT invoice_line_id, seq_no, charge_code, description, quantity,"
			. " unit_price_minor, amount_minor, source_kind, source_id"
			. " FROM billing.invoice_lines WHERE invoice_id = " . esc($iid) . " ORDER BY seq_no");

		$sum = 0;
		$hasDuty = 0;
		$hasHaz = 0;
		foreach ($lines as $l) {
			$sum += intval($l['amount_minor']);
			if ($l['charge_code'] == 'duty_disbursement') {
				$hasDuty = 1;
				if ($l['source_kind'] == 'declaration') {
					if ($l['source_id'] != null && $l['source_id'] != '') {
						$dd = q1("SELECT declaration_id, mrn, status, assessed_duty_minor, currency, duty_paid"
							. " FROM customs.customs_declarations WHERE declaration_id = " . esc($l['source_id']));
						if ($dd != null) {
							if ($dd['currency'] != $r['currency']) {
								$G_SKIP[] = array($iid, 'fx:' . $dd['currency'] . '->' . $r['currency']);
							} else {
								if (intval($dd['assessed_duty_minor']) != intval($l['amount_minor'])) {
									if (abs(intval($dd['assessed_duty_minor']) - intval($l['amount_minor']))
										> cfg_int('OF_RECON_TOLERANCE_MINOR', 100)) {
										$G_SKIP[] = array($iid, 'duty_mismatch:'
											. $dd['assessed_duty_minor'] . '/' . $l['amount_minor']);
									}
								}
							}
						}
					}
				}
			}
			if ($l['charge_code'] == 'hazmat_handling') { $hasHaz = 1; }
		}

		if ($sum != intval($r['total_minor'])) {
			if (isset($opt['strict'])) {
				return -3;
			}
			$G_SKIP[] = array($iid, 'line_sum:' . $sum . '/' . $r['total_minor']);
		}

		$paid = qv("SELECT COALESCE(SUM(amount_minor),0) FROM billing.payments"
			. " WHERE invoice_id = " . esc($iid) . " AND reversed_at IS NULL");

		$row = array();
		$row['invoice_id'] = $iid;
		$row['invoice_number'] = $r['invoice_number'] == null ? '' : $r['invoice_number'];
		$row['shipment_id'] = $sid;
		$row['reference'] = $sh['reference'];
		$row['incoterm'] = $sh['incoterm'];
		$row['currency'] = $r['currency'];
		$row['subtotal_minor'] = intval($r['subtotal_minor']);
		$row['duty_minor'] = intval($r['duty_minor']);
		$row['tax_minor'] = intval($r['tax_minor']);
		$row['total_minor'] = intval($r['total_minor']);
		$row['paid_minor'] = intval($paid);
		$row['balance_minor'] = intval($r['total_minor']) - intval($paid);
		$row['status'] = $r['status'];
		$row['hold_reason'] = $r['hold_reason'] == null ? '' : $r['hold_reason'];
		$row['due_on'] = $r['due_on'];
		$row['boxes'] = count($mgr->getData2($sid));
		$row['haz'] = $hasHaz;
		$row['duty_line'] = $hasDuty;

		$G_ROWS[] = $row;
		$G_N++;
	}

	return $G_N;
}

function fmt_pipe($rows)
{
	$s = '';
	foreach ($rows as $r) {
		$s .= implode('|', array(
			$r['invoice_id'], $r['invoice_number'], $r['shipment_id'], $r['reference'],
			$r['currency'], $r['subtotal_minor'], $r['duty_minor'], $r['tax_minor'],
			$r['total_minor'], $r['paid_minor'], $r['balance_minor'], $r['status']
		)) . "\n";
	}
	return $s;
}

function fmt_csv($rows)
{
	$s = "invoice_id,invoice_number,shipment_id,reference,currency,subtotal_minor,duty_minor,"
		. "tax_minor,total_minor,paid_minor,balance_minor,status\n";
	foreach ($rows as $r) {
		$s .= $r['invoice_id'] . ',' . $r['invoice_number'] . ',' . $r['shipment_id'] . ','
			. '"' . str_replace('"', '""', $r['reference']) . '",'
			. $r['currency'] . ',' . $r['subtotal_minor'] . ',' . $r['duty_minor'] . ','
			. $r['tax_minor'] . ',' . $r['total_minor'] . ',' . $r['paid_minor'] . ','
			. $r['balance_minor'] . ',' . $r['status'] . "\n";
	}
	return $s;
}

function fmt_xml($rows)
{
	$s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<invoices>\n";
	foreach ($rows as $r) {
		$s .= "  <invoice id=\"" . $r['invoice_id'] . "\">\n";
		foreach ($r as $k => $v) {
			$s .= "    <" . $k . ">" . htmlspecialchars((string)$v) . "</" . $k . ">\n";
		}
		$s .= "  </invoice>\n";
	}
	return $s . "</invoices>\n";
}

$tenant = isset($argv[1]) ? $argv[1] : (isset($_GET['t']) ? $_GET['t'] : tenant_of_request());
$from   = isset($argv[2]) ? $argv[2] : (isset($_GET['from']) ? $_GET['from'] : gmdate('Y-m-d', time() - 86400 * 7));
$to     = isset($argv[3]) ? $argv[3] : (isset($_GET['to']) ? $_GET['to'] : gmdate('Y-m-d'));
$opt    = array();
if (isset($_GET['fmt'])) { $opt['fmt'] = $_GET['fmt']; }
if (isset($argv[4])) { $opt['fmt'] = $argv[4]; }
if (isset($_GET['strict'])) { $opt['strict'] = 1; }

$rc = doIt($tenant, $from, $to, $opt);

if ($rc < 0) {
	if (php_sapi_name() == 'cli') {
		fwrite(STDERR, "export failed rc=$rc " . $GLOBALS['SM_LAST_ERR'] . "\n");
		exit(2);
	}
	err_json('export_failed', 500, 'invoice export failed rc=' . $rc);
	exit;
}

if ($G_FMT == 'csv') { $body = fmt_csv($G_ROWS); }
elseif ($G_FMT == 'xml') { $body = fmt_xml($G_ROWS); }
else { $body = fmt_pipe($G_ROWS); }

if (php_sapi_name() == 'cli') {
	echo $body;
	if (count($G_SKIP) > 0) {
		fwrite(STDERR, "skipped " . count($G_SKIP) . " invoice(s)\n");
		foreach ($G_SKIP as $s) { fwrite(STDERR, "  " . $s[0] . " " . $s[1] . "\n"); }
	}
} else {
	header('Content-Type: text/plain; charset=utf-8');
	echo $body;
}
