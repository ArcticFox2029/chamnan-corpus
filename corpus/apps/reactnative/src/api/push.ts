/**
 * दोनों देशी पुश-पुलों (bridge) का JavaScript मुख।
 *
 * iOS पर `OFPushBridge` (Objective-C) और Android पर `OFPushBridgeModule`
 * (Kotlin) — दोनों एक ही नाम `OFPushBridge` से उजागर होते हैं, इसलिए यहाँ से
 * आगे कोई मंच-विशेष शाखा नहीं है।
 *
 * सूचनाएँ **notification-service** भेजती है (§3.10), और वह उन्हें
 * `OF_NOTIFY_PUSH_APNS_KEY_PATH` तथा `OF_NOTIFY_PUSH_FCM_KEY_PATH` वाली
 * कुंजियों से निकालती है। पेलोड में तीन मान हमेशा होते हैं और तीनों का उपयोग
 * नीचे है:
 *
 *  • `template_code` — जैसे `shipment_delayed`, `invoice_overdue`। यही तय करता
 *    है कि टैप पर कौन-सी स्क्रीन खुले।
 *  • `source_event_id` — evt_…, वही जो घटना-लिफ़ाफ़े में था। सूचना दो बार आने
 *    पर (at-least-once देना ही अनुबंध है) इसी से पहचाना जाता है कि यह वही है।
 *  • `shipment_id` — जिस पर स्क्रीन खुलनी है।
 *
 * **यहाँ कोई पंजीकरण-पथ नहीं है।** साझेदार सतह पर
 * `platform.notification_preferences` को छूने वाला कोई endpoint नहीं है;
 * उपकरण का टोकन सत्र बनाते समय `POST /partner/v1/sessions` के साथ जाता है।
 */
import {NativeEventEmitter, NativeModules, Platform} from 'react-native';

interface PushBridge {
  /**
   * उपकरण का पुश टोकन — iOS पर APNs का, Android पर FCM का।
   * अनुमति न मिली हो तो `null`।
   */
  deviceToken(): Promise<string | null>;

  /** वह सूचना जिस पर टैप करके ऐप खुला, यदि ऐसा हुआ हो। */
  launchNotification(): Promise<NotificationPayload | null>;
}

export interface NotificationPayload {
  /** notification-service का `template_code`। */
  template_code: string;
  /** evt_<ULID> — वही जो घटना-लिफ़ाफ़े में था; दोहराव यहीं से पकड़ा जाता है। */
  source_event_id: string;
  shipment_id?: string;
  invoice_id?: string;
}

const bridge = NativeModules.OFPushBridge as PushBridge | undefined;

/**
 * पहले से देखी गई सूचनाओं के `source_event_id`।
 *
 * यह §4.19 नियम 1 का ऐप-रूप है: देना at-least-once है, इसलिए वही सूचना दो बार
 * आ सकती है — एक बार पुश से और एक बार ऐप के खुलने पर। बिना इस सेट के ग्राहक को
 * एक ही देरी दो बार दिखती थी।
 */
const seenEventIds = new Set<string>();

let launchPayload: NotificationPayload | null = null;

/**
 * ऐप के जगते ही, React के पहले render से पहले चलता है।
 *
 * देशी पक्ष यह मान केवल **एक बार** देता है; दूसरी बार पूछने पर `null` मिलता है,
 * क्योंकि तब तक वह सामान्य घटना-धारा में जा चुका होता है। इसीलिए इसे यहाँ
 * पकड़कर रखा जाता है और स्क्रीन तैयार होने पर [consumeLaunchNotification] से
 * निकाला जाता है।
 */
export function captureLaunchNotification(): void {
  if (bridge === undefined) {
    // सिम्युलेटर पर, या तब जब देशी पक्ष पुराना हो। ऐप को इससे रुकना नहीं चाहिए —
    // सूचनाएँ ऐप की सुविधा हैं, उसकी शर्त नहीं।
    return;
  }
  void bridge.launchNotification().then(payload => {
    if (payload !== null && !seenEventIds.has(payload.source_event_id)) {
      seenEventIds.add(payload.source_event_id);
      launchPayload = payload;
    }
  });
}

/** पकड़ी हुई सूचना, एक ही बार। दूसरी बार पूछने पर `null`। */
export function consumeLaunchNotification(): NotificationPayload | null {
  const payload = launchPayload;
  launchPayload = null;
  return payload;
}

/**
 * चलते ऐप में आने वाली सूचनाएँ।
 *
 * @returns सदस्यता रद्द करने वाला फ़ंक्शन; स्क्रीन के हटते ही उसे बुलाना है,
 *          वरना पुरानी स्क्रीन का बंद हो चुका navigator भी टैप संभालने की
 *          कोशिश करता है।
 */
export function onNotification(handler: (payload: NotificationPayload) => void): () => void {
  if (bridge === undefined) {
    return () => undefined;
  }
  const emitter = new NativeEventEmitter(NativeModules.OFPushBridge);
  const subscription = emitter.addListener('of.notification.received', (payload: NotificationPayload) => {
    if (seenEventIds.has(payload.source_event_id)) {
      return;
    }
    seenEventIds.add(payload.source_event_id);
    handler(payload);
  });
  return () => subscription.remove();
}

/**
 * उपकरण का पुश टोकन, लॉगिन के समय भेजने के लिए।
 *
 * Android पर यह FCM का टोकन है और iOS पर APNs का। notification-service दोनों
 * को अलग-अलग कुंजियों से भेजती है, इसलिए मंच का नाम भी साथ जाता है — टोकन
 * देखकर मंच का अनुमान लगाना काम करता है, पर वह अनुमान ही रहता है।
 */
export async function devicePushToken(): Promise<{token: string; platform: string} | null> {
  if (bridge === undefined) {
    return null;
  }
  const token = await bridge.deviceToken();
  if (token === null) {
    return null;
  }
  return {token, platform: Platform.OS};
}
