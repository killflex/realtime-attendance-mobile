import 'dart:async';

import 'package:camera/camera.dart';
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

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final AppLogger _log = AppLogger();

  bool _showCautionDialog = true;

  // Camera and Face Recognition - Step 2
  CameraController? controller;
  bool isBusy = false;
  late Size size;
  late CameraDescription description;
  List<Recognition> recognitions = [];
  late img.Image croppedFace;
  img.Image? image;
  CameraLensDirection camDirec = CameraLensDirection.front;
  List<Face>? _scanResults;
  CameraImage? frame;

  // Declare face detector
  late FaceDetector faceDetector;

  // Declare face recognizer
  late Recognizer recognizer;
  bool _recognizerReady = false;
  bool _isModelLoading = true; // show loading state while recognizer boots


  static const int _minFaceSizePx = 60;

  int _currentStep = 0;
  int _validFrameCount = 0;
  final int _requiredValidFrames =
      1; // 1 sharp frame is enough; throttling already limits rate

  List<String> faceAngles = ["straight", "right", "left", "down", "up"];

  final Map<String, IconData> angleIcons = {
    "straight": Icons.face,
    "right": Icons.keyboard_double_arrow_right_rounded,
    "left": Icons.keyboard_double_arrow_left_rounded,
    "down": Icons.keyboard_double_arrow_down_rounded,
    "up": Icons.keyboard_double_arrow_up_rounded,
  };

  bool getEmb = false;
  img.Image? frontFace;

  List<List<double>> embeddings = [];

  int registrationStep = 0;

  List<String> positionInstructions = [
    "Lihat lurus ke kamera",
    "Lihat sedikit ke kanan",
    "Lihat sedikit ke kiri",
    "Lihat sedikit ke bawah",
    "Lihat sedikit ke atas",
  ];

  bool dialogShown = false;
  bool register = false;

  // Timer control for 1.5 second pose hold
  Timer? _poseHoldTimer;
  bool _isHoldingPose = false;
  bool _isProcessingEmbedding = false; // guard against re-entrant calls
  int _holdTimeRemaining = 0; // ms

  @override
  void initState() {
    super.initState();

    // Initialize camera description safely
    _initializeCameraDescription();

    // Initialize face detector
    faceDetector = getIt<FaceDetector>();

    // Initialize face recognizer first, then camera.
    // This prevents the 1.5s pose hold from firing before the model is ready.
    _initRecognizer().then((_) {
      if (mounted) initializeCamera();
    });
  }

  Future<void> _initRecognizer() async {
    // ignore: avoid_print
    print('[REG] _initRecognizer: START');
    recognizer = getIt<Recognizer>();

    // Up to 3 attempts with an increasing delay between each.
    // This handles transient failures (e.g., GpuDelegate rejected on first try)
    // and ensures the model is genuinely loaded before the camera starts.
    for (int attempt = 1; attempt <= 3; attempt++) {
      // ignore: avoid_print
      print('[REG] _initRecognizer: attempt $attempt — isReady=${recognizer.isReady}');
      try {
        await recognizer.init();
      } catch (e, st) {
        // ignore: avoid_print
        print('[REG] _initRecognizer: attempt $attempt threw: $e');
        _log.e('[REG] _initRecognizer attempt $attempt error', e, st);
      }

      // ignore: avoid_print
      print('[REG] _initRecognizer: after attempt $attempt — isReady=${recognizer.isReady}');

      if (recognizer.isReady) break;

      // Wait before retrying to give the OS time to recover
      await Future.delayed(Duration(milliseconds: 300 * attempt));
    }

    // ignore: avoid_print
    print('[REG] _initRecognizer: DONE — isReady=${recognizer.isReady}');
    _log.d('[REG] _initRecognizer complete: isReady=${recognizer.isReady}');

    if (!mounted) return;
    setState(() {
      _recognizerReady = recognizer.isReady;
      _isModelLoading = false;
    });
  }

  void _initializeCameraDescription() {
    if (cameras.isEmpty) return;

    try {
      description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      camDirec = description.lensDirection;
    } catch (e) {
      _log.e('Error initializing camera', e);
      if (cameras.isNotEmpty) {
        description = cameras.first;
        camDirec = description.lensDirection;
      }
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    _poseHoldTimer?.cancel();
    super.dispose();
  }

  //TODO code to initialize the camera feed
  Future<void> initializeCamera() async {
    if (cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No cameras available'),
            backgroundColor: Colors.red,
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

      if (!mounted) return;

      setState(() {});

      controller!.startImageStream((image) {
        if (!isBusy) {
          isBusy = true;
          frame = image;
          doFaceDetectionOnFrame();
        }
      });
    } catch (e) {
      _log.e('Camera init error', e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Camera error: $e')));
      }
    }
  }

  bool _isFaceSharp(img.Image faceImage) {
    try {
      // Resize to small version for speed
      final resized = img.copyResize(faceImage, width: 64, height: 64);

      // Calculate luminance variance pixel-by-pixel
      // (getBytes() in image v4 returns RGBA — cannot be used for grayscale analysis)
      double sumLuma = 0.0;
      final int total = resized.width * resized.height;
      for (int y = 0; y < resized.height; y++) {
        for (int x = 0; x < resized.width; x++) {
          final p = resized.getPixel(x, y);
          sumLuma += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        }
      }
      final double mean = sumLuma / total;

      // GUARD: Tolak frame jika terlalu gelap (Auto-exposure belum stabil)
      if (mean < 50) {
        _log.d(
          '[REG] Face is too dark (mean luma=${mean.toStringAsFixed(1)} < 50)',
        );
        return false;
      }

      double variance = 0.0;
      for (int y = 0; y < resized.height; y++) {
        for (int x = 0; x < resized.width; x++) {
          final p = resized.getPixel(x, y);
          final luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
          variance += (luma - mean) * (luma - mean);
        }
      }
      variance /= total;

      _log.d(
        '[REG] sharpness variance=${variance.toStringAsFixed(1)} (threshold=50), luma=${mean.toStringAsFixed(1)}',
      );
      return variance >
          50; // Lowered threshold — mobile cameras are generally adequate
    } catch (e) {
      _log.w('[REG] Sharpness check error - assuming sharp', e);
      return true;
    }
  }

  bool _isFaceProperlyAligned(Face face, int step) {
    switch (step) {
      case 0:
        return face.headEulerAngleY!.abs() < 15 &&
            face.headEulerAngleX!.abs() < 15;
      case 1:
        return face.headEulerAngleY! < -20;
      case 2:
        return face.headEulerAngleY! > 20;
      case 3:
        return face.headEulerAngleX! < -15;
      case 4:
        return face.headEulerAngleX! > 10;
      default:
        return false;
    }
  }

  //TODO face detection on a frame
  Future<void> doFaceDetectionOnFrame() async {
    try {
      // Skip frame processing if holding pose (during 1.5s timer)
      if (_isHoldingPose) {
        isBusy = false;
        return;
      }

      if (frame == null || controller == null) {
        isBusy = false;
        return;
      }

      InputImage? inputImage = getInputImage();
      if (inputImage == null) {
        isBusy = false;
        return;
      }

      List<Face> faces = await faceDetector.processImage(inputImage);
      if (mounted) setState(() => _scanResults = faces);

      _log.d(
        '[REG] faces=${faces.length}, step=$_currentStep, validFrames=$_validFrameCount',
      );

      if (faces.isEmpty) {
        _validFrameCount = 0;
        isBusy = false;
        return;
      }

      final face = faces[0];
      final aligned = _isFaceProperlyAligned(face, _currentStep);
      _log.d(
        '[REG] aligned=$aligned eulerY=${face.headEulerAngleY?.toStringAsFixed(1)} eulerX=${face.headEulerAngleX?.toStringAsFixed(1)}',
      );

      if (!aligned) {
        _validFrameCount = 0;
        isBusy = false;
        return;
      }

      final faceBox = face.boundingBox;
      // Step 1: Transform ML Kit portrait bbox → landscape coordinates using raw frame dimensions
      final Rect lsBox = _portraitBoxToLandscape(
        faceBox,
        frame!.width,
        frame!.height,
      );

      // Step 2: Crop & Rotate in a single pass directly from NV21 bytes!
      final img.Image cropped = Util.convertNV21CropAndRotate(
        frame!,
        lsBox,
        camDirec,
      );

      if (cropped.width < _minFaceSizePx || cropped.height < _minFaceSizePx) {
        _log.d('[REG] Crop too small: ${cropped.width}x${cropped.height} - skipping');
        isBusy = false;
        return;
      }

      _log.d(
        '[REG] portrait_bbox=$faceBox cropSize=${cropped.width}x${cropped.height}',
      );

      if (_isFaceSharp(cropped)) {
        _validFrameCount++;
        _log.d(
          '[REG] Sharp frame. validFrameCount=$_validFrameCount/$_requiredValidFrames',
        );
        if (_validFrameCount >= _requiredValidFrames && !getEmb) {
          getEmb = true;
          _validFrameCount = 0;

          // Store cropped face and start pose hold timer
          frontFace = cropped;
          _startPoseHoldTimer();

          _log.d(
            '[REG] Valid pose detected - starting 1.5s hold timer for step $_currentStep',
          );
        }
      } else {
        _log.d('[REG] Face not sharp, skipping');
        _validFrameCount = 0;
      }

      isBusy = false;
    } catch (e, st) {
      _log.e('Face detection error', e, st);
      isBusy = false;
    }
  }

  /// Transforms a bounding box from portrait (ML Kit) space back to
  /// landscape (raw camera frame) space so we can crop before rotating.
  ///
  /// img.copyRotate(angle: 270) does 270° CCW:
  ///   portrait(px,py) = (landscape_sy, landscapeW-1-landscape_sx)
  ///   inverse: landscape_sx = landscapeW-1-py, landscape_sy = px
  ///
  /// img.copyRotate(angle: 90) does 90° CW:
  ///   portrait(px,py) = (landscapeH-1-landscape_sy, landscape_sx)
  ///   inverse: landscape_sx = py, landscape_sy = landscapeH-1-px
  Rect _portraitBoxToLandscape(Rect p, int lsW, int lsH) {
    if (camDirec == CameraLensDirection.front) {
      // 270° CCW: landscape_sx = lsW-1-py,  landscape_sy = px
      final left = (lsW - 1 - p.bottom).clamp(0.0, (lsW - 1).toDouble());
      final top = p.left.clamp(0.0, (lsH - 1).toDouble());
      final right = (lsW - 1 - p.top).clamp(left + 1, lsW.toDouble());
      final bottom = p.right.clamp(top + 1, lsH.toDouble());
      return Rect.fromLTRB(left, top, right, bottom);
    } else {
      // 90° CW: landscape_sx = py, landscape_sy = lsH-1-px
      final left = p.top.clamp(0.0, (lsW - 1).toDouble());
      final top = (lsH - 1 - p.right).clamp(0.0, (lsH - 1).toDouble());
      final right = p.bottom.clamp(left + 1, lsW.toDouble());
      final bottom = (lsH - 1 - p.left).clamp(top + 1, lsH.toDouble());
      return Rect.fromLTRB(left, top, right, bottom);
    }
  }

  /// Start 1.5 second pose hold timer. After timer expires, process embedding.
  void _startPoseHoldTimer() {
    if (_isHoldingPose) return; // Avoid duplicate timers

    _log.d('[REG] Starting 1.5s pose hold timer for step $_currentStep');

    _poseHoldTimer?.cancel();
    _isHoldingPose = true;
    int elapsedMs = 0;
    const holdDurationMs = 1500;
    const updateIntervalMs = 50;

    setState(() {
      _holdTimeRemaining = holdDurationMs;
    });

    _poseHoldTimer = Timer.periodic(
      const Duration(milliseconds: updateIntervalMs),
      (timer) {
        elapsedMs += updateIntervalMs;

        if (mounted) {
          setState(() {
            _holdTimeRemaining = (holdDurationMs - elapsedMs).clamp(
              0,
              holdDurationMs,
            );
          });
        }

        if (elapsedMs >= holdDurationMs) {
          timer.cancel();
          _poseHoldTimer = null;

          _log.d('[REG] Pose hold timer completed - processing embedding');

          // DO NOT reset _isHoldingPose here — keep it true while
          // _processHeldFrameEmbedding runs to block new captures.
          if (mounted && frontFace != null) {
            _processHeldFrameEmbedding();
          } else {
            // Nothing to process, clean up.
            if (mounted) setState(() { _isHoldingPose = false; _holdTimeRemaining = 0; });
            getEmb = false;
          }
        }
      },
    );
  }

  /// Process embedding from the frame held during 1.5s timer
  Future<void> _processHeldFrameEmbedding() async {
    // Guard against re-entrant calls (e.g. timer fires twice or widget rebuilds)
    if (_isProcessingEmbedding) {
      _log.w('[REG] _processHeldFrameEmbedding called while already processing — skipping');
      return;
    }
    _isProcessingEmbedding = true;

    // If the recognizer isn't ready yet, WAIT for it instead of silently
    // resetting and allowing the camera to loop infinitely.
    if (!recognizer.isReady) {
      _log.w('[REG] Recognizer not ready — waiting for init...');
      await recognizer.init();
      if (!recognizer.isReady) {
        _log.e('[REG] Recognizer still not ready after init. Aborting step.');
        _isProcessingEmbedding = false;
        if (mounted) {
          setState(() { _isHoldingPose = false; _holdTimeRemaining = 0; getEmb = false; });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Model AI belum siap. Coba lagi atau restart aplikasi.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }
    }

    try {
      _log.d('[REG] Processing held frame embedding for step $_currentStep');

      final dummyRect = Rect.fromLTWH(
        0, 0,
        frontFace!.width.toDouble(),
        frontFace!.height.toDouble(),
      );

      final img.Image resizedFace = img.copyResize(
        frontFace!, width: 112, height: 112,
      );
      final Uint8List faceBytes = Util.imageToRgbBytes(resizedFace);

      Recognition recognition = recognizer.recognizeCropped(faceBytes, dummyRect);

      // __busy__: the model is running concurrently — retry on next frame
      if (recognition.name == '__busy__') {
        _log.d('[REG] Model busy, will retry next valid frame');
        _isProcessingEmbedding = false;
        if (mounted) setState(() { _isHoldingPose = false; _holdTimeRemaining = 0; getEmb = false; });
        return;
      }

      // Any other sentinel (including __not_ready__, __invalid__) means the
      // crop itself is bad. Show a snackbar and allow retry.
      if (recognition.name.startsWith('__')) {
        _log.w('[REG] Sentinel result for step $_currentStep: ${recognition.name} — retrying');
        _isProcessingEmbedding = false;
        if (mounted) {
          setState(() { _isHoldingPose = false; _holdTimeRemaining = 0; getEmb = false; });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Gagal menangkap wajah (${recognition.name}). Coba posisikan wajah lebih jelas.'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      final bool embValid = recognition.embeddings.any((v) => v != 0.0);
      if (!embValid) {
        _log.w('[REG] Embedding is all zeros — skipping step $_currentStep');
        _isProcessingEmbedding = false;
        if (mounted) setState(() { _isHoldingPose = false; _holdTimeRemaining = 0; getEmb = false; });
        return;
      }

      embeddings.add(recognition.embeddings);
      _log.d(
        '[REG] Captured embedding ${embeddings.length}/${faceAngles.length} '
        'for step $_currentStep (${faceAngles[_currentStep]}) | '
        'emb[0]=${recognition.embeddings[0].toStringAsFixed(4)}',
      );

      // Advance step — commit state BEFORE releasing guards so the camera
      // stream sees the new _currentStep before it can re-enter.
      final bool allDone = (_currentStep >= faceAngles.length - 1);
      if (mounted) {
        setState(() {
          if (!allDone) {
            _currentStep++;
          }
          _isHoldingPose = false;
          _holdTimeRemaining = 0;
          getEmb = false;
        });
      }

      // Show final dialog AFTER setState, outside setState callback.
      if (allDone && mounted && !dialogShown) {
        showFaceRegistrationDialogue(frontFace!);
      }
    } catch (e, st) {
      _log.e('[REG] Error processing held frame embedding', e, st);
      if (mounted) {
        setState(() {
          _isHoldingPose = false;
          _holdTimeRemaining = 0;
          getEmb = false;
        });
      } else {
        getEmb = false;
      }
    } finally {
      _isProcessingEmbedding = false;
    }
  }




  //TODO Face Registration Dialogue
  TextEditingController textEditingController = TextEditingController();
  showFaceRegistrationDialogue(img.Image croppedFace) {
    dialogShown = true;
    textEditingController.clear();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Konfirmasi Pendaftaran'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Berhasil menangkap ${embeddings.length} sudut wajah',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),

                  const SizedBox(height: 16),

                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      Uint8List.fromList(img.encodeBmp(croppedFace)),
                      width: 150,
                      height: 150,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: textEditingController,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: 'Nama',
                      hintText: 'Masukkan nama',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _currentStep = 0;
                  embeddings.clear();
                  frontFace = null;
                  dialogShown = false;
                  Navigator.pop(context);
                },
                child: const Text('Ulangi'),
              ),
              FilledButton(
                onPressed: () async {
                  // Buat salinan data sebelum state direset
                  final String name = textEditingController.text.trim();
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Nama wajib diisi'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }
                  final List<List<double>> embs = List<List<double>>.from(
                    embeddings,
                  );
                  final Uint8List imgBytes = Uint8List.fromList(
                    img.encodeBmp(croppedFace),
                  );

                  // Reset state
                  setState(() {
                    _currentStep = 0;
                    embeddings.clear();
                    frontFace = null;
                    dialogShown = false;
                  });

                  // Tutup dialog
                  if (mounted) Navigator.pop(context);

                  // Simpan ke DB — await agar error tidak hilang
                  try {
                    await recognizer.registerFaceInDB(name, embs, imgBytes);
                    if (mounted) {
                      Navigator.pop(context); // Kembali ke HomeScreen
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✅ Wajah berhasil didaftarkan!'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    }
                  } catch (e) {
                    _log.e('[REG] registerFaceInDB failed', e);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('❌ Gagal menyimpan wajah: $e'),
                          backgroundColor: Colors.red,
                          duration: const Duration(seconds: 6),
                        ),
                      );
                    }
                  }
                },
                child: const Text('Konfirmasi'),
              ),
            ],
          ),
    );
  }

  // Convert CameraImage to InputImage
  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  InputImage? getInputImage() {
    if (controller == null || frame == null) return null;

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

  // Show rectangles around detected faces
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

  // Toggle camera direction
  Future<void> _toggleCameraDirection() async {
    if (cameras.isEmpty || cameras.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only one camera available')),
      );
      return;
    }

    try {
      if (controller != null) {
        await controller!.stopImageStream();
        await controller!.dispose();
      }

      if (camDirec == CameraLensDirection.back) {
        final frontCamera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.front,
          orElse: () => cameras.last,
        );
        description = frontCamera;
        camDirec = CameraLensDirection.front;
      } else {
        final backCamera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        );
        description = backCamera;
        camDirec = CameraLensDirection.back;
      }

      setState(() {});
      await initializeCamera();
    } catch (e) {
      _log.e('Toggle camera error', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: Colors.grey[50], body: _buildStep2());
  }

  // Step 2: Face Capture
  Widget _buildStep2() {
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

      // View for displaying rectangles around detected faces
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
      stackChildren.add(
        const Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    // Back button
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

    // Caution Dialog on first entry
    if (_showCautionDialog) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showCaptureInstructions();
      });
    }

    // Progress indicator for multi-angle capture
    if (_currentStep < faceAngles.length) {
      stackChildren.add(
        Positioned(
          top: 60,
          left: 0,
          right: 0,
          child: Card(
            margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            color: Colors.white.withValues(alpha: 0.9),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(
                    angleIcons[faceAngles[_currentStep]],
                    color: Colors.black,
                    size: 40,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    positionInstructions[_currentStep],
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      faceAngles.length,
                      (index) => Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              index < _currentStep
                                  ? Colors.green
                                  : index == _currentStep
                                  ? Colors.blue
                                  : Colors.grey[300],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Loading indicator overlay during pose hold
    if (_isHoldingPose) {
      stackChildren.add(
        Positioned.fill(
          child: Container(
            color: Colors.black.withValues(alpha: 0.5),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 80,
                    height: 80,
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      strokeWidth: 4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Menangkap embedding...\n${(_holdTimeRemaining / 1000).toStringAsFixed(1)}s',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Loading indicator overlay while model boots
    if (_isModelLoading) {
      stackChildren.add(
        Positioned.fill(
          child: Container(
            color: Colors.black.withValues(alpha: 0.8),
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 20),
                  Text(
                    'Menyiapkan Model AI...',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // View for displaying the bar to switch camera direction
    stackChildren.add(
      Positioned(
        bottom: 40,
        left: 0,
        right: 0,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                backgroundColor: Colors.white.withValues(alpha: 0.9),
                foregroundColor: Colors.black,
              ),
              onPressed: _toggleCameraDirection,
              child: const Icon(Icons.flip_camera_android_rounded, size: 28),
            ),

            const SizedBox(width: 16),

            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.9),
                foregroundColor: Colors.black,
              ),
              onPressed: () {
                setState(() {
                  _currentStep = 0;
                  embeddings.clear();
                  frontFace = null;
                  dialogShown = false;
                });
              },
              child: const Icon(Icons.refresh_rounded, size: 28),
            ),
          ],
        ),
      ),
    );

    return SafeArea(
      child: Container(
        color: Colors.black,
        child: Stack(children: stackChildren),
      ),
    );
  }

  void _showCaptureInstructions() {
    if (!_showCautionDialog) return;

    setState(() {
      _showCautionDialog = false;
    });

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            backgroundColor: Colors.white.withValues(alpha: 0.9),
            iconColor: Colors.black,
            icon: const Icon(Icons.info_outline, size: 48),
            title: const Text('Instruksi'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.visibility_off),
                  title: const Text('Lepas Aksesoris'),
                  dense: true,
                ),
                ListTile(
                  leading: const Icon(Icons.wb_sunny_outlined),
                  title: const Text('Pencahayaan Stabil'),
                  dense: true,
                ),
                ListTile(
                  leading: const Icon(Icons.face),
                  title: const Text('Ikuti Instruksi'),
                  dense: true,
                ),
                ListTile(
                  leading: const Icon(Icons.camera_alt),
                  title: const Text('5 Sudut Pandang'),
                  dense: true,
                ),
              ],
            ),
            actions: [
              Center(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Mulai Foto'),
                ),
              ),
            ],
          ),
    );
  }
}

class FaceDetectorPainter extends CustomPainter {
  final Size absoluteImageSize;
  final List<Face> faces;
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
          ..strokeWidth = 2.5
          ..color = Colors.deepPurple.shade300;

    for (final face in faces) {
      final double left =
          camDirection == CameraLensDirection.front
              ? (absoluteImageSize.width - face.boundingBox.right) * scaleX -
                  offsetX
              : face.boundingBox.left * scaleX - offsetX;
      final double top = face.boundingBox.top * scaleY - offsetY;
      final double right =
          camDirection == CameraLensDirection.front
              ? (absoluteImageSize.width - face.boundingBox.left) * scaleX -
                  offsetX
              : face.boundingBox.right * scaleX - offsetX;
      final double bottom = face.boundingBox.bottom * scaleY - offsetY;

      final rect = Rect.fromLTRB(left, top, right, bottom);
      final rRect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
      canvas.drawRRect(rRect, boxPaint);
    }
  }

  @override
  bool shouldRepaint(FaceDetectorPainter oldDelegate) => true;
}
