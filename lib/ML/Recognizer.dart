import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../DB/DatabaseHelper.dart';
import 'Recognition.dart';

class Recognizer {
  Interpreter? _interpreter;
  late InterpreterOptions _interpreterOptions;
  static const int inputWidth = 160;
  static const int inputHeight = 160;
  static const int outputSize = 512;
  final dbHelper = DatabaseHelper();
  Map<String, List<List<double>>> registered = {};

  // Cache untuk optimasi

  String get modelName => 'assets/facenet.tflite';
  // TODO: switch to 'assets/mobilefacenet_f32.tflite' (112x112, 128-dim)
  // after re-exporting without mixed_float16 (see notebook fix below)

  bool _isLoaded = false;

  bool get isReady => _isLoaded && _interpreter != null;

  Recognizer({int? numThreads}) {
    _interpreterOptions = InterpreterOptions();

    if (numThreads != null) {
      _interpreterOptions.threads = numThreads;
    }
    // Initialization is async; callers should await init().
  }

  Future<void> init() async {
    await loadModel();
    try {
      await initDB();
    } catch (e, st) {
      // DB init failure is non-fatal: model inference still works
      // Registered faces just won't be loaded from DB
      print('[Recognizer] initDB error (non-fatal, continuing): $e\n$st');
    }
  }

  initDB() async {
    await dbHelper.init();
    loadRegisteredFaces();
  }

  Future<void> loadRegisteredFaces() async {
    registered.clear();
    final allRows = await dbHelper.queryAllRows();
    // debugPrint('query all rows:');
    for (final row in allRows) {
      //  debugPrint(row.toString());
      print(row[DatabaseHelper.columnName]);
      String name = row[DatabaseHelper.columnName];
      String embeddingJson = row[DatabaseHelper.columnEmbedding];

      // Parse JSON array of embeddings (multiple angles)
      List<dynamic> parsedJson = jsonDecode(embeddingJson);
      List<List<double>> embd =
          parsedJson
              .map((e) => (e as List<dynamic>).map((v) => v as double).toList())
              .toList();

      registered[name] = embd;
      print('Loaded ${embd.length} embeddings for $name');
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
    // Ensure DB is open — idempotent: if already open, returns immediately
    await dbHelper.init();

    final String embeddingJson = jsonEncode(embeddings);
    final Uint8List compressedImage = await compressImage(faceImage);

    final Map<String, dynamic> row = {
      DatabaseHelper.columnName: name,
      DatabaseHelper.columnEmbedding: embeddingJson,
      DatabaseHelper.columnImage: compressedImage,
    };

    final int id = await dbHelper.insert(row);
    print('[Recognizer] ✅ Registered "$name" → DB id=$id  embeddings=${embeddings.length}');

    // Reload in-memory map so recognition works immediately after registration
    await loadRegisteredFaces();
  }


  Future<void> loadModel() async {
    try {
      print('[Recognizer] Loading model: $modelName');
      _interpreter = await Interpreter.fromAsset(
        modelName,
        options: _interpreterOptions,
      );
      _isLoaded = true;
      print(
        '[Recognizer] ✅ Model loaded. Input: ${_interpreter!.getInputTensors().map((t) => t.shape)}, Output: ${_interpreter!.getOutputTensors().map((t) => t.shape)}',
      );
    } catch (e, st) {
      _isLoaded = false;
      print('[Recognizer] ❌ Failed to load model "$modelName": $e\n$st');
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

    var input = imageToArray(image);
    print('Input shape: ${input.shape}');

    // CRITICAL: output buffer MUST be a List<List<double>> — int or bare list causes silent failure
    final List<List<double>> output = [List.filled(outputSize, 0.0)];

    //TODO performs inference
    final runs = DateTime.now().millisecondsSinceEpoch;
    _interpreter!.run(input, output);
    final run = DateTime.now().millisecondsSinceEpoch - runs;

    List<double> outputArray = output[0];

    // Guard: NaN/Inf embedding means model failed for this crop (bad input region)
    final bool hasNaN = outputArray.any((v) => v.isNaN || v.isInfinite);
    if (hasNaN) {
      print('[Recognizer] ⚠️ NaN/Inf in embedding — invalid crop or model issue. Skipping.');
      // distance = -2 signals "bad embedding" to callers (distinct from -5 = no DB)
      return Recognition('__invalid__', location, List.filled(outputSize, 0.0), -2);
    }

    print(
      'Inference time: ${run}ms | embedding[0..4]: ${outputArray.sublist(0, 4).map((v) => v.toStringAsFixed(4))}',
    );

    //TODO looks for the nearest embeeding in the database and returns the pair
    Pair pair = findNearest(outputArray);
    print('distance= ${pair.distance}');

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

    // FaceNet L2-normalized: threshold 1.0 (Euclidean on unit sphere 0–2)
    // Switch to 0.8 when using mobilefacenet_f32.tflite
    if (pair.distance > 1.0 && pair.distance != -5) {
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
