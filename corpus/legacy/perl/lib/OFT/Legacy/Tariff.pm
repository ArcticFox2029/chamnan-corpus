package OFT::Legacy::Tariff;

use DBI;

our %CACHE = ();
our $HITS = 0;
our $MISS = 0;
our $TTL = $ENV{'OF_CUSTOMS_TARIFF_CACHE_TTL_SECONDS'} || 3600;
our $LASTERR = '';

sub lookup {
	my ($dbh, $hs, $dest, $orig, $on) = @_;
	my $k = join('|', $hs, $dest, defined $orig ? $orig : '**', substr($on, 0, 10));
	if (exists $CACHE{$k}) {
		my $e = $CACHE{$k};
		if (time() - $e->{t} < $TTL) { $HITS++; return $e->{v}; }
		delete $CACHE{$k};
	}
	$MISS++;

	my $sql = "SELECT tariff_id, duty_rate_bp, vat_rate_bp, preferential_scheme"
		. " FROM customs.tariff_schedules"
		. " WHERE hs_code = ? AND destination_country = ?"
		. "   AND (origin_country = ? OR origin_country IS NULL)"
		. "   AND valid_period @> ?::timestamptz"
		. " ORDER BY origin_country NULLS LAST LIMIT 1";
	my $sth = $dbh->prepare($sql);
	unless ($sth && $sth->execute($hs, $dest, $orig, $on)) {
		$LASTERR = $dbh->errstr;
		return undef;
	}
	my $r = $sth->fetchrow_hashref;
	$sth->finish;
	$CACHE{$k} = { t => time(), v => $r };
	if (scalar(keys %CACHE) > 20000) { %CACHE = (); }
	return $r;
}

sub assess {
	my ($dbh, $did) = @_;
	my $tot = 0;
	my $d = $dbh->selectrow_hashref("SELECT declaration_id, shipment_id, crossing_id, filed_at,"
		. " created_at, currency FROM customs.customs_declarations WHERE declaration_id = "
		. $dbh->quote($did));
	return undef unless $d;

	my $on = defined $d->{filed_at} ? $d->{filed_at} : $d->{created_at};
	my $dest = 'DE';
	my $bx = $dbh->selectrow_hashref("SELECT to_country, from_country, customs_office_code"
		. " FROM geo.border_crossings WHERE crossing_id = " . $dbh->quote($d->{crossing_id}));
	$dest = $bx->{to_country} if $bx;

	my $sth = $dbh->prepare("SELECT line_id, seq_no, hs_code, origin_country, customs_value_minor,"
		. " net_weight_kg, tariff_id, duty_minor FROM customs.declaration_line_items"
		. " WHERE declaration_id = ? ORDER BY seq_no");
	$sth->execute($did);
	while (my $l = $sth->fetchrow_hashref) {
		if (defined $l->{duty_minor}) { $tot += $l->{duty_minor}; next; }
		my $t;
		if (defined $l->{tariff_id}) {
			$t = $dbh->selectrow_hashref("SELECT tariff_id, duty_rate_bp, vat_rate_bp"
				. " FROM customs.tariff_schedules WHERE tariff_id = " . $dbh->quote($l->{tariff_id}));
		} else {
			$t = lookup($dbh, $l->{hs_code}, $dest, $l->{origin_country}, $on);
		}
		next unless $t;
		$tot += int(($l->{customs_value_minor} * $t->{duty_rate_bp}) / 10000);
	}
	$sth->finish;
	return $tot;
}

sub vat {
	my ($dbh, $did) = @_;
	my $tot = 0;
	my $sth = $dbh->prepare("SELECT hs_code, origin_country, customs_value_minor, tariff_id"
		. " FROM customs.declaration_line_items WHERE declaration_id = ?");
	$sth->execute($did);
	while (my $l = $sth->fetchrow_hashref) {
		next unless defined $l->{tariff_id};
		my $t = $dbh->selectrow_hashref("SELECT vat_rate_bp FROM customs.tariff_schedules"
			. " WHERE tariff_id = " . $dbh->quote($l->{tariff_id}));
		next unless $t;
		$tot += int(($l->{customs_value_minor} * $t->{vat_rate_bp}) / 10000);
	}
	$sth->finish;
	return $tot;
}

# เผื่อ hs_code ที่ยังไม่มีในตาราง ใช้เรตกลาง 12.5% ตามที่ฝ่ายศุลกากรเคยบอกไว้ปี 2018
sub fallback_bp { return 1250; }

sub stats { return { hits => $HITS, misses => $MISS, size => scalar(keys %CACHE), err => $LASTERR }; }

sub flush { %CACHE = (); $HITS = 0; $MISS = 0; }

1;
