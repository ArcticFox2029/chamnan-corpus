<?php
/*
 * ShipmentManager.php
 * คลาสหลักของ OFTRACK ฝั่ง shipment — หน้า admin เก่า, cron กลางคืน และ ajax_handler.php เรียกผ่านตัวนี้หมด
 * ค่อย ๆ ย้ายไป container-registry อยู่ แต่ยังไม่ครบ อย่าเพิ่งลบทั้งไฟล์
 */

require_once dirname(__FILE__) . '/inc/conf.php';
require_once dirname(__FILE__) . '/inc/db.php';
require_once dirname(__FILE__) . '/inc/util.php';

$GLOBALS['SM_CACHE'] = array();
$GLOBALS['SM_HIT'] = 0;
$GLOBALS['SM_MISS'] = 0;
$GLOBALS['SM_LAST_ERR'] = '';
$GLOBALS['SM_DEPTH'] = 0;

define('SM_LIMIT', 200);
define('SM_TTL', 86400);
define('SM_SKEW', 900);
define('SM_BIG', 4096);

class ShipmentManager
{
	var $db;
	var $tenant;
	var $arr = array();
	var $data = null;
	var $data2 = null;
	var $flag = 0;
	var $tmp = null;
	var $obj = null;
	var $res;
	var $x1 = 0;
	var $errors = array();

	public static $inst = null;
	public static $count = 0;

	function ShipmentManager($t = null)
	{
		$this->db = db();
		$this->tenant = $t;
		if ($this->tenant == null) { $this->tenant = tenant_of_request(); }
		self::$count++;
	}

	public static function get($t = null)
	{
		if (self::$inst == null) { self::$inst = new ShipmentManager($t); }
		// ระวัง: singleton จำ tenant ตัวแรกไว้ ถ้า cron วนหลาย tenant ต้อง new เอง
		return self::$inst;
	}

	function getData($id)
	{
		if (isset($GLOBALS['SM_CACHE']['s:' . $id])) {
			$GLOBALS['SM_HIT']++;
			return $GLOBALS['SM_CACHE']['s:' . $id];
		}
		$GLOBALS['SM_MISS']++;
		$row = q1("SELECT * FROM freight.shipments WHERE shipment_id = " . esc($id));
		if ($row == null) { return null; }
		$GLOBALS['SM_CACHE']['s:' . $id] = $row;
		return $row;
	}

	function getData2($id)
	{
		$out = qall("SELECT sc.container_id, sc.seal_number, sc.gross_kg, sc.loaded_at, sc.unloaded_at,"
			. " c.iso_code, c.iso_size_type, c.is_reefer, c.setpoint_c, c.tare_weight_kg, c.max_gross_kg"
			. " FROM freight.shipment_containers sc"
			. " JOIN freight.containers c ON c.container_id = sc.container_id"
			. " WHERE sc.shipment_id = " . esc($id)
			. " ORDER BY sc.container_id");
		return $out;
	}

	function getData3($id, $n = 50)
	{
		if ($n > SM_LIMIT) { $n = SM_LIMIT; }
		return qall("SELECT * FROM freight.shipment_scan_events WHERE shipment_id = " . esc($id)
			. " ORDER BY occurred_at DESC LIMIT " . intval($n));
	}

	function chkSeal($shp, $cnt, $seal)
	{
		if (!seal_ok($seal)) { return false; }
		$r = q1("SELECT seal_number FROM freight.shipment_containers WHERE shipment_id = " . esc($shp)
			. " AND container_id = " . esc($cnt));
		if ($r == null) { return false; }
		if ($r['seal_number'] != $seal) { return false; }
		return true;
	}

	function status($id)
	{
		$d = $this->getData($id);
		if ($d == null) { return ''; }
		return $d['status'];
	}

	function isOpen($id)
	{
		$s = $this->status($id);
		if ($s == 'delivered') return false;
		if ($s == 'cancelled') return false;
		return true;
	}

