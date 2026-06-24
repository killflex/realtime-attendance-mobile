import 'dart:async';
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
  static const double _liveThresholdOffset = 0.0;

  final List<String> _recognitionHistory = [];
  static const int _historyWindowSize = 5;

  // Performance tracking
  late PerformanceTracker _performanceTracker;
  double _displayLatency = 0.0;
  double _displayFps = 0.0;
  double _livePreMs = 0.0;
  double _liveInferMs = 0.0;
  double _livePostMs = 0.0;
  bool _isRecordingTelemetry = false;
  DateTime? _lastFpsMark;
  int _fpsFrames = 0;
  int _totalFramesReceived = 0;
  
  // Camera stream FPS tracking
  int _cameraFpsFrames = 0;
  DateTime? _lastCameraFpsMark;
  double _cameraFps = 0.0;

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

    // Initialize performance tracker
    _performanceTracker = PerformanceTracker();

    // Chain: recognizer init → isolate init → camera start
    // This prevents a race condition where _initIsolate reads `recognizer.modelName`
    // before `recognizer` is assigned from getIt.
    _initRecognizerThenIsolate();
  }

  Future<void> _initRecognizerThenIsolate() async {
    await _initRecognizer();
    await _initIsolate();
    // Start camera only after both are ready so the first frame
    // already has a live isolate available.
    if (mounted) initializeCamera();
  }

  Future<void> _initRecognizer() async {
    try {
      recognizer = getIt<Recognizer>();
      await recognizer.init();
      if (!mounted) return;
      setState(() {
        _recognizerReady = recognizer.isReady;
      });
      if (!recognizer.isReady) {
        _log.w('[REC] recognizer.init() completed but isReady=false. Will retry once.');
        // Single retry: close and re-open the interpreter
        await recognizer.loadModel();
        if (mounted) {
          setState(() {
            _recognizerReady = recognizer.isReady;
          });
        }
      }
    } catch (e, st) {
      _log.e('[REC] _initRecognizer failed', e, st);
      // Do not crash the screen; pipeline will show 'Loading...' boxes
      // and the user can see the error label.
    }
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
        // Track raw camera feed FPS
        _cameraFpsFrames++;
        final now = DateTime.now();
        _lastCameraFpsMark ??= now;
        if (now.difference(_lastCameraFpsMark!).inMilliseconds >= 1000) {
          if (mounted) {
            setState(() {
              _cameraFps = _cameraFpsFrames.toDouble();
            });
          }
          _cameraFpsFrames = 0;
          _lastCameraFpsMark = now;
        }

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
    _telemetryCountdownTimer?.cancel();
    controller?.dispose();
    _recognitionIsolate?.kill(priority: Isolate.beforeNextEvent);
    _isolateReceivePort?.close();
    super.dispose();
  }

  //TODO face detection on a frame
  List<Recognition>? _scanResults;
  CameraImage? frame;

  Future<void> doFaceDetectionOnFrame() async {
    _totalFramesReceived++;
    if (_totalFramesReceived % 60 == 0) {
      _log.i('Received frame #$_totalFramesReceived. isBusy=$isBusy, frameSize=${frame?.width}x${frame?.height}, format=${frame?.format.raw}');
    }
    try {
      final sTotal = Stopwatch()..start();

      // Time frame conversion
      final sFrameConv = Stopwatch()..start();
      final inputImage = getInputImage();
      sFrameConv.stop();

      if (inputImage == null) {
        if (mounted) {
          setState(() {
            isBusy = false;
          });
        }
        return;
      }

      // Time ML Kit face detection
      final sDetect = Stopwatch()..start();
      final faces = await faceDetector.processImage(inputImage);
      sDetect.stop();
      _log.d('Detected faces: ${faces.length}');

      final double detectMs = sDetect.elapsedMicroseconds / 1000.0;

      Recognition? recognitionResult;
      if (faces.isNotEmpty) {
        recognitionResult = await performFaceRecognition(faces, detectMs);
      } else {
        if (mounted) {
          setState(() {
            isBusy = false;
            _scanResults = null;
            _recognitionHistory.clear();
          });
        }
      }
      sTotal.stop();

      final double totalMs = sTotal.elapsedMicroseconds / 1000.0;

      double finalPrepMs = detectMs;
      double finalInferMs = 0.0;
      double finalPostMs = 0.0;
      double finalTotalMs = totalMs;

      if (recognitionResult != null) {
        finalPrepMs = recognitionResult.prepMs ?? detectMs;
        finalInferMs = recognitionResult.inferMs ?? 0.0;
        finalPostMs = recognitionResult.postMs ?? 0.0;
        finalTotalMs = finalPrepMs + finalInferMs + finalPostMs;
      }

      // ignore: avoid_print
      print('[Timing Outside] FrameConv: ${sFrameConv.elapsedMilliseconds}ms | FaceDetection: ${detectMs.toStringAsFixed(2)}ms | T_pre: ${finalPrepMs.toStringAsFixed(2)}ms | T_infer: ${finalInferMs.toStringAsFixed(2)}ms | T_post: ${finalPostMs.toStringAsFixed(2)}ms | Total Pipeline: ${finalTotalMs.toStringAsFixed(2)}ms');
      _log.i('[Timing Outside] FrameConv: ${sFrameConv.elapsedMilliseconds}ms | FaceDetection: ${detectMs.toStringAsFixed(2)}ms | T_pre: ${finalPrepMs.toStringAsFixed(2)}ms | T_infer: ${finalInferMs.toStringAsFixed(2)}ms | T_post: ${finalPostMs.toStringAsFixed(2)}ms | Total Pipeline: ${finalTotalMs.toStringAsFixed(2)}ms');

      if (_isRecordingTelemetry && faces.isNotEmpty) {
        _performanceTracker.addFrameMetrics(
          preMs: finalPrepMs,
          inferMs: finalInferMs,
          postMs: finalPostMs,
          totalMs: finalTotalMs,
        );
      }

      // Update local FPS calculation
      _fpsFrames++;
      final now = DateTime.now();
      _lastFpsMark ??= now;
      if (now.difference(_lastFpsMark!).inMilliseconds >= 1000) {
        _displayFps = _fpsFrames.toDouble();
        _fpsFrames = 0;
        _lastFpsMark = now;
      }

      if (mounted) {
        setState(() {
          _displayLatency = finalTotalMs;
          _livePreMs = finalPrepMs;
          _liveInferMs = finalInferMs;
          _livePostMs = finalPostMs;
        });
      }
    } catch (e) {
      _log.e('Error in face detection', e);
      if (mounted) {
        setState(() {
          isBusy = false;
        });
      }
    }
  }

  Timer? _telemetryCountdownTimer;
  int _remainingSeconds = 10;

  void _toggleTelemetryRecording() {
    if (_isRecordingTelemetry) {
      _stopRecordingSession();
    } else {
      _startRecordingSession();
    }
  }

  void _startRecordingSession() {
    _performanceTracker.reset();
    _telemetryCountdownTimer?.cancel();
    setState(() {
      _isRecordingTelemetry = true;
      _remainingSeconds = 10;
    });

    _telemetryCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_remainingSeconds > 1) {
          _remainingSeconds--;
        } else {
          timer.cancel();
          _stopRecordingSession();
        }
      });
    });

    _log.i('[TELEMETRY] Started 10-second recording session.');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🔴 Telemetry recording started (10-second automated benchmark).'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _stopRecordingSession() {
    _telemetryCountdownTimer?.cancel();
    _telemetryCountdownTimer = null;
    if (mounted) {
      setState(() {
        _isRecordingTelemetry = false;
      });
    }
    _log.i('[TELEMETRY] Stopped recording session.');
    _performanceTracker.printSummaryToConsole();
    _showTelemetrySummaryDialog();
  }

  void _showTelemetrySummaryDialog() {
    final meanPre = _performanceTracker.calculateMean(_performanceTracker.preLatencies);
    final stdPre = _performanceTracker.calculateStdDev(_performanceTracker.preLatencies, meanPre);
    final minPre = _performanceTracker.preLatencies.isEmpty ? 0.0 : _performanceTracker.preLatencies.reduce((a, b) => a < b ? a : b);
    final maxPre = _performanceTracker.preLatencies.isEmpty ? 0.0 : _performanceTracker.preLatencies.reduce((a, b) => a > b ? a : b);
    final p95Pre = _performanceTracker.calculatePercentile(_performanceTracker.preLatencies, 0.95);

    final meanInfer = _performanceTracker.calculateMean(_performanceTracker.inferLatencies);
    final stdInfer = _performanceTracker.calculateStdDev(_performanceTracker.inferLatencies, meanInfer);
    final minInfer = _performanceTracker.inferLatencies.isEmpty ? 0.0 : _performanceTracker.inferLatencies.reduce((a, b) => a < b ? a : b);
    final maxInfer = _performanceTracker.inferLatencies.isEmpty ? 0.0 : _performanceTracker.inferLatencies.reduce((a, b) => a > b ? a : b);
    final p95Infer = _performanceTracker.calculatePercentile(_performanceTracker.inferLatencies, 0.95);

    final meanPost = _performanceTracker.calculateMean(_performanceTracker.postLatencies);
    final stdPost = _performanceTracker.calculateStdDev(_performanceTracker.postLatencies, meanPost);
    final minPost = _performanceTracker.postLatencies.isEmpty ? 0.0 : _performanceTracker.postLatencies.reduce((a, b) => a < b ? a : b);
    final maxPost = _performanceTracker.postLatencies.isEmpty ? 0.0 : _performanceTracker.postLatencies.reduce((a, b) => a > b ? a : b);
    final p95Post = _performanceTracker.calculatePercentile(_performanceTracker.postLatencies, 0.95);

    final meanTotal = _performanceTracker.calculateMean(_performanceTracker.totalLatencies);
    final stdTotal = _performanceTracker.calculateStdDev(_performanceTracker.totalLatencies, meanTotal);
    final minTotal = _performanceTracker.totalLatencies.isEmpty ? 0.0 : _performanceTracker.totalLatencies.reduce((a, b) => a < b ? a : b);
    final maxTotal = _performanceTracker.totalLatencies.isEmpty ? 0.0 : _performanceTracker.totalLatencies.reduce((a, b) => a > b ? a : b);
    final p95Total = _performanceTracker.calculatePercentile(_performanceTracker.totalLatencies, 0.95);

    final meanFps = _performanceTracker.calculateMean(_performanceTracker.fpsValues);
    final stdFps = _performanceTracker.calculateStdDev(_performanceTracker.fpsValues, meanFps);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Row(
            children: const [
              Icon(Icons.assessment, color: Colors.green),
              SizedBox(width: 8),
              Text(
                '🔬 Telemetry Results',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Session Frames: ${_performanceTracker.totalFramesLogged}',
                  style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                _buildMetricRow('Preprocessing (T_pre)', meanPre, stdPre, minPre, maxPre, p95Pre),
                const Divider(color: Colors.white24),
                _buildMetricRow('Inference (T_infer)', meanInfer, stdInfer, minInfer, maxInfer, p95Infer),
                const Divider(color: Colors.white24),
                _buildMetricRow('Postprocessing (T_post)', meanPost, stdPost, minPost, maxPost, p95Post),
                const Divider(color: Colors.white24),
                _buildMetricRow('Total Pipeline (T_total)', meanTotal, stdTotal, minTotal, maxTotal, p95Total),
                const Divider(color: Colors.white24),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Throughput:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    Text(
                      '${meanFps.toStringAsFixed(2)} ± ${stdFps.toStringAsFixed(2)} FPS',
                      style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  '* Note: Full raw statistics table has been exported to the IDE console.',
                  style: TextStyle(color: Colors.white38, fontSize: 10, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close', style: TextStyle(color: Colors.green)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMetricRow(String name, double mean, double std, double min, double max, double p95) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Mean ± StdDev:', style: TextStyle(color: Colors.white70, fontSize: 11)),
            Text('${mean.toStringAsFixed(2)} ± ${std.toStringAsFixed(2)} ms', style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace')),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Min / Max Bounds:', style: TextStyle(color: Colors.white70, fontSize: 11)),
            Text('${min.toStringAsFixed(1)} / ${max.toStringAsFixed(1)} ms', style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace')),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('p95 Percentile:', style: TextStyle(color: Colors.white70, fontSize: 11)),
            Text('${p95.toStringAsFixed(1)} ms', style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace')),
          ],
        ),
      ],
    );
  }

  Future<void> _reloadIsolateAndModel() async {
    // Show a loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          color: Color(0xFF1E1E1E),
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Colors.green),
                SizedBox(height: 16),
                Text(
                  'Reloading Model & Hardware Options...',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      // 1. Temporarily pause inference
      isBusy = true;
      _isolateReady = false;

      // 2. Kill current isolate
      _recognitionIsolate?.kill(priority: Isolate.beforeNextEvent);
      _recognitionIsolate = null;
      _isolateReceivePort?.close();
      _isolateReceivePort = null;
      _isolateSendPort = null;

      // 3. Reload model on the main thread
      await recognizer.loadModel();

      // 4. Restart the isolate with new settings
      await _initIsolate();
      
      // 5. Reset telemetry
      _performanceTracker.reset();
      _recognitionHistory.clear();

      if (mounted) {
        Navigator.pop(context); // Dismiss loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Model & Execution options applied successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      _log.e('Failed to reload isolate/model', e);
      if (mounted) {
        Navigator.pop(context); // Dismiss loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to apply options: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      isBusy = false;
    }
  }

  void _showModelSettingsDialog() {
    bool forceCpu = recognizer.forceCpuOnly;
    int threads = recognizer.numThreads;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '🔬 Performance Settings',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Hardware Acceleration
                  const Text(
                    'Execution Hardware:',
                    style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<bool>(
                        dropdownColor: const Color(0xFF1E1E1E),
                        value: forceCpu,
                        isExpanded: true,
                        icon: const Icon(Icons.arrow_drop_down, color: Colors.green),
                        items: const [
                          DropdownMenuItem(
                            value: true,
                            child: Text('CPU Only (Stable)', style: TextStyle(color: Colors.white, fontSize: 13)),
                          ),
                          DropdownMenuItem(
                            value: false,
                            child: Text('GPU Delegate (Hardware Accelerated)', style: TextStyle(color: Colors.white, fontSize: 13)),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setModalState(() => forceCpu = val);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // CPU Thread Count
                  if (forceCpu) ...[
                    const Text(
                      'CPU Threads:',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          dropdownColor: const Color(0xFF1E1E1E),
                          value: threads,
                          isExpanded: true,
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.green),
                          items: const [
                            DropdownMenuItem(value: 1, child: Text('1 Thread (Low overhead)', style: TextStyle(color: Colors.white, fontSize: 13))),
                            DropdownMenuItem(value: 2, child: Text('2 Threads (Recommended)', style: TextStyle(color: Colors.white, fontSize: 13))),
                            DropdownMenuItem(value: 4, child: Text('4 Threads (Default)', style: TextStyle(color: Colors.white, fontSize: 13))),
                            DropdownMenuItem(value: 8, child: Text('8 Threads (High resource)', style: TextStyle(color: Colors.white, fontSize: 13))),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setModalState(() => threads = val);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Action Buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                          // Apply changes
                          recognizer.forceCpuOnly = forceCpu;
                          recognizer.numThreads = threads;
                          _reloadIsolateAndModel();
                        },
                        child: const Text('Apply & Restart Isolate'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
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

      // Load model bytes on main thread to avoid isolate asset loading issues
      final ByteData data = await rootBundle.load(recognizer.modelName);
      final Uint8List modelBytes = data.buffer.asUint8List();

      final replyPort = ReceivePort();
      _isolateSendPort!.send(IsolateInitMessage(
        token: token,
        modelBytes: modelBytes,
        forceCpuOnly: recognizer.forceCpuOnly,
        numThreads: recognizer.numThreads,
        replyPort: replyPort.sendPort,
      ));

      final initResult = await replyPort.first;
      replyPort.close();

      if (initResult == true) {
        _log.i('Background isolate initialized successfully with model: ${recognizer.modelName}');
        if (mounted) {
          setState(() {
            _isolateReady = true;
            // Safety net: if main-thread init failed but isolate succeeded,
            // the pipeline can still run via the isolate fallback path.
            _recognizerReady = true;
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
  Future<Recognition?> performFaceRecognition(List<Face> faces, double detectMs) async {
    try {
      if (!_recognizerReady) {
        if (mounted) {
          setState(() {
            isBusy = false;
            _scanResults = faces.map((face) {
              return Recognition(
                'Loading...',
                face.boundingBox,
                [],
                0.0,
              );
            }).toList();
          });
        }
        return null;
      }

      if (frame == null) {
        if (mounted) setState(() => isBusy = false);
        return null;
      }

      if (faces.isEmpty) {
        if (mounted) setState(() => isBusy = false);
        return null;
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
          if (mounted) {
            setState(() {
              isBusy = false;
              _scanResults = null;
              _recognitionHistory.clear();
            });
          }
          return null;
        }

        // Step 1: Transform portrait bbox → landscape coordinates using raw frame dimensions
        final Rect lsBox = _portraitBoxToLandscape(
          face.boundingBox,
          frame!.width,
          frame!.height,
        );

        // Step 2: Crop & Convert directly from NV21 bytes (without copyRotate or copyResize)
        final sCrop = Stopwatch()..start();
        final Uint8List croppedFaceBytes = _cropNv21ToRgb(frame!, lsBox);
        sCrop.stop();

        _log.d(
          '[REC] bbox=${face.boundingBox} cropSize=112x112 (direct RGB extraction)',
        );

        List<double> outputArray;
        double isolateTensorConvMs = 0.0;
        double isolatePureInferenceMs = 0.0;

        if (_isolateReady && _isolateSendPort != null) {
          // Inference via background isolate
          final replyPort = ReceivePort();
          _isolateSendPort!.send(IsolateInferenceMessage(
            rgbBytes: croppedFaceBytes,
            replyPort: replyPort.sendPort,
          ));
          final dynamic result = await replyPort.first;
          replyPort.close();

          if (result is Map) {
            outputArray = List<double>.from(result['embeddings'] as List);
            isolateTensorConvMs = result['tensorConvMs'] as double;
            isolatePureInferenceMs = result['pureInferenceMs'] as double;
          } else {
            throw Exception('Isolate inference failed: $result');
          }
        } else {
          // Fallback to main thread
          final rec = recognizer.recognizeCropped(croppedFaceBytes, face.boundingBox);
          isolateTensorConvMs = rec.prepMs ?? 0.0;
          isolatePureInferenceMs = rec.inferMs ?? 0.0;
          outputArray = rec.embeddings;
        }

        final sPost = Stopwatch()..start();
        final Pair pair = recognizer.findNearest(outputArray);
        sPost.stop();

        final double cropFaceMs = sCrop.elapsedMicroseconds / 1000.0;
        final double postMs = sPost.elapsedMicroseconds / 1000.0;

        final double tPre = detectMs + cropFaceMs + isolateTensorConvMs;
        final double tInfer = isolatePureInferenceMs;
        final double tPost = postMs;

        // ignore: avoid_print
        print('[Timing Inside performFaceRecognition] CropFace: ${cropFaceMs.toStringAsFixed(2)}ms | IsolateTensorConv: ${isolateTensorConvMs.toStringAsFixed(2)}ms | IsolatePureInference: ${isolatePureInferenceMs.toStringAsFixed(2)}ms | FindNearest: ${postMs.toStringAsFixed(2)}ms');
        _log.i('[Timing Inside performFaceRecognition] CropFace: ${cropFaceMs.toStringAsFixed(2)}ms | IsolateTensorConv: ${isolateTensorConvMs.toStringAsFixed(2)}ms | IsolatePureInference: ${isolatePureInferenceMs.toStringAsFixed(2)}ms | FindNearest: ${postMs.toStringAsFixed(2)}ms');

        final Recognition recognition = Recognition(
          pair.name,
          face.boundingBox,
          outputArray,
          pair.score,
        );
        recognition.prepMs = tPre;
        recognition.inferMs = tInfer;
        recognition.postMs = tPost;

        _log.d(
          '[REC] name=${recognition.name} score=${recognition.score.toStringAsFixed(3)}',
        );

        if (!recognition.name.startsWith('__')) {
          final double liveThreshold =
              recognizer.cosineThreshold + _liveThresholdOffset;
          final bool aboveThreshold = recognition.score >= liveThreshold;
          final String candidateName =
              aboveThreshold ? recognition.name : 'Unknown';

          _recognitionHistory.add(candidateName);
          if (_recognitionHistory.length > _historyWindowSize) {
            _recognitionHistory.removeAt(0);
          }

          // Count frequencies to determine the most stable prediction
          final Map<String, int> counts = {};
          for (final name in _recognitionHistory) {
            counts[name] = (counts[name] ?? 0) + 1;
          }

          String mostFrequentName = 'Unknown';
          int maxCount = 0;
          counts.forEach((name, count) {
            if (count > maxCount) {
              maxCount = count;
              mostFrequentName = name;
            }
          });

          // Show name if it appears at least 3 out of the last 5 frames
          final String displayName = (mostFrequentName != 'Unknown' && maxCount >= 3)
              ? mostFrequentName
              : 'Unknown';

          final Recognition finalRec = Recognition(
            displayName,
            recognition.location,
            recognition.embeddings,
            recognition.score,
          );
          finalRec.prepMs = tPre;
          finalRec.inferMs = tInfer;
          finalRec.postMs = tPost;
          currentRecognitions.add(finalRec);
        }

        if (mounted) {
          setState(() {
            isBusy = false;
            _scanResults = List.from(currentRecognitions);
          });
        }

        return recognition;
      } catch (e) {
        _log.e('[REC] Error processing face', e);
      }

      if (mounted) {
        setState(() {
          isBusy = false;
        });
      }
    } catch (e) {
      _log.e('[REC] Error in face recognition', e);
      if (mounted) setState(() => isBusy = false);
    }
    return null;
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
      if (_totalFramesReceived % 60 == 0) {
        _log.w('getInputImage: unsupported format: raw=${frame!.format.raw}, format=$format');
      }
      return null;
    }

    if (frame!.planes.length != 1) {
      if (_totalFramesReceived % 60 == 0) {
        _log.w('getInputImage: planes length is not 1: ${frame!.planes.length}');
      }
      return null;
    }
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
      _recognitionHistory.clear();
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
                    'Model: ${recognizer.modelName.split('/').last.replaceAll('.tflite', '')}',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Recognizer: ${_recognizerReady ? "READY" : "LOADING/ERROR"}',
                    style: TextStyle(
                      color: _recognizerReady ? Colors.green : Colors.red,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Isolate: ${_isolateReady ? "READY" : "FALLBACK/CPU"}',
                    style: TextStyle(
                      color: _isolateReady ? Colors.green : Colors.orange,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'T_pre: ${_livePreMs.toStringAsFixed(1)} ms',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'T_infer: ${_liveInferMs.toStringAsFixed(1)} ms',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'T_post: ${_livePostMs.toStringAsFixed(1)} ms',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'T_total: ${_displayLatency.toStringAsFixed(1)} ms',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Cam FPS: ${_cameraFps.toStringAsFixed(1)}',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'AI FPS : ${_displayFps.toStringAsFixed(1)}',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Mode: ${recognizer.forceCpuOnly ? "CPU (${recognizer.numThreads}T)" : "GPU"}',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 120,
                    height: 28,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isRecordingTelemetry ? Colors.red : Colors.green,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      onPressed: _toggleTelemetryRecording,
                      icon: Icon(
                        _isRecordingTelemetry ? Icons.stop : Icons.fiber_manual_record,
                        size: 12,
                        color: _isRecordingTelemetry ? Colors.white : Colors.red,
                      ),
                      label: Text(
                        _isRecordingTelemetry ? 'Stop (${_remainingSeconds}s)' : 'Start Test',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 120,
                    height: 28,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey[800],
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      onPressed: _showModelSettingsDialog,
                      icon: const Icon(
                        Icons.settings,
                        size: 12,
                        color: Colors.green,
                      ),
                      label: const Text(
                        'Settings',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
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

    // Telemetry and background isolate are active in profile/debug mode
    // (A/B testing buttons removed for clean optimized layout)

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
  final Uint8List modelBytes;
  final bool forceCpuOnly;
  final int numThreads;
  final SendPort replyPort;

  IsolateInitMessage({
    required this.token,
    required this.modelBytes,
    required this.forceCpuOnly,
    required this.numThreads,
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
  
  // OPTIMIZATION: Pre-allocate reusable buffer to avoid recreating 
  // 37,632 floats per frame and triggering heavy Dart GC.
  final Float32List sharedInputBuffer = Float32List(112 * 112 * 3);

  await for (final message in receivePort) {
    if (message is IsolateInitMessage) {
      try {
        BackgroundIsolateBinaryMessenger.ensureInitialized(message.token);
        final options = InterpreterOptions();
        if (!message.forceCpuOnly) {
          options.addDelegate(GpuDelegate());
        } else {
          options.threads = message.numThreads;
        }
        interpreter = Interpreter.fromBuffer(message.modelBytes, options: options);
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
        final sTensor = Stopwatch()..start();
        
        for (int i = 0; i < rgbBytes.length; i++) {
          sharedInputBuffer[i] = (rgbBytes[i] - 127.5) / 127.5;
        }
        final input = sharedInputBuffer.reshape([1, 112, 112, 3]);
        sTensor.stop();

        final sInfer = Stopwatch()..start();
        final List<List<double>> output = [List.filled(128, 0.0)];
        interpreter.run(input, output);
        sInfer.stop();

        // ignore: avoid_print
        print('[Isolate Timing] TensorConv: ${sTensor.elapsedMicroseconds / 1000.0}ms | PureInference: ${sInfer.elapsedMicroseconds / 1000.0}ms');

        message.replyPort.send({
          'embeddings': output[0],
          'tensorConvMs': sTensor.elapsedMicroseconds / 1000.0,
          'pureInferenceMs': sInfer.elapsedMicroseconds / 1000.0,
        });
      } catch (e) {
        message.replyPort.send(e.toString());
      }
    }
  }
}
