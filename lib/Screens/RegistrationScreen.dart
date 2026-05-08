import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
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
  final int _requiredValidFrames = 3;

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
    "Look straight into the camera",
    "Tilt your head slightly to the right",
    "Tilt your head slightly to the left",
    "Look down",
    "Look up",
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
    recognizer = Recognizer(numThreads: 2);
    await recognizer.init();
    if (!mounted) return;
    setState(() {
      _recognizerReady = recognizer.isReady;
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
      // Use smaller image for sharpness check - much faster
      final resized = img.copyResize(faceImage, width: 100);
      final grayImage = img.grayscale(resized);
      final laplacianImage = img.sobel(grayImage);
      final pixels = laplacianImage.getBytes();

      if (pixels.isEmpty) return false;

      double mean = pixels.reduce((a, b) => a + b) / pixels.length;
      double variance =
          pixels.map((p) => pow(p - mean, 2)).reduce((a, b) => a + b) /
          pixels.length;

      return variance > 1500; // Threshold for sharpness
    } catch (e) {
      print('Sharpness check error: $e');
      return true; // Assume sharp on error
    }
  }

  bool _isFaceProperlyAligned(Face face, int step) {
    switch (step) {
      case 0:
        return face.headEulerAngleY!.abs() < 10 &&
            face.headEulerAngleX!.abs() < 10 &&
            face.boundingBox.width > 80;
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
      if (frame == null || controller == null) {
        isBusy = false;
        return;
      }

      //TODO convert frame into InputImage format
      InputImage? inputImage = getInputImage();
      if (inputImage == null) {
        if (mounted) {
          setState(() {
            isBusy = false;
          });
        }
        return;
      }

      //TODO pass InputImage to face detection model and detect faces
      List<Face> faces = await faceDetector.processImage(inputImage);

      if (mounted) {
        setState(() {
          _scanResults = faces;
        });
      }

      if (faces.isNotEmpty && _isFaceProperlyAligned(faces[0], _currentStep)) {
        final tempImage =
            Platform.isIOS
                ? Util.convertBGRA8888ToImage(frame!)
                : Util.convertNV21(frame!);

        if (tempImage == null) {
          isBusy = false;
          return;
        }

        final rotated = img.copyRotate(
          tempImage,
          angle: camDirec == CameraLensDirection.front ? 270 : 90,
        );

        final faceBox = faces[0].boundingBox;
        if (faceBox.left < 0 ||
            faceBox.top < 0 ||
            faceBox.right > rotated.width ||
            faceBox.bottom > rotated.height) {
          isBusy = false;
          return;
        }

        final cropped = img.copyCrop(
          rotated,
          x: faceBox.left.toInt(),
          y: faceBox.top.toInt(),
          width: faceBox.width.toInt(),
          height: faceBox.height.toInt(),
        );

        // Check sharpness with small resized copy
        if (_isFaceSharp(cropped)) {
          _validFrameCount++;
          if (_validFrameCount >= _requiredValidFrames && !getEmb) {
            getEmb = true;
            _validFrameCount = 0;
            performFaceRecognition(faces[0], cropped);
          }
        } else {
          _validFrameCount = 0;
        }
      } else {
        _validFrameCount = 0;
      }

      isBusy = false;
    } catch (e) {
      print('Face detection error: $e');
      isBusy = false;
    }
  }

  void performFaceRecognition(Face face, img.Image cropped) async {
    if (!_recognizerReady) {
      if (mounted) {
        setState(() {
          isBusy = false;
        });
      } else {
        isBusy = false;
      }
      return;
    }

    recognitions.clear();

    // Store the first face (straight) as the profile image
    if (_currentStep == 0) {
      frontFace = cropped;
    }

    Recognition recognition = recognizer.recognize(cropped, face.boundingBox);
    embeddings.add(recognition.embeddings);

    print(
      'Captured embedding ${embeddings.length}/${faceAngles.length} for ${faceAngles[_currentStep]}',
    );

    if (!mounted) return;

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
            title: const Text('Confirm Registration'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Captured ${embeddings.length} face angles',
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
                child: const Text('Retake'),
              ),
              FilledButton(
                onPressed: () {
                  recognizer.registerFaceInDB(
                    userName,
                    embeddings,
                    Uint8List.fromList(img.encodeBmp(croppedFace)),
                  );
                  _currentStep = 0;
                  embeddings.clear();
                  frontFace = null;
                  dialogShown = false;
                  Navigator.pop(context);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Face Registered Successfully!'),
                    ),
                  );
                },
                child: const Text('Confirm'),
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
    return CustomPaint(painter: painter);
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