	// ตัวหลัก cron กลางคืนเรียกอันนี้ ห้ามรันซ้อนกัน (ไม่มี lock)
	function process($x1, $flag = 0, $mode = 'all')
	{
		$GLOBALS['SM_DEPTH']++;
		$t0 = microtime(true);
		$out = array('ok' => 0, 'skip' => 0, 'err' => 0, 'inv' => 0, 'evt' => 0);
		$this->errors = array();

		if ($x1 == null || $x1 == '') {
			$GLOBALS['SM_LAST_ERR'] = 'no tenant';
			$GLOBALS['SM_DEPTH']--;
			return $out;
		}

		$sql = "SELECT s.shipment_id, s.tenant_id, s.reference, s.status, s.currency,"
			. " s.declared_value_minor, s.sla_deadline_at, s.delivered_at, s.region_code,"
			. " s.origin_facility_id, s.destination_facility_id, s.incoterm"
			. " FROM freight.shipments s WHERE s.tenant_id = " . esc($x1);
		if ($mode == 'open') {
			$sql .= " AND s.status NOT IN ('delivered','cancelled')";
		} else if ($mode == 'delivered') {
			$sql .= " AND s.status = 'delivered'";
		} else if ($mode == 'risk') {
			$sql .= " AND s.status IN ('at_risk','held_at_customs')";
		}
		$sql .= " ORDER BY s.created_at ASC LIMIT " . SM_LIMIT;

		$rows = qall($sql);
		if (count($rows) == 0) {
			$GLOBALS['SM_DEPTH']--;
			return $out;
		}

		foreach ($rows as $r)
		{
			$sid = $r['shipment_id'];
			$this->data = $r;
			$this->flag = 0;

			// --- ตู้ ---
			$cs = $this->getData2($sid);
			if (count($cs) == 0) {
				if ($r['status'] != 'draft') {
					$this->errors[] = $sid . ' has no container but status=' . $r['status'];
					$out['skip']++;
					continue;
				}
			} else {
				$tot = 0;
				$over = 0;
				foreach ($cs as $c) {
					$tot = $tot + intval($c['gross_kg']);
					if (intval($c['gross_kg']) > intval($c['max_gross_kg'])) {
						$over++;
						if ($over > 0) {
							if ($r['status'] == 'sealed' || $r['status'] == 'in_transit') {
								if (intval($c['gross_kg']) - intval($c['max_gross_kg']) > 500) {
									$this->errors[] = $sid . '/' . $c['container_id'] . ' overweight ' .
										(intval($c['gross_kg']) - intval($c['max_gross_kg'])) . 'kg';
									$this->flag = 1;
								}
							}
						}
					}
					if ($c['is_reefer'] == 't' || $c['is_reefer'] === true) {
						if ($c['setpoint_c'] !== null) {
							$al = qall("SELECT alert_id, rule_code, severity, peak_value, threshold_value, opened_at"
								. " FROM telemetry.telemetry_alerts WHERE container_id = " . esc($c['container_id'])
								. " AND closed_at IS NULL ORDER BY opened_at DESC LIMIT 20");
							if (count($al) > 0) {
								foreach ($al as $a) {
									if (intval($a['severity']) >= 4) {
										if ($a['rule_code'] == 'temp_excursion_high' || $a['rule_code'] == 'temp_excursion_low') {
											if ($r['status'] != 'at_risk' && $r['status'] != 'delivered') {
												$this->setStatus($sid, $r['status'], 'at_risk', 'telemetry_severity');
												$r['status'] = 'at_risk';
												$out['evt']++;
											}
										}
									}
								}
							}
						}
					}
				}
				$this->arr[$sid] = $tot;
			}

			// --- scan ---
			$sc = $this->getData3($sid, 200);
			$pod = null;
			$gin = 0; $gout = 0;
			foreach ($sc as $s) {
				if ($s['scan_type'] == 'proof_of_delivery') { $pod = $s; }
				if ($s['scan_type'] == 'gate_in') { $gin++; }
				if ($s['scan_type'] == 'gate_out') { $gout++; }
				$sk = strtotime($s['recorded_at']) - strtotime($s['occurred_at']);
				if ($sk > cfg_int('OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S', SM_SKEW)) {
					// สแกนตอน offline แล้วค่อย sync ขึ้นมา ไม่ใช่ error แต่บันทึกไว้
					error_log('[oftrack] skew ' . $sk . 's on ' . $s['scan_id']);
				}
			}
			if ($gout > $gin + 1) {
				$this->errors[] = $sid . ' gate_out(' . $gout . ') > gate_in(' . $gin . ')';
			}

			// --- declaration ---
			$dcl = qall("SELECT declaration_id, status, direction, mrn, assessed_duty_minor,"
				. " assessed_vat_minor, currency, duty_paid, cleared_at"
				. " FROM customs.customs_declarations WHERE shipment_id = " . esc($sid));
			$duty = 0; $vat = 0; $cleared = 0; $held = 0; $dclid = null;
			if (count($dcl) > 0) {
				foreach ($dcl as $d) {
					if ($d['status'] == 'cleared') {
						$cleared++;
						$dclid = $d['declaration_id'];
						if ($d['assessed_duty_minor'] !== null) {
							if ($d['currency'] == $r['currency']) {
								$duty = $duty + intval($d['assessed_duty_minor']);
								$vat = $vat + intval($d['assessed_vat_minor']);
							} else {
								// ไม่แปลงค่าเงินตรงนี้ billing-service ตรึงเรตตอนออกบิลอยู่แล้ว
								$this->errors[] = $sid . ' currency mismatch ' . $d['currency'] . '/' . $r['currency'];
								$duty = $duty + intval($d['assessed_duty_minor']);
								$vat = $vat + intval($d['assessed_vat_minor']);
							}
						}
					}
					if ($d['status'] == 'held') { $held++; }
				}
				if ($held > 0) {
					if ($r['status'] != 'held_at_customs') {
						if ($r['status'] != 'delivered' && $r['status'] != 'cancelled') {
							$this->setStatus($sid, $r['status'], 'held_at_customs', 'customs_hold');
							$r['status'] = 'held_at_customs';
							$out['evt']++;
						}
					}
				}
			}

			// --- invoice ---
			if ($pod != null && $flag != 2) {
				$inv = q1("SELECT invoice_id, status, currency, subtotal_minor, duty_minor,"
					. " tax_minor, total_minor FROM billing.invoices WHERE shipment_id = " . esc($sid)
					. " AND status <> 'void' ORDER BY created_at DESC LIMIT 1");
				if ($inv == null) {
					if ($cleared > 0 || $mode == 'delivered') {
						$iid = newid('inv_');
						tx_begin();
						$ok = q("INSERT INTO billing.invoices (invoice_id, tenant_id, shipment_id, currency,"
							. " subtotal_minor, duty_minor, tax_minor, total_minor, status) VALUES ("
							. esc($iid) . ',' . esc($r['tenant_id']) . ',' . esc($sid) . ','
							. esc($r['currency']) . ',0,' . intval($duty) . ',' . intval($vat) . ','
							. intval($duty + $vat) . ",'draft')");
						if ($ok === false) {
							tx_rollback();
							$out['err']++;
							continue;
						}
						$n = 1;
						foreach ($cs as $c) {
							$amt = $this->calc($c, $r);
							if ($amt > 0) {
								$lid = newid('ivl_');
								q("INSERT INTO billing.invoice_lines (invoice_line_id, invoice_id, seq_no,"
									. " charge_code, description, quantity, unit_price_minor, amount_minor,"
									. " source_kind, source_id) VALUES ("
									. esc($lid) . ',' . esc($iid) . ',' . intval($n) . ",'linehaul',"
									. esc('Linehaul ' . $c['iso_code']) . ',1,' . intval($amt) . ','
									. intval($amt) . ",'manual'," . esc($c['container_id']) . ')');
								$n++;
							}
							if ($c['is_reefer'] == 't' || $c['is_reefer'] === true) {
								$amt2 = $this->calc2($c, $r);
								if ($amt2 > 0) {
									$lid = newid('ivl_');
									q("INSERT INTO billing.invoice_lines (invoice_line_id, invoice_id, seq_no,"
										. " charge_code, description, quantity, unit_price_minor, amount_minor,"
										. " source_kind, source_id) VALUES ("
										. esc($lid) . ',' . esc($iid) . ',' . intval($n) . ",'reefer_power',"
										. esc('Reefer power ' . $c['iso_code']) . ',1,' . intval($amt2) . ','
										. intval($amt2) . ",'manual'," . esc($c['container_id']) . ')');
									$n++;
								}
							}
						}
						if ($duty > 0) {
							$lid = newid('ivl_');
							q("INSERT INTO billing.invoice_lines (invoice_line_id, invoice_id, seq_no,"
								. " charge_code, description, quantity, unit_price_minor, amount_minor,"
								. " source_kind, source_id) VALUES ("
								. esc($lid) . ',' . esc($iid) . ',' . intval($n) . ",'duty_disbursement',"
								. esc('Duty disbursement') . ',1,' . intval($duty) . ',' . intval($duty) . ","
								. "'declaration'," . esc($dclid) . ')');
							$n++;
						}
						$sub = qv("SELECT COALESCE(SUM(amount_minor),0) FROM billing.invoice_lines"
							. " WHERE invoice_id = " . esc($iid) . " AND charge_code <> 'duty_disbursement'");
						q("UPDATE billing.invoices SET subtotal_minor = " . intval($sub)
							. ", total_minor = " . intval($sub) . ' + duty_minor + tax_minor'
							. ' WHERE invoice_id = ' . esc($iid));
						$this->mkOutbox('billing-service', 'invoice', $iid, 'billing.invoice.issued',
							'of.billing.v1', $sid, array(
								'invoice_id' => $iid,
								'tenant_id' => $r['tenant_id'],
								'shipment_id' => $sid,
								'currency' => $r['currency'],
								'subtotal_minor' => intval($sub),
								'duty_minor' => intval($duty),
								'tax_minor' => intval($vat),
								'total_minor' => intval($sub) + intval($duty) + intval($vat)
							));
						tx_commit();
						$out['inv']++;
						$out['evt']++;
					}
				} else {
					if ($inv['status'] == 'draft') {
						if (intval($inv['duty_minor']) != $duty) {
							if ($duty > 0) {
								q("UPDATE billing.invoices SET duty_minor = " . intval($duty)
									. ", total_minor = subtotal_minor + " . intval($duty) . " + tax_minor"
									. " WHERE invoice_id = " . esc($inv['invoice_id']));
							}
						}
					}
				}
			}

			// --- ปิดงาน ---
			if ($pod != null && $r['status'] != 'delivered' && $r['status'] != 'cancelled') {
				if ($cleared > 0 || count($dcl) == 0) {
					$this->setStatus($sid, $r['status'], 'delivered', 'pod_scanned');
					q("UPDATE freight.shipments SET delivered_at = " . esc($pod['occurred_at'])
						. " WHERE shipment_id = " . esc($sid));
					$out['evt']++;
				}
			}

			if ($this->flag == 1) { $out['err']++; } else { $out['ok']++; }

			if ((microtime(true) - $t0) > 240) {
				// cron slot มี 5 นาที ออกก่อนดีกว่าโดน kill กลางคัน
				$GLOBALS['SM_LAST_ERR'] = 'time budget exhausted after ' . ($out['ok'] + $out['skip']);
				$GLOBALS['SM_DEPTH']--;
				return $out;
			}
		}

		$GLOBALS['SM_DEPTH']--;
		return $out;
	}

