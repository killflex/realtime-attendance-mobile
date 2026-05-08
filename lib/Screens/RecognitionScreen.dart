import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:realtime_attendance_mobile/ML/Recognizer.dart';
import 'package:realtime_attendance_mobile/Util.dart';

import '../ML/Recognition.dart';
import '../main.dart';

class RecognitionScreen extends StatefulWidget {
  const RecognitionScreen({super.key});

  @override
  State<RecognitionScreen> createState() => _RecognitionScreenState();
}

class _RecognitionScreenState extends State<RecognitionScreen> {
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
  static const _skipFrames = 2; // Skip 2 frames between processing

  @override
  void initState() {
    super.initState();

    // Set initial camera description
    _initializeCameraDescription();

    //TODO initialize face detector
    final options = FaceDetectorOptions(performanceMode: FaceDetectorMode.fast);
    faceDetector = FaceDetector(options: options);

    //TODO initialize face recognizer
    _initRecognizer();

    //TODO initialize camera footage
    initializeCamera();
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
    // Check if cameras are available
    if (cameras.isEmpty) {
      print('No cameras available on this device');
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
      print('Error initializing camera: $e');
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
            content: Text('No cameras available on this device'),
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
        imageFormatGroup:
            Platform.isAndroid
                ? ImageFormatGroup
                    .nv21 // for Android
                : ImageFormatGroup.yuv420, // for iOS
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
      print('Error initializing camera: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Camera initialization failed: $e'),
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
    faceDetector.close();
    recognizer.close();
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
      print(" Detected Faces: ${faces.length} ");

      //TODO perform face recognition on detected faces
      await performFaceRecognition(faces);
    } catch (e) {
      print('Error in face detection: $e');
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
        if (mounted) {
          setState(() {
            isBusy = false;
          });
        }
        return;
      }

      recognitions.clear();

      // Limit number of faces to process for better performance
      final facesToProcess = faces.take(3).toList();

      if (frame == null) {
        if (mounted) {
          setState(() {
            isBusy = false;
          });
        }
        return;
      }

      //TODO convert CameraImage to Image and rotate it so that our frame will be in a portrait
      image =
          Platform.isIOS
              ? Util.convertBGRA8888ToImage(frame!)
              : Util.convertNV21(frame!);

      if (image == null) {
        if (mounted) {
          setState(() {
            isBusy = false;
          });
        }
        return;
      }

      image = img.copyRotate(
        image!,
        angle: camDirec == CameraLensDirection.front ? 270 : 90,
      );

      for (Face face in facesToProcess) {
        Rect faceRect = face.boundingBox;

        // Validate face rect bounds
        if (faceRect.left < 0 ||
            faceRect.top < 0 ||
            faceRect.right > image!.width ||
            faceRect.bottom > image!.height) {
          continue;
        }

        // Additional validation for crop dimensions
        if (faceRect.width <= 0 || faceRect.height <= 0) {
          continue;
        }

        try {
          //TODO crop face
          img.Image croppedFace = img.copyCrop(
            image!,
            x: faceRect.left.toInt(),
            y: faceRect.top.toInt(),
            width: faceRect.width.toInt(),
            height: faceRect.height.toInt(),
          );

          //TODO pass cropped face to face recognition model
          Recognition recognition = recognizer.recognize(croppedFace, faceRect);

          if (recognition.distance < 1 && recognition.distance >= 0) {
            recognitions.add(recognition);
            print(
              'Recognized: ${recognition.name} with distance: ${recognition.distance}',
            );
          } else {
            recognition.name = "Unknown";
            print('Face not recognized. Distance: ${recognition.distance}');
          }
        } catch (e) {
          print('Error processing face: $e');
          continue;
        }
      }

      if (mounted) {
        setState(() {
          isBusy = false;
          _scanResults = recognitions;
        });
      }
    } catch (e) {
      print('Error in face recognition: $e');
      if (mounted) {
        setState(() {
          isBusy = false;
        });
      }
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
    // Check if cameras are available
    if (cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No cameras available on this device'),
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
            content: Text('Only one camera available on this device'),
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
      print('Error toggling camera: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to switch camera: $e'),
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
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('Back'),
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
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              backgroundColor: Colors.white.withOpacity(0.9),
              foregroundColor: Colors.black,
            ),
            onPressed: _toggleCameraDirection,
            icon: const Icon(Icons.flip_camera_android_rounded, size: 28),
            label: const Text('Flip Camera', style: TextStyle(fontSize: 16)),
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
          ..color = const Color(0xFF212121).withOpacity(0.85);

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
              ? '${face.name} (${face.distance.toStringAsFixed(2)})'
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
