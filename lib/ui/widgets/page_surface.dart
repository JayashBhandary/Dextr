import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

/// Paints the page, under every route.
///
/// Nothing else does. `WidgetsApp` paints no background, and `AstryxAppShell`
/// fills only its rail — and only in the drawer layout — so every pixel the
/// components do not cover shows whatever sits behind the Flutter view. On macOS
/// that is the native window, whose colour follows the *operating system's*
/// appearance rather than the mode chosen in Settings: pick Light on a Mac in
/// dark appearance and the light theme's near-black text lands on a near-black
/// window. Filling `backgroundBody` here makes the mode the app was told to use
/// the mode it actually renders in.
///
/// Installed through `AstryxApp.builder`, which puts it inside the theme scope
/// and under the overlay stack — so dialogs, popovers and toasts still portal
/// above it.
class DextrPageSurface extends StatelessWidget {
  const DextrPageSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = AstryxTheme.of(context);
    return ColoredBox(
      color: theme.color(AstryxColorToken.backgroundBody),
      // Flutter's `IconTheme` fallback is black at 24 logical pixels, which no
      // token chose and which disappears against a dark surface. Every astryx
      // control overrides this inside its own icon slots — a button's leading
      // glyph takes the button's foreground — so this is only the floor under
      // everything that sits outside one.
      child: IconTheme.merge(
        data: IconThemeData(
          color: theme.color(AstryxColorToken.iconPrimary),
          size: AstryxIconSize.sm.pixels,
        ),
        child: child,
      ),
    );
  }
}