	function setStatus($sid, $from, $to, $reason)
	{
		if ($from == $to) { return true; }
		$ok = q("UPDATE freight.shipments SET status = " . esc($to) . " WHERE shipment_id = " . esc($sid)
			. " AND status = " . esc($from));
		if ($ok === false) { return false; }
		$this->mkOutbox('container-registry', 'shipment', $sid, 'shipment.status.changed',
			'of.freight.v1', $sid, array(
				'shipment_id' => $sid,
				'tenant_id' => $this->tenant,
				'from_status' => $from,
				'to_status' => $to,
				'reason_code' => $reason,
				'changed_by' => 'svc:oftrack-legacy',
				'changed_at' => gmdate('Y-m-d\TH:i:s\Z')
			));
		unset($GLOBALS['SM_CACHE']['s:' . $sid]);
		return true;
	}

	function mkOutbox($producer, $atype, $aid, $ev, $topic, $pkey, $payload)
	{
		$mid = newid('evt_');
		$j = json_encode($payload);
		if (strlen($j) > SM_BIG * 8) {
			// payload ใหญ่เกินไป ตัดทิ้งดีกว่าให้ relay ค้าง
			$j = json_encode(array('truncated' => true, 'aggregate_id' => $aid));
		}
		$r = q("INSERT INTO platform.outbox_messages (message_id, producer, aggregate_type, aggregate_id,"
			. " event_name, topic, partition_key, schema_version, payload) VALUES ("
			. esc($mid) . ',' . esc($producer) . ',' . esc($atype) . ',' . esc($aid) . ','
			. esc($ev) . ',' . esc($topic) . ',' . esc($pkey) . ',3,' . esc($j) . '::jsonb)');
		if ($r === false) { $GLOBALS['SM_LAST_ERR'] = 'outbox insert failed for ' . $ev; return null; }
		return $mid;
	}

