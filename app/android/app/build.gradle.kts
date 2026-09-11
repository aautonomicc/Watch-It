import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (never committed) points at the
// keystore in ~/keystores/. Falls back to debug signing if absent (e.g. CI).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

// scripts/build_android.sh supplies one explicit selection to all three
// toolchains. The default stays ARM64 for existing release commands.
val supportedWatchAbis = listOf("armeabi-v7a", "arm64-v8a")
val watchAbis = providers.environmentVariable("WATCHIT_ANDROID_ABIS")
    .orElse("arm64-v8a").get().split(",")
require(watchAbis.isNotEmpty() && watchAbis.all { it in supportedWatchAbis }
    && watchAbis.distinct().size == watchAbis.size) {
    "WATCHIT_ANDROID_ABIS must contain unique armeabi-v7a and/or arm64-v8a entries"
}
val watchTestSetting = providers.environmentVariable("WATCHIT_TEST_APP").orElse("0").get()
require(watchTestSetting in listOf("0", "1")) { "WATCHIT_TEST_APP must be 0 or 1" }
val watchTestApp = watchTestSetting == "1"
val watchSplitPerAbi = providers.gradleProperty("split-per-abi")
    .orElse("false").get().toBoolean()

android {
    namespace = "io.github.aautonomicc.watchit"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.aautonomicc.watchit"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["watchitAppLabel"] = if (watchTestApp) "W@tch Test" else "W@tch"
        ndk {
            // Flutter configures splits for --split-per-abi; AGP rejects
            // combining those splits with defaultConfig's ndk.abiFilters.
            if (!watchSplitPerAbi) abiFilters += watchAbis
        }
    }

    packaging {
        jniLibs {
            // Plugin AARs (media_kit's libmpv etc.) ship other ABIs; the
            // Flutter plugin ignores abiFilters for those, so strip
            // unselected ABIs here as well. The artifact check then verifies
            // the actual native library set, including watchit_core.
            excludes += (supportedWatchAbis + listOf("x86", "x86_64"))
                .filter { it !in watchAbis }.map { "lib/$it/**" }
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            if (watchTestApp) applicationIdSuffix = ".validation"
            signingConfig = if (!watchTestApp && keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // MediaSessionCompat + MediaStyle notification for MediaPlaybackService
    // (androidx.core comes in transitively; androidx.media does not).
    implementation("androidx.media:media:1.7.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
