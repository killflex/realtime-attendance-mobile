import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:realtime_attendance_mobile/ML/Recognizer.dart';
import 'package:realtime_attendance_mobile/Screens/HomeScreen.dart';
import 'package:realtime_attendance_mobile/Util.dart';

import '../ML/Recognition.dart';
import '../main.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  // Page Controller for two-step process
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Form Controllers and State - Step 1
  final _formKey = GlobalKey<FormState>();
  final _namaLengkapController = TextEditingController();
  String? _selectedStatus;
  String? _selectedUnitType;
  String? _selectedUnit;
  final _identityController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();

  // Unit Kerja Data
  final Map<String, List<String>> _unitKerjaData = {
    'UPA': ['Bahasa', 'Kewirausahaan', 'Perpustakaan', 'TIK'],
    'Lembaga': ['LPPM', 'LPMPP'],
    'Fakultas': ['Ilmu Komputer', 'Ekonomi dan Bisnis', 'Teknik', 'Hukum'],
  };

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

  //TODO declare face detector
  late FaceDetector faceDetector;

  //TODO declare face recognizer
  late Recognizer recognizer;
  bool _recognizerReady = false;

  // Performance optimization
  DateTime? _lastProcessedTime;
  static const _processingInterval = Duration(
    milliseconds: 500,
  ); // Slower for registration
  int _skipFrameCount = 0;
  static const _skipFrames = 3; // Skip more frames during registration

  int _currentStep = 0;
  int _validFrameCount = 0;
  final int _requiredValidFrames = 1; // 1 sharp frame is enough; throttling already limits rate

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
    "Tengok sedikit ke kanan",
    "Tengok sedikit ke kiri",
    "Lihat ke bawah",
    "Lihat ke atas",
  ];

  bool dialogShown = false;
  bool register = false;

  @override
  void initState() {
    super.initState();

    // Initialize camera description safely
    _initializeCameraDescription();

    //TODO initialize face detector
    final options = FaceDetectorOptions(performanceMode: FaceDetectorMode.fast);
    faceDetector = FaceDetector(options: options);

    //TODO initialize face recognizer
    _initRecognizer();

    // Camera will be initialized when moving to Step 2
  }

  Future<void> _initRecognizer() async {
    print('[REG] _initRecognizer: start');
    try {
      recognizer = Recognizer(numThreads: 2);
      print('[REG] _initRecognizer: Recognizer object created, calling init()...');
      await recognizer.init();
      print('[REG] _initRecognizer: init() complete. isReady=${recognizer.isReady}');
      if (!mounted) {
        print('[REG] _initRecognizer: widget not mounted after init — skipping setState');
        return;
      }
      setState(() {
        _recognizerReady = recognizer.isReady;
      });
      print('[REG] _initRecognizer: _recognizerReady set to $_recognizerReady');
    } catch (e, st) {
      print('[REG] _initRecognizer ERROR: $e\n$st');
    }
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
      print('Error initializing camera: $e');
      if (cameras.isNotEmpty) {
        description = cameras.first;
        camDirec = description.lensDirection;
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _namaLengkapController.dispose();
    _identityController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    controller?.dispose();
    faceDetector.close();
    recognizer.close();
    super.dispose();
  }

  // Step 1 Methods - Form Validation and Navigation
  String _getIdentityLabel() {
    if (_selectedStatus == 'Mahasiswa') return 'NPM';
    return 'NIP';
  }

  void _nextStep() {
    if (_formKey.currentState!.validate()) {
      // Initialize camera when moving to Step 2
      initializeCamera();
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      setState(() {
        _currentPage = 1;
      });
    }
  }

  void _previousStep() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    setState(() {
      _currentPage = 0;
    });
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
        imageFormatGroup:
            Platform.isAndroid
                ? ImageFormatGroup.nv21
                : ImageFormatGroup.yuv420,
        enableAudio: false,
      );

      await controller!.initialize();

      if (!mounted) return;

      setState(() {});

      controller!.startImageStream((image) {
        if (!isBusy) {
          // Throttle with time and frame skipping
          final now = DateTime.now();
          if (_lastProcessedTime == null ||
              now.difference(_lastProcessedTime!) > _processingInterval) {
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
      print('Camera init error: $e');
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

      double variance = 0.0;
      for (int y = 0; y < resized.height; y++) {
        for (int x = 0; x < resized.width; x++) {
          final p = resized.getPixel(x, y);
          final luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
          variance += (luma - mean) * (luma - mean);
        }
      }
      variance /= total;

      print('[REG] sharpness variance=${variance.toStringAsFixed(1)} (threshold=50)');
      return variance > 50; // Lowered threshold — mobile cameras are generally adequate
    } catch (e) {
      print('[REG] Sharpness check error: $e — assuming sharp');
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
      if (frame == null || controller == null) { isBusy = false; return; }

      InputImage? inputImage = getInputImage();
      if (inputImage == null) { isBusy = false; return; }

      List<Face> faces = await faceDetector.processImage(inputImage);
      if (mounted) setState(() => _scanResults = faces);

      print('[REG] faces=${faces.length}, step=$_currentStep, validFrames=$_validFrameCount');

      if (faces.isEmpty) { _validFrameCount = 0; isBusy = false; return; }

      final face = faces[0];
      final aligned = _isFaceProperlyAligned(face, _currentStep);
      print('[REG] aligned=$aligned eulerY=${face.headEulerAngleY?.toStringAsFixed(1)} eulerX=${face.headEulerAngleX?.toStringAsFixed(1)}');

      if (!aligned) { _validFrameCount = 0; isBusy = false; return; }

      // Step 1: Convert NV21 → landscape image (raw, no rotation)
      img.Image? tempImage;
      if (Platform.isIOS) {
        tempImage = await compute(Util.convertBGRA8888ToImage, frame!);
      } else {
        tempImage = await compute(Util.convertNV21, frame!);
      }
      if (tempImage == null) { isBusy = false; return; }

      // Step 2: Transform ML Kit portrait bbox → landscape coordinates
      // ML Kit returns bbox in portrait (rotated) space. Transform back to avoid
      // rotating the full ~3MB frame — instead we only rotate the small crop.
      final faceBox = face.boundingBox;
      final Rect lsBox = _portraitBoxToLandscape(
        faceBox, tempImage.width, tempImage.height,
      );

      final int left   = lsBox.left.clamp(0.0,  (tempImage.width  - 1).toDouble()).toInt();
      final int top    = lsBox.top.clamp(0.0,   (tempImage.height - 1).toDouble()).toInt();
      final int right  = lsBox.right.clamp((left + 1).toDouble(),  tempImage.width.toDouble()).toInt();
      final int bottom = lsBox.bottom.clamp((top  + 1).toDouble(), tempImage.height.toDouble()).toInt();
      final int cropW  = right - left;
      final int cropH  = bottom - top;

      if (cropW <= 0 || cropH <= 0) {
        print('[REG] Invalid crop: ${cropW}x$cropH');
        isBusy = false; return;
      }

      // Step 3: Crop SMALL region from landscape (cheap, ~200x200px vs 720x480)
      final img.Image croppedLandscape = img.copyCrop(
        tempImage, x: left, y: top, width: cropW, height: cropH,
      );

      // Step 4: Rotate only the small crop to portrait orientation
      final img.Image cropped = img.copyRotate(
        croppedLandscape,
        angle: camDirec == CameraLensDirection.front ? 270 : 90,
      );

      print('[REG] portrait_bbox=$faceBox  cropSize=${cropped.width}x${cropped.height}');

      if (_isFaceSharp(cropped)) {
        _validFrameCount++;
        print('[REG] Sharp frame! validFrameCount=$_validFrameCount/$_requiredValidFrames');
        if (_validFrameCount >= _requiredValidFrames && !getEmb) {
          getEmb = true;
          _validFrameCount = 0;
          performFaceRecognition(face, cropped);
        }
      } else {
        print('[REG] Face not sharp, skipping');
        _validFrameCount = 0;
      }

      isBusy = false;
    } catch (e, st) {
      print('Face detection error: $e\n$st');
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
      final left   = (lsW - 1 - p.bottom).clamp(0.0, (lsW - 1).toDouble());
      final top    = p.left.clamp(0.0, (lsH - 1).toDouble());
      final right  = (lsW - 1 - p.top).clamp(left + 1, lsW.toDouble());
      final bottom = p.right.clamp(top + 1, lsH.toDouble());
      return Rect.fromLTRB(left, top, right, bottom);
    } else {
      // 90° CW: landscape_sx = py, landscape_sy = lsH-1-px
      final left   = p.top.clamp(0.0, (lsW - 1).toDouble());
      final top    = (lsH - 1 - p.right).clamp(0.0, (lsH - 1).toDouble());
      final right  = p.bottom.clamp(left + 1, lsW.toDouble());
      final bottom = (lsH - 1 - p.left).clamp(top + 1, lsH.toDouble());
      return Rect.fromLTRB(left, top, right, bottom);
    }
  }


  void performFaceRecognition(Face face, img.Image cropped) async {
    // Check recognizer.isReady directly — do NOT rely on _recognizerReady cache
    // because initState() calls _initRecognizer() async without await, creating
    // a race condition where setState may not have fired yet.
    print('[REG] performFaceRecognition: isReady=${recognizer.isReady}, _recognizerReady=$_recognizerReady');
    if (!recognizer.isReady) {
      print('[REG] Recognizer not ready — waiting and retrying once...');
      // Wait briefly and try once more in case model is mid-load
      await Future.delayed(const Duration(milliseconds: 300));
      if (!recognizer.isReady) {
        print('[REG] Recognizer still not ready after wait. Aborting.');
        isBusy = false;
        getEmb = false;
        return;
      }
    }
    // Sync the state flag if it was stale
    if (!_recognizerReady && mounted) {
      setState(() => _recognizerReady = true);
    }

    try {
      recognitions.clear();

      // Store the first face (straight) as the profile image
      if (_currentStep == 0) {
        frontFace = cropped;
      }

      Recognition recognition = recognizer.recognize(cropped, face.boundingBox);

      // NaN guard: jika model menghasilkan NaN, coba frame berikutnya
      if (recognition.distance == -2) {
        print('[REG] ⚠️ NaN embedding untuk step $_currentStep — retrying next frame');
        if (mounted) {
          setState(() {
            isBusy = false;
            getEmb = false;
          });
        } else {
          isBusy = false;
          getEmb = false;
        }
        return;
      }

      // Guard: if embedding is all zeros, model failed silently
      final bool embValid = recognition.embeddings.any((v) => v != 0.0);
      if (!embValid) {
        print('[REG] WARNING: embedding is all zeros — model inference may have failed');
      }

      embeddings.add(recognition.embeddings);
      print(
        '[REG] ✅ Captured embedding ${embeddings.length}/${faceAngles.length} for step $_currentStep (${faceAngles[_currentStep]}) | emb[0]=${recognition.embeddings[0].toStringAsFixed(4)}',
      );

      if (!mounted) {
        getEmb = false;
        return;
      }

      setState(() {
        if (_currentStep < faceAngles.length - 1) {
          _currentStep++;
        } else {
          if (!dialogShown) {
            showFaceRegistrationDialogue(frontFace!);
          }
        }
        isBusy = false;
        getEmb = false;
      });
    } catch (e, st) {
      // CRITICAL: always reset getEmb so subsequent frames are not permanently blocked
      print('[REG] performFaceRecognition ERROR: $e\n$st');
      if (mounted) {
        setState(() {
          isBusy = false;
          getEmb = false;
        });
      } else {
        isBusy = false;
        getEmb = false;
      }
    }
  }

  //TODO Face Registration Dialogue
  TextEditingController textEditingController = TextEditingController();
  showFaceRegistrationDialogue(img.Image croppedFace) {
    dialogShown = true;
    String userName = _namaLengkapController.text.trim();

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
                  Card.outlined(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildInfoRow('Nama', userName),
                          const Divider(height: 16),
                          _buildInfoRow('Status', _selectedStatus ?? '-'),
                          const Divider(height: 16),
                          _buildInfoRow('Unit', _selectedUnit ?? '-'),
                          const Divider(height: 16),
                          _buildInfoRow(
                            _getIdentityLabel(),
                            _identityController.text,
                          ),
                        ],
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
                  final String name = userName;
                  final List<List<double>> embs =
                      List<List<double>>.from(embeddings);
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
                    print('[REG] registerFaceInDB FAILED: $e');
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

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF09090b),
          ),
        ),
      ],
    );
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

    final camera = cameras.firstWhere(
      (cam) => cam.lensDirection == camDirec,
      orElse: () => description,
    );
    final sensorOrientation = camera.sensorOrientation;

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
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
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(frame!.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
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

  void startFaceRegistration() {
    embeddings.clear();
    registrationStep = 0;
    promptForNextPosition();
  }

  void promptForNextPosition() {
    if (registrationStep < positionInstructions.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(positionInstructions[registrationStep]),
          duration: const Duration(seconds: 2),
        ),
      );
      registrationStep++;
    } else {
      // Registration complete
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Face registration complete!")),
      );
    }
  }

  void captureEmbedding(Recognition recognition) {
    embeddings.add(recognition.embeddings);
    registrationStep++;

    if (registrationStep < positionInstructions.length) {
      promptForNextPosition();
    } else {
      // All embeddings captured, proceed to save
      completeRegistration();
    }
  }

  void completeRegistration() {
    recognizer.registerFaceInDB(
      textEditingController.text,
      embeddings,
      Uint8List.fromList(img.encodeBmp(frontFace!)),
    );

    textEditingController.clear();
    dialogShown = false;
    Navigator.pop(context); // Close dialog

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Face Registered Successfully with Multiple Angles!"),
      ),
    );

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const HomeScreen()),
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

      _skipFrameCount = 0;
      _lastProcessedTime = null;

      setState(() {});
      await initializeCamera();
    } catch (e) {
      print('Toggle camera error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF09090b)),
          onPressed: () {
            if (_currentPage == 1) {
              _previousStep();
            } else {
              Navigator.pop(context);
            }
          },
        ),
        title: Text(
          _currentPage == 0
              ? 'Registration - User Data'
              : 'Registration - Face Capture',
          style: const TextStyle(
            color: Color(0xFF09090b),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE5E7EB), height: 1),
        ),
      ),
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        onPageChanged: (page) {
          setState(() {
            _currentPage = page;
          });
        },
        children: [_buildStep1(), _buildStep2()],
      ),
    );
  }

  // Step 1: User Data Form
  Widget _buildStep1() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              const Text(
                'Personal Information',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF09090b),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Please fill in your information to proceed with face registration.',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
              ),
              const SizedBox(height: 24),

              // Nama Lengkap (Full Name)
              const Text(
                'Nama Lengkap',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF09090b),
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _namaLengkapController,
                keyboardType: TextInputType.name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Enter your full name',
                  hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: Color(0xFF09090b),
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your full name';
                  }
                  if (value.length < 3) {
                    return 'Name must be at least 3 characters';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Status Dropdown
              const Text(
                'Status',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF09090b),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                decoration: InputDecoration(
                  hintText: 'Select your status',
                  hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: Color(0xFF09090b),
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                items:
                    ['Dosen', 'Tendik', 'Mahasiswa']
                        .map(
                          (status) => DropdownMenuItem(
                            value: status,
                            child: Text(status),
                          ),
                        )
                        .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedStatus = value;
                    // Auto-select Fakultas for Mahasiswa
                    if (value == 'Mahasiswa') {
                      _selectedUnitType = 'Fakultas';
                    } else {
                      _selectedUnitType = null;
                    }
                    _selectedUnit = null;
                  });
                },
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please select your status';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Unit Type Dropdown
              const Text(
                'Unit Type',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF09090b),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _selectedUnitType,
                decoration: InputDecoration(
                  hintText: 'Select unit type',
                  hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: Color(0xFF09090b),
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                items:
                    (_selectedStatus == 'Mahasiswa'
                            ? ['Fakultas']
                            : ['UPA', 'Lembaga', 'Fakultas'])
                        .map(
                          (type) =>
                              DropdownMenuItem(value: type, child: Text(type)),
                        )
                        .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedUnitType = value;
                    _selectedUnit = null;
                  });
                },
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please select unit type';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Cascading Unit Kerja Dropdown
              if (_selectedUnitType != null) ...[
                const Text(
                  'Unit Kerja',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF09090b),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  decoration: InputDecoration(
                    hintText: 'Select unit kerja',
                    hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: Color(0xFF09090b),
                        width: 2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  items:
                      _unitKerjaData[_selectedUnitType]!
                          .map(
                            (unit) => DropdownMenuItem(
                              value: unit,
                              child: Text(unit),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedUnit = value;
                    });
                  },
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please select unit kerja';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 20),
              ],

              // Dynamic Identity Field (NIP/NPM)
              Text(
                _getIdentityLabel(),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF09090b),
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _identityController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: 'Enter your ${_getIdentityLabel()}',
                  hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: Color(0xFF09090b),
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your ${_getIdentityLabel()}';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Phone Number
              const Text(
                'Phone Number',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF09090b),
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  hintText: 'Enter your phone number',
                  hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: Color(0xFF09090b),
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your phone number';
                  }
                  if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
                    return 'Please enter a valid phone number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Email
              const Text(
                'Email',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF09090b),
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: 'Enter your email',
                  hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: Color(0xFF09090b),
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your email';
                  }
                  if (!RegExp(
                    r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$',
                  ).hasMatch(value)) {
                    return 'Please enter a valid email';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 32),

              // Next Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _nextStep,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF09090b),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Next: Face Capture',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
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
      stackChildren.add(
        const Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

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
            margin: const EdgeInsets.symmetric(horizontal: 20),
            color: Colors.white.withOpacity(0.9),
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

    //TODO View for displaying the bar to switch camera direction
    stackChildren.add(
      Positioned(
        bottom: 40,
        left: 0,
        right: 0,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FloatingActionButton(
              heroTag: 'flip',
              backgroundColor: Colors.white,
              onPressed: _toggleCameraDirection,
              child: const Icon(
                Icons.flip_camera_android_rounded,
                color: Colors.black,
              ),
            ),
            const SizedBox(width: 16),
            FloatingActionButton(
              heroTag: 'reset',
              backgroundColor: Colors.white,
              onPressed: () {
                setState(() {
                  _currentStep = 0;
                  embeddings.clear();
                  frontFace = null;
                  dialogShown = false;
                });
              },
              child: const Icon(Icons.refresh_rounded, color: Colors.black),
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
            icon: const Icon(Icons.info_outline, size: 48),
            title: const Text('Capture Instructions'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.visibility_off),
                  title: const Text('Remove glasses'),
                  dense: true,
                ),
                ListTile(
                  leading: const Icon(Icons.wb_sunny_outlined),
                  title: const Text('Good lighting'),
                  dense: true,
                ),
                ListTile(
                  leading: const Icon(Icons.face),
                  title: const Text('Follow instructions'),
                  dense: true,
                ),
                ListTile(
                  leading: const Icon(Icons.camera_alt),
                  title: const Text('5 different angles'),
                  dense: true,
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Start Capture'),
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

    final Paint labelBgPaint =
        Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.deepPurple.shade300.withAlpha(150);

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
