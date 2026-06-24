import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../data/face_record.dart';
import '../data/face_repository.dart';
import '../logging/app_logger.dart';
import 'recognition.dart';

class Recognizer {
  late Interpreter? _interpreter;
  late InterpreterOptions _interpreterOptions;

  static const int inputWidth = 112;
  static const int inputHeight = 112;
  static const int outputSize = 128;

  final FaceRepository _faceRepository;
  final AppLogger _log = AppLogger();

  // CPU-only execution inside background isolates is highly performant and extremely stable
  bool forceCpuOnly = true;
  int numThreads = 4;

  // OPTIMIZATION: Pre-allocate reusable buffer to avoid recreating 
  // 37,632 floats per frame and triggering heavy Dart GC during normalization.
  late final Float32List _sharedInputBuffer;

  Map<String, List<List<double>>> registered = {};

  // Default to the highly performant Baseline Float32 model with zero dynamic dequantization overhead
  String modelName = 'assets/mobilefacenet_baseline_f32.tflite';

  bool _isLoaded = false;
  bool _isRunning = false;
  Future<void>? _initFuture;

  bool get isReady => _isLoaded && _interpreter != null;

  Recognizer({required FaceRepository faceRepository, int? numThreads})
    : _faceRepository = faceRepository {
    _interpreterOptions = InterpreterOptions();

    if (numThreads != null) {
      this.numThreads = numThreads;
    }
    _interpreterOptions.threads = this.numThreads;
    _sharedInputBuffer = Float32List(inputWidth * inputHeight * 3);
  }

  Future<void> init() async {
    // Always allow re-init if the model is not ready.
    // This handles cases where a previous init attempt failed silently
    // (e.g., GpuDelegate exception that was caught internally).
    if (!isReady) {
      // ignore: avoid_print
      print('[Recognizer] init() called but isReady=false — resetting and retrying.');
      _initFuture = null;
    }
    _initFuture ??= _initInternal();
    return _initFuture!;
  }

  Future<void> _initInternal() async {
    await loadModel();

    try {
      await initDB();
    } catch (e, st) {
      // DB init failure is non-fatal: model inference still works.
      // Registered faces just won't be loaded from DB.
      _log.w('Recognizer initDB error (non-fatal, continuing).', e, st);
    }
  }

  Future<void> initDB() async {
    await _faceRepository.init();
    await loadRegisteredFaces();
  }

  Future<void> loadRegisteredFaces() async {
    registered.clear();

    final records = await _faceRepository.getAllFaces();

    for (final record in records) {
      // Normalisasi defensif saat load dari DB.
      // Ini memastikan embedding database konsisten dengan threshold cosine.
      registered[record.name] =
          record.embeddings.map((embedding) => l2Normalize(embedding)).toList();

      _log.d(
        'Loaded ${record.embeddings.length} normalized embeddings for ${record.name}',
      );
    }
  }

  Future<Uint8List> compressImage(
    Uint8List imageData, {
    int maxSizeInKB = 500,
  }) async {
    img.Image? image = img.decodeImage(imageData);

    if (image == null) throw Exception('Image decoding failed');

    img.Image resized = img.copyResize(image, width: 300);

    int quality = 85;
    Uint8List jpg;

    do {
      jpg = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
      quality -= 5;
    } while (jpg.lengthInBytes > maxSizeInKB * 1024 && quality > 20);

    return jpg;
  }

  Future<void> registerFaceInDB(
    String name,
    List<List<double>> embeddings,
    Uint8List faceImage,
  ) async {
    final Uint8List compressedImage = await compressImage(faceImage);

    // Normalisasi defensif sebelum disimpan ke database.
    final List<List<double>> normalizedEmbeddings =
        embeddings.map((embedding) => l2Normalize(embedding)).toList();

    final record = FaceRecord(
      name: name,
      embeddings: normalizedEmbeddings,
      imageBytes: compressedImage,
    );

    final int id = await _faceRepository.insertFace(record);

    _log.i(
      'Registered "$name" to DB id=$id embeddings=${normalizedEmbeddings.length}',
    );

    await loadRegisteredFaces();
  }

