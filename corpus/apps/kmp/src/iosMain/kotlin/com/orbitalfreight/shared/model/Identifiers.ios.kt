package com.orbitalfreight.shared.model

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.refTo
import platform.Foundation.NSUUID
import platform.Security.SecRandomCopyBytes
import platform.Security.kSecRandomDefault

/**
 * iOS पर यादृच्छिक मान — Security ढाँचे के `SecRandomCopyBytes` से।
 *
 * Android वाले रूप से शर्त वही है: स्रोत क्रिप्टोग्राफ़िक होना चाहिए। यहाँ
 * `arc4random` भी उपलब्ध है और तेज़ भी, पर `SecRandomCopyBytes` विफलता को
 * लौटाता है (`errSecSuccess` न मिलने पर), और चुपचाप कमज़ोर बाइट देने से
 * ज़ोर से गिरना बेहतर है — टकराई हुई idempotency कुंजी का नतीजा एक लापता स्कैन
 * होता है, जो महीनों बाद reconciliation-service की विसंगति बनकर ही दिखता है।
 */
@OptIn(ExperimentalForeignApi::class)
actual object IdempotencyKeys {

    /** UUIDv4, वही रूप जो Android पक्ष भेजता है — सर्वर को दोनों एक जैसे दिखते हैं। */
    actual fun newIdempotencyKey(): String = NSUUID().UUIDString

    /** W3C trace-id: 16 बाइट, हेक्स में 32 अक्षर। */
    actual fun newTraceId(): String {
        val bytes = ByteArray(16)
        val status = bytes.usePinnedRandomFill()
        check(status) { "SecRandomCopyBytes failed; refusing to send a request without a trace id" }

        val hex = StringBuilder(32)
        for (byte in bytes) {
            val value = byte.toInt() and 0xFF
            hex.append(HEX[value ushr 4])
            hex.append(HEX[value and 0x0F])
        }
        return hex.toString()
    }

    private fun ByteArray.usePinnedRandomFill(): Boolean = memScoped {
        SecRandomCopyBytes(kSecRandomDefault, size.toULong(), refTo(0).getPointer(this)) == 0
    }

    private const val HEX = "0123456789abcdef"
}
