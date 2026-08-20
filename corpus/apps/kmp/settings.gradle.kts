// ---------------------------------------------------------------------------
// साझा मॉड्यूल के अपने बिल्ड की जड़। यह अकेले भी बनता है (CI इसे यहीं से जाँचता
// है) और composite build के रूप में भी जुड़ता है — apps/android का
// settings.gradle.kts इसे `includeBuild("../kmp")` से खींचता है, और iOS पक्ष
// इसका XCFramework बनाकर लेता है।
//
// rootProject.name को मत बदलिए: Android ऐप निर्भरता को
// `com.orbitalfreight:shared-client` लिखकर माँगता है, और composite build में
// Gradle उसी नाम से मिलान करके प्रकाशित संस्करण की जगह स्रोत जोड़ता है। नाम
// बदलते ही वह मिलान टूटेगा और Gradle चुपचाप Maven से पुराना संस्करण उठा लेगा।
// ---------------------------------------------------------------------------

pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "shared-client"
