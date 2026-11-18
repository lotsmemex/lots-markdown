plugins { id("com.android.application") }

android {
    namespace = "com.lotsmemex.markdown"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.lotsmemex.markdown"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.0.1"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    buildTypes { release { isMinifyEnabled = false; signingConfig = signingConfigs.getByName("debug") } }
    // librender_stub.so is built by ../build.sh into src/main/jniLibs.
}