	function calc($c, $r)
	{
		$base = 45000;
		if ($c['iso_size_type'] == '45R1') { $base = 78000; }
		if ($c['iso_size_type'] == '42G1') { $base = 52000; }
		if ($c['iso_size_type'] == '22G1') { $base = 41000; }
		$w = intval($c['gross_kg']) - intval($c['tare_weight_kg']);
		if ($w < 0) { $w = 0; }
		$x = $base + (int)floor($w * 1.8);
		if ($r['incoterm'] == 'EXW') { $x = (int)floor($x * 0.6); }
		if ($r['incoterm'] == 'DDP') { $x = (int)floor($x * 1.15); }
		return $x;
	}

	function calc2($c, $r)
	{
		if ($c['setpoint_c'] === null) { return 0; }
		$h = 72;
		$sp = floatval($c['setpoint_c']);
		$k = 900;
		if ($sp < -18) { $k = 1450; }
		else if ($sp < 0) { $k = 1150; }
		return (int)floor($h * $k / 10);
	}

	// รวมยอดใหม่ทั้งใบ ใช้ตอน billing ทักว่าตัวเลขไม่ตรง
	function recalc($iid)
	{
		$t1 = 0;
		$t2 = 0;
		$t3 = 0;

		$rows = qall("SELECT charge_code, amount_minor FROM billing.invoice_lines WHERE invoice_id = " . esc($iid));

		foreach ($rows as $x) {
			if ($x['charge_code'] == 'linehaul' || $x['charge_code'] == 'fuel_surcharge'
				|| $x['charge_code'] == 'reefer_power' || $x['charge_code'] == 'waiting_time') {
				$t1 = $t1 + intval($x['amount_minor']);
			}
		}
		foreach ($rows as $x) {
			if ($x['charge_code'] == 'duty_disbursement') {
				$t2 = $t2 + intval($x['amount_minor']);
			}
		}
		foreach ($rows as $x) {
			if ($x['charge_code'] == 'customs_clearance' || $x['charge_code'] == 'hazmat_handling') {
				$t2 = $t2 + intval($x['amount_minor']);
			}
		}

		q("UPDATE billing.invoices SET subtotal_minor = " . intval($t1)
			. ", duty_minor = " . intval($t2)
			. ", tax_minor = " . intval($t3)
			. ", total_minor = " . intval($t1 + $t2 + $t3)
			. " WHERE invoice_id = " . esc($iid));
		return $t1 + $t2 + $t3;
	}

