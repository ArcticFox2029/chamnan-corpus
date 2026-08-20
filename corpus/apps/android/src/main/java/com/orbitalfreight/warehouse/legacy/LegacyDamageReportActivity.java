package com.orbitalfreight.warehouse.legacy;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.text.TextUtils;
import android.util.Log;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.Toast;

import com.orbitalfreight.warehouse.BuildConfig;
import com.orbitalfreight.warehouse.R;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * क्षति दर्ज करने की पुरानी स्क्रीन: एक तस्वीर, एक टिप्पणी, और
 * <code>damage_report</code> प्रकार का स्कैन।
 *
 * <p>यह {@link LegacySealCheckActivity} से खुलती है जब गेट पर सील जाँचते समय
 * डिब्बे पर चोट दिखे। मेनिफ़ेस्ट में यह {@code exported="false"} है — रिंग-स्कैनर
 * इसे सीधे नहीं खोलते, क्योंकि इसे खोलने के लिए पहले जोड़ी (shipment + container)
 * पता होनी चाहिए और वह जानकारी सील-जाँच स्क्रीन के पास ही होती है।</p>
 *
 * <p>दो चीज़ें यहाँ ऐसी हैं जिन्हें नई स्क्रीन ने बदल दिया है और यहाँ नहीं बदला
 * गया:</p>
 *
 * <ul>
 *   <li>तस्वीर सिस्टम कैमरा ऐप से आती है ({@code ACTION_IMAGE_CAPTURE}), CameraX
 *       से नहीं। पुराने Zebra उपकरणों पर CameraX का पूर्वावलोकन धीमा था और
 *       कर्मचारी शिकायत करते थे कि तस्वीर "देर से जमती" है।</li>
 *   <li>तस्वीर यहीं JPEG में दबाई जाती है ताकि वह
 *       {@code OF_DOCUMENT_MAX_UPLOAD_BYTES} की सीमा में रहे। सीमा से बड़ी फ़ाइल
 *       document-service पर {@code 413} लाती है और कतार में एक मरी हुई पंक्ति
 *       छोड़ जाती है, इसलिए जाँच भेजने से पहले होती है, बाद में नहीं।</li>
 * </ul>
 *
 * <p>तस्वीर स्वयं यहाँ से नहीं चढ़ती। यह स्क्रीन केवल दो पंक्तियाँ लिखती है —
 * एक <code>scan_outbox</code> में और एक <code>damage_photo_outbox</code> में —
 * और चढ़ाने का काम {@code DamagePhotoUploadWorker} करता है, क्योंकि उसे
 * बिना-मीटर वाले कनेक्शन का इंतज़ार करने की छूट है।</p>
 */
public class LegacyDamageReportActivity extends Activity {

    private static final String TAG = "OFDamageReport";

    private static final int REQUEST_CAPTURE = 71;

    /** {@link LegacySealCheckActivity} इन्हीं कुंजियों से जोड़ी आगे भेजती है। */
    public static final String EXTRA_SHIPMENT_ID = "shipment_id";
    public static final String EXTRA_CONTAINER_ID = "container_id";

    /** दबाव की गुणवत्ता; 70 पर 12 MP की तस्वीर लगभग 2 MB रह जाती है। */
    private static final int JPEG_QUALITY = 70;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private LegacyScanStore store;
    private EditText notesField;
    private ImageView preview;
    private File capturedFile;

