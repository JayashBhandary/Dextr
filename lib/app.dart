import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'state/settings_provider.dart';
import 'state/workspace_provider.dart';
import 'ui/shell/window_frame.dart';
import 'ui/shell/workspace_hotkeys.dart';
import 'ui/widgets/page_surface.dart';

class DextrApp extends ConsumerWidget {
  const DextrApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final settings = ref.watch(settingsProvider);
    final theme = ref.watch(astryxThemeProvider);

    // AstryxApp is a WidgetsApp, not a MaterialApp: it installs the theme, the
    // icon registry, the localisations, the focus-visible scope and the toast
    // host, and nothing has to neutralise Material's defaults afterwards.
    return AstryxApp.router(
      title: 'Dextr',
      theme: theme,
      mode: settings.colorMode,
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      // Both of these belong above the router, so they hold for every page and
      // survive navigation: the surface because the app has to paint its own
      // page, the frame because the window has no title bar of its own.
      // The frame gets an overlay of its own. The builder runs *above* the
      // router, and the only overlay a routed app has is the one the navigator
      // builds underneath it — so the band's own controls have nowhere to
      // portal a tooltip or a menu to, and the first hover over the window
      // buttons throws `No Overlay widget found`.
      builder: (context, child) => _TabHotkeys(
        child: DextrPageSurface(
          child: Overlay.wrap(
            child: WindowFrame(child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
  }
}

/// Binds ⌘/Ctrl+W and ⌘/Ctrl+⌥+W for the whole application.
///
/// Above the router on purpose. A key event is dispatched from whatever holds
/// focus and walks *up* the focus chain, and the two places focus most often
/// sits are not inside the routed page: an open menu, popover or dialog is
/// mounted in the overlay above the navigator, and the window caption's own
/// buttons sit beside it. A scope inside the shell misses both — which is
/// exactly the "sometimes ⌘W does nothing" the shortcut had before — so the
/// scope that owns closing a tab is the outermost one there is.
class _TabHotkeys extends ConsumerWidget {
  const _TabHotkeys({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.read(workspaceProvider.notifier);

    // Autofocus, because until something in the subtree is focused there is
    // nothing for a key event to walk through: ⌘W on a freshly opened window
    // would otherwise do nothing at all. The node is skipped by Tab, so this
    // costs no tab stop, and the shell's own scope below still takes focus for
    // its rail shortcut.
    return AstryxHotkeys(
      autofocus: true,
      bindings: <AstryxHotkey, VoidCallback>{
        closeTabHotkey: workspace.closeActiveTab,
        closeAllTabsHotkey: workspace.closeAllTabs,
      },
      child: child,
    );
  }
}
