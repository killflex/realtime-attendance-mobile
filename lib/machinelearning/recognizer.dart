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
  Interpreter? _interpreter;
  late InterpreterOptions _interpreterOptions;
  static const int inputWidth = 112;
  static const int inputHeight = 112;
  static const int outputSize = 128;
  final FaceRepository _faceRepository;
  final AppLogger _log = AppLogger();
  Map<String, List<List<double>>> registered = {};

  // Cache untuk optimasi

  String get modelName => 'assets/mobilefacenet_f32.tflite';

  bool _isLoaded = false;
  Future<void>? _initFuture;
  bool _isRunning = false;

  bool get isReady => _isLoaded && _interpreter != null;

  Recognizer({required FaceRepository faceRepository, int? numThreads})
    : _faceRepository = faceRepository {
    _interpreterOptions = InterpreterOptions();

    if (numThreads != null) {
      _interpreterOptions.threads = numThreads;
    }
    // Initialization is async; callers should await init().
  }

  Future<void> init() async {
    _initFuture ??= _initInternal();
    return _initFuture!;
  }

  Future<void> _initInternal() async {
    await loadModel();
    try {
      await initDB();
    } catch (e, st) {
      // DB init failure is non-fatal: model inference still works
      // Registered faces just won't be loaded from DB
      _log.w('Recognizer initDB error (non-fatal, continuing).', e, st);
    }
  }

  initDB() async {
    await _faceRepository.init();
    loadRegisteredFaces();
  }

  Future<void> loadRegisteredFaces() async {
    registered.clear();
    final records = await _faceRepository.getAllFaces();
    for (final record in records) {
      registered[record.name] = record.embeddings;
      _log.d(
        'Loaded ${record.embeddings.length} embeddings for ${record.name}',
      );
    }
  }

  Future<Uint8List> compressImage(
    Uint8List imageData, {
    int maxSizeInKB = 500,
  }) async {
    img.Image? image = img.decodeImage(imageData);
    if (image == null) throw Exception('Image decoding failed');

    // Resize to smaller dimensions if necessary
    img.Image resized = img.copyResize(image, width: 300); // ~300px width

    int quality = 85; // Start with high quality
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
    final record = FaceRecord(
      name: name,
      embeddings: embeddings,
      imageBytes: compressedImage,
    );
    final int id = await _faceRepository.insertFace(record);
    _log.i('Registered "$name" to DB id=$id embeddings=${embeddings.length}');

    // Reload in-memory map so recognition works immediately after registration
    await loadRegisteredFaces();
  }

  Future<void> loadModel() async {
    try {
      _log.i('Loading model: $modelName');
      _interpreter = await Interpreter.fromAsset(
        modelName,
        options: _interpreterOptions,
      );
      _isLoaded = true;
      _log.i(
        'Model loaded. Input: ${_interpreter!.getInputTensors().map((t) => t.shape)}, Output: ${_interpreter!.getOutputTensors().map((t) => t.shape)}',
      );
    } catch (e, st) {
      _isLoaded = false;
      _log.e('Failed to load model "$modelName".', e, st);
    }
  }

  List<dynamic> imageToArray(img.Image inputImage) {
    img.Image resizedImage = img.copyResize(
      inputImage,
      width: inputWidth,
      height: inputHeight,
    );

    // Extract only R, G, B channels (not alpha) and normalize to [-1, 1]
    final int totalPixels = inputWidth * inputHeight;
    Float32List inputBuffer = Float32List(totalPixels * 3);
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

  Recognition recognize(img.Image image, Rect location) {
    //TODO crop face from image resize it and convert it to float array
    if (!isReady) {
      return Recognition('Unknown', location, List.filled(outputSize, 0.0), -1);
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
      var input = imageToArray(image);
      _log.d('Input shape: ${input.shape}');

      // CRITICAL: output buffer MUST be a List<List<double>> — int or bare list causes silent failure
      final List<List<double>> output = [List.filled(outputSize, 0.0)];

      //TODO performs inference
      final runs = DateTime.now().millisecondsSinceEpoch;
      _interpreter!.run(input, output);
      run = DateTime.now().millisecondsSinceEpoch - runs;

      outputArray = output[0];
    } finally {
      _isRunning = false;
    }

    // Guard: NaN/Inf embedding means model failed for this crop (bad input region)
    final bool hasNaN = outputArray.any((v) => v.isNaN || v.isInfinite);
    if (hasNaN) {
      _log.w('NaN/Inf in embedding - invalid crop or model issue. Skipping.');
      // distance = -2 signals "bad embedding" to callers (distinct from -5 = no DB)
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

    //TODO looks for the nearest embeeding in the database and returns the pair
    Pair pair = findNearest(outputArray);
    _log.d('Distance: ${pair.distance}');

    return Recognition(pair.name, location, outputArray, pair.distance);
  }

  //TODO  looks for the nearest embeeding in the database and returns the pair which contain information of registered face with which face is most similar
  Pair findNearest(List<double> emb) {
    Pair pair = Pair("Unknown", -5);

    // Early exit if no registered faces
    if (registered.isEmpty) {
      return pair;
    }

    for (MapEntry<String, List<List<double>>> entry in registered.entries) {
      final String name = entry.key;
      final List<List<double>> storedEmbeddings = entry.value;

      // Compare against all stored embeddings (multiple angles) and use the best match
      double minDistance = double.infinity;
      for (List<double> storedEmb in storedEmbeddings) {
        // Use dot product for faster computation (no sqrt needed immediately)
        double dotProduct = 0;
        for (int i = 0; i < emb.length; i++) {
          double diff = emb[i] - storedEmb[i];
          dotProduct += diff * diff;
        }

        // Only compute sqrt if needed (when comparing or final result)
        if (dotProduct < minDistance) {
          minDistance = dotProduct;
        }
      }

      // Compute actual Euclidean distance only for the best match
      double similarity = sqrt(minDistance);

      if (pair.distance == -5 || similarity < pair.distance) {
        pair.distance = similarity;
        pair.name = name;
      }
    }

    // MobileFaceNet L2-normalized: Euclidean distance range 0-2.
    // Threshold 0.8 = cosine similarity ~0.68
    if (pair.distance > 0.6 && pair.distance != -5) {
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
  double distance;
  Pair(this.name, this.distance);
}
