import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(960, 600),
      center: true,
      title: 'Dextr',
      // No title bar: the app draws the top of its own window. `WindowFrame`
      // puts the strip back that the window needs to be draggable, and on
      // Windows and Linux the buttons too — there, hiding the bar takes them
      // with it. macOS keeps its traffic lights, which then float over the
      // app's own surface, which is why the frame reserves height for them.
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: true,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ProviderScope(child: DextrApp()));
}