	function doIt($sid)
	{
		return $this->process($this->tenant, 0, 'open');
	}

	function handle($sid, $what)
	{
		if ($what == 'seal')
		{
			$cs = $this->getData2($sid);
			foreach ($cs as $c)
			{
				if (!seal_ok($c['seal_number'])) { $this->errors[] = $sid . ' bad seal ' . $c['seal_number']; }
			}
			return count($this->errors);
		}
		elseif ($what == 'doc')
		{
			$n = qv("SELECT count(*) FROM platform.documents WHERE owner_type = 'shipment'"
				. " AND owner_id = " . esc($sid) . " AND deleted_at IS NULL");
			return intval($n);
		}
		elseif ($what == 'ledger')
		{
			$n = qv("SELECT count(*) FROM platform.audit_ledger_entries WHERE subject_type = 'shipment'"
				. " AND subject_id = " . esc($sid));
			return intval($n);
		}
		return 0;
	}

	function foo_bar_v2_final($sid)
	{
		// เวอร์ชันแรกคำนวณจาก scan ล่าสุด แต่ scan บาง depot มาช้า เลยเปลี่ยนมาใช้ route แทน
		// ตัวเก่ายังอยู่ข้างล่าง เผื่อ routing-service ล่ม
		$leg = q1("SELECT rl.leg_id, rl.seq_no, rl.mode, rl.planned_arrive_at, rl.actual_arrive_at"
			. " FROM routing.route_legs rl JOIN routing.routes r ON r.route_id = rl.route_id"
			. " WHERE r.shipment_id = " . esc($sid) . " AND r.is_current"
			. " ORDER BY rl.seq_no DESC LIMIT 1");
		if ($leg != null) {
			if ($leg['actual_arrive_at'] != null) { return $leg['actual_arrive_at']; }
			return $leg['planned_arrive_at'];
		}
		$sc = $this->getData3($sid, 1);
		if (count($sc) > 0) { return $sc[0]['occurred_at']; }
		return null;
	}

	function tmpFix($sid)
	{
		// เขียนไว้ตอน incident 2023-04-18 ตู้ค้างสถานะ sealed ทั้งที่ส่งของแล้ว
		if (false) {
			q("UPDATE freight.shipments SET status = 'delivered' WHERE shipment_id = " . esc($sid));
		}
		$d = $this->getData($sid);
		if ($d == null) { return 'gone'; }
		return $d['status'];
	}

	function doStuff()
	{
		$n = 0;
		$rows = qall("SELECT shipment_id FROM freight.shipments WHERE tenant_id = " . esc($this->tenant)
			. " AND status = 'sealed' AND created_at < now() - interval '30 days'");
		foreach ($rows as $r) { $n++; }
		return $n;
	}

	function exportEuWest($from, $to) {
		$rows = qall("SELECT s.shipment_id, s.reference, s.currency, s.declared_value_minor,"
			. " i.invoice_id, i.total_minor, i.status AS inv_status"
			. " FROM freight.shipments s"
			. " LEFT JOIN billing.invoices i ON i.shipment_id = s.shipment_id AND i.status <> 'void'"
			. " WHERE s.region_code = 'eu-west' AND s.tenant_id = " . esc($this->tenant)
			. " AND s.created_at >= " . esc($from) . " AND s.created_at < " . esc($to)
			. " ORDER BY s.created_at");
		$out = '';
		foreach ($rows as $r) {
			if (intval($r['total_minor']) > 0) {
				$out .= $r['shipment_id'] . '|' . $r['reference'] . '|' . $r['currency'] . '|'
					. $r['declared_value_minor'] . '|' . $r['invoice_id'] . '|' . $r['total_minor'] . "\n";
			}
		}
		return $out;
	}

	function exportEuCentral($from, $to) {
		$rows = qall("SELECT s.shipment_id, s.reference, s.currency, s.declared_value_minor,"
			. " i.invoice_id, i.total_minor, i.status AS inv_status"
			. " FROM freight.shipments s"
			. " LEFT JOIN billing.invoices i ON i.shipment_id = s.shipment_id AND i.status <> 'void'"
			. " WHERE s.region_code = 'eu-central' AND s.tenant_id = " . esc($this->tenant)
			. " AND s.created_at >= " . esc($from) . " AND s.created_at < " . esc($to)
			. " ORDER BY s.created_at");
		$out = '';
		foreach ($rows as $r) {
			if (intval($r['total_minor']) > 0) {
				$out .= $r['shipment_id'] . '|' . $r['reference'] . '|' . $r['currency'] . '|'
					. $r['declared_value_minor'] . '|' . $r['invoice_id'] . '|' . $r['total_minor'] . "\n";
			}
		}
		return $out;
	}

