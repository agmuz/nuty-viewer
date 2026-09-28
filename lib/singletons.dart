import 'package:verovio_flutter/verovio_flutter.dart';

/// Singleton dla VerovioAsyncService.
///
/// Tworzy JEDEN silnik Verovio na całą sesję aplikacji.
/// Dzięki temu kolejne otwarcia utworów nie tworzą nowych workerów.
class VerovioSingleton {
  static VerovioAsyncService? _instance;
  static bool _initializing = false;

  static Future<VerovioAsyncService> get() async {
    if (_instance != null) return _instance!;
    if (_initializing) {
      while (_initializing) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return _instance!;
    }
    _initializing = true;
    try {
      final resourcePath =
          await VerovioResourceManager.ensureVerovioAssetsReady();
      _instance = await VerovioAsyncService.spawn(resourcePath: resourcePath);
    } finally {
      _initializing = false;
    }
    return _instance!;
  }

  static VerovioAsyncService? get instanceOrNull => _instance;

  static Future<void> dispose() async {
    _instance = null;
  }
}