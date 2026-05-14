import 'dart:convert';
import 'dart:typed_data';

import '../database/database_helper.dart';

class FaceRecord {
  final int? id;
  final String name;
  final List<List<double>> embeddings;
  final Uint8List imageBytes;

  FaceRecord({
    this.id,
    required this.name,
    required this.embeddings,
    required this.imageBytes,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      DatabaseHelper.columnName: name,
      DatabaseHelper.columnEmbedding: jsonEncode(embeddings),
      DatabaseHelper.columnImage: imageBytes,
    };

    if (id != null) {
      map[DatabaseHelper.columnId] = id;
    }

    return map;
  }

  factory FaceRecord.fromMap(Map<String, dynamic> row) {
    final embeddingJson = row[DatabaseHelper.columnEmbedding] as String;
    final parsedJson = jsonDecode(embeddingJson) as List<dynamic>;
    final embeddings =
        parsedJson
            .map(
              (e) =>
                  (e as List<dynamic>)
                      .map((v) => (v as num).toDouble())
                      .toList(),
            )
            .toList();

    return FaceRecord(
      id: row[DatabaseHelper.columnId] as int?,
      name: row[DatabaseHelper.columnName] as String,
      embeddings: embeddings,
      imageBytes: row[DatabaseHelper.columnImage] as Uint8List,
    );
  }
}
