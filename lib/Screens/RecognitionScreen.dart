import 'dart:io';
import 'dart:ui';

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
  dynamic controller;
  bool isBusy = false;
  late Size size;
  late CameraDescription description = cameras[1];
  late List<Recognition> recognitions = [];
  CameraLensDirection camDirec = CameraLensDirection.front;

  //TODO declare face detector
  late FaceDetector faceDetector;

  //TODO declare face recognizer
  late Recognizer recognizer;

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

  //TODO face detection on a frame
  dynamic _scanResults;
  CameraImage? frame;
  doFaceDetectionOnFrame() async {
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
    performFaceRecognition(faces);
  }

  img.Image? image;
  //TODO perform Face Recognition
  performFaceRecognition(List<Face> faces) async {
    recognitions.clear();

    //TODO convert CameraImage to Image and rotate it so that our frame will be in a portrait
    image =
        Platform.isIOS
            ? Util.convertBGRA8888ToImage(frame!)
            : Util.convertNV21(frame!);
    image = img.copyRotate(
      image!,
      angle: camDirec == CameraLensDirection.front ? 270 : 90,
    );

    for (Face face in faces) {
      Rect faceRect = face.boundingBox;
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
    }

    if (mounted) {
      setState(() {
        isBusy = false;
        _scanResults = recognitions;
      });
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
          ..strokeWidth = 2.5
          ..color = Colors.deepPurple.shade300;

    final Paint labelBgPaint =
        Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.deepPurple.shade300.withAlpha(150);

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
