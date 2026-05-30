import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'state/settings_provider.dart';
import 'theme/app_theme.dart';

class DextrApp extends ConsumerWidget {
  const DextrApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final settings = ref.watch(settingsProvider);
    return MaterialApp.router(
      title: 'Dextr',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(
          seed: settings.seed, compact: settings.compactDensity),
      darkTheme: AppTheme.dark(
          seed: settings.seed, compact: settings.compactDensity),
      themeMode: settings.themeMode,
      routerConfig: router,
    );
  }
}
