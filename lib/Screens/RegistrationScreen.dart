import 'dart:io';
import 'dart:nativewrappers/_internal/vm/lib/math_patch.dart';
import 'dart:ui';

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
  State<RegistrationScreen> createState() => _RecognitionScreenState();
}

class _RecognitionScreenState extends State<RegistrationScreen> {
  dynamic controller;
  bool isBusy = false;
  late Size size;
  late CameraDescription description = cameras[1];
  late List<Recognition> recognitions = [];
  late img.Image croppedFace;
  img.Image? image;
  CameraLensDirection camDirec = CameraLensDirection.front;
  dynamic _scanResults;
  CameraImage? frame;

  //TODO declare face detector
  late FaceDetector faceDetector;

  //TODO declare face recognizer
  late Recognizer recognizer;

  int _currentStep = 0;
  int _validFrameCount = 0;
  final int _requiredValidFrames = 3;

  List<String> faceAngles = ["straight", "left", "right", "up", "down"];

  final Map<String, IconData> angleIcons = {
    "straight": Icons.face,
    "left": Icons.rotate_left,
    "right": Icons.rotate_right,
    "up": Icons.arrow_upward,
    "down": Icons.arrow_downward,
  };

  bool getEmb = false;
  img.Image? frontFace;

  List<List<double>> embeddings = [];

  int registrationStep = 0;

  List<String> positionInstructions = [
    "Look straight into the camera",
    "Tilt your head slightly to the left",
    "Tilt your head slightly to the right",
    "Look up",
    "Look down",
  ];

  bool dialogShown = false;
  bool register = false;

  @override
  void initState() {
    super.initState();

    //TODO initialize face detector
    final options = FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
    );
    faceDetector = FaceDetector(options: options);

    //TODO initialize face recognizer
    recognizer = Recognizer(numThreads: 2);