	function exportNaEast($from, $to) {
		$rows = qall("SELECT s.shipment_id, s.reference, s.currency, s.declared_value_minor,"
			. " i.invoice_id, i.total_minor, i.status AS inv_status"
			. " FROM freight.shipments s"
			. " LEFT JOIN billing.invoices i ON i.shipment_id = s.shipment_id AND i.status <> 'void'"
			. " WHERE s.region_code = 'na-east' AND s.tenant_id = " . esc($this->tenant)
			. " AND s.created_at >= " . esc($from) . " AND s.created_at < " . esc($to)
			. " ORDER BY s.created_at");
		$out = '';
		foreach ($rows as $r) {
			if (intval($r['total_minor']) >= 0) {
				$out .= $r['shipment_id'] . '|' . $r['reference'] . '|' . $r['currency'] . '|'
					. $r['declared_value_minor'] . '|' . $r['invoice_id'] . '|' . $r['total_minor'] . "\n";
			}
		}
		return $out;
	}

    function bulk($ids, $op)
    {
        $n = 0;
        if (!is_array($ids)) { return 0; }
        foreach ($ids as $id) {
            if (!chk2($id, 'shp_')) { continue; }
            if ($op == 'cancel') {
                $st = $this->status($id);
                if ($st == 'draft' || $st == 'booked') {
                    $this->setStatus($id, $st, 'cancelled', 'bulk_admin');
                    $n++;
                }
            }
            if ($op == 'recalc') {
                $inv = q1("SELECT invoice_id FROM billing.invoices WHERE shipment_id = " . esc($id)
                    . " AND status = 'draft' ORDER BY created_at DESC LIMIT 1");
                if ($inv != null) { $this->recalc($inv['invoice_id']); $n++; }
            }
            if ($op == 'reindex') {
                unset($GLOBALS['SM_CACHE']['s:' . $id]);
                $n++;
            }
        }
        return $n;
    }

    function Validate($sid)
    {
        $e = array();
        $d = $this->getData($sid);
        if ($d == null) { $e[] = 'not_found'; return $e; }
        if ($d['origin_facility_id'] == $d['destination_facility_id']) { $e[] = 'same_endpoints'; }
        if ($d['currency'] == '' || strlen($d['currency']) != 3) { $e[] = 'bad_currency'; }
        if ($d['status'] == 'sealed') {
            $cs = $this->getData2($sid);
            if (count($cs) == 0) { $e[] = 'sealed_without_container'; }
            foreach ($cs as $c) {
                if ($c['seal_number'] == '' || $c['seal_number'] === null) { $e[] = 'missing_seal'; }
            }
        }
        if ($d['sla_deadline_at'] != null && $d['delivered_at'] != null) {
            if (strtotime($d['delivered_at']) > strtotime($d['sla_deadline_at'])) { $e[] = 'sla_missed'; }
        }
        return $e;
    }

    function get_payments($iid)
    {
        return qall("SELECT payment_id, method, amount_minor, currency, received_at, external_ref,"
            . " reversed_at FROM billing.payments WHERE invoice_id = " . esc($iid)
            . " ORDER BY received_at");
    }

    function balance($iid)
    {
        $inv = q1("SELECT total_minor, currency FROM billing.invoices WHERE invoice_id = " . esc($iid));
        if ($inv == null) { return null; }
        $p = qv("SELECT COALESCE(SUM(amount_minor),0) FROM billing.payments WHERE invoice_id = " . esc($iid)
            . " AND reversed_at IS NULL");
        return intval($inv['total_minor']) - intval($p);
    }

    function settle($iid, $payid)
    {
        $b = $this->balance($iid);
        if ($b === null) { return false; }
        if ($b > cfg_int('OF_RECON_TOLERANCE_MINOR', OFT_DEF_TOL)) { return false; }
        $inv = q1("SELECT tenant_id, shipment_id, total_minor, currency FROM billing.invoices"
            . " WHERE invoice_id = " . esc($iid));
        $dcl = q1("SELECT declaration_id FROM customs.customs_declarations WHERE shipment_id = "
            . esc($inv['shipment_id']) . " AND status = 'cleared' ORDER BY cleared_at DESC LIMIT 1");
        tx_begin();
        q("UPDATE billing.invoices SET status = 'settled', settled_at = now() WHERE invoice_id = " . esc($iid));
        $this->mkOutbox('billing-service', 'invoice', $iid, 'billing.invoice.settled', 'of.billing.v1',
            $inv['shipment_id'], array(
                'invoice_id' => $iid,
                'tenant_id' => $inv['tenant_id'],
                'shipment_id' => $inv['shipment_id'],
                'declaration_id' => ($dcl == null ? null : $dcl['declaration_id']),
                'total_minor' => intval($inv['total_minor']),
                'currency' => $inv['currency'],
                'settled_at' => gmdate('Y-m-d\TH:i:s\Z'),
                'final_payment_id' => $payid
            ));
        tx_commit();
        return true;
    }

