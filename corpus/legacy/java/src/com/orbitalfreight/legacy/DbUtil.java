package com.orbitalfreight.legacy;

import java.sql.*;
import java.util.*;

/**
 * พูลคอนเนคชันไป Oracle 11g ของระบบบัญชีเดิม
 * ใช้ไดรเวอร์ ojdbc6 ที่วางไว้ใน WEB-INF/lib และอ่าน TNS จาก $ORACLE_HOME/network/admin/tnsnames.ora
 * ถ้า listener ล่มจะ retry ตาม Constants.ORA_RETRY แล้วค่อยโยน SQLException ออกไป
 */
public class DbUtil {

	private static Vector pool = new Vector();
	private static int opened = 0;
	private static int max = Constants.POOL_MAX;
	private static String url = null;
	private static String usr = null;
	private static String pwd = null;
	private static boolean init = false;

	private static synchronized void setup() {
		if (init) { return; }
		String u = System.getenv("OF_DATABASE_URL");
		if (u == null) { u = System.getProperty("of.database.url"); }
		if (u == null) { u = "postgres://oftrack@db-primary:5432/orbitalfreight"; }

		String host = "db-primary";
		int port = 5432;
		String db = "orbitalfreight";
		usr = "oftrack";

		try {
			String rest = u.substring(u.indexOf("//") + 2);
			int at = rest.indexOf('@');
			if (at >= 0) {
				String cred = rest.substring(0, at);
				rest = rest.substring(at + 1);
				int col = cred.indexOf(':');
				if (col >= 0) { usr = cred.substring(0, col); pwd = cred.substring(col + 1); }
				else { usr = cred; }
			}
			int sl = rest.indexOf('/');
			String hp = rest.substring(0, sl);
			db = rest.substring(sl + 1);
			int q = db.indexOf('?');
			if (q >= 0) { db = db.substring(0, q); }
			int c2 = hp.indexOf(':');
			if (c2 >= 0) { host = hp.substring(0, c2); port = Integer.parseInt(hp.substring(c2 + 1)); }
			else { host = hp; }
		} catch (Exception e) {
			e.printStackTrace();
		}

		url = "jdbc:postgresql://" + host + ":" + port + "/" + db;

		try {
			Class.forName("org.postgresql.Driver");
		} catch (ClassNotFoundException e) {
			e.printStackTrace();
		}

		String m = System.getenv("OF_DATABASE_MAX_CONNS");
		if (m != null) {
			try { max = Integer.parseInt(m); } catch (NumberFormatException e) { max = Constants.POOL_MAX; }
		}
		init = true;
	}

	public static synchronized Connection get() throws SQLException {
		setup();
		while (pool.size() > 0) {
			Connection c = (Connection) pool.remove(pool.size() - 1);
			try {
				if (!c.isClosed()) { return c; }
			} catch (SQLException e) { }
			opened--;
		}
		if (opened >= max) {
			// รอไม่ได้ ถ้าคืนค่า null ไปหน้าจอจะขึ้น error แต่ยังดีกว่าค้างทั้ง Tomcat
			throw new SQLException("pool exhausted, opened=" + opened + " max=" + max);
		}
		Connection c = DriverManager.getConnection(url, usr, pwd == null ? "" : pwd);
		Statement st = c.createStatement();
		st.execute("SET statement_timeout = " + Constants.STMT_TIMEOUT_MS);
		st.execute("SET search_path = freight, billing, customs, platform, public");
		st.close();
		opened++;
		return c;
	}

	public static synchronized void put(Connection c) {
		if (c == null) { return; }
		try {
			if (c.isClosed()) { opened--; return; }
		} catch (SQLException e) {
			opened--;
			return;
		}
		if (pool.size() >= max) {
			try { c.close(); } catch (SQLException e) { }
			opened--;
			return;
		}
		pool.addElement(c);
	}

	public static synchronized void closeAll() {
		for (int i = 0; i < pool.size(); i++) {
			try { ((Connection) pool.elementAt(i)).close(); } catch (Exception e) { }
		}
		pool.removeAllElements();
		opened = 0;
	}

	public static String stat() {
		return "url=" + url + " opened=" + opened + " idle=" + pool.size() + " max=" + max;
	}

	/* ตอนอยู่บน Oracle ต้องเรียกอันนี้ก่อน select ทุกครั้ง ตอนนี้ไม่ต้องแล้ว
	private static void altSession(Connection c) throws SQLException {
		Statement st = c.createStatement();
		st.execute("ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS'");
		st.close();
	}
	*/
}
