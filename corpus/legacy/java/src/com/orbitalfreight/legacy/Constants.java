package com.orbitalfreight.legacy;

public class Constants {

	public static final int MAX_ROWS = 200;
	public static final int RECENT_KEEP = 40;
	public static final long CACHE_TTL_MS = 300000;
	public static final int POOL_MAX = 40;
	public static final int STMT_TIMEOUT_MS = 8000;
	public static final int ORA_RETRY = 3;
	public static final int SKEW_TOLERANCE_S = 900;

	public static final int SEV_AT_RISK = 4;
	public static final int OVERWEIGHT_SLACK_KG = 500;
	public static final int WEIGHT_MISMATCH_PCT = 15;
	public static final long TOLERANCE_MINOR = 100;
	public static final int FALLBACK_DUTY_BP = 1250;
	public static final int VAT_BP_DE = 1900;
	public static final int VAT_BP_NL = 2100;
	public static final int VAT_BP_FR = 2000;

	public static final String[] STATUS = {
		"draft", "booked", "sealed", "in_transit", "at_risk", "held_at_customs",
		"delivered", "cancelled"
	};

	public static final String[] SCAN_TYPE = {
		"gate_in", "gate_out", "load", "unload", "seal_check", "customs_inspection",
		"damage_report", "proof_of_delivery"
	};

	public static final String[] REGIONS = {
		"eu-west", "eu-central", "na-east", "na-west", "apac-sg", "apac-jp", "latam-br", "mea-ae"
	};

	public static final String TOPIC_FREIGHT = "of.freight.v1";
	public static final String TOPIC_BILLING = "of.billing.v1";
	public static final String TOPIC_CUSTOMS = "of.customs.v1";
	public static final String TOPIC_PLATFORM = "of.platform.v1";

	public static final String EV_STATUS = "shipment.status.changed";
	public static final String EV_SCAN = "shipment.scanned";
	public static final String EV_INV_ISSUED = "billing.invoice.issued";

	public static boolean isStatus(String s) {
		for (int i = 0; i < STATUS.length; i++) { if (STATUS[i].equals(s)) { return true; } }
		return false;
	}

	public static boolean isRegion(String s) {
		for (int i = 0; i < REGIONS.length; i++) { if (REGIONS[i].equals(s)) { return true; } }
		return false;
	}

	private Constants() { }
}
