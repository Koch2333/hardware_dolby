plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.koch2333.dolbypassthrough"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.koch2333.dolbypassthrough"
        minSdk = 29          // isDirectPlaybackSupported exists from API 29
        targetSdk = 34
        versionCode = 2
        versionName = "0.2.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // Xposed API is compileOnly — it is provided by the LSPosed framework at runtime.
    // Pull it from the api-82 branch; see README for the exact repo/coordinate options.
    compileOnly("de.robv.android.xposed:api:82")
}
