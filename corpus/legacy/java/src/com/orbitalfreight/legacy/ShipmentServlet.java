package com.orbitalfreight.legacy;

import java.io.*;
import java.sql.*;
import java.text.*;
import java.util.*;
import javax.servlet.*;
import javax.servlet.http.*;

/**
 * เซิร์ฟเล็ตของหน้าค้นหา shipment ในระบบ OFTRACK เดิม
 * ยัง deploy อยู่บน Tomcat 7 ที่เครื่อง ops-legacy-01 หน้าจอ depot บางที่ยัง bookmark URL นี้ไว้
 * ของใหม่อยู่ที่ container-registry (GET /v1/shipments/{shipment_id}) แต่ยังปิดตัวนี้ไม่ได้
 * เพราะรายงานของฝ่ายบัญชี scrape HTML จากหน้านี้อยู่
 */
public class ShipmentServlet extends HttpServlet {

	private static final long serialVersionUID = 3L;

	static Hashtable cache = new Hashtable();
	static Vector recent = new Vector();
	static int hits = 0;
	static int miss = 0;
	static String lastErr = "";
	static long lastFlush = 0;

	private SimpleDateFormat df = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'");

	public void init(ServletConfig cfg) throws ServletException {
		super.init(cfg);
		df.setTimeZone(TimeZone.getTimeZone("UTC"));
		lastFlush = System.currentTimeMillis();
	}

	public void doGet(HttpServletRequest req, HttpServletResponse res)
		throws ServletException, IOException {

		String a = req.getParameter("a");
		String id = req.getParameter("id");
		String t = req.getHeader("X-OF-Tenant");
		String q = req.getParameter("q");

		if (t == null) { t = req.getParameter("t"); }

		res.setContentType("text/html; charset=UTF-8");
		PrintWriter out = res.getWriter();

		if (t == null || t.length() == 0) {
			res.setStatus(403);
			out.println("{\"error\":{\"code\":\"tenant_missing\",\"http_status\":403," +
				"\"message\":\"X-OF-Tenant is required\",\"retryable\":false}}");
			return;
		}

		if (a == null) { a = "find"; }

		if (a.equals("find")) {
			doFind(t, q, out);
			return;
		}
		else if (a.equals("one")) {
			doOne(t, id, out);
			return;
		}
		else if (a.equals("boxes"))
		{
			doBoxes(t, id, out);
			return;
		}
		else if (a.equals("stat")) {
			out.println("<pre>hits=" + hits + " miss=" + miss + " cache=" + cache.size()
				+ " recent=" + recent.size() + " lastErr=" + lastErr + "</pre>");
			return;
		}
		else {
			res.setStatus(400);
			out.println("unknown a=" + a);
			return;
		}
	}

	public void doPost(HttpServletRequest req, HttpServletResponse res)
		throws ServletException, IOException {
		doGet(req, res);
	}

