import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:realtime_attendance_mobile/di/service_locator.dart';
import 'package:realtime_attendance_mobile/logging/app_logger.dart';
import 'package:realtime_attendance_mobile/machinelearning/recognizer.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../machinelearning/recognition.dart';
import '../main.dart';

class RecognitionScreen extends StatefulWidget {
  const RecognitionScreen({super.key});

  @override
  State<RecognitionScreen> createState() => _RecognitionScreenState();
}

class _RecognitionScreenState extends State<RecognitionScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final AppLogger _log = AppLogger();
  CameraController? controller;
  bool isBusy = false;
  late Size size;
  late CameraDescription description;
  List<Recognition> recognitions = [];
  CameraLensDirection camDirec = CameraLensDirection.front;

  //TODO declare face detector
  late FaceDetector faceDetector;

  //TODO declare face recognizer
  late Recognizer recognizer;
  bool _recognizerReady = false;


  static const int _minFaceSizePx = 80;
  static const Duration _stableDuration = Duration(seconds: 1);
  static const double _liveThresholdOffset = 0.015;

  String? _lastName;
  DateTime? _stableSince;

  // Performance tracking
  late PerformanceTracker _performanceTracker;
  bool _isTestingActive = false;
  double _displayLatency = 0.0;
  double _displayFps = 0.0;

  // Background Isolate for Face Recognition
  Isolate? _recognitionIsolate;
  SendPort? _isolateSendPort;
  ReceivePort? _isolateReceivePort;
  bool _isolateReady = false;

  @override
  void initState() {
    super.initState();

    // Set initial camera description
    _initializeCameraDescription();

    //TODO initialize face detector
    faceDetector = getIt<FaceDetector>();

    //TODO initialize face recognizer
    _initRecognizer();

    // Initialize performance tracker
    _performanceTracker = PerformanceTracker();

    // Start background isolate initialization
    _initIsolate();

    //TODO initialize camera footage
    initializeCamera();
  }

  Future<void> _initRecognizer() async {
    recognizer = getIt<Recognizer>();
    await recognizer.init();
    if (!mounted) return;
    setState(() {
      _recognizerReady = recognizer.isReady;
    });
  }

  void _initializeCameraDescription() {
    // Check if cameras are available
    if (cameras.isEmpty) {
      _log.w('No cameras available on this device');
      return;
    }

    // Find front camera, fallback to back camera, or first available
    try {
      description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      camDirec = description.lensDirection;
    } catch (e) {
      _log.e('Error initializing camera', e);
      description = cameras.first;
      camDirec = description.lensDirection;
    }
  }

  //TODO code to initialize the camera feed
  Future<void> initializeCamera() async {
    // Check if cameras are available
    if (cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kamera tidak tersedia di perangkat ini'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }

    try {
      controller = CameraController(
        description,
        ResolutionPreset.medium,
        imageFormatGroup: ImageFormatGroup.nv21,
        enableAudio: false,
      );

      await controller!.initialize();

      if (!mounted) {
        return;
      }

      setState(() {});

      controller!.startImageStream((image) {
        if (!isBusy) {
          isBusy = true;
          frame = image;
          doFaceDetectionOnFrame();
        }
      });
    } catch (e) {
      _log.e('Error initializing camera', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Inisialisasi kamera gagal: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  //TODO close all resources
  @override
  void dispose() {
    controller?.dispose();
    _recognitionIsolate?.kill(priority: Isolate.beforeNextEvent);
    _isolateReceivePort?.close();
    super.dispose();
  }

  //TODO face detection on a frame
  List<Recognition>? _scanResults;
  CameraImage? frame;

  Future<void> doFaceDetectionOnFrame() async {
    try {
      // Start measuring frame latency
      _performanceTracker.startFrameMeasure();

      //TODO convert frame into InputImage format
      final inputImage = getInputImage();
      if (inputImage == null) {
        _performanceTracker.stopFrameMeasure();
        if (mounted) {
          setState(() {
            isBusy = false;
          });
        }
        return;
      }

      //TODO pass InputImage to face detection model and detect faces
      final faces = await faceDetector.processImage(inputImage);
      _log.d('Detected faces: ${faces.length}');

      //TODO perform face recognition on detected faces
      await performFaceRecognition(faces);

      // Stop measuring and update display metrics
      _performanceTracker.stopFrameMeasure();
      if (mounted) {
        setState(() {
          _displayLatency = _performanceTracker.currentAverageLatency;
          _displayFps = _performanceTracker.currentInstantFps;
        });
      }
    } catch (e) {
      _performanceTracker.stopFrameMeasure();
      _log.e('Error in face detection', e);
      if (mounted) {
        setState(() {
          isBusy = false;
        });
      }
    }
  }

  img.Image? image;

  Future<void> _initIsolate() async {
    try {
      _isolateReceivePort = ReceivePort();
      _recognitionIsolate = await Isolate.spawn(
        _recognitionIsolateEntryPoint,
        _isolateReceivePort!.sendPort,
      );

      _isolateSendPort = await _isolateReceivePort!.first as SendPort;

      final token = RootIsolateToken.instance;
      if (token == null) {
        _log.w('RootIsolateToken is null, background isolate cannot access rootBundle assets.');
        return;
      }

      final replyPort = ReceivePort();
      _isolateSendPort!.send(IsolateInitMessage(
        token: token,
        modelName: recognizer.modelName,
        forceCpuOnly: recognizer.forceCpuOnly,
        replyPort: replyPort.sendPort,
      ));

      final initResult = await replyPort.first;
      replyPort.close();

      if (initResult == true) {
        _log.i('Background isolate initialized successfully with model: ${recognizer.modelName}');
        if (mounted) {
          setState(() {
            _isolateReady = true;
          });
        }
      } else {
        _log.e('Failed to initialize background isolate: $initResult');
      }
    } catch (e, st) {
      _log.e('Error starting background isolate', e, st);
    }
  }

  Uint8List _cropNv21ToRgb(CameraImage image, Rect cropRect) {
    final int lsW = image.width;
    final int lsH = image.height;
    final Uint8List yuv420sp = image.planes[0].bytes;

    const int targetW = 112;
    const int targetH = 112;
    final Uint8List rgbBytes = Uint8List(targetW * targetH * 3);

    final double left = cropRect.left;
    final double top = cropRect.top;
    final double right = cropRect.right;
    final double bottom = cropRect.bottom;
    final double width = cropRect.width;
    final double height = cropRect.height;

    int outIdx = 0;

    for (int y = 0; y < targetH; y++) {
      final double yNorm = y / (targetH - 1);
      for (int x = 0; x < targetW; x++) {
        final double xNorm = x / (targetW - 1);

        int sx;
        int sy;

        if (camDirec == CameraLensDirection.front) {
          sx = (right - yNorm * width).round().clamp(0, lsW - 1);
          sy = (top + xNorm * height).round().clamp(0, lsH - 1);
        } else {
          sx = (left + yNorm * width).round().clamp(0, lsW - 1);
          sy = (bottom - xNorm * height).round().clamp(0, lsH - 1);
        }

        final int yIndex = sy * lsW + sx;
        final int yValue = yuv420sp[yIndex] & 0xFF;

        final int uvRow = sy >> 1;
        final int uvCol = sx >> 1;
        final int uvIndex = (lsW * lsH) + (uvRow * lsW) + (uvCol * 2);

        final int vValue = yuv420sp[uvIndex] & 0xFF;
        final int uValue = yuv420sp[uvIndex + 1] & 0xFF;

        int yVal = yValue - 16;
        if (yVal < 0) yVal = 0;
        int vVal = vValue - 128;
        int uVal = uValue - 128;

        int y1192 = 1192 * yVal;
        int r = (y1192 + 1634 * vVal) >> 10;
        int g = (y1192 - 833 * vVal - 400 * uVal) >> 10;
        int b = (y1192 + 2066 * uVal) >> 10;

        rgbBytes[outIdx++] = r.clamp(0, 255);
        rgbBytes[outIdx++] = g.clamp(0, 255);
        rgbBytes[outIdx++] = b.clamp(0, 255);
      }
    }

    return rgbBytes;
  }

  //TODO perform Face Recognition
  Future<void> performFaceRecognition(List<Face> faces) async {
    try {
      if (!_recognizerReady) {
        if (mounted) setState(() => isBusy = false);
        return;
      }

      if (frame == null) {
        if (mounted) setState(() => isBusy = false);
        return;
      }

      if (faces.isEmpty) {
        if (mounted) setState(() => isBusy = false);
        return;
      }

      // Use the largest face for recognition to reduce false positives.
      Face face = faces.reduce((a, b) {
        final double areaA = a.boundingBox.width * a.boundingBox.height;
        final double areaB = b.boundingBox.width * b.boundingBox.height;
        return areaA >= areaB ? a : b;
      });

      final List<Recognition> currentRecognitions = [];

      try {
        if (face.boundingBox.width < _minFaceSizePx ||
            face.boundingBox.height < _minFaceSizePx) {
          _log.d(
            '[REC] Face too small: ${face.boundingBox.width}x${face.boundingBox.height} - skipping',
          );
          if (mounted) setState(() => isBusy = false);
          return;
        }

        // Step 1: Transform portrait bbox → landscape coordinates using raw frame dimensions
        final Rect lsBox = _portraitBoxToLandscape(
          face.boundingBox,
          frame!.width,
          frame!.height,
        );

        // Step 2: Crop & Convert directly from NV21 bytes (without copyRotate or copyResize)
        final Uint8List croppedFaceBytes = _cropNv21ToRgb(frame!, lsBox);

        _log.d(
          '[REC] bbox=${face.boundingBox} cropSize=112x112 (direct RGB extraction)',
        );

        List<double> outputArray;
        final int startTimeMs = DateTime.now().millisecondsSinceEpoch;

        if (_isolateReady && _isolateSendPort != null) {
          // Inference via background isolate
          final replyPort = ReceivePort();
          _isolateSendPort!.send(IsolateInferenceMessage(
            rgbBytes: croppedFaceBytes,
            replyPort: replyPort.sendPort,
          ));
          final dynamic result = await replyPort.first;
          replyPort.close();

          if (result is List<double>) {
            outputArray = result;
          } else {
            throw Exception('Isolate inference failed: $result');
          }
        } else {
          // Fallback to main thread
          final rec = recognizer.recognizeCropped(croppedFaceBytes, face.boundingBox);
          outputArray = rec.embeddings;
        }

        final int runTimeMs = DateTime.now().millisecondsSinceEpoch - startTimeMs;
        _log.d('[REC] Total recognition time (inference + comms): ${runTimeMs}ms');

        final Pair pair = recognizer.findNearest(outputArray);
        final Recognition recognition = Recognition(
          pair.name,
          face.boundingBox,
          outputArray,
          pair.score,
        );

        _log.d(
          '[REC] name=${recognition.name} score=${recognition.score.toStringAsFixed(3)}',
        );

        if (!recognition.name.startsWith('__')) {
          final double liveThreshold =
              recognizer.cosineThreshold + _liveThresholdOffset;
          final bool aboveThreshold = recognition.score >= liveThreshold;
          final String candidateName =
              aboveThreshold ? recognition.name : 'Unknown';

          final DateTime now = DateTime.now();
          if (candidateName == 'Unknown') {
            _lastName = null;
            _stableSince = null;
          } else if (_lastName == candidateName) {
            _stableSince ??= now;
          } else {
            _lastName = candidateName;
            _stableSince = now;
          }

          final bool isStable =
              _stableSince != null &&
              now.difference(_stableSince!) >= _stableDuration;
          final String displayName = isStable ? candidateName : 'Unknown';

          currentRecognitions.add(
            Recognition(
              displayName,
              recognition.location,
              recognition.embeddings,
              recognition.score,
            ),
          );
        }
      } catch (e) {
        _log.e('[REC] Error processing face', e);
      }

      if (mounted) {
        setState(() {
          isBusy = false;
          _scanResults = List.from(currentRecognitions);
        });
      }
    } catch (e) {
      _log.e('[REC] Error in face recognition', e);
      if (mounted) setState(() => isBusy = false);
    }
  }

  /// Same coordinate transform as RegistrationScreen.
  Rect _portraitBoxToLandscape(Rect p, int lsW, int lsH) {
    if (camDirec == CameraLensDirection.front) {
      final left = (lsW - 1 - p.bottom).clamp(0.0, (lsW - 1).toDouble());
      final top = p.left.clamp(0.0, (lsH - 1).toDouble());
      final right = (lsW - 1 - p.top).clamp(left + 1, lsW.toDouble());
      final bottom = p.right.clamp(top + 1, lsH.toDouble());
      return Rect.fromLTRB(left, top, right, bottom);
    } else {
      final left = p.top.clamp(0.0, (lsW - 1).toDouble());
      final top = (lsH - 1 - p.right).clamp(0.0, (lsH - 1).toDouble());
      final right = p.bottom.clamp(left + 1, lsW.toDouble());
      final bottom = (lsH - 1 - p.left).clamp(top + 1, lsH.toDouble());
      return Rect.fromLTRB(left, top, right, bottom);
    }
  }

  // //TODO convert CameraImage to InputImage
  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  InputImage? getInputImage() {
    if (controller == null || frame == null) return null;

    // Safe camera selection based on direction
    final camera = cameras.firstWhere(
      (cam) => cam.lensDirection == camDirec,
      orElse: () => description,
    );
    final sensorOrientation = camera.sensorOrientation;

    InputImageRotation? rotation;
    var rotationCompensation =
        _orientations[controller!.value.deviceOrientation];
    if (rotationCompensation == null) return null;
    if (camera.lensDirection == CameraLensDirection.front) {
      // front-facing
      rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
    } else {
      // back-facing
      rotationCompensation =
          (sensorOrientation - rotationCompensation + 360) % 360;
    }
    rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(frame!.format.raw);
    if (format == null || format != InputImageFormat.nv21) {
      return null;
    }

    if (frame!.planes.length != 1) return null;
    final plane = frame!.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(frame!.width.toDouble(), frame!.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  // TODO Show rectangles around detected faces
  Widget buildResult() {
    if (_scanResults == null ||
        controller == null ||
        !controller!.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final previewSize = controller!.value.previewSize;
    if (previewSize == null) {
      return const SizedBox.shrink();
    }

    // Get the camera preview size (already rotated for portrait)
    final cameraPreviewSize = Size(previewSize.height, previewSize.width);

    // Calculate the actual displayed size accounting for BoxFit.cover
    final screenSize = MediaQuery.of(context).size;
    final screenRatio = screenSize.width / screenSize.height;
    final previewRatio = cameraPreviewSize.width / cameraPreviewSize.height;

    Size displayedSize;
    if (screenRatio > previewRatio) {
      // Screen is wider, preview is constrained by width
      displayedSize = Size(screenSize.width, screenSize.width / previewRatio);
    } else {
      // Screen is taller, preview is constrained by height
      displayedSize = Size(screenSize.height * previewRatio, screenSize.height);
    }

    CustomPainter painter = FaceDetectorPainter(
      cameraPreviewSize,
      _scanResults!,
      camDirec,
      displayedSize,
      screenSize,
    );
    return RepaintBoundary(child: CustomPaint(painter: painter));
  }

  /// Start 15-second performance test session
  void _startPerformanceTest() {
    _performanceTracker.reset();
    setState(() {
      _isTestingActive = true;
      // _testStartTime = DateTime.now();
    });

    // Schedule automatic stop after 15 seconds
    Future.delayed(const Duration(seconds: 15), () {
      _stopPerformanceTest();
    });

    _log.i('[TEST] Performance test started - 15 second measurement active');
  }

  /// Stop test and print statistics
  void _stopPerformanceTest() {
    setState(() {
      _isTestingActive = false;
    });

    final statsJson = _performanceTracker.getStatsAsJson();
    _log.i('[TEST] Performance test completed');
    _log.i('[TEST] Statistics: $statsJson');

    // Print to console for easy copy-paste
    // ignore: avoid_print
    print('═' * 60);
    // ignore: avoid_print
    print('PERFORMANCE TEST RESULTS (15 seconds)');
    // ignore: avoid_print
    print('═' * 60);
    // ignore: avoid_print
    print(statsJson);
    // ignore: avoid_print
    print('═' * 60);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            '✓ Test selesai. Lihat Console untuk hasil JSON.',
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  //TODO toggle camera direction
  Future<void> _toggleCameraDirection() async {
    // Check if cameras are available
    if (cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kamera tidak tersedia di perangkat ini'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Need at least 2 cameras to toggle
    if (cameras.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Hanya satu kamera yang tersedia di perangkat ini'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    try {
      if (controller != null) {
        await controller!.stopImageStream();
        await controller!.dispose();
      }

      // Toggle camera direction
      if (camDirec == CameraLensDirection.back) {
        // Switch to front
        final frontCamera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.front,
          orElse: () => cameras.last,
        );
        description = frontCamera;
        camDirec = CameraLensDirection.front;
      } else {
        // Switch to back
        final backCamera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        );
        description = backCamera;
        camDirec = CameraLensDirection.back;
      }

      // Reset processing state
      setState(() {});
      await initializeCamera();
    } catch (e) {
      _log.e('Error toggling camera', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengganti kamera: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    List<Widget> stackChildren = [];
    size = MediaQuery.of(context).size;

    final isControllerInitialized = controller?.value.isInitialized ?? false;
    final previewSize = controller?.value.previewSize;

    if (isControllerInitialized && previewSize != null) {
      //TODO View for displaying the live camera footage
      stackChildren.add(
        Positioned.fill(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: previewSize.height,
              height: previewSize.width,
              child: CameraPreview(controller!),
            ),
          ),
        ),
      );

      //TODO View for displaying rectangles around detected faces
      stackChildren.add(
        Positioned(
          top: 0.0,
          left: 0.0,
          width: size.width,
          height: size.height,
          child: buildResult(),
        ),
      );
    } else {
      // Show loading indicator while camera initializes
      stackChildren.add(
        const Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    //TODO View for displaying the bar to switch camera direction or for registering faces
    stackChildren.add(
      Positioned(
        top: 16,
        left: 16,
        child: SafeArea(
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.9),
            ),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('Kembali'),
          ),
        ),
      ),
    );

    // OSD: Display Latency and FPS in top-right corner
    if (!kReleaseMode) {
      stackChildren.add(
        Positioned(
          top: 16,
          right: 16,
          child: SafeArea(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green, width: 1),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Latency: ${_displayLatency.toStringAsFixed(1)} ms',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'FPS: ${_displayFps.toStringAsFixed(1)}',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Test button
    if (!kReleaseMode) {
      if (!_isTestingActive) {
        stackChildren.add(
          Positioned(
            top: 80,
            right: 16,
            child: SafeArea(
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.orange.withValues(alpha: 0.9),
                ),
                onPressed: _startPerformanceTest,
                icon: const Icon(Icons.assessment_rounded),
                label: const Text('Test (15s)'),
              ),
            ),
          ),
        );
      } else {
        stackChildren.add(
          Positioned(
            top: 80,
            right: 16,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '🔴 Testing...',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    stackChildren.add(
      Positioned(
        bottom: 40,
        left: 0,
        right: 0,
        child: Center(
          child: FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              backgroundColor: Colors.white.withValues(alpha: 0.9),
              foregroundColor: Colors.black,
            ),
            onPressed: _toggleCameraDirection,
            child: const Icon(Icons.flip_camera_android_rounded, size: 28),
          ),
        ),
      ),
    );

    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: RepaintBoundary(
          child: Container(
            margin: const EdgeInsets.only(top: 0),
            color: Colors.black,
            child: Stack(children: stackChildren),
          ),
        ),
      ),
    );
  }
}

class FaceDetectorPainter extends CustomPainter {
  final Size absoluteImageSize;
  final List<Recognition> faces;
  final CameraLensDirection camDirection;
  final Size displayedSize;
  final Size screenSize;

  FaceDetectorPainter(
    this.absoluteImageSize,
    this.faces,
    this.camDirection,
    this.displayedSize,
    this.screenSize,
  );

  @override
  void paint(Canvas canvas, Size size) {
    // Calculate scale from camera preview to displayed size
    final double scaleX = displayedSize.width / absoluteImageSize.width;
    final double scaleY = displayedSize.height / absoluteImageSize.height;

    // Calculate offset to center the preview (for BoxFit.cover)
    final double offsetX = (displayedSize.width - screenSize.width) / 2;
    final double offsetY = (displayedSize.height - screenSize.height) / 2;

    final Paint boxPaint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0
          ..color = const Color(0xFF4CAF50);

    final Paint labelBgPaint =
        Paint()
          ..style = PaintingStyle.fill
          ..color = const Color(0xFF212121).withValues(alpha: 0.85);

    for (final face in faces) {
      final double left =
          camDirection == CameraLensDirection.front
              ? (absoluteImageSize.width - face.location.right) * scaleX -
                  offsetX
              : face.location.left * scaleX - offsetX;
      final double top = face.location.top * scaleY - offsetY;
      final double right =
          camDirection == CameraLensDirection.front
              ? (absoluteImageSize.width - face.location.left) * scaleX -
                  offsetX
              : face.location.right * scaleX - offsetX;
      final double bottom = face.location.bottom * scaleY - offsetY;

      final rect = Rect.fromLTRB(left, top, right, bottom);
      final rRect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
      canvas.drawRRect(rRect, boxPaint);

      // Draw name label
      final String label =
          face.name.isNotEmpty
              ? '${face.name} (score ${face.score.toStringAsFixed(2)})'
              : 'Unknown';

      final textSpan = TextSpan(
        text: label,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width * 0.6);

      final double labelPadding = 6;
      final double labelX = left;
      final double labelY = top - textPainter.height - 8;

      final backgroundRect = Rect.fromLTWH(
        labelX,
        labelY < 0 ? top + 4 : labelY,
        textPainter.width + labelPadding * 2,
        textPainter.height + labelPadding,
      );

      canvas.drawRRect(
        RRect.fromRectAndRadius(backgroundRect, const Radius.circular(8)),
        labelBgPaint,
      );

      textPainter.paint(
        canvas,
        Offset(
          backgroundRect.left + labelPadding,
          backgroundRect.top + labelPadding / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(FaceDetectorPainter oldDelegate) => true;
}

class IsolateInitMessage {
  final RootIsolateToken token;
  final String modelName;
  final bool forceCpuOnly;
  final SendPort replyPort;

  IsolateInitMessage({
    required this.token,
    required this.modelName,
    required this.forceCpuOnly,
    required this.replyPort,
  });
}

class IsolateInferenceMessage {
  final Uint8List rgbBytes;
  final SendPort replyPort;

  IsolateInferenceMessage({
    required this.rgbBytes,
    required this.replyPort,
  });
}

void _recognitionIsolateEntryPoint(SendPort mainSendPort) async {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  Interpreter? interpreter;

  await for (final message in receivePort) {
    if (message is IsolateInitMessage) {
      try {
        BackgroundIsolateBinaryMessenger.ensureInitialized(message.token);
        final options = InterpreterOptions()..threads = 4;

        if (!message.forceCpuOnly) {
          try {
            if (Platform.isAndroid) {
              options.addDelegate(GpuDelegateV2(
                options: GpuDelegateOptionsV2(
                  isPrecisionLossAllowed: true,
                  inferencePreference: TfLiteGpuInferenceUsage.fastSingleAnswer,
                  inferencePriority1: TfLiteGpuInferencePriority.minLatency,
                ),
              ));
            } else if (Platform.isIOS) {
              options.addDelegate(GpuDelegate(
                options: GpuDelegateOptions(
                  allowPrecisionLoss: true,
                  waitType: TFLGpuDelegateWaitType.aggressive,
                ),
              ));
            }
          } catch (_) {
            // Fallback CPU options will be used if delegate initialization fails
          }
        }

        interpreter = await Interpreter.fromAsset(message.modelName, options: options);
        message.replyPort.send(true);
      } catch (e) {
        message.replyPort.send(e.toString());
      }
    } else if (message is IsolateInferenceMessage) {
      if (interpreter == null) {
        message.replyPort.send(null);
        continue;
      }

      try {
        final rgbBytes = message.rgbBytes;
        final Float32List inputBuffer = Float32List(112 * 112 * 3);
        for (int i = 0; i < rgbBytes.length; i++) {
          inputBuffer[i] = (rgbBytes[i] - 127.5) / 127.5;
        }
        final input = inputBuffer.reshape([1, 112, 112, 3]);

        final List<List<double>> output = [List.filled(128, 0.0)];
        interpreter.run(input, output);

        message.replyPort.send(output[0]);
      } catch (e) {
        message.replyPort.send(e.toString());
      }
    }
  }
}
