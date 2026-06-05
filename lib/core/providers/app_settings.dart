import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_strings.dart';

/// Global app settings: language (lo / en) + theme mode (light / dark / system).
/// Persist to SharedPreferences automatically on change.
class AppSettings extends ChangeNotifier {
  static const _kLang  = 'app_language';
  static const _kTheme = 'app_theme';

  AppStrings _strings = AppStrings.lo;  // ລາວ as default
  ThemeMode  _themeMode = ThemeMode.system;

  AppStrings get strings    => _strings;
  AppStrings get s          => _strings;  // shorthand alias
  ThemeMode  get themeMode  => _themeMode;
  String     get langCode   => _strings.langCode;

  AppSettings() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final lang  = prefs.getString(_kLang)  ?? 'lo';
    final theme = prefs.getString(_kTheme) ?? 'system';
    _strings   = lang == 'en' ? AppStrings.en : AppStrings.lo;
    _themeMode = _parseTheme(theme);
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    _strings = code == 'en' ? AppStrings.en : AppStrings.lo;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLang, code);
  }

  void toggleLanguage() =>
      setLanguage(_strings.isLao ? 'en' : 'lo');

  Future<void> setTheme(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTheme, _themeStr(mode));
  }

  ThemeMode _parseTheme(String s) => switch (s) {
        'light'  => ThemeMode.light,
        'dark'   => ThemeMode.dark,
        _        => ThemeMode.system,
      };

  String _themeStr(ThemeMode m) => switch (m) {
        ThemeMode.light  => 'light',
        ThemeMode.dark   => 'dark',
        _                => 'system',
      };
}
