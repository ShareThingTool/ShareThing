plugins {
    kotlin("multiplatform") version "2.3.10" apply false
    id("com.android.kotlin.multiplatform.library") version "9.1.0" apply false
    kotlin("plugin.serialization") version "2.0.0" apply false
}



tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}