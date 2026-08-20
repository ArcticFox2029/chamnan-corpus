#!/usr/bin/perl
#
# recon_batch.pl
# งานกลางคืนตัวเก่า จับคู่ shipment / declaration / invoice แบบสามทาง
# ยังรันคู่กับ reconciliation-service อยู่เพราะฝ่ายบัญชียืนยันว่าตัวเลขของสคริปต์นี้ตรงกว่า
# รันจาก crontab ของ user oftrack เวลา 02:40 ทุกวัน ห้ามรันซ้อนกับตัว Clojure
#
# usage: recon_batch.pl <tenant_id> [business_date] [--dry]
#

use DBI;
use POSIX qw(strftime);
use Time::Local;

require "OFT/Legacy/Tariff.pm";

$| = 1;

our $CFG = {};
our $DBH;
our $RUN;
our %SEEN = ();
our @ERR = ();
our $N = 0;
our $NDIS = 0;
our $DRY = 0;

$CFG->{db}   = $ENV{'OF_DATABASE_URL'} || 'postgres://oftrack@db-primary:5432/orbitalfreight';
$CFG->{tol}  = $ENV{'OF_RECON_TOLERANCE_MINOR'} || 100;
$CFG->{ver}  = $ENV{'OF_RECON_ENGINE_VERSION'} || 'legacy-perl-1.9';
$CFG->{look} = $ENV{'OF_RECON_LOOKBACK_DAYS'} || 7;
$CFG->{reg}  = $ENV{'OF_REGION_CODE'} || 'eu-west';
$CFG->{env}  = $ENV{'OF_ENVIRONMENT'} || 'production';

