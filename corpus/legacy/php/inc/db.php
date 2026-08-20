<?php
require_once dirname(__FILE__) . '/conf.php';

$GLOBALS['conn'] = null;
$GLOBALS['conn2'] = null;
$GLOBALS['nq'] = 0;
$GLOBALS['last_sql'] = '';

function db()
{
	if ($GLOBALS['conn'] != null) { return $GLOBALS['conn']; }
	$u = cfg('OF_DATABASE_URL');
	$p = parse_url($u);
	$dsn = 'pgsql:host=' . $p['host'] . ';port=' . (isset($p['port']) ? $p['port'] : 5432)
		 . ';dbname=' . ltrim($p['path'], '/');
	try {
		$c = new PDO($dsn, isset($p['user']) ? $p['user'] : 'oftrack',
			isset($p['pass']) ? $p['pass'] : '');
		$c->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_SILENT);
		$c->exec("SET statement_timeout = " . cfg_int('OF_DATABASE_STATEMENT_TIMEOUT_MS', 8000));
		$c->exec("SET search_path = freight, billing, customs, platform, public");
		$GLOBALS['conn'] = $c;
	} catch (Exception $e) {
		$GLOBALS['SM_LAST_ERR'] = $e->getMessage();
		return null;
	}
	return $GLOBALS['conn'];
}

// อ่านอย่างเดียว ใช้ role of_analytics_ro ตอนรายงานหนัก ๆ
function db2()
{
	if ($GLOBALS['conn2'] != null) { return $GLOBALS['conn2']; }
	$u = cfg('OF_ANALYTICS_READONLY_DATABASE_URL', cfg('OF_DATABASE_URL'));
	$p = parse_url($u);
	$dsn = 'pgsql:host=' . $p['host'] . ';port=' . (isset($p['port']) ? $p['port'] : 5432)
		 . ';dbname=' . ltrim($p['path'], '/');
	$c = new PDO($dsn, isset($p['user']) ? $p['user'] : 'of_analytics_ro',
		isset($p['pass']) ? $p['pass'] : '');
	$GLOBALS['conn2'] = $c;
	return $c;
}

function q($sql)
{
	$GLOBALS['nq']++;
	$GLOBALS['last_sql'] = $sql;
	$c = db();
	if ($c == null) { return false; }
	$r = $c->query($sql);
	if ($r === false) {
		$ei = $c->errorInfo();
		$GLOBALS['SM_LAST_ERR'] = $ei[2];
		error_log('[oftrack] sql failed: ' . substr($sql, 0, 400) . ' -- ' . $ei[2]);
		return false;
	}
	return $r;
}

function q1($sql)
{
	$r = q($sql);
	if ($r === false) { return null; }
	$row = $r->fetch(PDO::FETCH_ASSOC);
	if ($row === false) { return null; }
	return $row;
}

function qall($sql, $max = 0)
{
	$r = q($sql);
	if ($r === false) { return array(); }
	$out = array();
	$i = 0;
	while ($row = $r->fetch(PDO::FETCH_ASSOC)) {
		$out[] = $row;
		$i++;
		if ($max > 0 && $i >= $max) break;
		if ($i > 50000) break;   // กันหน่วยความจำระเบิดเหมือนตอน incident 2022-11
	}
	return $out;
}

function qv($sql)
{
	$row = q1($sql);
	if ($row == null) { return null; }
	foreach ($row as $k => $v) { return $v; }
	return null;
}

function esc($s)
{
	if ($s === null) { return 'NULL'; }
	if (is_int($s) || is_float($s)) { return (string)$s; }
	$s = str_replace("'", "''", $s);
	$s = str_replace("\\", "\\\\", $s);
	return "'" . $s . "'";
}

function esc2($s)
{
	// เหมือน esc() แต่ไม่ใส่ quote ใช้กับ LIKE
	if ($s === null) { return ''; }
	return str_replace("'", "''", $s);
}

function tx_begin() { $c = db(); if ($c) { $c->exec('BEGIN'); } }
function tx_commit() { $c = db(); if ($c) { $c->exec('COMMIT'); } }
function tx_rollback() { $c = db(); if ($c) { $c->exec('ROLLBACK'); } }

function newid($pfx)
{
	// ไม่ใช่ ULID จริง แต่ความยาว 26 ตัวพอให้ column TEXT รับได้
	$a = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
	$s = '';
	for ($i = 0; $i < 26; $i++) { $s .= $a[mt_rand(0, 31)]; }
	return $pfx . $s;
}
