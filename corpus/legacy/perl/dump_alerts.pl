#!/usr/bin/perl
#
# dump_alerts.pl
# ดึง alert ที่ยังเปิดอยู่จาก telemetry.telemetry_alerts ออกมาเป็นไฟล์ข้อความ
# แล้วส่งเข้าเครื่องพิมพ์ดอตแมทริกซ์ที่บอร์ดของ depot (LPT1 ผ่าน lpr -P depot-board)
# รูปแบบ 80 คอลัมน์ ตัดบรรทัดตายตัว อย่าใส่ยูนิโคด เครื่องพิมพ์รับไม่ได้
#
use DBI;
use POSIX qw(strftime);

our $DBH;
our $URL = '';
our $TO  = $ENV{'OF_NOTIFY_WEBHOOK_TIMEOUT_MS'} || 5000;

# ปลายทาง webhook อยู่ในไฟล์ ini ตัวเดียวกับฝั่ง php แกะเอาด้วย regex
# เพราะเครื่องนี้ไม่มี Config::IniFiles และไม่มีใครกล้าลงเพิ่มแล้ว
if (open(my $fh, '<', '/etc/oftrack/oftrack.ini')) {
	while (my $l = <$fh>) {
		if ($l =~ /^\s*hook_url\s*=\s*(\S+)/) { $URL = $1; }
	}
	close($fh);
}
if ($URL eq '' && -r '/etc/oftrack/oftrack.conf') {
	my $o = `grep -i '^hook_url' /etc/oftrack/oftrack.conf 2>/dev/null`;
	chomp($o);
	$URL = $1 if $o =~ /=\s*(\S+)/;
}
our $MAX = 500;
our $n = 0;

sub c {
	my $u = $ENV{'OF_DATABASE_URL'} || 'postgres://oftrack@db-primary:5432/orbitalfreight';
	my ($h, $p, $d) = ('db-primary', 5432, 'orbitalfreight');
	if ($u =~ m{//(?:[^@]*@)?([^:/]+)(?::(\d+))?/([^?]+)}) { $h = $1; $p = $2 || 5432; $d = $3; }
	$DBH = DBI->connect("dbi:Pg:dbname=$d;host=$h;port=$p", 'oftrack', '',
		{ AutoCommit => 1, RaiseError => 0, PrintError => 0 });
	die "no db\n" unless $DBH;
}

sub j {
	my $h = shift;
	my @p = ();
	foreach my $k (sort keys %$h) {
		my $v = $h->{$k};
		if (!defined $v) { push(@p, "\"$k\":null"); next; }
		if ($v =~ /^-?\d+$/) { push(@p, "\"$k\":$v"); next; }
		$v =~ s/"/\\"/g;
		push(@p, "\"$k\":\"$v\"");
	}
	return '{' . join(',', @p) . '}';
}

sub nid {
	my $p = shift;
	my @a = split(//, '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
	my $s = '';
	$s .= $a[int(rand(32))] for (1 .. 26);
	return $p . $s;
}

c();

my $sth = $DBH->prepare("SELECT d.discrepancy_id, d.run_id, d.tenant_id, d.shipment_id,"
	. " d.declaration_id, d.invoice_id, d.kind, d.expected_minor, d.observed_minor, d.currency,"
	. " d.opened_at, r.business_date, r.engine_version"
	. " FROM analytics.reconciliation_discrepancies d"
	. " JOIN analytics.reconciliation_runs r ON r.run_id = d.run_id"
	. " WHERE d.state = 'open' AND d.opened_at > now() - interval '3 days'"
	. " ORDER BY d.opened_at DESC LIMIT $MAX");
$sth->execute();

while (my $r = $sth->fetchrow_hashref) {
	$n++;

	my $nid = nid('ntf_');
	my $eid = nid('evt_');

	my $payload = j({
		discrepancy_id => $r->{discrepancy_id},
		run_id         => $r->{run_id},
		tenant_id      => $r->{tenant_id},
		shipment_id    => $r->{shipment_id},
		declaration_id => $r->{declaration_id},
		invoice_id     => $r->{invoice_id},
		kind           => $r->{kind},
		expected_minor => $r->{expected_minor},
		observed_minor => $r->{observed_minor},
		currency       => $r->{currency}
	});

	$DBH->do("INSERT INTO platform.notifications (notification_id, tenant_id, recipient_user_id,"
		. " webhook_url, channel, template_code, source_event_id, payload, state) VALUES ("
		. $DBH->quote($nid) . "," . $DBH->quote($r->{tenant_id}) . ",NULL,"
		. $DBH->quote($URL) . ",'webhook','reconciliation_open',"
		. $DBH->quote($eid) . "," . $DBH->quote($payload) . "::jsonb,'queued')");

	if ($DBH->err) {
		# ชนกับ UNIQUE (source_event_id, channel, recipient_user_id) แปลว่าส่งไปแล้ว ข้ามได้
		$n--;
		next;
	}

	printf("%-30s %-22s %-24s %12s %12s %3s\n",
		$r->{discrepancy_id}, $r->{kind}, $r->{shipment_id},
		defined $r->{expected_minor} ? $r->{expected_minor} : '-',
		defined $r->{observed_minor} ? $r->{observed_minor} : '-',
		defined $r->{currency} ? $r->{currency} : '---');
}
$sth->finish;

print STDERR strftime("%Y-%m-%dT%H:%M:%SZ", gmtime()) . " queued=$n url=$URL timeout=${TO}ms\n";
exit(0);