    //TODO initialize camera footage
    initializeCamera();
  }

  //TODO code to initialize the camera feed
  initializeCamera() async {
    controller = CameraController(
      description,
      ResolutionPreset.medium,
      imageFormatGroup:
          Platform.isAndroid
              ? ImageFormatGroup
                  .nv21 // for Android
              : ImageFormatGroup.bgra8888,
      enableAudio: false,
    ); // for iOS);
    await controller.initialize().then((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        controller;
      });
      controller.startImageStream(
        (image) => {
          if (!isBusy) {isBusy = true, frame = image, doFaceDetectionOnFrame()},
        },
      );
    });
  }

  //TODO close all resources
  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  bool _isFaceSharp(img.Image faceImage) {
    final grayImage = img.grayscale(faceImage);
    final laplacianImage = img.sobel(grayImage);
    final pixels = laplacianImage.getBytes();

    double mean = pixels.reduce((a, b) => a + b) / pixels.length;
    double variance =
        pixels.map((p) => pow(p - mean, 2)).reduce((a, b) => a + b) /
        pixels.length;

    return variance > 1500; // Threshold for sharpness
  }

  bool _isFaceProperlyAligned(Face face, int step) {
    switch (step) {
      case 0: // straight
        return face.headEulerAngleY!.abs() < 10 &&
            face.headEulerAngleX!.abs() < 10 &&
            face.boundingBox.width > 80;
      case 1: // left
        return face.headEulerAngleY! < -15;
      case 2: // right
        return face.headEulerAngleY! > 15;
      case 3: // up
        return face.headEulerAngleX! < -15;
      case 4: // down
        return face.headEulerAngleX! > 15;
      default:
        return false;
    }
  }

  //TODO face detection on a frame
  doFaceDetectionOnFrame() async {
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
    // _scanResults = faces;

    if (faces.isNotEmpty && _isFaceProperlyAligned(faces[0], _currentStep)) {
      final tempImage =
          Platform.isIOS
              ? Util.convertBGRA8888ToImage(frame!)
              : Util.convertNV21(frame!);
      final rotated = img.copyRotate(
        tempImage,
        angle: camDirec == CameraLensDirection.front ? 270 : 90,
      );
      final cropped = img.copyCrop(
        rotated,
        x: faces[0].boundingBox.left.toInt(),
        y: faces[0].boundingBox.top.toInt(),
        width: faces[0].boundingBox.width.toInt(),
        height: faces[0].boundingBox.height.toInt(),
      );

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
  }

  void performFaceRecognition(Face face, img.Image cropped) async {
    recognitions.clear();

    image =
        Platform.isIOS
            ? Util.convertBGRA8888ToImage(frame!)
            : Util.convertNV21(frame!);
    image = img.copyRotate(
      image!,
      angle: camDirec == CameraLensDirection.front ? 270 : 90,
    );

    frontFace ??= croppedFace;

    Recognition recognition = recognizer.recognize(cropped, face.boundingBox);
    embeddings.add(recognition.embeddings);

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
      _scanResults = recognitions;
    });
  }

  //TODO Face Registration Dialogue
  TextEditingController textEditingController = TextEditingController();
  showFaceRegistrationDialogue(img.Image croppedFace) {
    dialogShown = true;
    textEditingController.clear();
    showDialog(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 60,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .2),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          "Register Your Face",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 20),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(100),
                          child: Image.memory(
                            Uint8List.fromList(img.encodeBmp(croppedFace)),
                            width: 150,
                            height: 150,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: textEditingController,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: "Enter your name",
                            hintStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.white.withAlpha(80),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              recognizer.registerFaceInDB(
                                textEditingController.text.trim(),
                                embeddings,
                                Uint8List.fromList(img.encodeBmp(croppedFace)),
                              );
                              Navigator.pop(context);
                              Navigator.pop(context); // Close dialog
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text("Face Registered"),
                                ),
                              );
                            },
                            icon: const Icon(Icons.check),
                            label: const Text("Register"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.deepPurple.shade300,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
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
    final camera =
        camDirec == CameraLensDirection.front ? cameras[1] : cameras[0];
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
        !controller.value.isInitialized) {
      return const Center(child: Text('Camera is not initialized'));
    }

    // Get the camera preview size (already rotated for portrait)
    final cameraPreviewSize = Size(
      controller.value.previewSize!.height,
      controller.value.previewSize!.width,
    );

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
      _scanResults,
      camDirec,
      displayedSize,
      screenSize,
    );
    return CustomPaint(painter: painter);
  }

  //TODO toggle camera direction
  void _toggleCameraDirection() async {
    if (camDirec == CameraLensDirection.back) {
      camDirec = CameraLensDirection.front;
      description = cameras[1];
    } else {
      camDirec = CameraLensDirection.back;
      description = cameras[0];
    }
    await controller.stopImageStream();
    setState(() {
      controller;
    });
    initializeCamera();
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> stackChildren = [];
    size = MediaQuery.of(context).size;
    if (controller != null) {
      //TODO View for displaying the live camera footage
      stackChildren.add(
        Positioned.fill(
          child: Container(
            child:
                (controller.value.isInitialized)
                    ? FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: controller.value.previewSize!.height,
                        height: controller.value.previewSize!.width,
                        child: CameraPreview(controller),
                      ),
                    )
                    : Container(),
          ),
        ),
      );

      //TODO View for displaying rectangles around detected aces
      stackChildren.add(
        Positioned(
          top: 0.0,
          left: 0.0,
          width: size.width,
          height: size.height,
          child: buildResult(),
        ),
      );
    }

    //TODO View for displaying the bar to switch camera direction or for registering faces
    stackChildren.add(
      Positioned(
        bottom: 40,
        left: 20,
        right: 20,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.deepPurple.withAlpha(80),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: .2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: IconButton(
                      icon: Icon(Icons.cached, color: Colors.white),
                      iconSize: 40,
                      color: Colors.black,
                      onPressed: () {
                        _toggleCameraDirection();
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: IconButton(
                      icon: Icon(
                        Icons.face_retouching_natural,
                        color: Colors.white,
                      ),
                      iconSize: 40,
                      color: Colors.black,
                      onPressed: () {
                        register = true;
                      },
                    ),
                  ),
                ],
              ),
            ),
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
