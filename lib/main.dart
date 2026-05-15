import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:realtime_attendance_mobile/di/service_locator.dart';
import 'package:realtime_attendance_mobile/logging/app_logger.dart';
import 'package:realtime_attendance_mobile/screens/error_screen.dart';
import 'package:realtime_attendance_mobile/screens/home_screen.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupLocator();
  final log = getIt<AppLogger>();

  try {
    cameras = await availableCameras();

    if (cameras.isEmpty) {
      log.w('No cameras available on this device');

      runApp(
        MaterialApp(
          home: ErrorScreen.cameraError(
            onRetry: () {
              // Reload aplikasi
              runApp(const MyApp());
            },
            onBack: () {
              // Keluar dari aplikasi
              SystemNavigator.pop();
            },
          ),
        ),
      );
      return;
    }
  } catch (e) {
    log.e('Error initializing cameras', e);
    cameras =
        []; // Initialize with empty list to prevent LateInitializationError
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'QuantFace Mobile',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