  Future<void> loadModel() async {
    // Reset state at the start so a previous successful load
    // doesn't mask a new failure.
    _isLoaded = false;
    // ignore: avoid_print
    print('[Recognizer] loadModel() START — model=$modelName forceCpuOnly=$forceCpuOnly threads=$numThreads');

    // --- Attempt 1: load with configured options (CPU threads or GPU) ---
    try {
      final options = InterpreterOptions();
      if (!forceCpuOnly) {
        // ignore: avoid_print
        print('[Recognizer] Attempting load with GPU Delegate...');
        options.addDelegate(GpuDelegate());
      } else {
        // ignore: avoid_print
        print('[Recognizer] Attempting load with CPU ($numThreads threads)...');
        options.threads = numThreads;
      }

      if (_interpreter != null) {
        _interpreter!.close();
        _interpreter = null;
      }

      _interpreter = await Interpreter.fromAsset(modelName, options: options);
      _isLoaded = true;
      // ignore: avoid_print
      print('[Recognizer] Model loaded successfully (attempt 1).');
      _log.i(
        'Model loaded successfully. Input: ${_interpreter!.getInputTensors().map((t) => t.shape)}, Output: ${_interpreter!.getOutputTensors().map((t) => t.shape)}',
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('[Recognizer] Attempt 1 FAILED: $e');
      _log.w('Failed to load model with custom options. Falling back to bare CPU.', e, st);

      // --- Attempt 2: bare CPU fallback with no delegates or thread count ---
      try {
        if (_interpreter != null) {
          _interpreter!.close();
          _interpreter = null;
        }
        // ignore: avoid_print
        print('[Recognizer] Attempting load with bare CPU (no options)...');
        _interpreter = await Interpreter.fromAsset(modelName);
        _isLoaded = true;
        // ignore: avoid_print
        print('[Recognizer] Model loaded successfully via bare CPU fallback.');
        _log.i(
          'Model loaded via CPU fallback. Input: ${_interpreter!.getInputTensors().map((t) => t.shape)}, Output: ${_interpreter!.getOutputTensors().map((t) => t.shape)}',
        );
      } catch (e2, st2) {
        _isLoaded = false;
        _interpreter = null;
        // ignore: avoid_print
        print('[Recognizer] CRITICAL: Both load attempts FAILED. e=$e2');
        _log.e('Failed to load model even on bare CPU fallback.', e2, st2);
      }
    }

    // ignore: avoid_print
    print('[Recognizer] loadModel() END — _isLoaded=$_isLoaded, _interpreter=${_interpreter != null}');

    if (_isLoaded) {
      _log.i('Cosine threshold: ${cosineThreshold.toStringAsFixed(6)}');
    }
  }

  // ============================================================
  // THRESHOLD BERDASARKAN MODEL YANG DIMUAT
  // ============================================================
  //
  // Threshold ini berasal dari evaluasi LFW:
  //
  // Float32:
  //   cosine threshold = 0.950696
  //
  // Dynamic Range:
  //   cosine threshold = 0.950633
  //
  // Float16:
  //   cosine threshold = 0.950688
  //
  // Karena sekarang aplikasi memakai cosine similarity:
  //   similarity >= threshold → wajah sama
  //   similarity < threshold  → Unknown
  //
  double get cosineThreshold {
    final String lowerName = modelName.toLowerCase();

    if (lowerName.contains('dynamic') ||
        lowerName.contains('int8') ||
        lowerName.contains('dynamic_range')) {
      return 0.965;
    }

    if (lowerName.contains('float16') || lowerName.contains('fp16')) {
      return 0.965;
    }

    if (lowerName.contains('baseline') ||
        lowerName.contains('f32') ||
        lowerName.contains('float32')) {
      return 0.965;
    }

    // Default aman jika nama model tidak dikenali.
    return 0.960;
  }

  // ============================================================
  // L2 NORMALIZATION DEFENSIF
  // ============================================================
  //
  // Walaupun model sudah menghasilkan embedding L2-normalized,
  // fungsi ini tetap digunakan agar embedding query dan database
  // selalu konsisten.
  //
  List<double> l2Normalize(List<double> emb) {
    double norm = 0.0;

    for (final double v in emb) {
      if (v.isNaN || v.isInfinite) {
        return emb;
      }
      norm += v * v;
    }

    norm = sqrt(norm);

    if (norm < 1e-10) {
      return emb;
    }

    return emb.map((v) => v / norm).toList();
  }

  // ============================================================
  // COSINE SIMILARITY
  // ============================================================
  //
  // Karena embedding sudah L2-normalized, dot product sama dengan
  // cosine similarity.
  //
  double cosineSimilarity(List<double> emb1, List<double> emb2) {
    final int len = min(emb1.length, emb2.length);

    double dotProduct = 0.0;

    for (int i = 0; i < len; i++) {
      dotProduct += emb1[i] * emb2[i];
    }

    // Clamp agar aman dari error numerik kecil.
    if (dotProduct > 1.0) return 1.0;
    if (dotProduct < -1.0) return -1.0;

    return dotProduct;
  }

  // ============================================================
  // CROP WAJAH DARI FRAME
  // ============================================================
  //
  // Fungsi ini memastikan input yang masuk ke model adalah crop wajah,
  // bukan full frame. Rect location diasumsikan sebagai bounding box
  // wajah dari face detector.
  //
  // Jika location tidak valid atau crop gagal, fallback ke image asli.
  //
  img.Image cropFaceFromLocation(img.Image source, Rect location) {
    if (source.width <= 0 || source.height <= 0) {
      return source;
    }

    if (location.width <= 1 || location.height <= 1) {
      _log.w('Invalid face Rect. Using original image as fallback.');
      return source;
    }

    // Tambahkan sedikit margin agar area wajah tidak terlalu ketat.
    // const double marginRatio = 0.15;
    const double marginRatio = 0.05;

    final double marginX = location.width * marginRatio;
    final double marginY = location.height * marginRatio;

    int x = (location.left - marginX).round();
    int y = (location.top - marginY).round();
    int w = (location.width + 2 * marginX).round();
    int h = (location.height + 2 * marginY).round();

    x = max(0, x);
    y = max(0, y);

    if (x >= source.width || y >= source.height) {
      _log.w('Face Rect outside image. Skipping crop.');
      return source;
    }

    if (x + w > source.width) {
      w = source.width - x;
    }

    if (y + h > source.height) {
      h = source.height - y;
    }

    if (w <= 1 || h <= 1) {
      _log.w('Invalid cropped face size. Skipping crop.');
      return source;
    }

    try {
      final img.Image croppedFace = img.copyCrop(
        source,
        x: x,
        y: y,
        width: w,
        height: h,
      );

      _log.d(
        'Face cropped: x=$x y=$y w=$w h=$h from image ${source.width}x${source.height}',
      );

      return croppedFace;
    } catch (e, st) {
      _log.w('Failed to crop face. Using original image as fallback.', e, st);
      return source;
    }
  }

  List<dynamic> imageToArray(img.Image inputImage) {
    final img.Image resizedImage = img.copyResize(
      inputImage,
      width: inputWidth,
      height: inputHeight,
    );

    // Extract R, G, B channels dan normalisasi ke [-1, 1].
    final int totalPixels = inputWidth * inputHeight;
    final Float32List inputBuffer = Float32List(totalPixels * 3);

    int idx = 0;

    for (int y = 0; y < inputHeight; y++) {
      for (int x = 0; x < inputWidth; x++) {
        final pixel = resizedImage.getPixel(x, y);

        inputBuffer[idx++] = (pixel.r.toDouble() - 127.5) / 127.5;
        inputBuffer[idx++] = (pixel.g.toDouble() - 127.5) / 127.5;
        inputBuffer[idx++] = (pixel.b.toDouble() - 127.5) / 127.5;
      }
    }

    return inputBuffer.reshape([1, inputHeight, inputWidth, 3]);
  }

  List<dynamic> rgbBytesToArray(Uint8List rgbBytes) {
    for (int i = 0; i < rgbBytes.length; i++) {
      _sharedInputBuffer[i] = (rgbBytes[i] - 127.5) / 127.5;
    }
    return _sharedInputBuffer.reshape([1, inputHeight, inputWidth, 3]);
  }

  Recognition recognizeCropped(Uint8List croppedFaceBytes, Rect location) {
    if (!isReady) {
      return Recognition(
        '__not_ready__',
        location,
        List.filled(outputSize, 0.0),
        -1,
      );
    }

    if (_isRunning) {
      _log.w('Recognizer busy - skipping frame');

      return Recognition(
        '__busy__',
        location,
        List.filled(outputSize, 0.0),
        -3,
      );
    }

    _isRunning = true;

    List<double> outputArray;
    double prepMs = 0.0;
    double inferMs = 0.0;

    try {
      final sTensor = Stopwatch()..start();
      final input = rgbBytesToArray(croppedFaceBytes);
      sTensor.stop();
      prepMs = sTensor.elapsedMicroseconds / 1000.0;

      _log.d('Input shape: ${input.shape}');

      // Output buffer harus List<List<double>>.
      final List<List<double>> output = [List.filled(outputSize, 0.0)];

      final sInfer = Stopwatch()..start();
      _interpreter!.run(input, output);
      sInfer.stop();
      inferMs = sInfer.elapsedMicroseconds / 1000.0;

      // Normalisasi defensif output embedding.
      outputArray = l2Normalize(output[0]);
    } finally {
      _isRunning = false;
    }

    // Guard: NaN/Inf embedding berarti model gagal untuk crop ini.
    final bool hasNaN = outputArray.any((v) => v.isNaN || v.isInfinite);

    if (hasNaN) {
      _log.w('NaN/Inf in embedding - invalid crop or model issue. Skipping.');

      return Recognition(
        '__invalid__',
        location,
        List.filled(outputSize, 0.0),
        -2,
      );
    }

    _log.d(
      'Inference time: ${inferMs.toStringAsFixed(2)}ms | embedding[0..4]: ${outputArray.sublist(0, 4).map((v) => v.toStringAsFixed(4))}',
    );

    // Cari identity dengan cosine similarity tertinggi.
    final Pair pair = findNearest(outputArray);

    _log.d(
      'Best match: ${pair.name} | cosine similarity: ${pair.score.toStringAsFixed(6)} | threshold: ${cosineThreshold.toStringAsFixed(6)}',
    );

    final Recognition recognition = Recognition(
      pair.name,
      location,
      outputArray,
      pair.score,
    );
    recognition.prepMs = prepMs;
    recognition.inferMs = inferMs;
    return recognition;
  }

  Recognition recognize(img.Image image, Rect location) {
    if (!isReady) {
      return Recognition(
        '__not_ready__',
        location,
        List.filled(outputSize, 0.0),
        -1,
      );
    }

    if (_isRunning) {
      _log.w('Recognizer busy - skipping frame');

      return Recognition(
        '__busy__',
        location,
        List.filled(outputSize, 0.0),
        -3,
      );
    }

    _isRunning = true;

    List<double> outputArray;
    int run;

    try {
      // Pastikan input model adalah crop wajah.
      final img.Image faceCrop = cropFaceFromLocation(image, location);

      final input = imageToArray(faceCrop);

      _log.d('Input shape: ${input.shape}');

      // Output buffer harus List<List<double>>.
      final List<List<double>> output = [List.filled(outputSize, 0.0)];

      final int runs = DateTime.now().millisecondsSinceEpoch;

      _interpreter!.run(input, output);

      run = DateTime.now().millisecondsSinceEpoch - runs;

      // Normalisasi defensif output embedding.
      outputArray = l2Normalize(output[0]);
    } finally {
      _isRunning = false;
    }

    // Guard: NaN/Inf embedding berarti model gagal untuk crop ini.
    final bool hasNaN = outputArray.any((v) => v.isNaN || v.isInfinite);

    if (hasNaN) {
      _log.w('NaN/Inf in embedding - invalid crop or model issue. Skipping.');

      return Recognition(
        '__invalid__',
        location,
        List.filled(outputSize, 0.0),
        -2,
      );
    }

    _log.d(
      'Inference time: ${run}ms | embedding[0..4]: ${outputArray.sublist(0, 4).map((v) => v.toStringAsFixed(4))}',
    );

    // Cari identity dengan cosine similarity tertinggi.
    final Pair pair = findNearest(outputArray);

    _log.d(
      'Best match: ${pair.name} | cosine similarity: ${pair.score.toStringAsFixed(6)} | threshold: ${cosineThreshold.toStringAsFixed(6)}',
    );

    // Catatan:
    // Recognition field terakhir sekarang menyimpan cosine similarity.
    return Recognition(pair.name, location, outputArray, pair.score);
  }

  // ============================================================
  // FIND NEAREST — COSINE SIMILARITY
  // ============================================================
  //
  // Rule:
  //   similarity >= cosineThreshold → wajah sama
  //   similarity < cosineThreshold  → Unknown
  //
  Pair findNearest(List<double> emb) {
    Pair pair = Pair("Unknown", -5.0);

    if (registered.isEmpty) {
      return pair;
    }

    final List<double> queryEmb = l2Normalize(emb);

    for (MapEntry<String, List<List<double>>> entry in registered.entries) {
      final String name = entry.key;
      final List<List<double>> storedEmbeddings = entry.value;

      double maxSimilarity = -double.infinity;

      for (List<double> storedEmb in storedEmbeddings) {
        final List<double> galleryEmb = l2Normalize(storedEmb);

        final double similarity = cosineSimilarity(queryEmb, galleryEmb);

        if (similarity > maxSimilarity) {
          maxSimilarity = similarity;
        }
      }

      if (pair.score == -5.0 || maxSimilarity > pair.score) {
        pair.score = maxSimilarity;
        pair.name = name;
      }
    }

    // Karena ini cosine similarity:
    // semakin besar = semakin mirip.
    if (pair.score < cosineThreshold && pair.score != -5.0) {
      pair.name = "Unknown";
    }

    return pair;
  }

  void close() {
    _interpreter?.close();
  }
}

class Pair {
  String name;

