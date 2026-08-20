package com.orbitalfreight.shared.model

import java.security.SecureRandom
import java.util.UUID

/**
 * Android पर यादृच्छिक मान — दोनों `SecureRandom` से, `java.util.Random` से नहीं।
 *
 * idempotency कुंजी की एकमात्र शर्त अद्वितीयता है, पर वह शर्त पूरे बेड़े पर लागू
 * होती है: सैकड़ों उपकरण, हर एक दिन में हज़ारों स्कैन, और सर्वर कुंजी को 24 घंटे
 * याद रखता है। कमज़ोर स्रोत से बनी दो एक जैसी कुंजियों का अर्थ है कि दूसरा स्कैन
 * चुपचाप पहले का दोहराव मान लिया जाएगा — कोई त्रुटि नहीं, बस एक लापता पंक्ति।
 */
actual object IdempotencyKeys {

    private val random = SecureRandom()

    /** UUIDv4; `randomUUID` अपने भीतर `SecureRandom` ही चलाता है। */
    actual fun newIdempotencyKey(): String = UUID.randomUUID().toString()

    /** W3C trace-id: 16 बाइट, हेक्स में 32 अक्षर। पूरा शून्य अमान्य है। */
    actual fun newTraceId(): String {
        val bytes = ByteArray(16)
        do {
            random.nextBytes(bytes)
        } while (bytes.all { it == 0.toByte() })

        val hex = StringBuilder(32)
        for (byte in bytes) {
            val value = byte.toInt() and 0xFF
            hex.append(HEX[value ushr 4])
            hex.append(HEX[value and 0x0F])
        }
        return hex.toString()
    }

    private const val HEX = "0123456789abcdef"
}
