plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
    id("com.android.kotlin.multiplatform.library")
}

dependencies {
}
kotlin {
    android{
        namespace = "pl.norwood.sharething"
        compileSdk = 36
        minSdk = 24
    }

    jvm("desktop") {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    // 3. Dependencies
    sourceSets {
        val commonMain by getting {
            dependencies {
                implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
                implementation("co.touchlab:kermit:2.0.4")
            }
        }

        val androidMain by getting {
            dependsOn(commonMain)
            dependencies {
                implementation("io.libp2p:jvm-libp2p:1.2.2-RELEASE")
            }
        }

        val desktopMain by getting {
            dependsOn(commonMain)
            dependencies {
                implementation("io.libp2p:jvm-libp2p:1.2.2-RELEASE")
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
            }
        }
    }
}
tasks.named<Jar>("desktopJar") {
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE

    val desktopTarget = kotlin.targets.getByName("desktop")
    val mainCompilation = desktopTarget.compilations.getByName("main")

    from(mainCompilation.output.classesDirs)
    from(mainCompilation.output.resourcesDir)

    val runtimeClasspath = mainCompilation.runtimeDependencyFiles!!
    from(runtimeClasspath.map { if (it.isDirectory) it else zipTree(it) }){
        exclude("META-INF/*.SF")
        exclude("META-INF/*.RSA")
        exclude("META-INF/*.DSA")
    }

    manifest {
        attributes["Main-Class"] = "pl.norwood.sharething.MainKt"
    }
}
tasks.register<Sync>("syncDesktopJar") {
    group = "distribution"
    description = "Copies the fat JAR to Flutter assets"

    dependsOn("desktopJar")

    from(layout.buildDirectory.file("libs/lib-desktop.jar"))

    into(file("../../ui/assets/engine"))

    rename { "p2p_engine.jar" }

    doLast {
        println("Engine JAR synced to Flutter assets!")
    }
}
