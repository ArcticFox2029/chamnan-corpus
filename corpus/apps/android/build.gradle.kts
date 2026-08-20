// ---------------------------------------------------------------------------
// यह फ़ाइल गोदाम स्कैनर ऐप का एकमात्र मॉड्यूल बिल्ड है: Android एप्लिकेशन प्लगइन,
// Compose, Room, Hilt और WorkManager की निर्भरताएँ, और वे BuildConfig स्थिरांक
// जिनसे ऐप को ORBITALFREIGHT की सेवाओं के पते और क्षेत्र कोड मिलते हैं।
//
// तीन बातें यहाँ जान-बूझकर तय की गई हैं:
//  1. minSdk 26 — गोदामों में लगे Zebra TC57 उपकरण Android 8 पर हैं, उससे नीचे
//     कुछ नहीं है, और WorkManager की foreground सेवा को यही न्यूनतम चाहिए।
//  2. Room की स्कीमा `schemas/` में लिखी जाती है और git में रहती है, क्योंकि
//     ऑफ़लाइन कतार में पड़े स्कैन माइग्रेशन के दौरान खोए नहीं जा सकते।
//  3. `debug` वैरिएंट पर भी प्रमाणपत्र-पिनिंग चालू रहती है; केवल पते बदलते हैं।
// ---------------------------------------------------------------------------

plugins {
    id("com.android.application") version "8.5.2"
    id("org.jetbrains.kotlin.android") version "1.9.24"
    id("com.google.devtools.ksp") version "1.9.24-1.0.20"
    id("com.google.dagger.hilt.android") version "2.51.1"
    id("org.jetbrains.kotlin.plugin.serialization") version "1.9.24"
}

/** gradle.properties से पढ़कर, CI के -P ओवरराइड को प्राथमिकता देता है। */
fun buildProperty(name: String, fallback: String): String =
    (project.findProperty(name) as String?) ?: fallback

android {
    namespace = "com.orbitalfreight.warehouse"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.orbitalfreight.warehouse"
        minSdk = 26
        targetSdk = 34
        versionCode = 412
        versionName = "4.2.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // §1 की सेवाओं के सार्वजनिक पते।
        buildConfigField("String", "IDENTITY_BASE_URL", "\"${buildProperty("of.identityBaseUrl", "https://identity.local.orbitalfreight.example")}\"")
        buildConfigField("String", "CONTAINER_REGISTRY_BASE_URL", "\"${buildProperty("of.containerRegistryBaseUrl", "https://freight.local.orbitalfreight.example")}\"")
        buildConfigField("String", "DOCUMENT_BASE_URL", "\"${buildProperty("of.documentBaseUrl", "https://documents.local.orbitalfreight.example")}\"")
        buildConfigField("String", "TELEMETRY_BASE_URL", "\"${buildProperty("of.telemetryBaseUrl", "https://telemetry.local.orbitalfreight.example")}\"")

        // §0.6 का बंद क्षेत्र-कोड सेट; बिल्ड के समय एक ही चुना जाता है।
        buildConfigField("String", "REGION_CODE", "\"${buildProperty("of.regionCode", "eu-west")}\"")

        // सर्वर-साइड सीमाओं की नकल, ताकि उपकरण बेकार अनुरोध न भेजे:
        //  - OF_DOCUMENT_MAX_UPLOAD_BYTES जितनी ही ऊपरी सीमा (क्षति की तस्वीरें)
        //  - OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S जितनी ही घड़ी-विचलन सहनशीलता
        buildConfigField("long", "MAX_DOCUMENT_UPLOAD_BYTES", "26214400L")
        buildConfigField("int", "SCAN_CLOCK_SKEW_TOLERANCE_S", "900")

        // §0.5 — कर्सर पेजिनेशन, limit का अधिकतम 200 है; सूची स्क्रीन 50 माँगती है।
        buildConfigField("int", "DEFAULT_PAGE_LIMIT", "50")

        ksp {
            arg("room.schemaLocation", "$projectDir/schemas")
            arg("room.incremental", "true")
        }
    }

    signingConfigs {
        create("depot") {
            storeFile = file(buildProperty("of.keystorePath", "keystore/depot-debug.jks"))
            storePassword = buildProperty("of.keystorePassword", "android")
            keyAlias = buildProperty("of.keyAlias", "depot")
            keyPassword = buildProperty("of.keyPassword", "android")
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.getByName("depot")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // तीन पुरानी Java क्लासें (legacy/) अब भी बिल्ड में हैं; desugaring उन्हें
        // java.time इस्तेमाल करने देती है ताकि occurred_at को RFC 3339 में लिखा जा सके।
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += listOf("-opt-in=kotlin.RequiresOptIn")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.14"
    }

    packaging {
        resources.excludes += setOf("META-INF/AL2.0", "META-INF/LGPL2.1")
    }

    lint {
        // ऑफ़लाइन कतार वाला कोड जान-बूझकर मुख्य थ्रेड पर कुछ नहीं करता; यह जाँच
        // legacy/ की तीन क्लासों पर झूठे अलार्म देती थी, इसलिए चेतावनी तक सीमित है।
        warningsAsErrors = false
        abortOnError = true
        disable += "GradleDependency"
    }
}

dependencies {
    // apps/kmp का साझा क्लाइंट — यही OrbitalHttpClient और DTO देता है।
    implementation("com.orbitalfreight:shared-client")

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-compose:1.9.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.4")

    implementation(platform("androidx.compose:compose-bom:2024.06.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    implementation("androidx.work:work-runtime-ktx:2.9.0")
    implementation("androidx.hilt:hilt-work:1.2.0")
    implementation("com.google.dagger:hilt-android:2.51.1")
    ksp("com.google.dagger:hilt-compiler:2.51.1")
    ksp("androidx.hilt:hilt-compiler:1.2.0")

    implementation("com.squareup.retrofit2:retrofit:2.11.0")
    implementation("com.jakewharton.retrofit:retrofit2-kotlinx-serialization-converter:1.0.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")

    // बारकोड: ISO 6346 कंटेनर कोड (iso_code) और सील नंबर दोनों Code 128 में छपे हैं।
    implementation("com.google.mlkit:barcode-scanning:17.2.0")
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")

    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    androidTestImplementation("androidx.room:room-testing:2.6.1")
}
