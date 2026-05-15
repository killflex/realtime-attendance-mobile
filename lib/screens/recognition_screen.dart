import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:realtime_attendance_mobile/di/service_locator.dart';
import 'package:realtime_attendance_mobile/logging/app_logger.dart';
import 'package:realtime_attendance_mobile/machinelearning/recognizer.dart';
import 'package:realtime_attendance_mobile/util.dart';

import '../machinelearning/recognition.dart';
import '../main.dart';

class RecognitionScreen extends StatefulWidget {
  const RecognitionScreen({super.key});

  @override
  State<RecognitionScreen> createState() => _RecognitionScreenState();
}

class _RecognitionScreenState extends State<RecognitionScreen> {
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

  // Performance optimization
  DateTime? _lastProcessedTime;
  static const _processingInterval = Duration(
    milliseconds: 300,
  ); // Process every 300ms
  int _skipFrameCount = 0;
  static const _skipFrames = 0; // Skip 2 frames between processing
  static const int _minFaceSizePx = 80;
  static const Duration _stableDuration = Duration(seconds: 1);
  static const double _liveThresholdOffset = 0.015;

  String? _lastName;
  DateTime? _stableSince;

  @override
  void initState() {
    super.initState();

    // Set initial camera description
    _initializeCameraDescription();

    //TODO initialize face detector
    faceDetector = getIt<FaceDetector>();

    //TODO initialize face recognizer
    _initRecognizer();

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
          // Throttle processing with time-based check
          final now = DateTime.now();
          if (_lastProcessedTime == null ||
              now.difference(_lastProcessedTime!) > _processingInterval) {
            // Also skip frames for additional performance
            _skipFrameCount++;
            if (_skipFrameCount > _skipFrames) {
              _skipFrameCount = 0;
              isBusy = true;
              frame = image;
              _lastProcessedTime = now;
              doFaceDetectionOnFrame();
            }
          }
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
    super.dispose();
  }

  //TODO face detection on a frame
  List<Recognition>? _scanResults;
  CameraImage? frame;

  Future<void> doFaceDetectionOnFrame() async {
    try {
      //TODO convert frame into InputImage format
      final inputImage = getInputImage();
      if (inputImage == null) {
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
    } catch (e) {
      _log.e('Error in face detection', e);
      if (mounted) {
        setState(() {
          isBusy = false;
        });
      }
    }
  }

  img.Image? image;
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

      // Step 1: Convert NV21 → landscape (raw, no full rotation)
      img.Image? originalImage = await compute(Util.convertNV21, frame!);
      if (originalImage == null) {
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
        // Step 2: Transform portrait bbox → landscape coordinates
        final Rect lsBox = _portraitBoxToLandscape(
          face.boundingBox,
          originalImage.width,
          originalImage.height,
        );

        final int left =
            lsBox.left.clamp(0.0, (originalImage.width - 1).toDouble()).toInt();
        final int top =
            lsBox.top.clamp(0.0, (originalImage.height - 1).toDouble()).toInt();
        final int right =
            lsBox.right
                .clamp((left + 1).toDouble(), originalImage.width.toDouble())
                .toInt();
        final int bottom =
            lsBox.bottom
                .clamp((top + 1).toDouble(), originalImage.height.toDouble())
                .toInt();
        final int cropW = right - left;
        final int cropH = bottom - top;

        if (cropW <= 0 || cropH <= 0) {
          if (mounted) setState(() => isBusy = false);
          return;
        }

        if (cropW < _minFaceSizePx || cropH < _minFaceSizePx) {
          _log.d('[REC] Face too small: ${cropW}x$cropH - skipping');
          if (mounted) setState(() => isBusy = false);
          return;
        }

        // Step 3: Crop small region from landscape
        final img.Image croppedLandscape = img.copyCrop(
          originalImage,
          x: left,
          y: top,
          width: cropW,
          height: cropH,
        );

        // Step 4: Rotate only the small crop
        final img.Image croppedFace = img.copyRotate(
          croppedLandscape,
          angle: camDirec == CameraLensDirection.front ? 270 : 90,
        );

        _log.d(
          '[REC] bbox=${face.boundingBox} cropSize=${croppedFace.width}x${croppedFace.height}',
        );

        Recognition recognition = recognizer.recognizeCropped(
          croppedFace,
          face.boundingBox,
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
      _skipFrameCount = 0;
      _lastProcessedTime = null;

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
        body: Container(
          margin: const EdgeInsets.only(top: 0),
          color: Colors.black,
          child: Stack(children: stackChildren),
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
