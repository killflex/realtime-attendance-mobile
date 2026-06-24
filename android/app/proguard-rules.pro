# TensorFlow Lite JNI Keep Rules
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.natives.** { *; }
-keep class org.tensorflow.lite.delegates.** { *; }
-keep class org.tensorflow.lite.nnapi.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }

# Keep native methods and JNI bindings
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep the tflite_flutter plugin classes
-keep class com.tflite_flutter.** { *; }
-keep class com.amolg.tflite_flutter.** { *; }
-keep class com.tflite.flutter.** { *; }
