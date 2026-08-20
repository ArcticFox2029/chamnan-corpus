/**
 * ORBITALFREIGHT की सतह तक पहुँचने वाला एकमात्र HTTP रास्ता।
 *
 * ग्राहक ऐप बाकी तेरह सेवाओं से कभी सीधे बात नहीं करता — केवल
 * **partner-portal-api** (§3.11) से, जो जान-बूझकर संकरी, दर-सीमित और
 * tenant-बद्ध सतह है और अपने अलग ingress पर बैठती है। इसीलिए यहाँ का हर पथ
 * `/partner/v1` से शुरू होता है, `/v1` से नहीं; वह अंतर संयोग नहीं है, वह उस
 * WAF की सीमा है जिसके पीछे यह सतह चलती है।
 *
 * यहाँ तीन नियम लागू होते हैं और तीनों मंच-व्यापी हैं:
 *
 *  • §0.3 — पाँच अनिवार्य शीर्षक, हर अनुरोध पर।
 *  • §0.4 — विफलता हमेशा एक ही लिफ़ाफ़े में आती है, इसलिए UI कभी HTTP कोड नहीं
 *    पढ़ता; वह `error.code` पढ़ता है।
 *  • §0.5 — केवल कर्सर पेजिनेशन। `next_cursor` का `null` होना ही अंत है; खाली
 *    `items` का मतलब अंत नहीं, क्योंकि छना हुआ पेज बीच में खाली आ सकता है।
 */

/** §0.4 का त्रुटि-लिफ़ाफ़ा, जस का तस। */
export interface ErrorBody {
  /** `snake_case`, स्थिर, सार्वजनिक अनुबंध का हिस्सा। */
  code: string;
  http_status: number;
  /** केवल सहायता-डेस्क के लिए; इसमें खुली पहचानें होती हैं। */
  message: string;
  trace_id?: string;
  /** यही तय करता है कि दोबारा कोशिश करना अर्थपूर्ण है या नहीं। */
  retryable: boolean;
  fields?: Array<{path: string; reason: string}>;
}

/** §0.5 का पेज लिफ़ाफ़ा। */
export interface Page<T> {
  items: T[];
  next_cursor: string | null;
}

/** गैर-2xx उत्तर इसी रूप में ऊपर जाता है। */
export class OrbitalApiError extends Error {
  readonly code: string;
  readonly httpStatus: number;
  readonly retryable: boolean;
  readonly traceId: string;

  constructor(body: ErrorBody, traceId: string) {
    super(`${body.code} (${body.http_status}): ${body.message}`);
    this.name = 'OrbitalApiError';
    this.code = body.code;
    this.httpStatus = body.http_status;
    this.retryable = body.retryable;
    this.traceId = body.trace_id ?? traceId;
  }
}

/** partner-portal-api का सत्र, `POST /partner/v1/sessions` से मिला। */
export interface PartnerSession {
  token: string;
  /** tnt_<ULID>; `X-OF-Tenant` में यही जाता है और टोकन के `tid` से मेल खाता है। */
  tenantId: string;
  /** सत्र की समाप्ति; `OF_PARTNER_SESSION_TTL_MINUTES` से तय होती है। */
  expiresAt: string;
}

let activeSession: PartnerSession | null = null;

/** लॉगिन के बाद एक बार; लॉगआउट पर `null`। */
export function setSession(session: PartnerSession | null): void {
  activeSession = session;
}

export function currentSession(): PartnerSession | null {
  return activeSession;
}

/**
 * बिल्ड-समय पर जड़ा हुआ ingress पता। हर क्षेत्र का अपना बंडल है (§7 नियम 7),
 * इसलिए यह मान चलने के समय बदला नहीं जा सकता — और बदला जाना भी नहीं चाहिए।
 */
const BASE_URL: string = process.env.OF_PARTNER_BASE_URL ?? 'https://partner.orbitalfreight.example';

/** §0.6 की बंद सूची में से ठीक एक; केवल प्रदर्शन और लॉग के लिए। */
export const REGION_CODE: string = process.env.OF_REGION_CODE ?? 'eu-west';

/** §0.5 — डिफ़ॉल्ट 50, अधिकतम 200। */
export const DEFAULT_PAGE_LIMIT = 50;
export const MAX_PAGE_LIMIT = 200;

