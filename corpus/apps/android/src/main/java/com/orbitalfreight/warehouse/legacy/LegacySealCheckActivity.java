package com.orbitalfreight.warehouse.legacy;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.util.Log;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;
import android.widget.Toast;

import com.orbitalfreight.warehouse.R;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * सील जाँच की पुरानी स्क्रीन, जो Compose वाले पुनर्लेखन (2025 की गर्मियों) से
 * पहले की है और अब भी इसलिए ज़िंदा है कि DE-Hamburg तथा NL-Rotterdam के
 * रिंग-स्कैनर सीधे इसी को intent भेजते हैं
 * (<code>com.orbitalfreight.warehouse.SEAL_CHECK</code>)। वे उपकरण फ़र्मवेयर-स्तर
 * पर उस action से बँधे हैं और उन्हें बदलने का काम अगले हार्डवेयर चक्र में है।
 *
 * <p>यह क्लास नई स्क्रीन से तीन जगह अलग है, और तीनों अंतर जान-बूझकर छोड़े गए हैं
 * क्योंकि इसे बदलने का मतलब उन्हीं उपकरणों पर दोबारा परीक्षण करना है:</p>
 *
 * <ul>
 *   <li>यह स्कैन सीधे भेजने की कोशिश करती है और विफल होने पर ही कतार में डालती
 *       है। नई स्क्रीन हमेशा पहले कतार में डालती है। पुराना क्रम गोदाम के अंदर
 *       धीमा लगता है, पर गेट पर — जहाँ सिग्नल है — तुरंत पुष्टि देता है, और
 *       गेट-कर्मचारी उसी के आदी हैं।</li>
 *   <li>यह {@link LegacyScanUploadService} से बात करती है, {@code ScanOutboxWorker}
 *       से नहीं। दोनों एक ही तालिका पर लिखते हैं, इसलिए स्कैन खोता नहीं।</li>
 *   <li>यहाँ कोई ViewModel नहीं है; अवस्था Activity में ही है और घूमने पर खो
 *       जाती है — इसीलिए मेनिफ़ेस्ट में इसका orientation स्थिर किया गया है।</li>
 * </ul>
 *
 * <p><b>इसमें नया फ़ीचर मत जोड़िए।</b> जो कुछ भी बदलना है वह
 * {@code ui.scan.ScanScreen} में जाता है; यह फ़ाइल केवल तब छुई जाती है जब कोई
 * बग सीधे इन्हीं उपकरणों पर दिखे।</p>
 */
public class LegacySealCheckActivity extends Activity {

    private static final String TAG = "OFSealCheck";

    /** रिंग-स्कैनर इसी अतिरिक्त कुंजी में BIC कोड भेजता है। */
    public static final String EXTRA_ISO_CODE = "iso_code";

    /** पुराने फ़र्मवेयर में यह कुंजी नहीं थी; तब सील हाथ से टाइप होती है। */
    public static final String EXTRA_SEAL_NUMBER = "seal_number";

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private EditText isoCodeField;
    private EditText sealField;
    private TextView expectedSealLabel;
    private LegacyScanStore store;

    private String containerId;
    private String shipmentId;
    private String expectedSeal;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_legacy_seal_check);

        isoCodeField = findViewById(R.id.legacy_iso_code);
        sealField = findViewById(R.id.legacy_seal_number);
        expectedSealLabel = findViewById(R.id.legacy_expected_seal);
        Button submit = findViewById(R.id.legacy_submit);

        store = new LegacyScanStore(this);

        Intent intent = getIntent();
        String isoCode = intent.getStringExtra(EXTRA_ISO_CODE);
        if (!TextUtils.isEmpty(isoCode)) {
            isoCodeField.setText(isoCode);
            lookupContainer(isoCode);
        }
        String seal = intent.getStringExtra(EXTRA_SEAL_NUMBER);
        if (!TextUtils.isEmpty(seal)) {
            sealField.setText(seal);
        }

        submit.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                onSubmitPressed();
            }
        });
    }

    /**
     * स्थानीय कैश से डिब्बा और उसकी खुली जोड़ी निकालता है। सर्वर से नहीं पूछता —
     * यह स्क्रीन उन्हीं गेटों पर चलती है जहाँ कैश हर सुबह भरा जाता है।
     */
    private void lookupContainer(final String isoCode) {
        executor.execute(new Runnable() {
            @Override
            public void run() {
                final LegacyScanStore.Pairing pairing = store.findActivePairing(isoCode.trim().toUpperCase());
                mainHandler.post(new Runnable() {
                    @Override
                    public void run() {
                        if (pairing == null) {
                            Toast.makeText(LegacySealCheckActivity.this,
                                    R.string.error_offline_queued, Toast.LENGTH_LONG).show();
                            return;
                        }
                        containerId = pairing.containerId;
                        shipmentId = pairing.shipmentId;
                        expectedSeal = pairing.sealNumber;
                        expectedSealLabel.setText(pairing.sealNumber);
                    }
                });
            }
        });
    }

    /**
     * जाँच का परिणाम कतार में डालता है।
     *
     * <p>भिन्नता मिलने पर भी स्कैन रुकता नहीं। यह पहले दिन से ऐसा ही है और सही
     * है: गेट पर खड़ा कर्मचारी यह तय नहीं कर सकता कि सील बदली किसने — उसका काम
     * दर्ज करना है। असली मिलान reconciliation-service रात को करती है और ज़रूरत
     * पड़ने पर <code>weight_mismatch</code> जैसी विसंगति खोलती है।</p>
     */
    private void onSubmitPressed() {
        if (containerId == null || shipmentId == null) {
            Toast.makeText(this, R.string.error_offline_queued, Toast.LENGTH_LONG).show();
            return;
        }

        String observed = sealField.getText().toString().trim().toUpperCase();
        if (TextUtils.isEmpty(observed)) {
            sealField.setError(getString(R.string.scan_hint_seal));
            return;
        }

        final String notes;
        if (expectedSeal != null && !expectedSeal.equals(observed)) {
            notes = "seal mismatch: expected=" + expectedSeal + " observed=" + observed;
            Log.w(TAG, "seal mismatch on shipment " + shipmentId + " container " + containerId);
        } else {
            notes = "seal verified: " + observed;
        }

        executor.execute(new Runnable() {
            @Override
            public void run() {
                // scan_type हमेशा 'seal_check'; यह स्क्रीन कोई और प्रकार नहीं भेजती।
                store.enqueue(shipmentId, containerId, "seal_check", notes);
                LegacyScanUploadService.start(LegacySealCheckActivity.this);
                mainHandler.post(new Runnable() {
                    @Override
                    public void run() {
                        Toast.makeText(LegacySealCheckActivity.this,
                                R.string.scan_queued, Toast.LENGTH_SHORT).show();
                        finish();
                    }
                });
            }
        });
    }

    @Override
    protected void onDestroy() {
        executor.shutdownNow();
        super.onDestroy();
    }
}
