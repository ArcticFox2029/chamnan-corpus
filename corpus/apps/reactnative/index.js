/**
 * ऐप का प्रवेश-बिंदु, जिसे दोनों देशी पक्ष उठाते हैं — iOS पर `AppDelegate` और
 * Android पर `MainActivity`।
 *
 * यहाँ केवल पंजीकरण है और होना भी यही चाहिए; असली शुरुआत `App.tsx` में है।
 * एक अपवाद है: सूचना पर टैप करके खुलने वाला रास्ता। notification-service से आई
 * सूचना में `source_event_id` (evt_…) और `shipment_id` होते हैं, और वह मान यहाँ,
 * React के पहले render से पहले, पकड़ लिया जाता है — देशी पक्ष उसे केवल एक बार
 * देता है और तब तक ऐप का पेड़ खड़ा नहीं हुआ होता।
 */
import {AppRegistry} from 'react-native';
import App from './App';
import {captureLaunchNotification} from './src/api/push';

/**
 * यह नाम देशी पक्ष के `moduleName` से अक्षरशः मेल खाना चाहिए — iOS में
 * `AppDelegate.mm` का `moduleName`, Android में `MainActivity.getMainComponentName()`।
 * बेमेल होने पर ऐप बिना किसी त्रुटि के सफ़ेद स्क्रीन दिखाता है, इसलिए इसे यहीं
 * एक जगह रखा गया है।
 */
const APP_NAME = 'OrbitalFreightTracking';

captureLaunchNotification();

AppRegistry.registerComponent(APP_NAME, () => App);