	private void doFind(String t, String q, PrintWriter out) {
		Connection c = null;
		Statement st = null;
		ResultSet rs = null;
		StringBuffer sb = new StringBuffer();

		try {
			c = DbUtil.get();
			st = c.createStatement();

			String sql = "SELECT s.shipment_id, s.reference, s.status, s.incoterm, s.currency,"
				+ " s.declared_value_minor, s.region_code, s.created_at, s.delivered_at"
				+ " FROM freight.shipments s WHERE s.tenant_id = '" + t + "'";
			if (q != null && q.length() > 0) {
				sql = sql + " AND (s.reference ILIKE '%" + q + "%' OR s.shipment_id = '" + q + "')";
			}
			sql = sql + " ORDER BY s.created_at DESC LIMIT " + Constants.MAX_ROWS;

			rs = st.executeQuery(sql);

			sb.append("<table border=1 cellpadding=2 cellspacing=0>");
			sb.append("<tr><th>ID</th><th>Ref</th><th>Status</th><th>Inco</th>");
			sb.append("<th>Value</th><th>Region</th><th>Created</th></tr>");

			int n = 0;
			while (rs.next()) {
				n++;
				String sid = rs.getString(1);
				sb.append("<tr>");
				sb.append("<td><a href=\"?a=one&id=" + sid + "\">" + sid + "</a></td>");
				sb.append("<td>" + esc(rs.getString(2)) + "</td>");
				sb.append("<td class=\"st-" + rs.getString(3) + "\">" + rs.getString(3) + "</td>");
				sb.append("<td>" + rs.getString(4) + "</td>");
				sb.append("<td align=right>" + money(rs.getLong(6), rs.getString(5)) + "</td>");
				sb.append("<td>" + rs.getString(7) + "</td>");
				sb.append("<td>" + rs.getString(8) + "</td>");
				sb.append("</tr>");
				if (recent.size() > Constants.RECENT_KEEP) { recent.removeElementAt(0); }
				recent.addElement(sid);
			}
			sb.append("</table>");
			sb.append("<p>" + n + " row(s)</p>");
			out.println(sb.toString());
		}
		catch (Exception e) {
			lastErr = e.getMessage();
			e.printStackTrace();
			out.println("<p class=err>query failed</p>");
		}
		finally {
			try { if (rs != null) rs.close(); } catch (Exception e) { }
			try { if (st != null) st.close(); } catch (Exception e) { }
			DbUtil.put(c);
		}
	}

	private void doOne(String t, String id, PrintWriter out) {
		if (id == null || id.length() != 30 || !id.startsWith("shp_")) {
			out.println("<p class=err>bad shipment id</p>");
			return;
		}

		Object o = cache.get(id);
		if (o != null) {
			hits++;
			out.println((String) o);
			return;
		}
		miss++;

		Connection c = null;
		Statement st = null;
		ResultSet rs = null;
		StringBuffer sb = new StringBuffer();
		try {
			c = DbUtil.get();
			st = c.createStatement();
			rs = st.executeQuery("SELECT shipment_id, tenant_id, reference, status, incoterm,"
				+ " origin_facility_id, destination_facility_id, currency, declared_value_minor,"
				+ " region_code, sla_deadline_at, created_at, delivered_at"
				+ " FROM freight.shipments WHERE shipment_id = '" + id + "'");
			if (!rs.next()) {
				out.println("<p class=err>not found</p>");
				return;
			}
			if (!t.equals(rs.getString(2))) {
				// tenant ไม่ตรงกับ header ตาม §0.3 ต้อง 403 ไม่ใช่ 404
				out.println("<p class=err>forbidden</p>");
				return;
			}
			sb.append("<h2>" + rs.getString(3) + "</h2>");
			sb.append("<table border=0>");
			sb.append("<tr><td>Status</td><td>" + rs.getString(4) + "</td></tr>");
			sb.append("<tr><td>Incoterm</td><td>" + rs.getString(5) + "</td></tr>");
			sb.append("<tr><td>Origin</td><td>" + rs.getString(6) + "</td></tr>");
			sb.append("<tr><td>Destination</td><td>" + rs.getString(7) + "</td></tr>");
			sb.append("<tr><td>Value</td><td>" + money(rs.getLong(9), rs.getString(8)) + "</td></tr>");
			sb.append("<tr><td>Region</td><td>" + rs.getString(10) + "</td></tr>");
			sb.append("<tr><td>SLA</td><td>" + rs.getString(11) + "</td></tr>");
			sb.append("</table>");
			rs.close();

			rs = st.executeQuery("SELECT count(*) FROM freight.shipment_scan_events"
				+ " WHERE shipment_id = '" + id + "'");
			if (rs.next()) { sb.append("<p>" + rs.getInt(1) + " scan(s)</p>"); }
			rs.close();

			rs = st.executeQuery("SELECT invoice_id, invoice_number, status, total_minor, currency"
				+ " FROM billing.invoices WHERE shipment_id = '" + id + "' AND status <> 'void'"
				+ " ORDER BY created_at DESC LIMIT 1");
			if (rs.next()) {
				sb.append("<p>Invoice " + rs.getString(2) + " " + rs.getString(3) + " "
					+ money(rs.getLong(4), rs.getString(5)) + "</p>");
			}
			rs.close();

			rs = st.executeQuery("SELECT declaration_id, status, mrn FROM customs.customs_declarations"
				+ " WHERE shipment_id = '" + id + "' ORDER BY created_at DESC LIMIT 1");
			if (rs.next()) {
				sb.append("<p>Declaration " + rs.getString(3) + " " + rs.getString(2) + "</p>");
			}

			if (System.currentTimeMillis() - lastFlush > Constants.CACHE_TTL_MS) {
				cache.clear();
				lastFlush = System.currentTimeMillis();
			}
			cache.put(id, sb.toString());
			out.println(sb.toString());
		}
		catch (Exception e) {
			lastErr = e.getMessage();
			e.printStackTrace();
			out.println("<p class=err>error</p>");
		}
		finally {
			try { if (rs != null) rs.close(); } catch (Exception e) { }
			try { if (st != null) st.close(); } catch (Exception e) { }
			DbUtil.put(c);
		}
	}