  double score;

  Pair(this.name, this.score);
}

// ============================================================
// PERFORMANCE TRACKER — LATENCY & FPS MEASUREMENT
// ============================================================
//
// Kelas ini mengukur latency inference per frame dan FPS real-time.
// Digunakan untuk pengujian performa model tanpa I/O.
//
class PerformanceTracker {
  final List<double> preLatencies = [];
  final List<double> inferLatencies = [];
  final List<double> postLatencies = [];
  final List<double> totalLatencies = [];
  final List<double> fpsValues = [];

  DateTime? _lastSecondMark;
  int _framesThisSecond = 0;
  int totalFramesLogged = 0;

  PerformanceTracker() {
    _lastSecondMark = DateTime.now();
  }

  void addFrameMetrics({
    required double preMs,
    required double inferMs,
    required double postMs,
    required double totalMs,
  }) {
    preLatencies.add(preMs);
    inferLatencies.add(inferMs);
    postLatencies.add(postMs);
    totalLatencies.add(totalMs);
    _framesThisSecond++;
    totalFramesLogged++;

    final now = DateTime.now();
    if (now.difference(_lastSecondMark!).inMilliseconds >= 1000) {
      fpsValues.add(_framesThisSecond.toDouble());
      _framesThisSecond = 0;
      _lastSecondMark = now;

      // Print a publication-ready summary every 100 frames to make copy-pasting easy
      if (totalFramesLogged % 100 == 0) {
        printSummaryToConsole();
      }
    }
  }

