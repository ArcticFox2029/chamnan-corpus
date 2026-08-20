/**
 * शिपमेंट की सूची और एकल दृश्य — ऐप की मुख्य अवस्था।
 *
 * तीन बातें यहाँ की बनावट तय करती हैं:
 *
 *  1. **कर्सर, ऑफ़सेट नहीं (§0.5)।** पेज जोड़ते समय `next_cursor` ही आगे बढ़ने
 *     का साधन है, और उसका `null` होना ही अंत का संकेत। "पेज संख्या" जैसी कोई
 *     चीज़ नहीं है और उसे बनाने की कोशिश भी नहीं करनी चाहिए — सूची बीच में बदल
 *     सकती है और तब पेज संख्या झूठ बोलने लगती है।
 *  2. **पहचान से अनुक्रमित भंडार।** सूचना पर टैप करके सीधे एकल दृश्य खुल सकता
 *     है, यानी सूची लोड हुए बिना भी एक शिपमेंट भंडार में आ सकता है। इसलिए
 *     `byId` ही सत्य है और `order` केवल क्रम रखता है।
 *  3. **स्थिति सर्वर की भाषा में।** `status` वही आठ मान हैं जो
 *     `freight.shipments` में हैं; अनुवाद केवल दिखाते समय होता है। अवस्था में
 *     अनुवादित मान रखने से छानना टूट जाता है।
 */
import {createAsyncThunk, createSlice} from '@reduxjs/toolkit';
import {OrbitalApiError} from '../api/client';
import {getShipment, listShipments, type TrackedShipment} from '../api/partnerPortal';

export interface ShipmentsState {
  byId: Record<string, TrackedShipment>;
  /** सूची का क्रम, वैसा ही जैसा सर्वर ने दिया। */
  order: string[];
  nextCursor: string | null;
  loading: boolean;
  /** §0.4 का `error.code`। */
  errorCode: string | null;
  /** केवल तभी `true` जब विफलता दोबारा कोशिश करने लायक थी। */
  retryable: boolean;
}

const initialState: ShipmentsState = {
  byId: {},
  order: [],
  nextCursor: null,
  loading: false,
  errorCode: null,
  retryable: false,
};

/**
 * `GET /partner/v1/shipments` का अगला पेज।
 *
 * @param refresh `true` होने पर कर्सर छोड़कर शुरुआत से; खींचकर-ताज़ा करने वाला
 *        इशारा यही भेजता है। पुराना क्रम तभी हटता है जब नया पेज आ जाए, वरना
 *        सूची एक क्षण के लिए खाली दिखती है।
 */
export const loadShipments = createAsyncThunk<
  {items: TrackedShipment[]; nextCursor: string | null; refresh: boolean},
  {refresh: boolean; status?: string},
  {state: {shipments: ShipmentsState}; rejectValue: {code: string; retryable: boolean}}
>('shipments/load', async ({refresh, status}, {getState, rejectWithValue}) => {
  const cursor = refresh ? null : getState().shipments.nextCursor;
  try {
    const page = await listShipments(cursor, status);
    return {items: page.items, nextCursor: page.next_cursor, refresh};
  } catch (failure) {
    if (failure instanceof OrbitalApiError) {
      return rejectWithValue({code: failure.code, retryable: failure.retryable});
    }
    return rejectWithValue({code: 'network_unreachable', retryable: true});
  }
});

/**
 * `GET /partner/v1/shipments/{shipment_id}` — एकल, छँटा हुआ दृश्य।
 *
 * सूची वाला उत्तर और यह उत्तर एक ही आकार के हैं, पर एकल दृश्य में डिब्बे और
 * स्कैन भी भरे होते हैं। इसलिए यह हमेशा सूची वाली पंक्ति को *बदल* देता है,
 * जोड़ता नहीं — उल्टा करने पर आधा भरा शिपमेंट पूरे भरे को मिटा देता था।
 */
export const loadShipmentDetail = createAsyncThunk<
  TrackedShipment,
  string,
  {rejectValue: {code: string; retryable: boolean}}
>('shipments/detail', async (shipmentId, {rejectWithValue}) => {
  try {
    return await getShipment(shipmentId);
  } catch (failure) {
    if (failure instanceof OrbitalApiError) {
      return rejectWithValue({code: failure.code, retryable: failure.retryable});
    }
    return rejectWithValue({code: 'network_unreachable', retryable: true});
  }
});

const shipmentsSlice = createSlice({
  name: 'shipments',
  initialState,
  reducers: {
    /**
     * सूचना से आई स्थिति-बदलाव की ख़बर।
     *
     * यह सर्वर का उत्तर नहीं है, इसलिए इससे केवल `status` छुआ जाता है और कुछ
     * नहीं। असली पंक्ति अगले [loadShipmentDetail] पर आती है; तब तक ग्राहक को
     * नई स्थिति दिख जाती है, जो सूचना खोलने का पूरा कारण ही है।
     */
    statusNudged(state, action: {payload: {shipmentId: string; status: string}}) {
      const existing = state.byId[action.payload.shipmentId];
      if (existing !== undefined) {
        existing.status = action.payload.status;
      }
    },
    cleared() {
      return initialState;
    },
  },
  extraReducers: builder => {
    builder
      .addCase(loadShipments.pending, state => {
        state.loading = true;
        state.errorCode = null;
      })
      .addCase(loadShipments.fulfilled, (state, action) => {
        state.loading = false;
        if (action.payload.refresh) {
          state.order = [];
        }
        for (const shipment of action.payload.items) {
          state.byId[shipment.shipment_id] = shipment;
          if (!state.order.includes(shipment.shipment_id)) {
            state.order.push(shipment.shipment_id);
          }
        }
        state.nextCursor = action.payload.nextCursor;
      })
      .addCase(loadShipments.rejected, (state, action) => {
        state.loading = false;
        state.errorCode = action.payload?.code ?? 'unknown';
        state.retryable = action.payload?.retryable ?? false;
      })
      .addCase(loadShipmentDetail.fulfilled, (state, action) => {
        state.byId[action.payload.shipment_id] = action.payload;
      })
      .addCase(loadShipmentDetail.rejected, (state, action) => {
        state.errorCode = action.payload?.code ?? 'unknown';
        state.retryable = action.payload?.retryable ?? false;
      });
  },
});

export const {statusNudged, cleared} = shipmentsSlice.actions;
export default shipmentsSlice.reducer;
