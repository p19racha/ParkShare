# Stripe PaymentSheet and the SDK's optional push-provisioning references.
-keep class com.stripe.** { *; }
-dontwarn com.stripe.android.pushProvisioning.**
-dontwarn kotlinx.parcelize.Parceler$DefaultImpls
-dontwarn kotlinx.parcelize.Parceler
-dontwarn kotlinx.parcelize.Parcelize
