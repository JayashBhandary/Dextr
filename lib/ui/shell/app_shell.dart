import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/active_source_provider.dart';
import '../../state/connections_provider.dart';
import '../../state/workspace_provider.dart';
import '../widgets/dextr_icons.dart';
import '../workspace/workspace_page.dart';
import 'sidebar_connections.dart';
import 'window_frame.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeId = ref.watch(activeConnectionIdProvider);
    final workspace = ref.read(workspaceProvider.notifier);

    // Autofocus, because a key event is dispatched from whatever holds focus
    // and walks upwards: without a focused node inside the scope, ⌘W on a
    // freshly opened window would do nothing.
    return AstryxHotkeys(
      autofocus: true,
      bindings: <AstryxHotkey, VoidCallback>{
        const AstryxHotkey.mod(LogicalKeyboardKey.keyW):
            workspace.closeActiveTab,
        const AstryxHotkey.mod(LogicalKeyboardKey.keyW, alt: true):
            workspace.closeAllTabs,
      },
      child: AstryxAppShell(
        navLabel: 'Connections',
        sidebar: const ConnectionsRail(),
        // Below this the rail moves into a drawer. Chosen for this rail: the
        // widest connection name plus a table name indented under it stops
        // fitting beside a usable table at about here.
        compactBelow: 820,
        // The rail is the only surface that runs up into the caption; the
        // workspace beside it starts below the buttons like any other page.
        child: WindowCaptionInset(
          child: activeId == null
              ? const _NoConnection()
              : WorkspacePage(connectionId: activeId),
        ),
      ),
    );
  }
}

/// What the workspace shows before anything is connected.
class _NoConnection extends ConsumerWidget {
  const _NoConnection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connections = ref.watch(connectionsProvider);
    final hasAny = (connections.value ?? const []).isNotEmpty;
    final shell = AstryxAppShell.of(context);

    return AstryxCenter(
      child: AstryxEmptyState(
        icon: const Icon(DextrIcons.newConnection),
        title: hasAny ? 'No connection open' : 'No connections yet',
        description: hasAny
            ? 'Pick one from the rail to browse its tables, collections or buckets.'
            : 'Add a database, an object store or an HTTP endpoint to get started.',
        actions: <Widget>[
          if (!hasAny)
            AstryxButton(
              label: 'New connection',
              variant: AstryxButtonVariant.primary,
              leading: const Icon(DextrIcons.newConnection),
              onPressed: () => context.go('/connection/new'),
            )
          // In the drawer layout the rail is not on screen, so the way to it
          // has to be.
          else if (shell.compact)
            AstryxButton(
              label: 'Show connections',
              variant: AstryxButtonVariant.primary,
              onPressed: shell.controller.show,
            ),
        ],
      ),
    );
  }
}
