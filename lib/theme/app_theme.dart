import 'package:astryx_ui/astryx_ui.dart';

/// The astryx_ui themes Dextr offers, in the order the settings page shows them.
///
/// The engine resolves a theme once per definition, so the built-in seven are
/// looked up rather than rebuilt; only a custom accent goes through
/// [defineTheme] again.
enum DextrTheme {
  neutral,
  stone,
  gothic,
  matcha,
  butter,
  chocolate,
  y2k;

  static DextrTheme byName(String name) =>
      values.firstWhere((t) => t.name == name, orElse: () => neutral);

  String get label => switch (this) {
    neutral => 'Neutral',
    stone => 'Stone',
    gothic => 'Gothic',
    matcha => 'Matcha',
    butter => 'Butter',
    chocolate => 'Chocolate',
    y2k => 'Y2K',
  };

  /// What the theme is like, for the settings page.
  String get description => switch (this) {
    neutral => 'Grey, high contrast. The default.',
    stone => 'Warmer greys, softer borders.',
    gothic => 'Near-black surfaces, tight contrast.',
    matcha => 'Green accent, cool neutrals.',
    butter => 'Yellow accent, warm neutrals.',
    chocolate => 'Brown neutrals, amber accent.',
    y2k => 'Saturated, high chroma.',
  };

  AstryxDefinedTheme get definition => switch (this) {
    neutral => neutralTheme,
    stone => stoneTheme,
    gothic => gothicTheme,
    matcha => matchaTheme,
    butter => butterTheme,
    chocolate => chocolateTheme,
    y2k => y2kTheme,
  };
}

/// The accent swatches offered as an override on top of a theme.
///
/// The engine derives every accent token — hover, pressed, muted, on-accent —
/// from this one seed, so a swatch is a hex string rather than a palette.
const dextrAccents = <(String, int)>[
  ('Indigo', 0xFF3D5AFE),
  ('Blue', 0xFF1E88E5),
  ('Teal', 0xFF00897B),
  ('Green', 0xFF43A047),
  ('Amber', 0xFFFFB300),
  ('Orange', 0xFFFB8C00),
  ('Red', 0xFFE53935),
  ('Pink', 0xFFD81B60),
  ('Purple', 0xFF8E24AA),
  ('Slate', 0xFF546E7A),
];

/// Resolves the theme the application runs with.
///
/// [accentArgb] null means "whatever the theme picked" — the common case, and
/// the reason the accent setting is nullable rather than defaulting to indigo.
/// Given one, the theme is redefined on top of its base so the neutrals,
/// typography and motion survive and only the accent ramp is regenerated.
AstryxDefinedTheme buildDextrTheme({
  required DextrTheme theme,
  int? accentArgb,
}) {
  final base = theme.definition;
  if (accentArgb == null) return base;
  return defineTheme(
    AstryxDefineThemeInput(
      name: 'dextr-${theme.name}',
      extendsTheme: base,
      color: AstryxColorScaleConfig(accent: hexFromArgb(accentArgb)),
    ),
  );
}

/// `0xFF3D5AFE` as `#3D5AFE`, which is the form the colour engine parses.
String hexFromArgb(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
