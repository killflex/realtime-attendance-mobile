import '../database/database_helper.dart';
import '../logging/app_logger.dart';
import 'face_record.dart';

class FaceRepository {
  FaceRepository({required DatabaseHelper dbHelper, AppLogger? logger})
    : _dbHelper = dbHelper,
      _log = logger ?? AppLogger();

  final DatabaseHelper _dbHelper;
  final AppLogger _log;

  Future<void> init() async {
    await _dbHelper.init();
  }

  Future<List<FaceRecord>> getAllFaces() async {
    await _dbHelper.init();
    final rows = await _dbHelper.queryAllRows();
    return rows.map(FaceRecord.fromMap).toList();
  }

  Future<int> insertFace(FaceRecord record) async {
    await _dbHelper.init();
    final id = await _dbHelper.insert(record.toMap());
    _log.i('Inserted face record: name=${record.name}, id=$id');
    return id;
  }

  Future<void> deleteFace(int id) async {
    await _dbHelper.init();
    await _dbHelper.delete(id);
  }
}
