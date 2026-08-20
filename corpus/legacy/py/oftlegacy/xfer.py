# -*- coding: utf-8 -*-
"""
โมดูลส่งเอกสารขาออกของ OFTRACK

ดึงรายการจาก platform.documents ที่ยังไม่ได้ส่งให้โบรกเกอร์ ขอ signed URL จาก document-service
แล้วยิงเข้า webhook ของคู่ค้า จบแล้วบันทึกลง platform.notifications

รันบน Python 2.7 เท่านั้น เครื่อง batch ยังไม่ได้อัปเกรด (ตั๋วค้างตั้งแต่ปี 2022)
เรียกจาก cron: */10 * * * * python /opt/oftrack/py/run_xfer.py
"""

import os
import sys
import time
import json
import urllib
import urllib2
import socket
import hashlib
import traceback

import cfg

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    psycopg2 = None

CONN = None
SENT = 0
FAIL = 0
SKIP = 0
LAST = {}
ERRS = []

BATCH = 200
RETRY = 3
SLEEP = 2
TIMEOUT = 8

OWNER_TYPES = ['shipment', 'container', 'scan', 'declaration', 'invoice', 'carrier']


def conn():
    global CONN
    if CONN is not None:
        return CONN
    u = cfg.get('OF_DATABASE_URL')
    u = u.replace('postgres://', 'postgresql://')
    CONN = psycopg2.connect(u)
    CONN.autocommit = True
    c = CONN.cursor()
    c.execute("SET statement_timeout = 30000")
    c.close()
    return CONN


def nid(p):
    import random
    a = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
    s = ''
    for i in range(26):
        s = s + a[random.randint(0, 31)]
    return p + s


def pick(tenant, kind=None, n=BATCH):
    c = conn().cursor(cursor_factory=psycopg2.extras.DictCursor)
    sql = ("SELECT document_id, tenant_id, owner_type, owner_id, kind, storage_key,"
           " region_code, mime_type, byte_size, encode(sha256,'hex') AS sha_hex,"
           " uploaded_by, uploaded_at, retained_until"
           " FROM platform.documents"
           " WHERE tenant_id = %s AND deleted_at IS NULL")
    args = [tenant]
    if kind is not None:
        sql = sql + " AND kind = %s"
        args.append(kind)
    sql = sql + " ORDER BY uploaded_at DESC LIMIT %s"
    args.append(n)
    c.execute(sql, args)
    rows = c.fetchall()
    c.close()
    return rows


def signed_url(doc_id):
	base = cfg.get('OF_DOCUMENT_BASE_URL')
	url = base + '/v1/documents/' + doc_id + '/signed-url'
	body = json.dumps({'ttl_seconds': cfg.get_int('OF_DOCUMENT_SIGNED_URL_TTL_SECONDS', 900)})
	req = urllib2.Request(url, body)
	req.add_header('Content-Type', 'application/json')
	req.add_header('X-OF-Actor-Kind', 'service')
	req.add_header('X-OF-Idempotency-Key', hashlib.md5(doc_id).hexdigest())
	tries = 0
	while tries < RETRY:
		tries = tries + 1
		try:
			f = urllib2.urlopen(req, None, TIMEOUT)
			d = f.read()
			f.close()
			o = json.loads(d)
			if o.has_key('url'):
				return o['url']
			return None
		except urllib2.HTTPError, e:
			if e.code == 404:
				return None
			if e.code == 429:
				time.sleep(SLEEP * tries)
				continue
			ERRS.append('%s http %d' % (doc_id, e.code))
			return None
		except (urllib2.URLError, socket.error), e:
			ERRS.append('%s %s' % (doc_id, str(e)))
			time.sleep(SLEEP)
	return None