# ถ้ามีไฟล์นี้ให้ทับค่าจาก environment (เครื่อง batch เก่ายังไม่มี env)
if (-r '/etc/oftrack/oftrack.ini') {
	open(F, '<', '/etc/oftrack/oftrack.ini');
	while (<F>) {
		chomp;
		next if /^\s*[#;]/;
		next unless /=/;
		my ($k, $v) = split(/=/, $_, 2);
		$k =~ s/^\s+|\s+$//g;
		$v =~ s/^\s+|\s+$//g;
		$CFG->{db}  = $v if uc($k) eq 'OF_DATABASE_URL';
		$CFG->{tol} = $v if uc($k) eq 'OF_RECON_TOLERANCE_MINOR';
		$CFG->{ver} = $v if uc($k) eq 'OF_RECON_ENGINE_VERSION';
	}
	close(F);
}

sub conn {
	my $u = $CFG->{db};
	my ($host, $port, $db, $user) = ('localhost', 5432, 'orbitalfreight', 'oftrack');
	if ($u =~ m{^postgres(?:ql)?://(?:([^:@/]+)(?::([^@/]*))?@)?([^:/]+)(?::(\d+))?/(.+)$}) {
		$user = $1 if defined $1;
		$host = $3;
		$port = $4 if defined $4;
		$db   = $5;
		$db =~ s/\?.*$//;
	}
	my $dsn = "dbi:Pg:dbname=$db;host=$host;port=$port";
	$DBH = DBI->connect($dsn, $user, '', { AutoCommit => 1, RaiseError => 0, PrintError => 0 });
	unless ($DBH) {
		print STDERR "cannot connect: $DBI::errstr\n";
		exit 3;
	}
	$DBH->do("SET statement_timeout = 60000");
	return $DBH;
}

sub nid {
	my $p = shift;
	my @a = split(//, '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
	my $s = '';
	for (my $i = 0; $i < 26; $i++) { $s .= $a[int(rand(32))]; }
	return $p . $s;
}

sub esc {
	my $s = shift;
	return 'NULL' unless defined $s;
	$s =~ s/'/''/g;
	return "'" . $s . "'";
}

# -------------------------------------------------------------------------------------
# ตัวหลัก อย่าแยกเป็นฟังก์ชันย่อยถ้ายังไม่ได้เขียน test — เคยแยกแล้วยอดเพี้ยนไป 2 เดือน
# -------------------------------------------------------------------------------------
sub process {
	my ($tenant, $bd) = @_;
	my ($sth, $sth2, $sth3, $r, $r2, $r3);
	my $t0 = time();

	unless (defined $tenant && $tenant ne '') {
		push(@ERR, 'no tenant');
		return -1;
	}

	$RUN = nid('rec_');
	unless ($DRY) {
		$DBH->do("INSERT INTO analytics.reconciliation_runs (run_id, tenant_id, business_date,"
			. " state, engine_version) VALUES (" . esc($RUN) . "," . esc($tenant) . ","
			. esc($bd) . ",'running'," . esc($CFG->{ver}) . ")");
	}

	$sth = $DBH->prepare("SELECT s.shipment_id, s.reference, s.status, s.currency, s.region_code,"
		. " s.declared_value_minor, s.delivered_at, s.created_at"
		. " FROM freight.shipments s"
		. " WHERE s.tenant_id = ?"
		. "   AND s.created_at >= (?::date - (? || ' days')::interval)"
		. "   AND s.created_at < (?::date + interval '1 day')"
		. "   AND s.status NOT IN ('draft','cancelled')"
		. " ORDER BY s.created_at");
	unless ($sth && $sth->execute($tenant, $bd, $CFG->{look}, $bd)) {
		push(@ERR, 'select shipments failed: ' . $DBH->errstr);
		$DBH->do("UPDATE analytics.reconciliation_runs SET state = 'failed', finished_at = now()"
			. " WHERE run_id = " . esc($RUN)) unless $DRY;
		return -2;
	}

	while ($r = $sth->fetchrow_hashref) {
		my $sid = $r->{shipment_id};
		next if $SEEN{$sid};
		$SEEN{$sid} = 1;
		$N++;

		if ($r->{region_code} ne $CFG->{reg}) {
			# §7 ข้อ 7 ข้อมูลของภูมิภาคอื่นห้ามอ่านมาประมวลผลที่นี่
			push(@ERR, "$sid wrong region " . $r->{region_code});
			next;
		}

		# ---------- declaration ----------
		my $duty = 0;
		my $vat  = 0;
		my $ndcl = 0;
		my $dclid = undef;
		my $cleared = 0;
		$sth2 = $DBH->prepare("SELECT declaration_id, status, direction, mrn, assessed_duty_minor,"
			. " assessed_vat_minor, currency, duty_paid, cleared_at"
			. " FROM customs.customs_declarations WHERE shipment_id = ? ORDER BY created_at");
		$sth2->execute($sid);
		while ($r2 = $sth2->fetchrow_hashref) {
			$ndcl++;
			$dclid = $r2->{declaration_id};
			if ($r2->{status} eq 'cleared') {
				$cleared++;
				if (defined $r2->{assessed_duty_minor}) {
					if ($r2->{currency} eq $r->{currency}) {
						$duty += $r2->{assessed_duty_minor};
						$vat  += $r2->{assessed_vat_minor} if defined $r2->{assessed_vat_minor};
					} else {
						push(@ERR, "$sid currency " . $r2->{currency} . " vs " . $r->{currency});
					}
				} else {
					# ไม่มียอดประเมิน ลองคำนวณจาก line item เอง
					my $d2 = OFT::Legacy::Tariff::assess($DBH, $r2->{declaration_id});
					if (defined $d2 && $d2 > 0) {
						$duty += $d2;
					} else {
						if ($r2->{status} eq 'cleared' && $r->{status} eq 'delivered') {
							dis($tenant, $sid, $r2->{declaration_id}, undef, 'duty_mismatch',
								undef, 0, $r->{currency});
						}
					}
				}
			}
		}
		$sth2->finish;

		if ($ndcl == 0 && $r->{status} eq 'delivered') {
			dis($tenant, $sid, undef, undef, 'missing_declaration', undef, undef, $r->{currency});
		}

		# ---------- invoice ----------
		my $iid = undef;
		my $itot = 0;
		my $iduty = 0;
		my $istat = '';
		my $ninv = 0;
		$sth2 = $DBH->prepare("SELECT invoice_id, invoice_number, status, currency, subtotal_minor,"
			. " duty_minor, tax_minor, total_minor, settled_at"
			. " FROM billing.invoices WHERE shipment_id = ? AND status <> 'void'"
			. " ORDER BY created_at DESC");
		$sth2->execute($sid);
		while ($r2 = $sth2->fetchrow_hashref) {
			$ninv++;
			if ($ninv == 1) {
				$iid   = $r2->{invoice_id};
				$itot  = $r2->{total_minor};
				$iduty = $r2->{duty_minor};
				$istat = $r2->{status};
				if ($r2->{currency} ne $r->{currency}) {
					push(@ERR, "$sid invoice currency " . $r2->{currency});
				}
			} else {
				# ออกบิลซ้ำ เคยเกิดตอน billing-service retry แล้ว idempotency key หลุด
				push(@ERR, "$sid has $ninv non-void invoices");
			}
		}
		$sth2->finish;

		if ($ninv == 0) {
			if ($r->{status} eq 'delivered') {
				my $pod = 0;
				$sth3 = $DBH->prepare("SELECT count(*) FROM freight.shipment_scan_events"
					. " WHERE shipment_id = ? AND scan_type = 'proof_of_delivery'");
				$sth3->execute($sid);
				($pod) = $sth3->fetchrow_array;
				$sth3->finish;
				if ($pod > 0) {
					dis($tenant, $sid, $dclid, undef, 'missing_invoice', undef, undef, $r->{currency});
				}
			}
			next;
		}

		# ---------- duty ----------
		if ($cleared > 0) {
			my $d = abs($iduty - $duty);
			if ($d > $CFG->{tol}) {
				if ($istat ne 'on_hold') {
					dis($tenant, $sid, $dclid, $iid, 'duty_mismatch', $duty, $iduty, $r->{currency});
				}
			}
		}

		# ---------- payment ----------
		my $paid = 0;
		my $npay = 0;
		$sth2 = $DBH->prepare("SELECT payment_id, method, amount_minor, currency, received_at,"
			. " external_ref, reversed_at FROM billing.payments WHERE invoice_id = ?");
		$sth2->execute($iid);
		while ($r2 = $sth2->fetchrow_hashref) {
			$npay++;
			next if defined $r2->{reversed_at};
			if ($r2->{currency} ne $r->{currency}) {
				dis($tenant, $sid, $dclid, $iid, 'orphan_payment',
					$r2->{amount_minor}, 0, $r2->{currency});
				next;
			}
			$paid += $r2->{amount_minor};
		}
		$sth2->finish;

		if ($paid > $itot + $CFG->{tol}) {
			dis($tenant, $sid, $dclid, $iid, 'orphan_payment', $itot, $paid, $r->{currency});
		}

		if ($cleared > 0 && $paid < $duty - $CFG->{tol}) {
			if ($istat eq 'settled') {
				dis($tenant, $sid, $dclid, $iid, 'cleared_without_payment', $duty, $paid, $r->{currency});
			} else {
				if ($r->{status} eq 'delivered') {
					my $age = 0;
					$sth3 = $DBH->prepare("SELECT EXTRACT(epoch FROM (now() - delivered_at))::bigint"
						. " FROM freight.shipments WHERE shipment_id = ?");
					$sth3->execute($sid);
					($age) = $sth3->fetchrow_array;
					$sth3->finish;
					if (defined $age && $age > 30 * 86400) {
						dis($tenant, $sid, $dclid, $iid, 'cleared_without_payment',
							$duty, $paid, $r->{currency});
					}
				}
			}
		}

		# ---------- น้ำหนัก ----------
		my $gross = 0;
		$sth2 = $DBH->prepare("SELECT COALESCE(SUM(sc.gross_kg),0) FROM freight.shipment_containers sc"
			. " WHERE sc.shipment_id = ?");
		$sth2->execute($sid);
		($gross) = $sth2->fetchrow_array;
		$sth2->finish;

		if ($ndcl > 0 && $gross > 0) {
			my $net = 0;
			$sth2 = $DBH->prepare("SELECT COALESCE(SUM(li.net_weight_kg),0)"
				. " FROM customs.declaration_line_items li"
				. " JOIN customs.customs_declarations d ON d.declaration_id = li.declaration_id"
				. " WHERE d.shipment_id = ?");
			$sth2->execute($sid);
			($net) = $sth2->fetchrow_array;
			$sth2->finish;
			if ($net > 0) {
				my $diff = $gross - $net;
				if ($diff < 0) { $diff = -$diff; }
				if ($net > 0 && ($diff * 100 / $net) > 15) {
					dis($tenant, $sid, $dclid, $iid, 'weight_mismatch', $net, $gross, undef);
				}
			}
		}

		if ((time() - $t0) > 3000) {
			push(@ERR, "time budget exhausted after $N shipments");
			last;
		}
	}
	$sth->finish;

	unless ($DRY) {
		my $st = (scalar(@ERR) > 0) ? 'partial' : 'succeeded';
		$DBH->do("UPDATE analytics.reconciliation_runs SET state = " . esc($st)
			. ", finished_at = now(), shipments_examined = $N, discrepancies_opened = $NDIS"
			. " WHERE run_id = " . esc($RUN));
	}

	return $NDIS;
}

sub dis {
	my ($tenant, $sid, $did, $iid, $kind, $exp, $obs, $cur) = @_;
	$NDIS++;
	return if $DRY;
	my $id = nid('dsc_');
	my $sql = "INSERT INTO analytics.reconciliation_discrepancies (discrepancy_id, run_id, tenant_id,"
		. " shipment_id, declaration_id, invoice_id, kind, expected_minor, observed_minor, currency)"
		. " VALUES (" . esc($id) . "," . esc($RUN) . "," . esc($tenant) . "," . esc($sid) . ","
		. esc($did) . "," . esc($iid) . "," . esc($kind) . ","
		. (defined $exp ? $exp : 'NULL') . "," . (defined $obs ? $obs : 'NULL') . ","
		. esc($cur) . ")";
	$DBH->do($sql) or push(@ERR, "insert discrepancy failed: " . $DBH->errstr);

	my $mid = nid('evt_');
	my $pay = '{"discrepancy_id":"' . $id . '","run_id":"' . $RUN . '","tenant_id":"' . $tenant
		. '","shipment_id":"' . $sid . '","kind":"' . $kind . '"}';
	$DBH->do("INSERT INTO platform.outbox_messages (message_id, producer, aggregate_type,"
		. " aggregate_id, event_name, topic, partition_key, schema_version, payload) VALUES ("
		. esc($mid) . ",'reconciliation-service','discrepancy'," . esc($id)
		. ",'reconciliation.discrepancy.opened','of.platform.v1'," . esc($sid) . ",3,"
		. esc($pay) . "::jsonb)");
}

my $tenant = shift @ARGV;
my $bd = shift @ARGV;
foreach my $x (@ARGV) { $DRY = 1 if $x eq '--dry'; }
$bd = strftime("%Y-%m-%d", gmtime(time() - 86400)) unless defined $bd && $bd ne '';

conn();
my $rc = process($tenant, $bd);

print "run=$RUN tenant=$tenant date=$bd shipments=$N discrepancies=$NDIS\n";
if (scalar(@ERR) > 0) {
	print STDERR "-- " . scalar(@ERR) . " problem(s)\n";
	foreach my $e (@ERR) { print STDERR "   $e\n"; }
}
exit(0) if $rc >= 0;
exit(1);
