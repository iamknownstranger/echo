plugins { id("com.android.library") }

android {
  namespace = "echo.music.wear.sync"
  compileSdk = 36
  defaultConfig { minSdk = 26 }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
  }
}

kotlin { jvmToolchain(21) }

dependencies { testImplementation(libs.junit) }
