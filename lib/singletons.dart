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
/// rush_synth.stop() blokuje wątek natywny iOS — dlatego go NIE wołamy.
/// Zamiast tego:
///  - Każdy play() tworzy nową instancję (bo stop() blokuje).
///  - Wszystkie instancje zapisujemy na liście `_allInstances`.
///  - Panic() wycisza WSZYSTKIE instancje przez setSpeed(0).
class AudioSingleton {
  static RushSequencer? _instance;
  static bool _initializing = false;
  static bool _isPlaying = false;

  /// Wszystkie utworzone instancje — żeby móc je wyciszyć w Panic.
  static final List<RushSequencer> _allInstances = [];

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
      final seq = await RushSequencer.fromAsset(
        'assets/soundfonts/GeneralUser-GS.sf2',
      );
      _instance = seq;
      _allInstances.add(seq);
    } finally {
      _initializing = false;
    }
    return _instance!;
  }

  static RushSequencer? get instanceOrNull => _instance;

  /// Utwórz NOWĄ instancję — używaj przy każdym play().
  /// Stara zostaje na liście `_allInstances` — będzie wyciszona w Panic.
  static Future<RushSequencer> recreate() async {
    _isPlaying = false;
    final seq = await RushSequencer.fromAsset(
      'assets/soundfonts/GeneralUser-GS.sf2',
    );
    _instance = seq;
    _allInstances.add(seq);
    return seq;
  }

  /// PANIC — wycisz wszystkie silniki (setSpeed(0)).
  /// To nie zatrzymuje wątków natywnych, ale wycisza dźwięk.
  static Future<void> panic() async {
    _isPlaying = false;
    final snapshot = List<RushSequencer>.from(_allInstances);
    for (final seq in snapshot) {
      try {
        await seq.setSpeed(0.0);
      } catch (_) {}
    }
    // Wyczyść listę — stare silniki nie są już potrzebne
    _allInstances.clear();
    _instance = null;
  }

  static void markPlaying() {
    _isPlaying = true;
  }

  static void markStopped() {
    _isPlaying = false;
  }

  static Future<void> dispose() async {
    await panic();
  }
}