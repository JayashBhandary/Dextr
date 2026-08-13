import 'package:astryx_ui/astryx_ui.dart';
import 'package:dextr/theme/app_theme.dart';
import 'package:dextr/ui/widgets/page_surface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app has to paint its own page.
///
/// `WidgetsApp` paints no background and `AstryxAppShell` fills only its drawer,
/// so anything the components do not cover shows whatever is behind the Flutter
/// view — on macOS the native window, which follows the *operating system's*
/// appearance. Without a surface of its own, choosing Light on a Mac in dark
/// appearance put the light theme's near-black text on a near-black window.
void main() {
  /// Mounts the surface exactly as `DextrApp` does — through `AstryxApp.builder`,
  /// so the theme in scope is the one the app would resolve.
  Future<AstryxThemeData> pumpIn(
    WidgetTester tester,
    AstryxColorMode mode, {
    DextrTheme theme = DextrTheme.neutral,
  }) async {
    late AstryxThemeData resolved;
    await tester.pumpWidget(
      AstryxApp(
        theme: buildDextrTheme(theme: theme),
        mode: mode,
        builder: (context, child) =>
            DextrPageSurface(child: child ?? const SizedBox.shrink()),
        home: Builder(
          builder: (context) {
            resolved = AstryxTheme.of(context);
            return const AstryxText('page');
          },
        ),
      ),
    );
    await tester.pump();
    return resolved;
  }

  /// The colour the surface actually paints.
  Color paintedBy(WidgetTester tester) => tester
      .widget<ColoredBox>(
        find.descendant(
          of: find.byType(DextrPageSurface),
          matching: find.byType(ColoredBox),
        ),
      )
      .color;

  testWidgets('light mode paints the light page background', (tester) async {
    final theme = await pumpIn(tester, AstryxColorMode.light);

    expect(theme.brightness, Brightness.light);
    expect(paintedBy(tester), theme.color(AstryxColorToken.backgroundBody));
  });

  testWidgets('dark mode paints the dark page background', (tester) async {
    final theme = await pumpIn(tester, AstryxColorMode.dark);

    expect(theme.brightness, Brightness.dark);
    expect(paintedBy(tester), theme.color(AstryxColorToken.backgroundBody));
  });

  testWidgets('the two modes paint different pages', (tester) async {
    // Without this the two tests above would both pass on a theme that resolved
    // the same background either way, which would prove nothing.
    await pumpIn(tester, AstryxColorMode.light);
    final light = paintedBy(tester);
    await pumpIn(tester, AstryxColorMode.dark);
    final dark = paintedBy(tester);

    expect(light, isNot(dark));
  });

  testWidgets('an icon outside a control slot takes the token colour', (
    tester,
  ) async {
    // Flutter's fallback is black at 24 logical pixels whatever the mode says,
    // which is invisible on a dark surface.
    final theme = await pumpIn(tester, AstryxColorMode.dark);
    final icons = IconTheme.of(tester.element(find.byType(AstryxText)));

    expect(icons.color, theme.color(AstryxColorToken.iconPrimary));
    expect(icons.size, AstryxIconSize.sm.pixels);
  });
}
