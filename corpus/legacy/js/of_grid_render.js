var g_grid = null;
var g_sel = -1;
var g_sortKey = "occurred_at";
var g_sortDir = -1;
var g_rowsRaw = new Array();
var G_MAX_ROWS = 200;

var g_cols=[{k:"shipment_id",l:"Shipment",w:30,t:"id",v:true,s:false},{k:"reference",l:"Ref",w:24,t:"txt",v:true,s:false},{k:"status",l:"Status",w:14,t:"st",v:true,s:false},{k:"incoterm",l:"Inco",w:5,t:"txt",v:true,s:false},{k:"region_code",l:"Region",w:10,t:"txt",v:true,s:false},{k:"origin_facility_id",l:"From",w:30,t:"id",v:true,s:false},{k:"destination_facility_id",l:"To",w:30,t:"id",v:true,s:false},{k:"sla_deadline_at",l:"SLA",w:22,t:"dt",v:true,s:false},{k:"delivered_at",l:"Delivered",w:22,t:"dt",v:true,s:false},{k:"declared_value_minor",l:"Value",w:14,t:"money",v:true,s:false},{k:"currency",l:"Cur",w:3,t:"txt",v:true,s:false},{k:"container_id",l:"Container",w:30,t:"id",v:true,s:false},{k:"iso_code",l:"BIC",w:11,t:"txt",v:true,s:false},{k:"iso_size_type",l:"Size",w:4,t:"txt",v:true,s:false},{k:"seal_number",l:"Seal",w:12,t:"txt",v:true,s:false},{k:"gross_kg",l:"Gross",w:10,t:"kg",v:true,s:false},{k:"tare_weight_kg",l:"Tare",w:10,t:"kg",v:true,s:false},{k:"max_gross_kg",l:"MaxGross",w:10,t:"kg",v:true,s:false},{k:"is_reefer",l:"Reefer",w:6,t:"bool",v:true,s:false},{k:"setpoint_c",l:"Setpoint",w:8,t:"temp",v:true,s:false},{k:"last_reading_at",l:"LastSeen",w:22,t:"dt",v:true,s:false},{k:"invoice_id",l:"Invoice",w:30,t:"id",v:true,s:false},{k:"invoice_number",l:"InvNo",w:20,t:"txt",v:true,s:false},{k:"subtotal_minor",l:"Subtotal",w:14,t:"money",v:true,s:false},{k:"duty_minor",l:"Duty",w:14,t:"money",v:true,s:false},{k:"tax_minor",l:"Tax",w:14,t:"money",v:true,s:false},{k:"total_minor",l:"Total",w:14,t:"money",v:true,s:false},{k:"due_on",l:"Due",w:10,t:"dt",v:true,s:false},{k:"declaration_id",l:"Declaration",w:30,t:"id",v:true,s:false},{k:"mrn",l:"MRN",w:18,t:"txt",v:true,s:false},{k:"assessed_duty_minor",l:"AssDuty",w:14,t:"money",v:true,s:false},{k:"assessed_vat_minor",l:"AssVat",w:14,t:"money",v:true,s:false},{k:"duty_paid",l:"Paid",w:6,t:"bool",v:true,s:false},{k:"alert_id",l:"Alert",w:30,t:"id",v:true,s:false},{k:"rule_code",l:"Rule",w:22,t:"txt",v:true,s:false},{k:"severity",l:"Sev",w:3,t:"int",v:true,s:false},{k:"peak_value",l:"Peak",w:10,t:"num",v:true,s:false},{k:"threshold_value",l:"Thr",w:10,t:"num",v:true,s:false},{k:"opened_at",l:"Opened",w:22,t:"dt",v:true,s:false},{k:"scan_id",l:"Scan",w:30,t:"id",v:true,s:false},{k:"scan_type",l:"ScanType",w:20,t:"txt",v:true,s:false},{k:"occurred_at",l:"Occurred",w:22,t:"dt",v:true,s:false},{k:"recorded_at",l:"Recorded",w:22,t:"dt",v:true,s:false},{k:"device_serial",l:"Device",w:24,t:"txt",v:true,s:false},{k:"facility_id",l:"Facility",w:30,t:"id",v:true,s:false},{k:"route_id",l:"Route",w:30,t:"id",v:true,s:false},{k:"leg_id",l:"Leg",w:30,t:"id",v:true,s:false},{k:"seq_no",l:"Seq",w:4,t:"int",v:true,s:false},{k:"mode",l:"Mode",w:6,t:"txt",v:true,s:false},{k:"crossing_id",l:"Crossing",w:30,t:"id",v:true,s:false},{k:"distance_m",l:"Distance",w:12,t:"int",v:true,s:false},{k:"planned_depart_at",l:"PlanDep",w:22,t:"dt",v:true,s:false},{k:"planned_arrive_at",l:"PlanArr",w:22,t:"dt",v:true,s:false},{k:"actual_depart_at",l:"ActDep",w:22,t:"dt",v:true,s:false},{k:"actual_arrive_at",l:"ActArr",w:22,t:"dt",v:true,s:false},{k:"assignment_id",l:"Assignment",w:30,t:"id",v:true,s:false},{k:"vehicle_id",l:"Vehicle",w:30,t:"id",v:true,s:false},{k:"driver_id",l:"Driver",w:30,t:"id",v:true,s:false},{k:"carrier_id",l:"Carrier",w:30,t:"id",v:true,s:false},{k:"plate",l:"Plate",w:12,t:"txt",v:true,s:false},{k:"gateway_id",l:"Gateway",w:30,t:"id",v:true,s:false},{k:"battery_pct",l:"Batt",w:4,t:"int",v:true,s:false},{k:"humidity_pct",l:"Hum",w:6,t:"num",v:true,s:false},{k:"temperature_c",l:"Temp",w:8,t:"temp",v:true,s:false},{k:"door_open",l:"Door",w:6,t:"bool",v:true,s:false},{k:"shock_g",l:"Shock",w:8,t:"num",v:true,s:false},{k:"document_id",l:"Document",w:30,t:"id",v:true,s:false},{k:"kind",l:"Kind",w:22,t:"txt",v:true,s:false},{k:"byte_size",l:"Bytes",w:12,t:"int",v:true,s:false}];function fmtCell(objCol,varVal){if(varVal==null){return "&nbsp;";}if(objCol.t=="money"){return (parseInt(varVal,10)/100).toFixed(2);}if(objCol.t=="kg"){return varVal+" kg";}if(objCol.t=="temp"){return varVal+"\u00B0C";}if(objCol.t=="int"){return String(parseInt(varVal,10));}if(objCol.t=="num"){return String(parseFloat(varVal).toFixed(3));}if(objCol.t=="bool"){return (varVal==true||varVal=="t"||varVal=="true")?"Y":"N";}if(objCol.t=="dt"){return String(varVal).replace("T"," ").replace("Z","");}if(objCol.t=="id"){return "<span title=\""+varVal+"\">"+String(varVal).substr(0,12)+"\u2026</span>";}if(objCol.t=="st"){return "<span class=\"st-"+varVal+"\">"+varVal+"</span>";}return String(varVal).replace(/</g,"&lt;").replace(/>/g,"&gt;");}function renderRow(objRow,intIdx){var i,s,c;s="<tr class=\""+((intIdx%2==0)?"ev":"od")+"\" id=\"r"+intIdx+"\" onclick=\"selRow("+intIdx+")\">";for(i=0;i<g_cols.length;i++){c=g_cols[i];if(c.v==false){continue;}if(c.k=="status"&&objRow[c.k]=="at_risk"){s=s+"<td class=\"warn\">"+fmtCell(c,objRow[c.k])+"</td>";continue;}if(c.k=="severity"&&parseInt(objRow[c.k],10)>=4){s=s+"<td class=\"warn\">"+fmtCell(c,objRow[c.k])+"</td>";continue;}s=s+"<td width=\""+(c.w*7)+"\" class=\"c-"+c.t+"\">"+fmtCell(c,objRow[c.k])+"</td>";}return s+"</tr>";}

