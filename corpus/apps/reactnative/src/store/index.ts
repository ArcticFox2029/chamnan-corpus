/**
 * ऐप का एकमात्र भंडार (store) और उसके सहायक हुक।
 *
 * दो टुकड़े हैं और यही पर्याप्त हैं: सत्र और शिपमेंट। तीसरा टुकड़ा — सूचनाओं का —
 * जान-बूझकर नहीं बनाया गया; सूचना कोई अवस्था नहीं है, वह एक घटना है, और उसे
 * भंडार में रखने का मतलब होता उसी `source_event_id` को दो जगह याद रखना
 * (`src/api/push.ts` में पहले से है)।
 *
 * `serializableCheck` में `expiresAt` जैसी तिथियाँ स्ट्रिंग ही रहती हैं — RFC
 * 3339 का पाठ, वैसा ही जैसा तार पर आया (§0.2)। उन्हें `Date` में बदलकर भंडार
 * में रखना दो कारणों से नहीं किया गया: Redux की जाँच उन्हें अ-क्रमिक बताती है,
 * और स्थानीय समय-क्षेत्र में बदली हुई तिथि लॉग में सर्वर की तिथि से मेल नहीं खाती।
 */
import {configureStore} from '@reduxjs/toolkit';
import {useDispatch, useSelector, type TypedUseSelectorHook} from 'react-redux';
import sessionReducer from './sessionSlice';
import shipmentsReducer from './shipmentsSlice';

export const store = configureStore({
  reducer: {
    session: sessionReducer,
    shipments: shipmentsReducer,
  },
  middleware: getDefaultMiddleware =>
    getDefaultMiddleware({
      serializableCheck: {
        // थंक की अस्वीकृति में §0.4 का लिफ़ाफ़ा जाता है, जो सादा वस्तु है;
        // अपवाद केवल इसलिए कि जाँच उसके `Error` वंश पर अटकती थी।
        ignoredActionPaths: ['meta.arg', 'payload.error'],
      },
    }),
  devTools: process.env.OF_ENVIRONMENT !== 'production',
});

export type RootState = ReturnType<typeof store.getState>;
export type AppDispatch = typeof store.dispatch;

/** प्रकार-सहित हुक; स्क्रीनों में सादे `useSelector` की जगह यही चलते हैं। */
export const useAppDispatch: () => AppDispatch = useDispatch;
export const useAppSelector: TypedUseSelectorHook<RootState> = useSelector;

/**
 * चालू शिपमेंट पहले, फिर बाकी।
 *
 * "चालू" वही पाँच स्थितियाँ हैं जिनमें शिपमेंट अब भी रास्ते में है। यह क्रम
 * सर्वर से नहीं आता और आना भी नहीं चाहिए — साझेदार सतह सूची को अपने क्रम में
 * देती है और उस पर छँटाई थोपने का मतलब होता हर पेज पर पूरी सूची दोबारा माँगना।
 */
export function selectOrderedShipments(state: RootState) {
  const open = ['booked', 'sealed', 'in_transit', 'at_risk', 'held_at_customs'];
  return state.shipments.order
    .map(id => state.shipments.byId[id])
    .filter((shipment): shipment is NonNullable<typeof shipment> => shipment !== undefined)
    .sort((left, right) => {
      const leftOpen = open.includes(left.status) ? 0 : 1;
      const rightOpen = open.includes(right.status) ? 0 : 1;
      return leftOpen - rightOpen;
    });
}
