plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// The page agent is shared with iOS, not forked. It is copied out of the iOS
// app's resource folder at build time so there is exactly one copy in the
// repository and no path in the Xcode project has to move.
//
// Fails the build when the source is missing rather than shipping an APK whose
// WebView injects nothing — that failure would otherwise look like a blocking
// bug at runtime, not a packaging mistake.
// Named for the platform it comes from, not just "shared": inside a task
// configuration block the task itself is an implicit receiver, and Gradle's
// TaskInternal has a `sharedResources` property of its own. A val called
// `sharedResources` is silently shadowed by it there — and because
// `from(Object...)` accepts anything, the copy would have been wired to a list
// of Gradle resource locks and produced an APK with no agent in it.
val sharedIosResources = rootProject.layout.projectDirectory
    .dir("../ios/App/CleanPlayerApp/Resources")

val syncSharedAgent by tasks.registering(Copy::class) {
    description = "Copies the shared page agent from the iOS resource folder."
    from(sharedIosResources) {
        include("agent.js", "popupguard.js", "blocklist.json")
    }
    into(layout.buildDirectory.dir("generated/sharedAssets"))
    // Resolved here, at configuration time, rather than inside doFirst: a
    // lambda that reads a script-level val captures the script object itself,
    // which the configuration cache cannot serialize. A plain File can be.
    val agent = sharedIosResources.file("agent.js").asFile
    // A silent empty copy is the one outcome worth failing over.
    doFirst {
        require(agent.isFile) {
            "Shared agent.js not found at ${agent.path}. " +
                "The Android app injects the same agent as iOS; it is not vendored here."
        }
    }
}

android {
    namespace = "com.saisamardh.cliqx"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.saisamardh.cliqx"
        // WebView content worlds do not exist on any API level, but
        // shouldInterceptRequest and Media3 PiP both want a modern baseline.
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        // Single source of truth with iOS, which reads the same file.
        versionName = file("../../VERSION").readText().trim()
    }

    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/sharedAssets"))

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    testOptions { unitTests.isIncludeAndroidResources = true }
}

tasks.named("preBuild") { dependsOn(syncSharedAgent) }

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.webkit)

    implementation(libs.media3.exoplayer)
    implementation(libs.media3.datasource)
    implementation(libs.media3.exoplayer.hls)
    implementation(libs.media3.exoplayer.dash)
    implementation(libs.media3.ui)
    implementation(libs.media3.session)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
}
