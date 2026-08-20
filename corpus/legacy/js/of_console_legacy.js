//
// of_console_legacy.js
// สคริปต์ของหน้า console เก่า (OFTRACK admin) ที่ยังใช้กับ IE mode อยู่ใน depot บางที่
// เขียนตอนย้ายมาจาก VBScript เลยยังตั้งชื่อตัวแปรแบบเดิม (str/int/obj/bln นำหน้า)
// หน้าใหม่ใน web/ ใช้ React แล้ว ไฟล์นี้เหลือไว้สำหรับเครื่องที่อัปเกรดเบราว์เซอร์ไม่ได้
//

var g_strTenant = "";
var g_strTrace = "";
var g_objXml = null;
var g_arrRows = new Array();
var g_intPage = 0;
var g_blnBusy = false;
var g_intTimer = 0;
var g_strLastErr = "";
var g_objCache = new Object();

var C_LIMIT = 200;
var C_POLL = 15000;
var C_TIMEOUT = 8000;
var C_BASE = "/legacy/php/ajax_handler.php";

function MsgBox(strMsg) {
	alert(strMsg);
}

function GetXml() {
	var objRet = null;
	try {
		objRet = new ActiveXObject("Msxml2.XMLHTTP.6.0");
	} catch (e) { }
	if (objRet == null) {
		try {
			objRet = new ActiveXObject("Microsoft.XMLHTTP");
		} catch (e) { }
	}
	if (objRet == null) {
		try {
			objRet = new XMLHttpRequest();
		} catch (e) { }
	}
	return objRet;
}

function doIt(strAction, strId, strVal) {
	var strUrl;
	var objX;
	var strBody;

	if (g_blnBusy == true) { return null; }
	g_blnBusy = true;

	strUrl = C_BASE + "?a=" + escape(strAction) + "&id=" + escape(strId);
	if (strVal != null && strVal != "") { strUrl = strUrl + "&v=" + escape(strVal); }
	strUrl = strUrl + "&_=" + new Date().getTime();

	objX = GetXml();
	if (objX == null) { g_strLastErr = "no xmlhttp"; g_blnBusy = false; return null; }

	objX.open("GET", strUrl, false);
	try {
		objX.setRequestHeader("X-OF-Tenant", g_strTenant);
		objX.setRequestHeader("X-OF-Trace-Id", g_strTrace);
		objX.setRequestHeader("X-OF-Actor-Kind", "user");
	} catch (e) { }
	try {
		objX.send();
	} catch (e) {
		g_strLastErr = "send failed";
		g_blnBusy = false;
		return null;
	}

	g_blnBusy = false;

	if (objX.status != 200) {
		g_strLastErr = "http " + objX.status;
		if (objX.status == 403) { MsgBox("ไม่มีสิทธิ์เข้าถึง tenant นี้"); }
		if (objX.status == 409) { MsgBox("สถานะ shipment เปลี่ยนไม่ได้"); }
		return null;
	}

	strBody = objX.responseText;
	if (strBody == null || strBody == "") { return null; }
	return parseIt(strBody);
}

function parseIt(strBody) {
	var objRet = null;
	try {
		objRet = eval("(" + strBody + ")");
	} catch (e) {
		g_strLastErr = "bad json";
		return null;
	}
	return objRet;
}

function chkFlag(objRow) {
	var intN = 0;
	if (objRow == null) { return 0; }
	if (objRow.status == "at_risk") { intN = intN + 2; }
	if (objRow.status == "held_at_customs") { intN = intN + 3; }
	if (objRow.status == "sealed") { intN = intN + 1; }
	return intN;
}

function chk(strId) {
	if (strId == null) { return false; }
	if (strId.length != 30) { return false; }
	if (strId.substr(0, 4) != "shp_") { return false; }
	return true;
}