  void reset() {
    preLatencies.clear();
    inferLatencies.clear();
    postLatencies.clear();
    totalLatencies.clear();
    fpsValues.clear();
    _framesThisSecond = 0;
    totalFramesLogged = 0;
    _lastSecondMark = DateTime.now();
  }

  double calculateMean(List<double> values) {
    if (values.isEmpty) return 0.0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  double calculateStdDev(List<double> values, double mean) {
    if (values.length <= 1) return 0.0;
    final variance =
        values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
        (values.length - 1);
    return sqrt(variance);
  }

  double calculatePercentile(List<double> values, double percentile) {
    if (values.isEmpty) return 0.0;
    final sorted = List<double>.from(values)..sort();
    final index = ((sorted.length - 1) * percentile).round();
    return sorted[index];
  }

  void printSummaryToConsole() {
    if (totalLatencies.isEmpty) return;

    final meanPre = calculateMean(preLatencies);
    final stdPre = calculateStdDev(preLatencies, meanPre);
    final minPre = preLatencies.reduce((a, b) => a < b ? a : b);
    final maxPre = preLatencies.reduce((a, b) => a > b ? a : b);
    final p95Pre = calculatePercentile(preLatencies, 0.95);

    final meanInfer = calculateMean(inferLatencies);
    final stdInfer = calculateStdDev(inferLatencies, meanInfer);
    final minInfer = inferLatencies.reduce((a, b) => a < b ? a : b);
    final maxInfer = inferLatencies.reduce((a, b) => a > b ? a : b);
    final p95Infer = calculatePercentile(inferLatencies, 0.95);

    final meanPost = calculateMean(postLatencies);
    final stdPost = calculateStdDev(postLatencies, meanPost);
    final minPost = postLatencies.reduce((a, b) => a < b ? a : b);
    final maxPost = postLatencies.reduce((a, b) => a > b ? a : b);
    final p95Post = calculatePercentile(postLatencies, 0.95);

    final meanTotal = calculateMean(totalLatencies);
    final stdTotal = calculateStdDev(totalLatencies, meanTotal);
    final minTotal = totalLatencies.reduce((a, b) => a < b ? a : b);
    final maxTotal = totalLatencies.reduce((a, b) => a > b ? a : b);
    final p95Total = calculatePercentile(totalLatencies, 0.95);

    final meanFps = calculateMean(fpsValues);
    final stdFps = calculateStdDev(fpsValues, meanFps);

    // ignore: avoid_print
    print('\n${'═' * 80}');
    // ignore: avoid_print
    print(
      '🔬 RESEARCH DATA TELEMETRY SUMMARY (Frames Analyzed: $totalFramesLogged)',
    );
    // ignore: avoid_print
    print('═' * 80);
    // ignore: avoid_print
    print(
      'Metric               | Mean ± StdDev (ms)   | Min (ms) | Max (ms) | p95 (ms)',
    );
    // ignore: avoid_print
    print('─' * 80);
    // ignore: avoid_print
    print(
      '1. Preprocess (T_pre)| ${meanPre.toStringAsFixed(2).padLeft(6)} ± ${stdPre.toStringAsFixed(2).padRight(5)}      | ${minPre.toStringAsFixed(1).padLeft(8)} | ${maxPre.toStringAsFixed(1).padLeft(8)} | ${p95Pre.toStringAsFixed(1).padLeft(8)}',
    );
    // ignore: avoid_print
    print(
      '2. Inference (T_infer)  | ${meanInfer.toStringAsFixed(2).padLeft(6)} ± ${stdInfer.toStringAsFixed(2).padRight(5)}      | ${minInfer.toStringAsFixed(1).padLeft(8)} | ${maxInfer.toStringAsFixed(1).padLeft(8)} | ${p95Infer.toStringAsFixed(1).padLeft(8)}',
    );
    // ignore: avoid_print
    print(
      '3. Postprocess (T_post) | ${meanPost.toStringAsFixed(2).padLeft(6)} ± ${stdPost.toStringAsFixed(2).padRight(5)}      | ${minPost.toStringAsFixed(1).padLeft(8)} | ${maxPost.toStringAsFixed(1).padLeft(8)} | ${p95Post.toStringAsFixed(1).padLeft(8)}',
    );
    // ignore: avoid_print
    print(
      '4. Total Pipeline       | ${meanTotal.toStringAsFixed(2).padLeft(6)} ± ${stdTotal.toStringAsFixed(2).padRight(5)}      | ${minTotal.toStringAsFixed(1).padLeft(8)} | ${maxTotal.toStringAsFixed(1).padLeft(8)} | ${p95Total.toStringAsFixed(1).padLeft(8)}',
    );
    // ignore: avoid_print
    print('─' * 80);
    // ignore: avoid_print
    print(
      'System Throughput       | ${meanFps.toStringAsFixed(2)} ± ${stdFps.toStringAsFixed(2)} FPS',
    );
    // ignore: avoid_print
    print('${'═' * 80}\n');
  }

  double get currentInstantFps => fpsValues.isEmpty ? 0.0 : fpsValues.last;
  double get currentAverageLatency => calculateMean(totalLatencies);
}
