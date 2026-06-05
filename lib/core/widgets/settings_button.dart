import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_settings.dart';

/// PopupMenu ໃນ AppBar ສຳລັບ toggle ພາສາ (ລາວ / ອັງກິດ) ແລະ theme.
/// ໃຊ້ງານ: ວາງໃນ `AppBar.actions`.
class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final settings  = context.watch<AppSettings>();
    final s         = settings.s;
    final themeMode = settings.themeMode;
    final scheme    = Theme.of(context).colorScheme;

    Widget check() => Icon(Icons.check, size: 16, color: scheme.primary);

    return PopupMenuButton<String>(
      icon: const Icon(Icons.settings),
      tooltip: s.language,
      onSelected: (value) {
        switch (value) {
          case 'lang_lo':
            context.read<AppSettings>().setLanguage('lo');
          case 'lang_en':
            context.read<AppSettings>().setLanguage('en');
          case 'theme_light':
            context.read<AppSettings>().setTheme(ThemeMode.light);
          case 'theme_dark':
            context.read<AppSettings>().setTheme(ThemeMode.dark);
          case 'theme_system':
            context.read<AppSettings>().setTheme(ThemeMode.system);
        }
      },
      itemBuilder: (_) => [
        // ── ພາສາ ────────────────────────────────────────────────────────────
        PopupMenuItem<String>(
          enabled: false,
          child: Text(s.language,
              style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.bold)),
        ),
        PopupMenuItem<String>(
          value: 'lang_lo',
          child: Row(children: [
            const Text('🇱🇦', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Text(s.langLao),
            const Spacer(),
            if (settings.langCode == 'lo') check(),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'lang_en',
          child: Row(children: [
            const Text('🇬🇧', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Text(s.langEng),
            const Spacer(),
            if (settings.langCode == 'en') check(),
          ]),
        ),
        const PopupMenuDivider(),
        // ── Theme ────────────────────────────────────────────────────────────
        PopupMenuItem<String>(
          enabled: false,
          child: Text(s.theme,
              style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.bold)),
        ),
        PopupMenuItem<String>(
          value: 'theme_light',
          child: Row(children: [
            const Icon(Icons.light_mode_outlined, size: 20),
            const SizedBox(width: 8),
            Text(s.themeLight),
            const Spacer(),
            if (themeMode == ThemeMode.light) check(),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'theme_dark',
          child: Row(children: [
            const Icon(Icons.dark_mode_outlined, size: 20),
            const SizedBox(width: 8),
            Text(s.themeDark),
            const Spacer(),
            if (themeMode == ThemeMode.dark) check(),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'theme_system',
          child: Row(children: [
            const Icon(Icons.brightness_auto_outlined, size: 20),
            const SizedBox(width: 8),
            Text(s.themeSystem),
            const Spacer(),
            if (themeMode == ThemeMode.system) check(),
          ]),
        ),
      ],
    );
  }
}
