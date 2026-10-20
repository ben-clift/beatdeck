import java.io.FileInputStream
import java.util.Properties
import com.android.build.gradle.internal.api.ApkVariantOutputImpl

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "es.manifold.sidedeck"
    // sdkmanager installs API 37 as platforms/android-37.0; plain `compileSdk = 37`
    // looks up android-37 and fails on F-Droid / CI. minorApiLevel selects 37.0.
    compileSdk {
        version = release(37) {
            minorApiLevel = 0
        }
    }
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Own id so BeatDeck installs next to the original SideDeck. The code
        // namespace above stays the same (native code is bound to it).
        applicationId = "com.benclift.beatdeck"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17 -O2 -frtti -fexceptions"
                arguments += listOf("-DANDROID_STL=c++_shared")
            }
        }
        // Do not set ndk.abiFilters here: it conflicts with Flutter
        // `--split-per-abi` / AGP ABI splits used for F-Droid.
    }

    if (keystorePropertiesFile.exists()) {
        signingConfigs {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    // Fixed signing key for debug builds, so every new APK installs over the
    // last one (a random key per build forces an uninstall). Private repo only.
    signingConfigs {
        getByName("debug") {
            storeFile = file("beatdeck-debug.keystore")
            storePassword = "android"
            keyAlias = "beatdeck"
            keyPassword = "android"
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // F-Droid rejects AGP's Google-only "Dependency metadata" signing block.
    // Play/local builds keep it; F-Droid sets -Pfdroid (see metadata YAML).
    dependenciesInfo {
        val forFdroid = project.hasProperty("fdroid")
        includeInApk = !forFdroid
        includeInBundle = !forFdroid
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

// Per-ABI versionCodes for F-Droid split APKs (build-flutter.yml).
val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abiVersionCode = abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
        if (abiVersionCode != null) {
            (output as ApkVariantOutputImpl).versionCodeOverride =
                variant.versionCode * 10 + abiVersionCode
        }
    }
}
