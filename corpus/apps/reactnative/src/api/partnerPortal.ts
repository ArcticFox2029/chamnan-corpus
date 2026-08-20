/**
 * partner-portal-api (§3.11) के पाँच पथ, वैसे ही जैसे वे विनिर्देश में लिखे हैं।
 *
 * यह सतह ग्राहक ऐप की पूरी दुनिया है। उसके पीछे partner-portal-api खुद
 * billing-service, customs-service और container-registry को बुलाता है, पर वह
 * ऐप की चिंता नहीं — और यही इस परत का पूरा मूल्य है: ग्राहक को चौदह सेवाओं की
 * कोई जानकारी नहीं चाहिए, और उसे वह मिलनी भी नहीं चाहिए।
 *
 * दो बातें जो यहाँ के हर उत्तर पर लागू हैं:
 *
 *  • **छँटा हुआ दृश्य।** `GET /partner/v1/shipments/{shipment_id}` में
 *    `declared_value_minor` नहीं आता। वह `freight.shipments` में है, पर
 *    साझेदार सतह उसे हटा देती है — इसलिए नीचे के प्रकार में भी वह खेत नहीं है,
 *    और उसे "जोड़ना भूल गए" समझकर जोड़ना नहीं है।
 *  • **केवल वे शिपमेंट जिन्हें साझेदार की भूमिका छूती है।** सूची अपने आप छँटी
 *    हुई आती है; ऐप की तरफ़ कोई अतिरिक्त फ़िल्टर नहीं लगता।
 */
import {DEFAULT_PAGE_LIMIT, request, setSession, type Page, type PartnerSession} from './client';

/** साझेदार को दिखने वाला शिपमेंट — `freight.shipments` का छँटा हुआ रूप। */
export interface TrackedShipment {
  shipment_id: string;
  /** ग्राहक की अपनी बुकिंग संख्या; प्रति tenant अद्वितीय। */
  reference: string;
  /** आठ वैध मानों में से एक; अनुवाद केवल दिखाने के लिए होता है, तार पर कभी नहीं। */
  status: string;
  origin_facility_id: string;
  destination_facility_id: string;
  /** `DAP`, `CIF`, `EXW` … */
  incoterm: string;
  sla_deadline_at: string | null;
  delivered_at: string | null;
  region_code: string;
  containers: TrackedContainer[];
}

export interface TrackedContainer {
  container_id: string;
  /** BIC कोड, ISO 6346 — ग्यारह अक्षर। */
  iso_code: string;
  iso_size_type: string;
  is_reefer: boolean;
  /** सील जोड़ी की संपत्ति है, डिब्बे की नहीं। */
  seal_number: string;
  gross_kg: number;
}

/** स्कैन का इतिहास — `freight.shipment_scan_events` का दिखने वाला हिस्सा। */
export interface TrackedScan {
  scan_id: string;
  shipment_id: string;
  container_id: string | null;
  /** आठ वैध `scan_type` में से एक। */
  scan_type: string;
  facility_id: string | null;
  /** उपकरण की घड़ी से; ऑफ़लाइन स्कैन का असली समय यही है। */
  occurred_at: string;
  /** सर्वर की घड़ी से। दोनों का बड़ा अंतर = स्कैन देर तक कतार में पड़ा रहा। */
  recorded_at: string;
}

/** चालान — billing-service से proxy होकर आता है। */
export interface TrackedInvoice {
  invoice_id: string;
  invoice_number: string | null;
  shipment_id: string;
  /** पैसा हमेशा पूर्णांक लघु-इकाइयों में, और हमेशा अपनी मुद्रा के साथ (§0.2)। */
  subtotal_minor: number;
  duty_minor: number;
  tax_minor: number;
  total_minor: number;
  currency: string;
  /** सात वैध मान; `on_hold` का अर्थ है कि रात की मिलान-प्रक्रिया ने विसंगति खोली। */
  status: string;
  due_on: string | null;
}