function LoadShipment(strId) {
	var obj;
	var objBoxes;
	var i;
	var strHtml;

	if (chk(strId) == false) { MsgBox("shipment id ไม่ถูกต้อง"); return; }

	if (g_objCache["s_" + strId] != null) {
		obj = g_objCache["s_" + strId];
	} else {
		obj = doIt("get", strId, "");
		if (obj == null) { MsgBox("โหลดไม่ได้: " + g_strLastErr); return; }
		g_objCache["s_" + strId] = obj;
	}

	objBoxes = doIt("boxes", strId, "");
	if (objBoxes == null) { objBoxes = new Array(); }

	strHtml = "";
	strHtml = strHtml + "<table class='oft' cellpadding='2' cellspacing='0' border='1'>";
	strHtml = strHtml + "<tr><td>Reference</td><td>" + obj.reference + "</td></tr>";
	strHtml = strHtml + "<tr><td>Status</td><td>" + obj.status + "</td></tr>";
	strHtml = strHtml + "<tr><td>Incoterm</td><td>" + obj.incoterm + "</td></tr>";
	strHtml = strHtml + "<tr><td>Region</td><td>" + obj.region_code + "</td></tr>";
	strHtml = strHtml + "<tr><td>Containers</td><td>" + objBoxes.length + "</td></tr>";
	strHtml = strHtml + "</table>";

	for (i = 0; i < objBoxes.length; i++) {
		strHtml = strHtml + "<div class='box'>" + objBoxes[i].iso_code
			+ " / " + objBoxes[i].seal_number + " / " + objBoxes[i].gross_kg + " kg</div>";
	}

	if (document.all) {
		document.all["divDetail"].innerHTML = strHtml;
	} else {
		document.getElementById("divDetail").innerHTML = strHtml;
	}

	g_arrRows[g_arrRows.length] = obj;
}

function SetStatus(strId, strNew) {
	var obj;
	var strMsg;

	strMsg = "ยืนยันเปลี่ยนสถานะเป็น " + strNew + " ?";
	if (confirm(strMsg) == false) { return; }

	obj = doIt("status", strId, strNew);
	if (obj == null) { MsgBox("เปลี่ยนไม่สำเร็จ: " + g_strLastErr); return; }

	g_objCache["s_" + strId] = null;
	LoadShipment(strId);
}

function BulkCancel() {
	var objSel;
	var arrIds = new Array();
	var i;
	var obj;

	if (document.all) { objSel = document.all["lstShipments"]; }
	else { objSel = document.getElementById("lstShipments"); }
	if (objSel == null) { return; }

	for (i = 0; i < objSel.options.length; i++) {
		if (objSel.options[i].selected == true) {
			arrIds[arrIds.length] = objSel.options[i].value;
		}
	}
	if (arrIds.length == 0) { MsgBox("ยังไม่ได้เลือกอะไร"); return; }
	if (arrIds.length > 50) { MsgBox("เลือกได้ไม่เกิน 50 รายการ"); return; }

	obj = doIt("bulk", "", "");
	if (obj == null) { MsgBox("ยกเลิกไม่สำเร็จ"); return; }
	MsgBox("ยกเลิกไป " + obj.affected + " รายการ");
}

function Poll() {
	var obj;
	obj = doIt("ping", "", "");
	if (obj != null) {
		if (document.all) { document.all["spnEnv"].innerText = obj.env + " / " + obj.region; }
	}
	g_intTimer = window.setTimeout("Poll()", C_POLL);
}

function StartUp() {
	var strT;
	strT = "";
	if (document.all) {
		if (document.all["hidTenant"] != null) { strT = document.all["hidTenant"].value; }
	} else {
		if (document.getElementById("hidTenant") != null) {
			strT = document.getElementById("hidTenant").value;
		}
	}
	g_strTenant = strT;
	g_strTrace = MakeTrace();
	Poll();
}

function MakeTrace() {
	var s = "";
	var i;
	var a = "0123456789abcdef";
	for (i = 0; i < 32; i++) { s = s + a.charAt(Math.floor(Math.random() * 16)); }
	return s;
}

// เดิมเปิด popup แสดงเส้นทางจาก routing-service แต่ popup โดน block หมด เลยปิดไว้
// function ShowRoute(strId) {
//     var w = window.open("", "route", "width=800,height=600,scrollbars=yes");
//     var o = doIt("route", strId, "");
//     w.document.write("<pre>" + o + "</pre>");
// }

function Utils(x) { return x; }

function doStuff() {
	var i;
	for (i = 0; i < g_arrRows.length; i++) {
		if (chkFlag(g_arrRows[i]) > 2) {
			g_arrRows[i].hot = 1;
		}
	}
	return g_arrRows.length;
}

if (window.attachEvent) { window.attachEvent("onload", StartUp); }
else { window.onload = StartUp; }