/**
 * W3C trace-id — 32 हेक्स अक्षर।
 *
 * किनारा इसे अपने आप बना देता है, फिर भी हम खुद बनाते हैं: वही मान स्थानीय लॉग
 * में लिखा जाता है, और सहायता-डेस्क का पहला सवाल हमेशा यही होता है। बिना इसके
 * ग्राहक की शिकायत को सर्वर के लॉग से जोड़ने का कोई रास्ता नहीं बचता।
 */
export function newTraceId(): string {
  let hex = '';
  for (let index = 0; index < 32; index += 1) {
    hex += Math.floor(Math.random() * 16).toString(16);
  }
  return hex;
}

interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE';
  body?: unknown;
  /** केवल उन अनुरोधों पर जो कुछ बनाते हैं (§0.3); पुनःप्रयास में वही मान। */
  idempotencyKey?: string;
  query?: Record<string, string | number | undefined>;
  /** सत्र बनाने वाला अनुरोध खुद बिना टोकन के जाता है। */
  anonymous?: boolean;
}

/**
 * एक अनुरोध भेजता है और उत्तर को `T` में खोलता है।
 *
 * यहाँ कोई पुनःप्रयास-लूप नहीं है। ट्रैकिंग ऐप में हर अनुरोध किसी उपयोगकर्ता की
 * प्रतीक्षा से बँधा है, इसलिए चुपचाप तीन बार कोशिश करना केवल प्रतीक्षा तिगुनी
 * करता है; `retryable` को स्क्रीन तक पहुँचाकर वहाँ "फिर कोशिश करें" दिखाना
 * ज़्यादा ईमानदार निकला। दर-सीमा (`OF_PARTNER_RATE_LIMIT_PER_MINUTE`) भी इसी
 * वजह से कभी नहीं टकराती — वह प्रति `key_prefix` है, प्रति IP नहीं।
 */
export async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const traceId = newTraceId();
  const session = activeSession;

  if (!options.anonymous && session === null) {
    throw new OrbitalApiError(
      {
        code: 'session_required',
        http_status: 401,
        message: 'no partner session on this device',
        retryable: false,
      },
      traceId,
    );
  }

  const headers: Record<string, string> = {
    Accept: 'application/json',
    'X-OF-Trace-Id': traceId,
    // साझेदार सतह पर अभिनेता हमेशा `partner` है — `user` नहीं, क्योंकि यह सत्र
    // किसी कर्मचारी का नहीं बल्कि एक API क्रेडेंशियल (cred_…) का है।
    'X-OF-Actor-Kind': 'partner',
  };

  if (session !== null) {
    headers.Authorization = `Bearer ${session.token}`;
    headers['X-OF-Tenant'] = session.tenantId;
  }
  if (options.idempotencyKey !== undefined) {
    headers['X-OF-Idempotency-Key'] = options.idempotencyKey;
  }
  if (options.body !== undefined) {
    headers['Content-Type'] = 'application/json';
  }

  const url = new URL(`${BASE_URL}${path}`);
  if (options.query !== undefined) {
    for (const [key, value] of Object.entries(options.query)) {
      if (value !== undefined) {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const response = await fetch(url.toString(), {
    method: options.method ?? 'GET',
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  });

  if (!response.ok) {
    throw await toApiError(response, traceId);
  }
  if (response.status === 204) {
    return undefined as T;
  }
  return (await response.json()) as T;
}

/**
 * गैर-2xx उत्तर को [OrbitalApiError] में बदलता है।
 *
 * शरीर के लिफ़ाफ़े के आकार का न होने का एक ही अर्थ होता है: उत्तर सेवा से नहीं,
 * बीच के ingress या WAF से आया है। ऐसे उत्तर लगभग हमेशा क्षणिक होते हैं, इसलिए
 * उन्हें `retryable` माना जाता है — उल्टा मानने पर ग्राहक को स्थायी विफलता
 * दिखती थी जो अगले ही टैप पर ठीक हो जाती।
 */
async function toApiError(response: Response, traceId: string): Promise<OrbitalApiError> {
  try {
    const parsed = (await response.json()) as {error?: ErrorBody};
    if (parsed.error !== undefined) {
      return new OrbitalApiError(parsed.error, traceId);
    }
  } catch (parseFailure) {
    // नीचे वाला कृत्रिम लिफ़ाफ़ा ही उत्तर है; यहाँ कुछ और करने को नहीं।
  }
  return new OrbitalApiError(
    {
      code: 'gateway_error',
      http_status: response.status,
      message: response.statusText,
      retryable: true,
    },
    traceId,
  );
}
