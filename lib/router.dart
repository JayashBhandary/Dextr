import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'domain/connection_record.dart';
import 'ui/connection_form/connection_form_page.dart';
import 'ui/settings/settings_page.dart';
import 'ui/shell/app_shell.dart';
import 'ui/shell/window_frame.dart';

/// Builds the application's routes.
///
/// [initialLocation] is a parameter so a test can mount one screen directly
/// rather than driving the UI to it.
GoRouter buildRouter({String initialLocation = '/'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      // The shell places the caption inset itself, because its rail is meant to
      // run up into it. Every other route is a page that starts at the top of
      // the window, so it is held clear of the buttons here rather than each
      // page remembering to.
      GoRoute(path: '/', builder: (context, state) => const AppShell()),
      GoRoute(
        path: '/connection/new',
        builder: (context, state) =>
            const WindowCaptionInset(child: ConnectionFormPage()),
      ),
      GoRoute(
        path: '/connection/edit',
        builder: (context, state) => WindowCaptionInset(
          child: ConnectionFormPage(editing: state.extra as ConnectionRecord?),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) =>
            const WindowCaptionInset(child: SettingsPage()),
      ),
    ],
  );
}

final routerProvider = Provider<GoRouter>((ref) => buildRouter());
