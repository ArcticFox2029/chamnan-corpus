// ---------------------------------------------------------------------------
// ORBITALFREIGHT का साझा क्लाइंट मॉड्यूल — वह कोड जो गोदाम स्कैनर (Android) और
// ड्राइवर ऐप (iOS) दोनों में एक ही रूप में चलता है: HTTP क्लाइंट, अनिवार्य
// शीर्षक, §0.4 का त्रुटि-लिफ़ाफ़ा, §0.5 का कर्सर पेजिनेशन, और सेवाओं के DTO।
//
// यहाँ जो **नहीं** है वह उतना ही तय है जितना जो है:
//  • कोई UI नहीं, कोई डेटाबेस नहीं। ऑफ़लाइन कतार हर ऐप की अपनी है क्योंकि
//    Android पर वह Room है और iOS पर Core Data — साझा करने की कोशिश दोनों को
//    सबसे ख़राब साझा हर पर ले आती थी।
//  • कोई पुनःप्रयास-लूप नहीं। दोबारा भेजना कतार का काम है, क्लाइंट का नहीं;
//    यहाँ केवल यह बताया जाता है कि विफलता दोबारा भेजने योग्य थी या नहीं
//    (`error.retryable`)।
//
// लक्ष्य तीन हैं: androidTarget, और दो iOS (असली उपकरण + Apple Silicon सिम्युलेटर)।
// x86 सिम्युलेटर जान-बूझकर नहीं है — टीम के सारे Mac Apple Silicon पर हैं और
// तीसरा लक्ष्य CI का समय बिना किसी लाभ के बढ़ाता था।
// ---------------------------------------------------------------------------

plugins {
    id("org.jetbrains.kotlin.multiplatform") version "1.9.24"
    id("org.jetbrains.kotlin.plugin.serialization") version "1.9.24"
    id("com.android.library") version "8.5.2"
}

group = "com.orbitalfreight"
version = "4.2.0"

kotlin {
    androidTarget {
        compilations.all {
            kotlinOptions {
                jvmTarget = "17"
            }
        }
        publishLibraryVariants("release")
    }

    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            // Swift की ओर से यह `import OrbitalShared` बनता है।
            baseName = "OrbitalShared"
            // static इसलिए कि ड्राइवर ऐप का बिल्ड dSYM के साथ एक ही binary रखे;
            // dynamic framework पर Xcode 15 का bitcode-मुक्त पाइपलाइन धीमा था।
            isStatic = true
        }
    }

    sourceSets {
        val commonMain by getting {
            dependencies {
                implementation("io.ktor:ktor-client-core:2.3.12")
                implementation("io.ktor:ktor-client-content-negotiation:2.3.12")
                implementation("io.ktor:ktor-serialization-kotlinx-json:2.3.12")
                implementation("io.ktor:ktor-client-logging:2.3.12")
                implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
                implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.6.0")
            }
        }

        val commonTest by getting {
            dependencies {
                implementation(kotlin("test"))
                // मॉक इंजन से ही §0.4 के लिफ़ाफ़े की जाँच होती है — असली सेवा के
                // बिना भी `retryable` का व्यवहार पक्का रहता है।
                implementation("io.ktor:ktor-client-mock:2.3.12")
            }
        }

        val androidMain by getting {
            dependencies {
                // OkHttp इसलिए कि Android ऐप में प्रमाणपत्र-पिनिंग और प्रॉक्सी
                // की व्यवस्था पहले से उसी पर है; दो HTTP ढेर रखने का कोई कारण नहीं।
                implementation("io.ktor:ktor-client-okhttp:2.3.12")
                implementation("androidx.security:security-crypto:1.1.0-alpha06")
            }
        }

        val iosArm64Main by getting
        val iosSimulatorArm64Main by getting
        val iosMain by creating {
            dependsOn(commonMain)
            iosArm64Main.dependsOn(this)
            iosSimulatorArm64Main.dependsOn(this)
            dependencies {
                implementation("io.ktor:ktor-client-darwin:2.3.12")
            }
        }
    }
}

android {
    namespace = "com.orbitalfreight.shared"
    compileSdk = 34

    defaultConfig {
        // वही न्यूनतम जो गोदाम स्कैनर का है (Zebra TC57, Android 8)।
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
