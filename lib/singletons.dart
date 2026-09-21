import 'package:rush_synth/rush_synth.dart';
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

/// Singleton dla RushSequencer (syntezator audio).
///
/// UWAGA: rush_synth.stop() blokuje wątek natywny i po kilku wywołaniach
/// iOS zabija apkę (AURemoteIO::Stop error). Dlatego:
///  - NIE wołamy stop() w ogóle.
///  - Zamiast trzymać jedną instancję — przy każdym play() tworzymy nową.
///  - Stara instancja jest porzucana (GC się nią zajmie).
class AudioSingleton {
  static RushSequencer? _instance;
  static bool _initializing = false;
  static bool _isPlaying = false;

  static bool get isPlaying => _isPlaying;

  static Future<RushSequencer> get() async {
    if (_instance != null) return _instance!;
    if (_initializing) {
      while (_initializing) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return _instance!;
    }
    _initializing = true;
    try {
      _instance = await RushSequencer.fromAsset(
        'assets/soundfonts/FluidR3_GM.sf2',
      );
    } finally {
      _initializing = false;
    }
    return _instance!;
  }

  static RushSequencer? get instanceOrNull => _instance;

  /// Utwórz NOWĄ instancję — używaj przy każdym play().
  /// Stara instancja zostanie porzucona (GC).
  /// To jedyny sposób, żeby uniknąć stop() (który blokuje iOS).
  static Future<RushSequencer> recreate() async {
    _isPlaying = false;
    _instance = null;
    _instance = await RushSequencer.fromAsset(
      'assets/soundfonts/FluidR3_GM.sf2',
    );
    return _instance!;
  }

  /// Zwolnij instancję przy zamykaniu ekranu.
  /// NIE woła stop() — tylko ustawia null, żeby GC posprzątał.
  static void release() {
    _isPlaying = false;
    _instance = null;
  }

  static void markPlaying() {
    _isPlaying = true;
  }

  static void markStopped() {
    _isPlaying = false;
  }

  static Future<void> dispose() async {
    _isPlaying = false;
    _instance = null;
  }
}