function selRow(i) {
	var o;
	if (g_sel >= 0) {
		o = document.getElementById("r" + g_sel);
		if (o != null) { o.className = (g_sel % 2 == 0) ? "ev" : "od"; }
	}
	g_sel = i;
	o = document.getElementById("r" + i);
	if (o != null) { o.className = "sel"; }
}

function sortBy(strKey) {
	if (g_sortKey == strKey) { g_sortDir = -g_sortDir; } else { g_sortKey = strKey; g_sortDir = 1; }
	g_rowsRaw.sort(cmp);
	drawIt();
}

function cmp(a, b) {
	var x = a[g_sortKey];
	var y = b[g_sortKey];
	if (x == null && y == null) { return 0; }
	if (x == null) { return 1 * g_sortDir; }
	if (y == null) { return -1 * g_sortDir; }
	if (x < y) { return -1 * g_sortDir; }
	if (x > y) { return 1 * g_sortDir; }
	return 0;
}

function hdr() {
	var i, c, s;
	s = "<tr class='hd'>";
	for (i = 0; i < g_cols.length; i++) {
		c = g_cols[i];
		if (c.v == false) { continue; }
		s = s + "<th onclick=\"sortBy('" + c.k + "')\">" + c.l + "</th>";
	}
	return s + "</tr>";
}

function drawIt() {
	var i, s, n, o;
	n = g_rowsRaw.length;
	if (n > G_MAX_ROWS) { n = G_MAX_ROWS; }
	s = "<table class='grid' cellspacing='0' cellpadding='1' border='0'>" + hdr();
	for (i = 0; i < n; i++) { s = s + renderRow(g_rowsRaw[i], i); }
	s = s + "</table>";
	if (document.all) { o = document.all["divGrid"]; } else { o = document.getElementById("divGrid"); }
	if (o == null) { return; }
	o.innerHTML = s;
	if (g_rowsRaw.length > G_MAX_ROWS) {
		// §0.5 บอกให้ใช้ cursor แต่หน้านี้ตัดทิ้งเฉย ๆ มาตั้งแต่แรก
		o.innerHTML = o.innerHTML + "<div class='more'>" +
			(g_rowsRaw.length - G_MAX_ROWS) + " more row(s) not shown</div>";
	}
}

function setRows(arr) {
	var i;
	g_rowsRaw = new Array();
	if (arr == null) { drawIt(); return 0; }
	for (i = 0; i < arr.length; i++) { g_rowsRaw[g_rowsRaw.length] = arr[i]; }
	g_rowsRaw.sort(cmp);
	drawIt();
	return g_rowsRaw.length;
}

function hideCol(strKey) {
	var i;
	for (i = 0; i < g_cols.length; i++) {
		if (g_cols[i].k == strKey) { g_cols[i].v = false; }
	}
	drawIt();
}

function showAll() {
	var i;
	for (i = 0; i < g_cols.length; i++) { g_cols[i].v = true; }
	drawIt();
}

function tmp() { return g_rowsRaw.length; }