    private String shipmentId;
    private String containerId;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_legacy_damage_report);

        store = new LegacyScanStore(this);
        notesField = findViewById(R.id.legacy_damage_notes);
        preview = findViewById(R.id.legacy_damage_preview);
        Button capture = findViewById(R.id.legacy_damage_capture);
        Button submit = findViewById(R.id.legacy_damage_submit);

        shipmentId = getIntent().getStringExtra(EXTRA_SHIPMENT_ID);
        containerId = getIntent().getStringExtra(EXTRA_CONTAINER_ID);
        if (TextUtils.isEmpty(shipmentId) || TextUtils.isEmpty(containerId)) {
            // बिना जोड़ी के यह स्क्रीन कुछ नहीं कर सकती; चुपचाप बंद होना ही सही है।
            Log.e(TAG, "opened without a shipment/container pairing");
            finish();
            return;
        }

        capture.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                startActivityForResult(new Intent(MediaStore.ACTION_IMAGE_CAPTURE), REQUEST_CAPTURE);
            }
        });

        submit.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                onSubmitPressed();
            }
        });
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_CAPTURE || resultCode != RESULT_OK || data == null) {
            return;
        }
        // छोटा thumbnail सीधे intent में आता है; पूरी फ़ाइल Uri से पढ़ी जाती है
        // जब कैमरा ऐप ने वह दी हो, वरना thumbnail ही दर्ज होता है।
        final Uri source = data.getData();
        final Bitmap thumbnail = (Bitmap) data.getExtras().get("data");
        preview.setImageBitmap(thumbnail);

        executor.execute(new Runnable() {
            @Override
            public void run() {
                capturedFile = writeJpeg(source, thumbnail);
            }
        });
    }

    /**
     * तस्वीर को ऐप की अपनी फ़ाइलों में JPEG के रूप में लिखती है।
     *
     * <p>फ़ाइल {@code getFilesDir()} में जाती है, कैश में नहीं: कैश को सिस्टम
     * कभी भी खाली कर सकता है और तब कतार में पड़ी पंक्ति उस फ़ाइल की ओर इशारा
     * करती रह जाती जो अब नहीं है। अपलोड हो जाने के बाद वर्कर खुद फ़ाइल हटाता है।</p>
     */
    private File writeJpeg(Uri source, Bitmap fallback) {
        File target = new File(getFilesDir(), "damage-" + System.currentTimeMillis() + ".jpg");
        try {
            Bitmap image = fallback;
            if (source != null) {
                InputStream stream = getContentResolver().openInputStream(source);
                image = BitmapFactory.decodeStream(stream);
                stream.close();
            }
            FileOutputStream output = new FileOutputStream(target);
            image.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output);
            output.flush();
            output.close();
            return target;
        } catch (Exception error) {
            Log.e(TAG, "could not store the captured photo", error);
            return null;
        }
    }

    /**
     * दोनों कतारों में पंक्तियाँ डालती है और स्क्रीन बंद कर देती है।
     *
     * <p>क्रम मायने रखता है: पहले स्कैन, फिर तस्वीर। तस्वीर की पंक्ति स्कैन की
     * स्थानीय पंक्ति-संख्या पकड़ती है और scn_ मिलने पर ही {@code owner_id} भरता
     * है, क्योंकि document-service को {@code owner_type='scan'} के साथ एक असली
     * scn_ चाहिए — <code>platform.document_owner_types</code> की शब्दावली इसी
     * जोड़ी को वैध मानती है।</p>
     */
    private void onSubmitPressed() {
        if (capturedFile == null) {
            Toast.makeText(this, R.string.damage_photo_title, Toast.LENGTH_SHORT).show();
            return;
        }
        if (capturedFile.length() > BuildConfig.MAX_DOCUMENT_UPLOAD_BYTES) {
            Toast.makeText(this, R.string.damage_photo_too_large, Toast.LENGTH_LONG).show();
            return;
        }

        final String notes = notesField.getText().toString().trim();
        executor.execute(new Runnable() {
            @Override
            public void run() {
                long scanLocalId = store.enqueue(shipmentId, containerId, "damage_report",
                        TextUtils.isEmpty(notes) ? "damage reported at gate" : notes);
                store.enqueueDamagePhoto(scanLocalId, capturedFile.getAbsolutePath(),
                        capturedFile.length(), sha256Hex(capturedFile));
                LegacyScanUploadService.start(LegacyDamageReportActivity.this);

                mainHandler.post(new Runnable() {
                    @Override
                    public void run() {
                        Toast.makeText(LegacyDamageReportActivity.this,
                                R.string.scan_queued, Toast.LENGTH_SHORT).show();
                        finish();
                    }
                });
            }
        });
    }

    /**
     * फ़ाइल का SHA-256, हेक्स में। document-service इसी से वही तस्वीर दोबारा
     * चढ़ने पर नया blob लिखने के बजाय पुराना doc_ लौटा देता है।
     */
    private static String sha256Hex(File file) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            java.io.FileInputStream input = new java.io.FileInputStream(file);
            byte[] buffer = new byte[8192];
            int read;
            while ((read = input.read(buffer)) > 0) {
                digest.update(buffer, 0, read);
            }
            input.close();

            StringBuilder hex = new StringBuilder(64);
            for (byte value : digest.digest()) {
                hex.append(Character.forDigit((value >> 4) & 0xF, 16));
                hex.append(Character.forDigit(value & 0xF, 16));
            }
            return hex.toString();
        } catch (Exception error) {
            Log.e(TAG, "could not hash " + file.getName(), error);
            return "";
        }
    }

    @Override
    protected void onDestroy() {
        executor.shutdownNow();
        super.onDestroy();
    }
}
