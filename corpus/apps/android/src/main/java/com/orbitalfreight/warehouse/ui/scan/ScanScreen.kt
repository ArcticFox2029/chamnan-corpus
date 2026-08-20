package com.orbitalfreight.warehouse.ui.scan

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.orbitalfreight.warehouse.R
import dagger.hilt.android.AndroidEntryPoint

/**
 * गोदाम की मुख्य स्क्रीन — बारकोड, डिब्बे का विवरण, और वे बटन जो एक-एक स्कैन
 * प्रकार को कतार में डालते हैं।
 *
 * यह स्क्रीन दस्ताने पहने हाथ और गिरते हुए उपकरण के लिए बनी है, इसलिए कुछ चुनाव
 * सामान्य Material दिशानिर्देशों से अलग हैं:
 *
 *  • बटन बड़े हैं (न्यूनतम 64 dp), क्योंकि सर्दियों में Rotterdam के कर्मचारी
 *    मोटे दस्ताने पहनते हैं और 48 dp पर चूक की दर मापने योग्य थी।
 *  • कोई पुष्टि-डायलॉग नहीं। स्कैन ग़लत हो जाए तो सुधार अगली पंक्ति है, रोकथाम
 *    नहीं — यही सोच सर्वर पर भी है (§7 नियम 6: सुधार नई पंक्तियाँ हैं)।
 *  • कतार की गहराई हमेशा दिखती है। कर्मचारी को यह जानने का हक़ है कि उसका काम
 *    अभी उपकरण पर है या सर्वर पर पहुँच चुका है।
 */
@AndroidEntryPoint
class ScanActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            ScanScreen()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScanScreen(viewModel: ScanViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val queueDepth by viewModel.queueDepth.collectAsStateWithLifecycle(initialValue = 0)
    val deadCount by viewModel.deadCount.collectAsStateWithLifecycle(initialValue = 0)
    val snackbarHostState = remember { SnackbarHostState() }

    // हर संदेश एक बार दिखता है। संदेश अवस्था का हिस्सा है क्योंकि स्क्रीन घूमने
    // पर भी वह खोना नहीं चाहिए — गोदाम के उपकरण जेब में उलटे-सीधे होते रहते हैं।
    LaunchedEffect(state.message) {
        val message = state.message ?: return@LaunchedEffect
        val text = when (message) {
            is ScanViewModel.Message.Queued ->
                "${message.scanType} queued (${message.queueDepth} waiting)"
            is ScanViewModel.Message.SealMismatch ->
                "Seal mismatch — expected ${message.expected}, read ${message.observed}"
            ScanViewModel.Message.ContainerUnknown ->
                "Container not on this depot's manifest"
            is ScanViewModel.Message.Blocked ->
                message.reason
        }
        snackbarHostState.showSnackbar(text)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.scan_title)) },
                actions = {
                    // कतार की गहराई और मरी हुई पंक्तियाँ — दोनों अलग-अलग दिखती
                    // हैं, क्योंकि "अभी भेजा नहीं गया" और "कभी नहीं जाएगा" दो
                    // बिल्कुल अलग बातें हैं और दूसरी पर सहायता-डेस्क बुलानी है।
                    if (queueDepth > 0) {
                        AssistChip(onClick = {}, label = { Text("$queueDepth queued") })
                    }
                    if (deadCount > 0) {
                        AssistChip(onClick = {}, label = { Text("$deadCount failed") })
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            BarcodeField(onScanned = viewModel::onBarcodeScanned)

            state.containerIsoCode?.let { isoCode ->
                ContainerCard(
                    isoCode = isoCode,
                    reference = state.shipmentReference,
                    status = state.shipmentStatus,
                    isReefer = state.isReefer,
                    setpointC = state.setpointC,
                    hazardClass = state.primaryHazardClassCode,
                )
                SealField(
                    expectedSeal = state.expectedSeal,
                    onSubmit = viewModel::submitSealCheck,
                )
                ScanTypeRow(onPick = { viewModel.recordScan(it) })
            }
        }
    }
}

/**
 * ML Kit से आया कोड यहीं उतरता है। कीबोर्ड इनपुट भी स्वीकार है — कुछ पुराने
 * हैंडहेल्ड उपकरण कैमरे के बजाय कीबोर्ड-वेज की तरह काम करते हैं और कोड के अंत में
 * Enter भेजते हैं।
 */
