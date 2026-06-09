import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/providers/app_settings.dart';
import 'services/app_services.dart';
import 'services/background_sync_service.dart';
import 'screens/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppServices.instance.db.database;
  // OS-level background sync (runs even when the app is killed). Registering the
  // periodic task here means it keeps refreshing the offline mirror across app
  // restarts; it no-ops harmlessly until a user has logged in (token present).
  await BackgroundSync.initialize();
  await BackgroundSync.registerPeriodic();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppSettings(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static ThemeData _lightTheme() => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: const OutlineInputBorder(),
          filled: true,
          fillColor: Colors.grey.shade50,
        ),
      );

  static ThemeData _darkTheme() => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: const OutlineInputBorder(),
          filled: true,
          fillColor: Colors.grey.shade900,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<AppSettings>().themeMode;
    return MaterialApp(
      title: 'Village Support',
      debugShowCheckedModeBanner: false,
      theme: _lightTheme(),
      darkTheme: _darkTheme(),
      themeMode: themeMode,
      home: const LoginScreen(),
    );
  }
}