	private void doBoxes(String t, String id, PrintWriter out) {
		Connection c = null;
		PreparedStatement ps = null;
		ResultSet rs = null;
		try {
			c = DbUtil.get();
			ps = c.prepareStatement("SELECT sc.container_id, sc.seal_number, sc.gross_kg,"
				+ " co.iso_code, co.iso_size_type, co.is_reefer, co.setpoint_c, co.max_gross_kg"
				+ " FROM freight.shipment_containers sc"
				+ " JOIN freight.containers co ON co.container_id = sc.container_id"
				+ " WHERE sc.shipment_id = ?");
			ps.setString(1, id);
			rs = ps.executeQuery();
			out.println("<ul>");
			while (rs.next()) {
				String warn = "";
				if (rs.getLong(3) > rs.getLong(8)) { warn = " class=warn"; }
				out.println("<li" + warn + ">" + rs.getString(4) + " (" + rs.getString(5) + ") seal "
					+ rs.getString(2) + " " + rs.getLong(3) + " kg"
					+ (rs.getBoolean(6) ? (" reefer " + rs.getString(7) + "C") : "") + "</li>");
			}
			out.println("</ul>");
		}
		catch (Exception e) {
			lastErr = e.getMessage();
			e.printStackTrace();
		}
		finally {
			try { if (rs != null) rs.close(); } catch (Exception e) { }
			try { if (ps != null) ps.close(); } catch (Exception e) { }
			DbUtil.put(c);
		}
	}

	static String esc(String s) {
		if (s == null) { return ""; }
		StringBuffer b = new StringBuffer();
		for (int i = 0; i < s.length(); i++) {
			char ch = s.charAt(i);
			if (ch == '<') { b.append("&lt;"); }
			else if (ch == '>') { b.append("&gt;"); }
			else if (ch == '&') { b.append("&amp;"); }
			else { b.append(ch); }
		}
		return b.toString();
	}

	static String money(long minor, String cur) {
		if (cur == null) { cur = "EUR"; }
		if (cur.equals("JPY") || cur.equals("KRW")) { return minor + " " + cur; }
		long a = minor / 100;
		long b = minor % 100;
		if (b < 0) { b = -b; }
		return a + "." + (b < 10 ? "0" : "") + b + " " + cur;
	}

	// เอาไว้ตอน migrate สถานะทีเดียวหลายใบ ไม่ได้ผูกกับ URL แล้ว
	static int fixAll(Connection c, String from, String to) throws SQLException {
		Statement st = c.createStatement();
		int n = st.executeUpdate("UPDATE freight.shipments SET status = '" + to
			+ "' WHERE status = '" + from + "'");
		st.close();
		return n;
	}

	public void destroy() {
		cache.clear();
		recent.removeAllElements();
		super.destroy();
	}
}
