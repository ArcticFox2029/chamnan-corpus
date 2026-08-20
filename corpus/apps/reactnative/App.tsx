/**
 * ऐप की जड़ — भंडार, नेविगेशन, और सूचनाओं का रास्ता।
 *
 * तीन काम यहीं होते हैं और कहीं और नहीं:
 *
 * 1. Redux भंडार पूरे पेड़ पर चढ़ाया जाता है।
 * 2. दो स्क्रीनों का ढेर बनाया जाता है। ट्रैकिंग ऐप में तीसरी स्क्रीन कभी नहीं
 *    आई और यह अच्छी बात है — ग्राहक को शिपमेंट की सूची और एक शिपमेंट का दृश्य
 *    चाहिए, बाकी सब कंसोल पर है।
 * 3. सूचनाओं की सदस्यता ली जाती है और `template_code` के अनुसार स्क्रीन खोली
 *    जाती है। सूचनाएँ notification-service से आती हैं, और उनके पीछे की घटनाएँ
 *    तीन अलग सेवाओं की हैं — इसलिए यहाँ का मानचित्र `template_code` पर है,
 *    घटना के नाम पर नहीं: वही ऐप का अनुबंध है।
 *
 * सत्र समाप्त होने पर ऐप लॉगिन पर नहीं गिरता बल्कि एक पट्टी दिखाता है, क्योंकि
 * `OF_PARTNER_SESSION_TTL_MINUTES` छोटा है और बीच काम में स्क्रीन बदल जाना
 * ग्राहक को वहीं खो देता है जहाँ वह देख रहा था।
 */
import React, {useEffect, useRef} from 'react';
import {StatusBar} from 'react-native';
import {NavigationContainer, type NavigationContainerRef} from '@react-navigation/native';
import {createNativeStackNavigator} from '@react-navigation/native-stack';
import {Provider} from 'react-redux';
import ShipmentDetailScreen from './src/screens/ShipmentDetailScreen';
import ShipmentListScreen from './src/screens/ShipmentListScreen';
import {consumeLaunchNotification, onNotification, type NotificationPayload} from './src/api/push';
import {store} from './src/store';

type RootStackParamList = {
  Shipments: undefined;
  ShipmentDetail: {shipmentId: string};
};

const Stack = createNativeStackNavigator<RootStackParamList>();

/**
 * सूचना को स्क्रीन तक ले जाता है।
 *
 * `template_code` के तीन मान ही ऐप तक पहुँचते हैं। बाकी टेम्पलेट कंसोल या
 * ई-मेल के लिए हैं और उनके लिए यहाँ कुछ करने को नहीं — अनजान टेम्पलेट पर ऐप
 * केवल खुल जाता है, जो सही व्यवहार है: सूचना पहले ही दिख चुकी होती है।
 */
function routeNotification(
  navigation: NavigationContainerRef<RootStackParamList> | null,
  payload: NotificationPayload,
): void {
  if (navigation === null || payload.shipment_id === undefined) {
    return;
  }
  switch (payload.template_code) {
    case 'shipment_delayed':
    case 'invoice_overdue':
      navigation.navigate('ShipmentDetail', {shipmentId: payload.shipment_id});
      break;
    default:
      break;
  }
}

export default function App(): React.JSX.Element {
  const navigationRef = useRef<NavigationContainerRef<RootStackParamList>>(null);

  useEffect(() => {
    // ऐप के जगने से पहले पकड़ी गई सूचना, यदि उसी पर टैप करके खुला हो।
    const launch = consumeLaunchNotification();
    if (launch !== null) {
      routeNotification(navigationRef.current, launch);
    }

    // चलते ऐप में आने वाली सूचनाएँ। सदस्यता हटाना ज़रूरी है, वरना गरम-पुनर्लोड
    // के बाद दो श्रोता एक ही टैप पर दो बार स्क्रीन खोलते हैं।
    return onNotification(payload => {
      routeNotification(navigationRef.current, payload);
    });
  }, []);

  return (
    <Provider store={store}>
      <StatusBar barStyle="dark-content" backgroundColor="#FAFAF7" />
      <NavigationContainer ref={navigationRef}>
        <Stack.Navigator initialRouteName="Shipments">
          <Stack.Screen
            name="Shipments"
            component={ShipmentListScreen}
            options={{title: 'Your shipments'}}
          />
          <Stack.Screen
            name="ShipmentDetail"
            component={ShipmentDetailScreen}
            options={{title: 'Shipment'}}
          />
        </Stack.Navigator>
      </NavigationContainer>
    </Provider>
  );
}