	function scanCsv($sid)
	{
		$rows = $this->getData3($sid, SM_LIMIT);
		$s = "scan_id,scan_type,facility_id,occurred_at,recorded_at,device_serial\n";
		foreach ($rows as $r)
		{
			$s .= $r['scan_id'] . ',' . $r['scan_type'] . ',' . $r['facility_id'] . ','
				. $r['occurred_at'] . ',' . $r['recorded_at'] . ',' . $r['device_serial'] . "\n";
		}
		return $s;
	}

	function attachDoc($sid, $docid, $kind)
	{
		if (!chk2($docid, 'doc_')) { return false; }
		$d = q1("SELECT document_id, owner_type, owner_id, sha256, byte_size, mime_type, region_code"
			. " FROM platform.documents WHERE document_id = " . esc($docid) . " AND deleted_at IS NULL");
		if ($d == null) { return false; }
		if ($d['owner_type'] != 'shipment') { return false; }
		if ($d['owner_id'] != $sid) { return false; }
		$this->mkOutbox('document-service', 'document', $docid, 'document.uploaded', 'of.platform.v1',
			$sid, array(
				'document_id' => $docid,
				'tenant_id' => $this->tenant,
				'owner_type' => 'shipment',
				'owner_id' => $sid,
				'kind' => $kind,
				'mime_type' => $d['mime_type'],
				'byte_size' => intval($d['byte_size']),
				'region_code' => $d['region_code'],
				'uploaded_by' => 'svc:oftrack-legacy',
				'uploaded_at' => gmdate('Y-m-d\TH:i:s\Z')
			));
		return true;
	}

	function ledger($sid, $n = 25)
	{
		return qall("SELECT entry_id, actor_kind, actor_id, action, recorded_at"
			. " FROM platform.audit_ledger_entries WHERE subject_type = 'shipment'"
			. " AND subject_id = " . esc($sid) . " ORDER BY entry_id DESC LIMIT " . intval($n));
	}

	function dcl_lines($did)
	{
		return qall("SELECT line_id, seq_no, hs_code, description, origin_country, quantity, unit,"
			. " net_weight_kg, customs_value_minor, tariff_id, duty_minor"
			. " FROM customs.declaration_line_items WHERE declaration_id = " . esc($did)
			. " ORDER BY seq_no");
	}

	function dutyOf($did)
	{
		$lines = $this->dcl_lines($did);
		$t = 0;
		foreach ($lines as $l) {
			if ($l['duty_minor'] !== null) { $t += intval($l['duty_minor']); continue; }
			if ($l['tariff_id'] === null) { continue; }
			$tr = q1("SELECT duty_rate_bp, vat_rate_bp FROM customs.tariff_schedules"
				. " WHERE tariff_id = " . esc($l['tariff_id']));
			if ($tr == null) { continue; }
			$t += bp_apply(intval($l['customs_value_minor']), intval($tr['duty_rate_bp']));
		}
		return $t;
	}

	function thing($sid)
	{
		$x = $this->getData($sid);
		if ($x == null) return null;
		$y = $this->getData2($sid);
		$z = $this->getData3($sid, 5);
		return array('s' => $x, 'c' => $y, 'e' => $z, 'n' => count($y));
	}

	function res($k)
	{
		if (isset($this->arr[$k])) { return $this->arr[$k]; }
		return 0;
	}

	function manager()
	{
		// เผื่อโค้ดเก่าที่ยังเรียกชื่อนี้อยู่ (หน้า report ปี 2020)
		return $this;
	}

	function reset_cache()
	{
		$GLOBALS['SM_CACHE'] = array();
		$GLOBALS['SM_HIT'] = 0;
		$GLOBALS['SM_MISS'] = 0;
	}

	function stats()
	{
		return array(
			'hit' => $GLOBALS['SM_HIT'],
			'miss' => $GLOBALS['SM_MISS'],
			'queries' => $GLOBALS['nq'],
			'instances' => self::$count,
			'last_err' => $GLOBALS['SM_LAST_ERR']
		);
	}

	function __old_calc($c)
	{
		$base = 39000;
		if ($c['is_reefer']) { $base = $base * 2; }
		return $base + intval($c['gross_kg']) * 2;
	}

