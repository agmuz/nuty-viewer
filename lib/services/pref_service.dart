import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class PrefService {
  // ===== BANKI =====
  static const _kBanks = 'nuty_banks';
  static const _kActiveBank = 'nuty_active_bank';

  /// Domyślne banki przy pierwszym uruchomieniu.
  static const List<String> defaultBanks = [
    'bank1',
    'bank2',
    'bank3',
    'bank4',
    'bank5',
  ];

  static Future<List<String>> loadBanks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kBanks);
    if (raw == null) {
      await saveBanks(defaultBanks);
      return List<String>.from(defaultBanks);
    }
    try {
      final list = jsonDecode(raw) as List;
      return list.cast<String>();
    } catch (_) {
      return List<String>.from(defaultBanks);
    }
  }

  static Future<void> saveBanks(List<String> banks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBanks, jsonEncode(banks));
  }

  static Future<String> loadActiveBank() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kActiveBank) ?? defaultBanks.first;
  }

  static Future<void> saveActiveBank(String bank) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveBank, bank);
  }

  // ===== URI BANKÓW (SAF - Dysk Google) =====
  static const _kBankUris = 'nuty_bank_uris';

  static Future<Map<String, String>> loadBankUris() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kBankUris);
    if (raw == null) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveBankUris(Map<String, String> uris) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBankUris, jsonEncode(uris));
  }

  static Future<String?> loadBankUri(String bank) async {
    final uris = await loadBankUris();
    return uris[bank];
  }

  static Future<void> saveBankUri(String bank, String? uri) async {
    final uris = await loadBankUris();
    if (uri == null || uri.isEmpty) {
      uris.remove(bank);
    } else {
      uris[bank] = uri;
    }
    await saveBankUris(uris);
  }

  // ===== MIGRACJA =====
  /// Migracja: stare klucze `playlists` / `played` (globalne)
  /// przenosi do banku "bank1".
  static Future<void> migrateIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final migrated = prefs.getBool('nuty_migrated_to_banks') ?? false;
    if (migrated) return;

    // Nic nie przenosimy — nuty to pliki, nie playlisty.
    // Ale oznaczamy jako zmigrowane, żeby nie sprawdzać w kółko.
    await prefs.setBool('nuty_migrated_to_banks', true);
  }
}