@Composable
private fun BarcodeField(onScanned: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    OutlinedTextField(
        value = text,
        onValueChange = { raw ->
            text = raw
            // BIC कोड ठीक ग्यारह अक्षर का है; उतने आते ही खोज चला दो, ताकि
            // कर्मचारी को कोई बटन दबाना ही न पड़े।
            if (raw.trim().length == BIC_CODE_LENGTH) {
                onScanned(raw)
                text = ""
            }
        },
        label = { Text(stringResource(R.string.scan_hint_iso_code)) },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun ContainerCard(
    isoCode: String,
    reference: String?,
    status: String?,
    isReefer: Boolean,
    setpointC: Double?,
    hazardClass: String?,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(isoCode, style = MaterialTheme.typography.headlineSmall)
            reference?.let { Text(stringResource(R.string.scan_shipment_reference, it)) }
            status?.let { Text(localisedStatus(it), style = MaterialTheme.typography.labelLarge) }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                // रीफ़र का सेटपॉइंट यहाँ दिखता है ताकि कर्मचारी दरवाज़ा खोलने से
                // पहले जान ले कि डिब्बा कितनी ठंड पर चलना चाहिए।
                if (isReefer) {
                    AssistChip(onClick = {}, label = { Text("Reefer ${setpointC ?: "?"} °C") })
                }
                // ख़तरा-वर्ग का कोड बिना अनुवाद दिखता है — '3', '6.1', '8'।
                // प्लेकार्ड पर भी वही लिखा है, और अनुवाद करने से मेल टूट जाता।
                hazardClass?.let { AssistChip(onClick = {}, label = { Text("Hazard $it") }) }
            }
        }
    }
}

@Composable
private fun SealField(expectedSeal: String?, onSubmit: (String) -> Unit) {
    var seal by remember(expectedSeal) { mutableStateOf("") }
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinedTextField(
            value = seal,
            onValueChange = { seal = it },
            label = { Text(stringResource(R.string.scan_hint_seal)) },
            singleLine = true,
            modifier = Modifier.weight(1f),
        )
        Button(onClick = { onSubmit(seal) }, enabled = seal.isNotBlank()) {
            Text("Check")
        }
    }
}

/**
 * स्कैन प्रकार के बटन। `proof_of_delivery` यहाँ नहीं है — वह अलग स्क्रीन से आता
 * है जहाँ हस्ताक्षर भी लिया जाता है, और ViewModel उसे तभी स्वीकारता है जब
 * शिपमेंट `in_transit` हो।
 */
@Composable
private fun ScanTypeRow(onPick: (String) -> Unit) {
    val types = listOf(
        ScanViewModel.SCAN_TYPE_GATE_IN to R.string.scan_type_gate_in,
        ScanViewModel.SCAN_TYPE_LOAD to R.string.scan_type_load,
        ScanViewModel.SCAN_TYPE_UNLOAD to R.string.scan_type_unload,
        ScanViewModel.SCAN_TYPE_GATE_OUT to R.string.scan_type_gate_out,
        ScanViewModel.SCAN_TYPE_DAMAGE_REPORT to R.string.scan_type_damage_report,
    )
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(types) { (type, label) ->
            Button(onClick = { onPick(type) }, modifier = Modifier.padding(vertical = 8.dp)) {
                Text(stringResource(label))
            }
        }
    }
}

/**
 * `freight.shipments.status` का मान लेबल में बदलता है। जो मान यहाँ नहीं है वह
 * जस का तस दिखा दिया जाता है — सर्वर नई स्थिति जोड़े तो स्क्रीन खाली नहीं दिखेगी।
 */
@Composable
private fun localisedStatus(status: String): String = when (status) {
    "draft" -> stringResource(R.string.shipment_status_draft)
    "booked" -> stringResource(R.string.shipment_status_booked)
    "sealed" -> stringResource(R.string.shipment_status_sealed)
    "in_transit" -> stringResource(R.string.shipment_status_in_transit)
    "at_risk" -> stringResource(R.string.shipment_status_at_risk)
    "held_at_customs" -> stringResource(R.string.shipment_status_held_at_customs)
    "delivered" -> stringResource(R.string.shipment_status_delivered)
    "cancelled" -> stringResource(R.string.shipment_status_cancelled)
    else -> status
}

/** ISO 6346 का BIC कोड — चार अक्षर मालिक, छह अंक क्रम, एक अंक जाँच। */
private const val BIC_CODE_LENGTH = 11
