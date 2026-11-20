allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // TapAndPay is a private dependency of Stripe Issuing. ParkShare uses PaymentSheet.
    if (name == "stripe_android") {
        configurations.configureEach {
            if (name.endsWith("LintChecksClasspath")) {
                exclude(group = "com.google.android.gms", module = "play-services-tapandpay")
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
