import 'dart:ui';

class Recognition {
  String name;
  Rect location;
  List<double> embeddings;
  double score;
  double? prepMs;
  double? inferMs;
  double? postMs;

  /// Constructs a Category.
  Recognition(this.name, this.location, this.embeddings, this.score);
}
