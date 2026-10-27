plugins {
  id("com.android.application")
  alias(libs.plugins.compose.compiler)
}

android {
  namespace = "echo.music.wear"
  compileSdk = 36
  defaultConfig {
    applicationId = "echo.music.iad1tya"
    minSdk = 30
    targetSdk = 36
    versionCode = 155
    versionName = "1.2.5"
  }
  signingConfigs {
    getByName("debug") {
      storeFile = file("${System.getProperty("user.home")}/.android/debug.keystore")
      storePassword = "android"
      keyAlias = "androiddebugkey"
      keyPassword = "android"
    }
    create("release") {
      val key =
        rootProject.file("keystore.jks").takeIf { it.exists() }
          ?: rootProject.file("app/keystore/release.keystore").takeIf { it.exists() }
      if (key != null) storeFile = key
      storePassword = System.getenv("STORE_PASSWORD")
      keyAlias = System.getenv("KEY_ALIAS")
      keyPassword = System.getenv("KEY_PASSWORD")
    }
  }
  buildTypes {
    debug { applicationIdSuffix = ".debug" }
    release {
      isMinifyEnabled = false
      if (
        rootProject.file("keystore.jks").exists() ||
          rootProject.file("app/keystore/release.keystore").exists()
      ) {
        signingConfig = signingConfigs.getByName("release")
      }
    }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
  }
  buildFeatures { compose = true }
}

kotlin { jvmToolchain(21) }

dependencies {
  implementation(project(":wear-sync"))
  implementation(libs.wearable)
  implementation(libs.coroutines.play.services)
  implementation(libs.coroutines.guava)
  implementation(libs.activity)
  implementation(libs.wear.compose.material)
  implementation(libs.wear.compose.foundation)
  implementation(libs.compose.foundation)
  implementation(libs.compose.ui)
  implementation(libs.media3)
  implementation(libs.media3.session)
  implementation(libs.work.runtime.ktx)
}