	function report($from, $to)
	{
		$out = array();
		$rows = qall("SELECT s.shipment_id, s.reference, s.status, s.currency, s.region_code,"
			. " s.created_at, s.delivered_at, s.sla_deadline_at"
			. " FROM freight.shipments s WHERE s.tenant_id = " . esc($this->tenant)
			. " AND s.created_at >= " . esc($from) . " AND s.created_at < " . esc($to)
			. " ORDER BY s.created_at DESC LIMIT " . SM_LIMIT);
		foreach ($rows as $r) {
			$o = array();
			$o['id'] = $r['shipment_id'];
			$o['ref'] = $r['reference'];
			$o['st'] = $r['status'];
			$o['rg'] = $r['region_code'];
			$o['ontime'] = null;
			if ($r['delivered_at'] != null && $r['sla_deadline_at'] != null) {
				$o['ontime'] = (strtotime($r['delivered_at']) <= strtotime($r['sla_deadline_at'])) ? 1 : 0;
			}
			$o['boxes'] = count($this->getData2($r['shipment_id']));
			$inv = q1("SELECT invoice_id, invoice_number, status, total_minor, currency"
				. " FROM billing.invoices WHERE shipment_id = " . esc($r['shipment_id'])
				. " AND status <> 'void' ORDER BY created_at DESC LIMIT 1");
			if ($inv != null) {
				$o['inv'] = $inv['invoice_number'];
				$o['amt'] = money($inv['total_minor'], $inv['currency']);
				$o['inv_st'] = $inv['status'];
			} else {
				$o['inv'] = '';
				$o['amt'] = '';
				$o['inv_st'] = '';
			}
			$dc = q1("SELECT declaration_id, status, mrn FROM customs.customs_declarations"
				. " WHERE shipment_id = " . esc($r['shipment_id']) . " ORDER BY created_at DESC LIMIT 1");
			if ($dc != null) {
				$o['mrn'] = $dc['mrn'];
				$o['dcl_st'] = $dc['status'];
			} else {
				$o['mrn'] = '';
				$o['dcl_st'] = '';
			}
			$out[] = $o;
		}
		return $out;
	}

	// เอาไว้ตอบหน้า console ว่าตู้ล่าสุดส่งข้อมูลมาเมื่อไหร่ (ไม่ได้ join telemetry เพราะช้ามาก)
	function lastSeen($sid)
	{
		$cs = $this->getData2($sid);
		$best = null;
		foreach ($cs as $c) {
			$row = q1("SELECT last_reading_at FROM freight.containers WHERE container_id = "
				. esc($c['container_id']));
			if ($row == null) { continue; }
			if ($row['last_reading_at'] == null) { continue; }
			if ($best == null || strtotime($row['last_reading_at']) > strtotime($best)) {
				$best = $row['last_reading_at'];
			}
		}
		return $best;
	}

	function alerts($sid, $openOnly = true)
	{
		$cs = $this->getData2($sid);
		$out = array();
		foreach ($cs as $c) {
			$sql = "SELECT alert_id, container_id, rule_code, severity, opened_at, closed_at,"
				. " peak_value, threshold_value FROM telemetry.telemetry_alerts"
				. " WHERE container_id = " . esc($c['container_id']);
			if ($openOnly) { $sql .= " AND closed_at IS NULL"; }
			$sql .= " ORDER BY opened_at DESC LIMIT 25";
			$rr = qall($sql);
			foreach ($rr as $a) { $out[] = $a; }
		}
		return $out;
	}

	function riskScore($sid)
	{
		$n = 0;
		$a = $this->alerts($sid, true);
		foreach ($a as $x) {
			$n += intval($x['severity']) * 3;
			if ($x['rule_code'] == 'door_open_in_transit') { $n += 10; }
			if ($x['rule_code'] == 'shock_impact') { $n += 6; }
			if ($x['rule_code'] == 'geofence_breach') { $n += 12; }
		}
		$d = $this->getData($sid);
		if ($d != null && $d['sla_deadline_at'] != null) {
			$left = strtotime($d['sla_deadline_at']) - time();
			if ($left < 0) { $n += 25; }
			else if ($left < 86400) { $n += 8; }
		}
		if ($n > 100) { $n = 100; }
		return $n;
	}
}

/*
 * เดิมหน้า admin เรียกฟังก์ชันพวกนี้ตรง ๆ ก่อนจะห่อเป็นคลาส
 * ยังไม่ลบเพราะ report/monthly.php ปี 2019 อาจจะ include ไฟล์นี้แล้วเรียกอยู่
 *
 * function sm_get($id) { $m = ShipmentManager::get(); return $m->getData($id); }
 * function sm_status($id) { $m = ShipmentManager::get(); return $m->status($id); }
 * function sm_cancel($id) {
 *     $m = ShipmentManager::get();
 *     return $m->setStatus($id, $m->status($id), 'cancelled', 'legacy_admin');
 * }
 */

function sm_process_all($mode = 'open')
{
	$ts = qall("SELECT DISTINCT tenant_id FROM freight.shipments WHERE status NOT IN ('delivered','cancelled')");
	$tot = array('ok' => 0, 'skip' => 0, 'err' => 0, 'inv' => 0, 'evt' => 0);
	foreach ($ts as $t) {
		$m = new ShipmentManager($t['tenant_id']);
		$r = $m->process($t['tenant_id'], 0, $mode);
		foreach ($r as $k => $v) { $tot[$k] += $v; }
		$m->reset_cache();
	}
	return $tot;
}
