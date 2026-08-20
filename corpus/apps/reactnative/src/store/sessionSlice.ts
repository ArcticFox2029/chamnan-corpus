/**
 * साझेदार सत्र की अवस्था — लॉगिन, समाप्ति और लॉगआउट।
 *
 * यह टुकड़ा जान-बूझकर पतला है: टोकन यहाँ रहता है पर भंडार में नहीं जाता।
 * `OF_PARTNER_SESSION_TTL_MINUTES` छोटा है और ग्राहक ऐप कोई कतार नहीं रखता,
 * इसलिए टोकन को स्थायी भंडार में लिखने से केवल जोखिम बढ़ता, सुविधा नहीं —
 * ऐप दोबारा खुलने पर वैसे भी नया सत्र चाहिए होता।
 *
 * एक ही जगह ध्यान माँगती है: `key_prefix` याद रखा जाता है, `secret` कभी नहीं।
 * Prefix सार्वजनिक हैंडल है (कंसोल पर भी वही दिखता है), पर secret सर्वर पर भी
 * केवल argon2id हैश के रूप में है — उसे उपकरण पर रखना उस पूरी व्यवस्था को
 * बेकार कर देता।
 */
import {createAsyncThunk, createSlice, type PayloadAction} from '@reduxjs/toolkit';
import {OrbitalApiError, setSession, type PartnerSession} from '../api/client';
import {openSession} from '../api/partnerPortal';
import {devicePushToken} from '../api/push';

export interface SessionState {
  status: 'signed_out' | 'signing_in' | 'signed_in' | 'failed';
  /** cred_ का सार्वजनिक हैंडल — बारह अक्षर, कंसोल पर दिखने वाला। */
  keyPrefix: string | null;
  tenantId: string | null;
  expiresAt: string | null;
  /** §0.4 का `error.code`, जस का तस; स्क्रीन इसी पर संदेश चुनती है। */
  errorCode: string | null;
}

const initialState: SessionState = {
  status: 'signed_out',
  keyPrefix: null,
  tenantId: null,
  expiresAt: null,
  errorCode: null,
};

/**
 * `POST /partner/v1/sessions` — पुश टोकन के साथ।
 *
 * टोकन पहले माँगा जाता है और उसकी विफलता लॉगिन नहीं रोकती: अनुमति न देने वाला
 * ग्राहक भी शिपमेंट देख सकता है, उसे बस देरी की सूचना नहीं मिलेगी।
 */
export const signIn = createAsyncThunk<
  {session: PartnerSession; keyPrefix: string},
  {keyPrefix: string; secret: string},
  {rejectValue: string}
>('session/signIn', async ({keyPrefix, secret}, {rejectWithValue}) => {
  try {
    const push = await devicePushToken();
    const session = await openSession(keyPrefix, secret, push?.token ?? null);
    return {session, keyPrefix};
  } catch (failure) {
    if (failure instanceof OrbitalApiError) {
      return rejectWithValue(failure.code);
    }
    // नेटवर्क ही नहीं पहुँचा — यह सेवा की विफलता नहीं है और उसे वैसा दिखाना
    // भी नहीं चाहिए, वरना ग्राहक सहायता-डेस्क को ग़लत बात बताता है।
    return rejectWithValue('network_unreachable');
  }
});

const sessionSlice = createSlice({
  name: 'session',
  initialState,
  reducers: {
    /**
     * लॉगआउट, और वह भी जो सर्वर के `401` पर अपने आप होता है।
     *
     * यहाँ HTTP क्लाइंट का सत्र भी साफ़ किया जाता है — केवल Redux की अवस्था
     * बदलने से क्लाइंट पुराना टोकन भेजता रहता और हर अनुरोध `401` लाता।
     */
    signedOut(state) {
      setSession(null);
      state.status = 'signed_out';
      state.tenantId = null;
      state.expiresAt = null;
      state.errorCode = null;
    },
    sessionExpired(state, action: PayloadAction<string>) {
      setSession(null);
      state.status = 'failed';
      state.errorCode = action.payload;
    },
  },
  extraReducers: builder => {
    builder
      .addCase(signIn.pending, state => {
        state.status = 'signing_in';
        state.errorCode = null;
      })
      .addCase(signIn.fulfilled, (state, action) => {
        state.status = 'signed_in';
        state.keyPrefix = action.payload.keyPrefix;
        state.tenantId = action.payload.session.tenantId;
        state.expiresAt = action.payload.session.expiresAt;
      })
      .addCase(signIn.rejected, (state, action) => {
        state.status = 'failed';
        state.errorCode = action.payload ?? 'unknown';
      });
  },
});

export const {signedOut, sessionExpired} = sessionSlice.actions;
export default sessionSlice.reducer;
