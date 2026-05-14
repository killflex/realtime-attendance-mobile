import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class AppLogger {
  AppLogger._(this._logger);

  final Logger _logger;

  static final AppLogger _instance = AppLogger._(_buildLogger());

  factory AppLogger() => _instance;

  static Logger _buildLogger() {
    if (kReleaseMode) {
      return Logger(level: Level.warning, printer: SimplePrinter());
    }

    return Logger(
      level: Level.debug,
      printer: PrettyPrinter(
        methodCount: 0,
        errorMethodCount: 5,
        lineLength: 120,
        colors: true,
        printEmojis: false,
        dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
      ),
    );
  }

  void d(String message) => _logger.d(message);
  void i(String message) => _logger.i(message);
  void w(String message, [Object? error, StackTrace? stackTrace]) {
    _logger.w(message, error: error, stackTrace: stackTrace);
  }

  void e(String message, [Object? error, StackTrace? stackTrace]) {
    _logger.e(message, error: error, stackTrace: stackTrace);
  }
}

