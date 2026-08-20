package com.orbitalfreight.warehouse.ui.scan

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.orbitalfreight.warehouse.data.db.dao.ScanOutboxDao
import com.orbitalfreight.warehouse.data.db.dao.ShipmentDao
import com.orbitalfreight.warehouse.data.db.entity.ScanOutboxEntity
import com.orbitalfreight.warehouse.data.net.TokenStore
import com.orbitalfreight.warehouse.sync.ScanOutboxWorker
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID
import javax.inject.Inject

/**
 * स्कैन स्क्रीन का पूरा व्यवहार — बारकोड पढ़ने से लेकर कतार में पंक्ति डालने तक।
 *
 * यहाँ का केंद्रीय निर्णय यह है कि **UI कभी नेटवर्क का इंतज़ार नहीं करता**।
 * कर्मचारी बारकोड पढ़ता है, ऐप स्थानीय डेटाबेस में पंक्ति लिखता है, स्क्रीन
 * तुरंत अगले डिब्बे के लिए तैयार हो जाती है। भेजना [ScanOutboxWorker] का काम है।
 * गोदाम में हर स्कैन पर दो सेकंड का इंतज़ार दिन के अंत तक चालीस मिनट बन जाता है,
 * और रैक के बीच सिग्नल अक्सर होता ही नहीं।
 *
 * सील-भिन्नता का नियम भी यहीं है और यह जान-बूझकर "रोकने वाला" नहीं है: यदि पढ़ी
 * गई सील `freight.shipment_containers.seal_number` से नहीं मिलती, तो ऐप स्कैन
 * रोकता नहीं — वह `seal_check` वाला स्कैन बनाता है जिसके `notes` में दोनों मान
 * होते हैं। कर्मचारी का काम विसंगति दर्ज करना है, उसका न्याय करना नहीं; न्याय
 * reconciliation-service रात को करती है।
 */
