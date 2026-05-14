import 'package:get_it/get_it.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../data/face_repository.dart';
import '../database/database_helper.dart';
import '../logging/app_logger.dart';
import '../machinelearning/recognizer.dart';

final GetIt getIt = GetIt.instance;

Future<void> setupLocator() async {
  if (getIt.isRegistered<DatabaseHelper>()) {
    return;
  }

  getIt.registerLazySingleton<AppLogger>(() => AppLogger());
  getIt.registerLazySingleton<DatabaseHelper>(() => DatabaseHelper());
  getIt.registerLazySingleton<FaceRepository>(
    () => FaceRepository(dbHelper: getIt<DatabaseHelper>()),
  );
  getIt.registerLazySingleton<Recognizer>(
    () => Recognizer(faceRepository: getIt<FaceRepository>(), numThreads: 2),
  );
  getIt.registerLazySingleton<FaceDetector>(() {
    final options = FaceDetectorOptions(performanceMode: FaceDetectorMode.fast);
    return FaceDetector(options: options);
  });
}
