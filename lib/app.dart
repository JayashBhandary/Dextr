import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'state/settings_provider.dart';
import 'ui/shell/window_frame.dart';
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
      builder: (context, child) => DextrPageSurface(
        child: Overlay.wrap(
          child: WindowFrame(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
  }
}
