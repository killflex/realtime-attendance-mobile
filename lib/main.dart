
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:realtime_face_recognition_2026/ML/Recognition.dart';
import 'package:realtime_face_recognition_2026/Screens/HomeScreen.dart';

import 'ML/Recognition.dart';
import 'ML/Recognition.dart';
import 'ML/Recognition.dart';
import 'ML/Recognition.dart';
import 'ML/Recognizer.dart';


late List<CameraDescription> cameras;
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomeScreen(
      ),
    );
  }
}







