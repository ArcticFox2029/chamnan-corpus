import os
import sys
import ConfigParser

CFG = {}
LOADED = 0
SRC = ''

DEFAULTS = {
    'OF_ENVIRONMENT': 'production',
    'OF_REGION_CODE': 'eu-west',
    'OF_SERVICE_NAME': 'partner-portal-api',
    'OF_DATABASE_URL': 'postgres://oftrack@db-primary:5432/orbitalfreight',
    'OF_DOCUMENT_BASE_URL': 'http://document-service:8089',
    'OF_BILLING_BASE_URL': 'http://billing-service:8088',
    'OF_CUSTOMS_BASE_URL': 'http://customs-service:8087',
    'OF_IDENTITY_JWKS_URL': 'http://identity-service:8081/.well-known/jwks.json',
    'OF_DOCUMENT_SIGNED_URL_TTL_SECONDS': '900',
    'OF_PARTNER_RATE_LIMIT_PER_MINUTE': '120',
    'OF_NOTIFY_WEBHOOK_TIMEOUT_MS': '5000',
    'OF_LOG_LEVEL': 'info',
}

INI_PATHS = [
    '/etc/oftrack/oftrack.ini',
    '/etc/oftrack/oftrack.conf',
    os.path.expanduser('~/.oftrack.ini'),
]


def load():
    global LOADED, SRC
    if LOADED:
        return CFG
    for k in DEFAULTS.keys():
        CFG[k] = DEFAULTS[k]

    for p in INI_PATHS:
        if not os.path.exists(p):
            continue
        cp = ConfigParser.ConfigParser()
        try:
            cp.read(p)
        except Exception, e:
            print 'cfg: cannot read %s: %s' % (p, e)
            continue
        for sec in cp.sections():
            for (k, v) in cp.items(sec):
                CFG[k.upper()] = v
        SRC = p

    for k in os.environ.keys():
        if k[:3] == 'OF_':
            CFG[k] = os.environ[k]

    if len(sys.argv) > 1:
        for a in sys.argv[1:]:
            if a[:2] == '--' and a.find('=') > 0:
                (k, v) = a[2:].split('=', 1)
                CFG[k.upper().replace('-', '_')] = v

    LOADED = 1
    return CFG


def get(k, d=None):
    if not LOADED:
        load()
    if CFG.has_key(k):
        return CFG[k]
    if os.environ.has_key(k):
        return os.environ[k]
    return d


def get_int(k, d):
    v = get(k, d)
    try:
        return int(v)
    except:
        return d


def set(k, v):
    CFG[k] = v


def dump():
    if not LOADED:
        load()
    out = []
    for (k, v) in CFG.iteritems():
        if k.find('SECRET') >= 0 or k.find('TOKEN') >= 0 or k.find('KEY') >= 0:
            v = '***'
        out.append('%s=%s' % (k, v))
    out.sort()
    return '\n'.join(out)
