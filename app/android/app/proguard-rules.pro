# Picked up automatically by Flutter's Gradle plugin for release builds
# (FlutterPlugin.kt adds android/app/proguard-rules.pro when it exists).
#
# Pigeon "native interop" (JNI) plugins — shared_preferences_android 2.5.0+,
# any future jnigen-based plugin — resolve these Kotlin classes BY NAME from
# Dart. R8 renames them otherwise and the JNI lookup fails with
# NoSuchMethodError at the first call, which in this app happens before
# runApp (theme/TV prefs) and left alpha.125 on the Android splash forever.
# Neither package:jni (its consumer-rules.pro keeps only its own package) nor
# the plugin shipped these rules at the time — flutter/flutter#194649,
# flutter/packages#13311, dart-lang/native#3732. scripts/verify_android_apk.py
# refuses a release APK where these classes were renamed.
-keep class kotlin.Unit { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt { *; }
