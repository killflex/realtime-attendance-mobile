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
  static const int inputWidth = 112;
  static const int inputHeight = 112;
  static const int outputSize = 128;
  final dbHelper = DatabaseHelper();
  Map<String, List<List<double>>> registered = {};

  // Cache untuk optimasi
  img.Image? _lastResizedImage;
  List<dynamic>? _lastInputArray;

  String get modelName => 'assets/facenet.tflite';

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
    await initDB();
  }

  initDB() async {
    await dbHelper.init();
    loadRegisteredFaces();
  }

  void loadRegisteredFaces() async {
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

  void registerFaceInDB(
    String name,
    List<List<double>> embeddings,
    Uint8List faceImage,
  ) async {
    String embeddingJson = jsonEncode(embeddings);
    Uint8List compressedImage = await compressImage(faceImage);
    Map<String, dynamic> row = {
      DatabaseHelper.columnName: name,
      DatabaseHelper.columnEmbedding: embeddingJson,
      'image': compressedImage,
    };

    final id = await dbHelper.insert(row);
    print('inserted row id: $id');

    loadRegisteredFaces();
  }

  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(modelName);
      _isLoaded = true;
    } catch (e) {
      _isLoaded = false;
      print('Unable to create interpreter, Caught Exception: ${e.toString()}');
    }
  }

  List<dynamic> imageToArray(img.Image inputImage) {
    // Cache optimization
    img.Image resizedImage = img.copyResize(
      inputImage,
      width: inputWidth,
      height: inputHeight,
    );

    List<double> flattenedList =
        resizedImage.data!
            .expand((channel) => [channel.r, channel.g, channel.b])
            .map((value) => value.toDouble())
            .toList();
    Float32List float32Array = Float32List.fromList(flattenedList);
    int channels = 3;
    int height = inputHeight;
    int width = inputWidth;
    Float32List reshapedArray = Float32List(1 * height * width * channels);
    for (int c = 0; c < channels; c++) {
      for (int h = 0; h < height; h++) {
        for (int w = 0; w < width; w++) {
          int index = c * height * width + h * width + w;
          reshapedArray[index] =
              (float32Array[c * height * width + h * width + w] - 127.5) /
              127.5;
        }
      }
    }
    return reshapedArray.reshape([1, inputWidth, inputHeight, 3]);
  }

  Recognition recognize(img.Image image, Rect location) {
    //TODO crop face from image resize it and convert it to float array
    if (!isReady) {
      return Recognition('Unknown', location, List.filled(outputSize, 0.0), -1);
    }

    var input = imageToArray(image);
    print(input.shape.toString());

    //TODO output array
    List output = List.filled(1 * outputSize, 0).reshape([1, outputSize]);

    //TODO performs inference
    final runs = DateTime.now().millisecondsSinceEpoch;
    _interpreter!.run(input, output);
    final run = DateTime.now().millisecondsSinceEpoch - runs;
    print('Time to run inference: $run ms$output');

    //TODO convert dynamic list to double list
    List<double> outputArray = output.first.cast<double>();

    //TODO looks for the nearest embeeding in the database and returns the pair
    Pair pair = findNearest(outputArray);
    print("distance= ${pair.distance}");

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
