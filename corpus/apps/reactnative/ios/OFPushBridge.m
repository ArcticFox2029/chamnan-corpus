/**
 * OFPushBridge — iOS की ओर का देशी पुल, जिससे JavaScript को APNs का टोकन और
 * notification-service की सूचनाएँ मिलती हैं।
 *
 * यह फ़ाइल तीन ज़िम्मेदारियाँ निभाती है:
 *
 *  1. APNs का उपकरण-टोकन इकट्ठा करना और उसे JS की प्रतीक्षा से जोड़ना। टोकन
 *     ऐप के जगने के कई सौ मिलीसेकंड बाद आता है, इसलिए `deviceToken` का वादा
 *     (promise) तब तक रोका जाता है जब तक `AppDelegate` उसे यहाँ न सौंप दे।
 *  2. वह सूचना संभालना जिस पर टैप करके ऐप खुला। iOS उसे केवल एक बार देता है
 *     और ऐप के पूरे जगने से पहले, इसलिए वह यहाँ रखी जाती है और JS पहली फ़ुरसत
 *     में उठा लेता है।
 *  3. चलते ऐप में आने वाली सूचनाओं को `of.notification.received` घटना के रूप
 *     में ऊपर भेजना।
 *
 * पेलोड notification-service (§3.10) बनाती है और वहाँ से तीन मान हमेशा आते हैं:
 * `template_code`, `source_event_id` (evt_…) और `shipment_id`। दूसरा ही JS को
 * दोहराव पकड़ने देता है — देना at-least-once है, यानी वही सूचना दो बार आ सकती है।
 *
 * यहाँ कोई नेटवर्क कॉल नहीं है और नहीं होनी चाहिए: टोकन का पंजीकरण
 * `POST /partner/v1/sessions` के साथ JS से जाता है, क्योंकि साझेदार सतह पर
 * उसके लिए कोई अलग पथ नहीं है।
 */

#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <UIKit/UIKit.h>

static NSString *const OFNotificationReceivedEvent = @"of.notification.received";

@interface OFPushBridge : RCTEventEmitter <RCTBridgeModule>

/** `AppDelegate` से, `didRegisterForRemoteNotificationsWithDeviceToken` पर। */
+ (void)storeDeviceToken:(NSData *)tokenData;

/** `AppDelegate` से, तब जब सूचना पर टैप करके ऐप खुला हो। */
+ (void)storeLaunchNotification:(NSDictionary *)payload;

/** `AppDelegate` से, चलते ऐप में सूचना आने पर। */
+ (void)deliverNotification:(NSDictionary *)payload;

@end

@implementation OFPushBridge {
  BOOL _hasListeners;
}

/**
 * ये तीनों स्थिर हैं क्योंकि `AppDelegate` को मॉड्यूल का उदाहरण नहीं मिलता —
 * वह ब्रिज के भीतर बनता है और तब तक APNs का उत्तर आ चुका होता है।
 */
static NSString *_deviceToken = nil;
static NSDictionary *_launchNotification = nil;
static NSMutableArray<RCTPromiseResolveBlock> *_waitingForToken = nil;
static __weak OFPushBridge *_activeInstance = nil;

RCT_EXPORT_MODULE(OFPushBridge);

+ (BOOL)requiresMainQueueSetup {
  // कोई UI नहीं बनता, इसलिए मुख्य कतार की ज़रूरत नहीं; इसे YES रखने से हर
  // शुरुआत में मुख्य थ्रेड बेवजह रुकता है।
  return NO;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _activeInstance = self;
  }
  return self;
}

- (NSArray<NSString *> *)supportedEvents {
  return @[OFNotificationReceivedEvent];
}

- (void)startObserving {
  _hasListeners = YES;
}

- (void)stopObserving {
  _hasListeners = NO;
}

+ (void)storeDeviceToken:(NSData *)tokenData {
  const unsigned char *bytes = (const unsigned char *)tokenData.bytes;
  NSMutableString *hex = [NSMutableString stringWithCapacity:tokenData.length * 2];
  for (NSUInteger index = 0; index < tokenData.length; index++) {
    [hex appendFormat:@"%02x", bytes[index]];
  }
  _deviceToken = [hex copy];

  // वे सारे वादे जो टोकन आने से पहले माँगे गए थे, अब एक साथ पूरे होते हैं।
  if (_waitingForToken != nil) {
    for (RCTPromiseResolveBlock resolve in _waitingForToken) {
      resolve(_deviceToken);
    }
    [_waitingForToken removeAllObjects];
  }
}

+ (void)storeLaunchNotification:(NSDictionary *)payload {
  _launchNotification = [payload copy];
}

+ (void)deliverNotification:(NSDictionary *)payload {
  OFPushBridge *instance = _activeInstance;
  if (instance == nil || !instance->_hasListeners) {
    // JS अभी सुन नहीं रहा (ऐप पृष्ठभूमि में है)। सूचना खोई नहीं जाती — वह
    // सिस्टम की ट्रे में है, और टैप करने पर `storeLaunchNotification:` वाला
    // रास्ता चलता है।
    return;
  }
  [instance sendEventWithName:OFNotificationReceivedEvent body:payload];
}

/**
 * APNs का टोकन, हेक्स में।
 *
 * टोकन अभी न आया हो तो वादा रोका जाता है, अस्वीकार नहीं किया जाता: अस्वीकार
 * करने पर लॉगिन बिना पुश-टोकन के हो जाता था और ग्राहक को कोई सूचना नहीं मिलती
 * थी, बिना किसी संकेत के। उपयोगकर्ता ने अनुमति ही न दी हो तो `AppDelegate`
 * कभी टोकन नहीं सौंपेगा और वादा लॉगिन की अपनी समय-सीमा के साथ ही समाप्त होगा।
 */
RCT_EXPORT_METHOD(deviceToken:(RCTPromiseResolveBlock)resolve
                     rejecter:(RCTPromiseRejectBlock)reject) {
  if (_deviceToken != nil) {
    resolve(_deviceToken);
    return;
  }
  if (_waitingForToken == nil) {
    _waitingForToken = [NSMutableArray array];
  }
  [_waitingForToken addObject:resolve];
}

/**
 * वह सूचना जिस पर टैप करके ऐप खुला — केवल एक बार।
 *
 * दूसरी बार `null` लौटता है, और यही ठीक है: JS उसे अपने पास रख लेता है और
 * `source_event_id` से दोहराव रोकता है।
 */
RCT_EXPORT_METHOD(launchNotification:(RCTPromiseResolveBlock)resolve
                            rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *payload = _launchNotification;
  _launchNotification = nil;
  resolve(payload);
}

@end
