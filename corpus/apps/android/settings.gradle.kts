// ---------------------------------------------------------------------------
// यह फ़ाइल गोदाम स्कैनर ऐप के Gradle बिल्ड की जड़ है। यह तय करती है कि प्लगइन और
// निर्भरताएँ किन रिपॉज़िटरी से आएँगी, और apps/kmp वाले साझा मॉड्यूल को composite
// build के रूप में जोड़ती है ताकि Android और iOS दोनों क्लाइंट ORBITALFREIGHT के
// एक ही HTTP क्लाइंट और एक ही DTO सेट पर चलें।
//
// ऐप जान-बूझकर एक ही मॉड्यूल का रखा गया है — स्रोत सीधे src/main में हैं — क्योंकि
// गोदाम का पूरा फ़ीचर-सेट (स्कैन, सील जाँच, क्षति की तस्वीरें) एक ही टीम संभालती है
// और मॉड्यूल बाँटने से बिल्ड समय घटने के बजाय बढ़ा था।
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
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "orbitalfreight-warehouse-scanner"

// साझा मॉड्यूल का समूह/नाम com.orbitalfreight:shared-client है; composite build होने
// की वजह से यहाँ कोई प्रकाशित संस्करण नहीं चाहिए — Gradle स्रोत से ही जोड़ लेता है।
includeBuild("../kmp")
