import 'dart:convert';

import 'package:astryx_ui/astryx_ui.dart';

import '../theme/app_theme.dart';

/// User-configurable application settings, persisted as JSON.
class AppSettings {
  const AppSettings({
    this.colorMode = AstryxColorMode.system,
    this.theme = DextrTheme.neutral,
    this.seedColor,
    this.density = AstryxTableDensity.compact,
    this.pageSize = 100,
    this.confirmDeletes = true,
  });

  /// Light, dark, or follow the OS.
  final AstryxColorMode colorMode;

  /// Which astryx_ui theme the tokens come from.
  final DextrTheme theme;

  /// An accent override as a 32-bit ARGB int, or null to keep the theme's own.
  final int? seedColor;

  /// How much room a row of data takes.
  final AstryxTableDensity density;

  /// Default rows-per-page when browsing tabular data.
  final int pageSize;

  /// Ask for confirmation before destructive actions.
  final bool confirmDeletes;

  /// The rhythm lists and rails take, which follows the table density: a user
  /// who asked for dense rows did not mean dense rows only in tables.
  AstryxItemDensity get itemDensity => density == AstryxTableDensity.spacious
      ? AstryxItemDensity.balanced
      : AstryxItemDensity.compact;

  AppSettings copyWith({
    AstryxColorMode? colorMode,
    DextrTheme? theme,
    int? seedColor,
    bool clearSeedColor = false,
    AstryxTableDensity? density,
    int? pageSize,
    bool? confirmDeletes,
  }) => AppSettings(
    colorMode: colorMode ?? this.colorMode,
    theme: theme ?? this.theme,
    seedColor: clearSeedColor ? null : (seedColor ?? this.seedColor),
    density: density ?? this.density,
    pageSize: pageSize ?? this.pageSize,
    confirmDeletes: confirmDeletes ?? this.confirmDeletes,
  );

  Map<String, Object?> toJson() => {
    'colorMode': colorMode.name,
    'theme': theme.name,
    'seedColor': seedColor,
    'density': density.name,
    'pageSize': pageSize,
    'confirmDeletes': confirmDeletes,
  };

  /// Reads both the current shape and the pre-astryx one: `themeMode` was the
  /// Material `ThemeMode` (same three names), and `compactDensity` was a bool.
  /// An installed copy should not lose its settings to a UI rewrite.
  static AppSettings fromJson(Map<String, Object?> j) {
    final mode = (j['colorMode'] ?? j['themeMode']) as String?;
    final density = j['density'] as String?;
    final legacyCompact = j['compactDensity'] as bool?;
    return AppSettings(
      colorMode: AstryxColorMode.values.firstWhere(
        (m) => m.name == mode,
        orElse: () => AstryxColorMode.system,
      ),
      theme: DextrTheme.byName(j['theme'] as String? ?? 'neutral'),
      seedColor: (j['seedColor'] as num?)?.toInt(),
      density: AstryxTableDensity.values.firstWhere(
        (d) => d.name == density,
        orElse: () => legacyCompact == false
            ? AstryxTableDensity.balanced
            : AstryxTableDensity.compact,
      ),
      pageSize: (j['pageSize'] as num?)?.toInt() ?? 100,
      confirmDeletes: j['confirmDeletes'] as bool? ?? true,
    );
  }

  String encode() => jsonEncode(toJson());

  static AppSettings decode(String raw) =>
      fromJson(jsonDecode(raw) as Map<String, Object?>);
}
