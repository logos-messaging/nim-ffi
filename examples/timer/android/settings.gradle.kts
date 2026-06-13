// Standalone settings so this directory builds as its own library module.
// To use it from an existing app instead, drop the `android/` directory in as a
// module and add `include(":mytimer")` to your project's settings.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        id("com.android.library") version "8.5.2"
        id("org.jetbrains.kotlin.android") version "1.9.24"
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "mytimer"