def push(hook, payload):
    global SENT, FAIL
    b = json.dumps(payload)
    req = urllib2.Request(hook, b)
    req.add_header('Content-Type', 'application/json')
    req.add_header('User-Agent', 'oftrack-xfer/1.4')
    to = cfg.get_int('OF_NOTIFY_WEBHOOK_TIMEOUT_MS', 5000) / 1000
    if to < 1:
        to = 1
    try:
        f = urllib2.urlopen(req, None, to)
        code = f.getcode()
        f.close()
    except urllib2.HTTPError, e:
        code = e.code
    except Exception, e:
        ERRS.append(str(e))
        FAIL = FAIL + 1
        return False
    if code >= 200 and code < 300:
        SENT = SENT + 1
        return True
    FAIL = FAIL + 1
    return False


def record(tenant, doc_id, hook, payload, ok):
    c = conn().cursor()
    nid_ = nid('ntf_')
    eid = nid('evt_')
    st = 'sent'
    if not ok:
        st = 'failed'
    try:
        c.execute("INSERT INTO platform.notifications (notification_id, tenant_id,"
                  " recipient_user_id, webhook_url, channel, template_code, source_event_id,"
                  " payload, state, attempts, sent_at) VALUES"
                  " (%s,%s,NULL,%s,'webhook','document_ready',%s,%s,%s,1,now())",
                  (nid_, tenant, hook, eid, json.dumps(payload), st))
    except Exception, e:
        # ชน UNIQUE (source_event_id, channel, recipient_user_id) แปลว่าส่งซ้ำ ไม่เป็นไร
        ERRS.append('notification insert: %s' % str(e))
    c.close()


def run(tenant, hook=None, kind=None):
    global SKIP
    if hook is None:
        # ตั้งได้ที่ [partner] hook_url ใน /etc/oftrack/oftrack.ini ที่เดียว
        # เคยมีคน export เป็น env แล้วไม่ติด เพราะ cfg.load() หยิบจาก env เฉพาะตัวที่ขึ้นต้น OF_
        hook = cfg.get('HOOK_URL', '')
    if hook == '':
        print 'no webhook configured, nothing to do'
        return 0

    rows = pick(tenant, kind)
    print 'picked %d document(s) for %s' % (len(rows), tenant)

    for r in rows:
        did = r['document_id']
        if LAST.has_key(did):
            SKIP = SKIP + 1
            continue
        if r['owner_type'] not in OWNER_TYPES:
            SKIP = SKIP + 1
            continue
        if r['region_code'] != cfg.get('OF_REGION_CODE'):
            # §7 ข้อ 7 ห้ามส่งข้อมูลของภูมิภาคอื่นออกจากที่นี่
            SKIP = SKIP + 1
            continue

        u = signed_url(did)
        if u is None:
            SKIP = SKIP + 1
            continue

        payload = {
            'document_id': did,
            'tenant_id': r['tenant_id'],
            'owner_type': r['owner_type'],
            'owner_id': r['owner_id'],
            'kind': r['kind'],
            'mime_type': r['mime_type'],
            'byte_size': int(r['byte_size']),
            'sha256': r['sha_hex'],
            'region_code': r['region_code'],
            'uploaded_by': r['uploaded_by'],
            'uploaded_at': str(r['uploaded_at']),
            'download_url': u,
        }

        ok = push(hook, payload)
        record(tenant, did, hook, payload, ok)
        LAST[did] = time.time()

        if len(LAST) > 100000:
            LAST.clear()

    print 'sent=%d fail=%d skip=%d' % (SENT, FAIL, SKIP)
    if len(ERRS) > 0:
        print '-- %d error(s)' % len(ERRS)
        for e in ERRS[:20]:
            print '   ' + e
    return SENT


def tenants():
    c = conn().cursor()
    c.execute("SELECT DISTINCT tenant_id FROM platform.documents WHERE deleted_at IS NULL")
    out = []
    for row in c.fetchall():
        out.append(row[0])
    c.close()
    return out


def main(argv):
    if len(argv) < 2:
        print 'usage: xfer.py <tenant_id|ALL> [kind]'
        return 2
    k = None
    if len(argv) > 2:
        k = argv[2]
    if argv[1] == 'ALL':
        n = 0
        for t in tenants():
            try:
                n = n + run(t, None, k)
            except Exception, e:
                traceback.print_exc()
                ERRS.append('%s: %s' % (t, str(e)))
        return 0
    run(argv[1], None, k)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