@HiltViewModel
class ScanViewModel @Inject constructor(
    private val shipmentDao: ShipmentDao,
    private val outboxDao: ScanOutboxDao,
    private val tokenStore: TokenStore,
    private val workManager: WorkManager,
    private val deviceSerial: DeviceSerialProvider,
    private val facility: FacilityProvider,
) : ViewModel() {

    /** स्क्रीन की पूरी अवस्था; Compose इसी को देखता है। */
    data class UiState(
        val isBusy: Boolean = false,
        val containerIsoCode: String? = null,
        val containerId: String? = null,
        val shipmentId: String? = null,
        val shipmentReference: String? = null,
        val shipmentStatus: String? = null,
        val expectedSeal: String? = null,
        val isReefer: Boolean = false,
        val setpointC: Double? = null,
        val primaryHazardClassCode: String? = null,
        /** अंतिम कार्रवाई का परिणाम, snackbar के लिए। */
        val message: Message? = null,
    )

    sealed interface Message {
        data class Queued(val scanType: String, val queueDepth: Int) : Message
        data class SealMismatch(val expected: String, val observed: String) : Message
        data object ContainerUnknown : Message
        data class Blocked(val reason: String) : Message
    }

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    /** बैज के लिए — कितने स्कैन अभी उपकरण पर ही हैं। */
    val queueDepth: kotlinx.coroutines.flow.Flow<Int> = outboxDao.observeQueueDepth()

    /** सहायता-डेस्क के लिए — कितनी पंक्तियाँ आठ प्रयासों के बाद मर चुकी हैं। */
    val deadCount: kotlinx.coroutines.flow.Flow<Int> = outboxDao.observeDeadCount()

    /**
     * ML Kit से आया BIC कोड। ग्यारह अक्षर, जैसे MSCU3948571।
     *
     * खोज पहले स्थानीय कैश में होती है। न मिलने पर ऐप जान-बूझकर सर्वर से नहीं
     * पूछता: यदि डिब्बा उपकरण के कैश में नहीं है तो वह इस डिपो का काम ही नहीं है,
     * और गोदाम के फ़र्श पर खड़े होकर नेटवर्क का इंतज़ार करना बेकार है। कैश को
     * पृष्ठभूमि में भरा जाता है, माँग पर नहीं।
     */
    fun onBarcodeScanned(isoCode: String) {
        viewModelScope.launch {
            _state.value = _state.value.copy(isBusy = true)
            val container = shipmentDao.findContainerByIsoCode(isoCode.trim().uppercase())
            if (container == null) {
                _state.value = UiState(message = Message.ContainerUnknown)
                return@launch
            }

            val pairing = shipmentDao.findActivePairing(container.containerId)
            val shipment = pairing?.let { shipmentDao.observeShipment(it.shipmentId) }

            _state.value = UiState(
                containerIsoCode = container.isoCode,
                containerId = container.containerId,
                shipmentId = pairing?.shipmentId,
                expectedSeal = pairing?.sealNumber,
                isReefer = container.isReefer,
                setpointC = container.setpointC,
                primaryHazardClassCode = container.primaryHazardClassCode,
            )
            // शिपमेंट का विवरण अलग प्रवाह से आता है; यहाँ केवल उसकी प्रतीक्षा न
            // करना ज़रूरी है, वरना स्क्रीन डिब्बा दिखाने से पहले रुक जाएगी।
            shipment?.collect { withContainers ->
                withContainers ?: return@collect
                _state.value = _state.value.copy(
                    isBusy = false,
                    shipmentReference = withContainers.shipment.reference,
                    shipmentStatus = withContainers.shipment.status,
                )
            }
        }
    }

    /**
     * स्कैन कतार में डालता है।
     *
     * `proof_of_delivery` केवल तभी स्वीकार होता है जब शिपमेंट `in_transit` हो।
     * कारण गोदाम से बाहर का है: billing-service इसी scan_type पर चालान का द्वार
     * खोलती है (`shipment.scanned` का उपभोक्ता), इसलिए ग़लती से भेजा गया POD
     * ग्राहक को समय से पहले बिल भेज देता है। सर्वर इसे वैसे भी रोक देगा, पर
     * उपकरण पर रोकना कर्मचारी को तुरंत बताता है कि क्यों।
     */
    fun recordScan(scanType: String, notes: String? = null, position: Pair<Double, Double>? = null) {
        val snapshot = _state.value
        val containerId = snapshot.containerId ?: return
        val shipmentId = snapshot.shipmentId ?: run {
            _state.value = snapshot.copy(message = Message.Blocked("container_not_on_open_shipment"))
            return
        }

        if (scanType == SCAN_TYPE_PROOF_OF_DELIVERY && snapshot.shipmentStatus != STATUS_IN_TRANSIT) {
            _state.value = snapshot.copy(message = Message.Blocked("shipment_not_in_transit"))
            return
        }

        viewModelScope.launch {
            val credentials = tokenStore.current()
            val entity = ScanOutboxEntity(
                shipmentId = shipmentId,
                containerId = containerId,
                scanType = scanType,
                scannedByUserId = credentials.userId,
                facilityId = facility.currentFacilityId(),
                occurredAt = Instant.now().toString(),
                latitude = position?.first,
                longitude = position?.second,
                deviceSerial = deviceSerial.serial(),
                notes = notes,
                // कुंजी यहीं, एक बार बनती है और पुनःप्रयासों में कभी नहीं बदलती।
                // यही वह अकेली चीज़ है जो टाइमआउट के बाद दूसरा scn_ बनने से रोकती है।
                idempotencyKey = UUID.randomUUID().toString(),
            )
            outboxDao.enqueueScan(entity)
            nudgeRelay()
            _state.value = _state.value.copy(
                message = Message.Queued(scanType, queueDepthSnapshot()),
                // डिब्बा साफ़ — कर्मचारी अगला बॉक्स पढ़ने के लिए तैयार है।
                containerIsoCode = null,
                containerId = null,
            )
        }
    }

    /**
     * पढ़ी गई सील की तुलना करता है और भिन्नता मिलने पर `seal_check` वाला स्कैन
     * दोनों मानों के साथ कतार में डालता है।
     */
    fun submitSealCheck(observedSeal: String) {
        val expected = _state.value.expectedSeal
        val cleaned = observedSeal.trim().uppercase()
        if (expected != null && expected != cleaned) {
            recordScan(
                scanType = SCAN_TYPE_SEAL_CHECK,
                notes = "seal mismatch: expected=$expected observed=$cleaned",
            )
            _state.value = _state.value.copy(message = Message.SealMismatch(expected, cleaned))
        } else {
            recordScan(scanType = SCAN_TYPE_SEAL_CHECK, notes = "seal verified: $cleaned")
        }
    }

    /**
     * रिले को तुरंत जगाता है। आवधिक वर्कर का न्यूनतम अंतराल पंद्रह मिनट है, जो
     * गेट पर खड़े ट्रक के लिए बहुत लंबा है; एक-बार वाला अनुरोध उसी UNIQUE नाम से
     * जुड़ता है ताकि दस स्कैन दस वर्कर न बनाएँ।
     */
    private fun nudgeRelay() {
        workManager.enqueueUniqueWork(
            ScanOutboxWorker.UNIQUE_NAME + "-now",
            ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<ScanOutboxWorker>().build(),
        )
    }

    private suspend fun queueDepthSnapshot(): Int =
        outboxDao.selectPendingScans(limit = 200).size

    companion object {
        const val SCAN_TYPE_GATE_IN = "gate_in"
        const val SCAN_TYPE_GATE_OUT = "gate_out"
        const val SCAN_TYPE_LOAD = "load"
        const val SCAN_TYPE_UNLOAD = "unload"
        const val SCAN_TYPE_SEAL_CHECK = "seal_check"
        const val SCAN_TYPE_DAMAGE_REPORT = "damage_report"
        const val SCAN_TYPE_PROOF_OF_DELIVERY = "proof_of_delivery"

        private const val STATUS_IN_TRANSIT = "in_transit"
    }
}

/** उपकरण का क्रमांक — `telemetry.device_gateways.serial` से मेल खाता स्वरूप। */
interface DeviceSerialProvider {
    fun serial(): String
}

/** वह गोदाम जहाँ यह उपकरण तैनात है; fac_<ULID>, प्रावधान के समय तय होता है। */
interface FacilityProvider {
    fun currentFacilityId(): String?
}