/**
 * `POST /partner/v1/sessions` — साझेदार लॉगिन।
 *
 * प्रमाण एक API क्रेडेंशियल जोड़ी है (`identity.api_credentials`): `key_prefix`
 * वह बारह-अक्षर का हैंडल है जो कंसोल पर दिखता है, और `secret` वह मान जो
 * बनाते समय **एक ही बार** दिखाया गया था — सर्वर पर उसका केवल argon2id हैश है।
 * इसीलिए भूला हुआ secret दोबारा नहीं मिलता, नई क्रेडेंशियल बनानी पड़ती है।
 *
 * पुश टोकन यहीं भेजा जाता है, अलग पंजीकरण-पथ से नहीं: साझेदार सतह पर
 * `platform.notification_preferences` को छूने वाला कोई पथ है ही नहीं, और
 * होना भी नहीं चाहिए — वरीयताएँ कंसोल की चीज़ हैं।
 */
export async function openSession(
  keyPrefix: string,
  secret: string,
  pushToken: string | null,
): Promise<PartnerSession> {
  const response = await request<{
    token: string;
    tenant_id: string;
    expires_at: string;
  }>('/partner/v1/sessions', {
    method: 'POST',
    anonymous: true,
    body: {key_prefix: keyPrefix, secret, push_token: pushToken},
  });

  const session: PartnerSession = {
    token: response.token,
    tenantId: response.tenant_id,
    expiresAt: response.expires_at,
  };
  setSession(session);
  return session;
}

/**
 * `GET /partner/v1/shipments` — साझेदार को दिखने वाली सूची, कर्सर-पेजिनेटेड।
 *
 * @param status एक ही स्थिति पर छानने के लिए; कई स्थितियाँ एक साथ नहीं जातीं,
 *        इसलिए "चालू सब" वाला दृश्य ऐप की तरफ़ जोड़ा जाता है।
 */
export function listShipments(
  cursor: string | null,
  status?: string,
): Promise<Page<TrackedShipment>> {
  return request<Page<TrackedShipment>>('/partner/v1/shipments', {
    query: {
      limit: DEFAULT_PAGE_LIMIT,
      cursor: cursor ?? undefined,
      status,
    },
  });
}

/** `GET /partner/v1/shipments/{shipment_id}` — छँटा हुआ एकल दृश्य। */
export function getShipment(shipmentId: string): Promise<TrackedShipment> {
  return request<TrackedShipment>(`/partner/v1/shipments/${shipmentId}`);
}

/**
 * स्कैन का इतिहास।
 *
 * यह उसी एकल-शिपमेंट उत्तर के साथ आता है, अलग पथ से नहीं — साझेदार सतह पर
 * `GET /v1/shipments/{shipment_id}/scans` जैसा कोई पथ नहीं है, वह
 * container-registry का आंतरिक पथ है। इसलिए यह फ़ंक्शन नेटवर्क को छूता ही नहीं,
 * और इसका होना केवल इसलिए है कि स्क्रीन को यह न सोचना पड़े कि डेटा कहाँ से आया।
 */
export function scansOf(shipment: TrackedShipment & {scans?: TrackedScan[]}): TrackedScan[] {
  return shipment.scans ?? [];
}

/** `GET /partner/v1/invoices/{invoice_id}` — billing-service से proxy होकर। */
export function getInvoice(invoiceId: string): Promise<TrackedInvoice> {
  return request<TrackedInvoice>(`/partner/v1/invoices/${invoiceId}`);
}

/**
 * `POST /partner/v1/declarations/{declaration_id}/documents` — दलाल का अपलोड।
 *
 * ग्राहक ऐप में यह केवल एक ही दस्तावेज़ के लिए खुलता है:
 * `certificate_of_origin`। बाकी नौ `kind` मान या तो सेवाएँ खुद बनाती हैं
 * (`rendered_invoice`, `customs_decision`) या गोदाम से आते हैं
 * (`damage_photo`, `proof_of_delivery`)।
 *
 * idempotency कुंजी अनिवार्य है और उसे पुनःप्रयास में बदलना नहीं है — वही
 * तस्वीर दो बार चढ़ने पर document-service `sha256` से दोहराव पकड़कर पुराना
 * `doc_` लौटा देता है, पर तभी जब कुंजी वही हो।
 */
export function uploadCertificateOfOrigin(
  declarationId: string,
  storageKeyOfUpload: string,
  idempotencyKey: string,
): Promise<{document_id: string}> {
  return request<{document_id: string}>(
    `/partner/v1/declarations/${declarationId}/documents`,
    {
      method: 'POST',
      idempotencyKey,
      body: {kind: 'certificate_of_origin', storage_key: storageKeyOfUpload},
    },
  );
}
