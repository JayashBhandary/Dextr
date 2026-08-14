import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/export/export_format.dart';
import '../domain/app_settings.dart';
import '../theme/app_theme.dart';
import 'providers.dart';

/// Holds [AppSettings] in memory, seeded with defaults and replaced once the
/// persisted file loads. Every mutation persists immediately.
class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier(this._ref) : super(const AppSettings()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    state = await _ref.read(settingsRepoProvider).load();
  }

  Future<void> _update(AppSettings next) async {
    state = next;
    await _ref.read(settingsRepoProvider).save(next);
  }

  Future<void> setColorMode(AstryxColorMode mode) =>
      _update(state.copyWith(colorMode: mode));

  Future<void> setTheme(DextrTheme theme) =>
      _update(state.copyWith(theme: theme));

  /// Null clears the override and hands the accent back to the theme.
  Future<void> setSeedColor(int? argb) => _update(
    argb == null
        ? state.copyWith(clearSeedColor: true)
        : state.copyWith(seedColor: argb),
  );

  Future<void> setDensity(AstryxTableDensity density) =>
      _update(state.copyWith(density: density));

  Future<void> setPageSize(int v) => _update(state.copyWith(pageSize: v));

  Future<void> setConfirmDeletes(bool v) =>
      _update(state.copyWith(confirmDeletes: v));

  Future<void> setExportFormat(ExportFormat v) =>
      _update(state.copyWith(exportFormat: v));

  Future<void> setExportIncludeHeader(bool v) =>
      _update(state.copyWith(exportIncludeHeader: v));

  Future<void> setExportNullText(String v) =>
      _update(state.copyWith(exportNullText: v));

  Future<void> reset() => _update(const AppSettings());
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// The resolved theme, rebuilt only when the theme or the accent changes.
final astryxThemeProvider = Provider<AstryxDefinedTheme>((ref) {
  final settings = ref.watch(settingsProvider);
  return buildDextrTheme(theme: settings.theme, accentArgb: settings.seedColor);
});
