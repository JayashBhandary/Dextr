import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/active_source_provider.dart';
import '../../state/connections_provider.dart';
import '../../state/rail_provider.dart';
import '../widgets/dextr_icons.dart';
import '../workspace/workspace_page.dart';
import 'sidebar_connections.dart';
import 'window_frame.dart';
import 'workspace_hotkeys.dart';

/// The window width below which the rail moves into a drawer.
const _compactBelow = 820.0;

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeId = ref.watch(activeConnectionIdProvider);
    final collapsed = ref.watch(railCollapsedProvider);

    // Only the rail's own shortcut lives here. Closing a tab is bound above the
    // router in `DextrApp`, because a key event walks *up* from whatever holds
    // focus: an open menu, dialog or popover is mounted in the overlay above
    // this route, so a scope down here never sees ⌘W once one is open.
    //
    // Autofocus, because until something inside the scope is focused there is
    // nothing for the event to walk through: ⌘B on a freshly opened window
    // would do nothing at all.
    return AstryxHotkeys(
      autofocus: true,
      bindings: <AstryxHotkey, VoidCallback>{
        // The same key every editor collapses its file tree with, for the same
        // reason: the rail is not what is being read while a query is written.
        toggleRailHotkey: () =>
            ref.read(railCollapsedProvider.notifier).update((value) => !value),
      },
      // The width is decided out here because the collapsed rail is only the
      // column beside the content: a drawer is opened on purpose and has room
      // for the labels, so it stays wide however the rail was left.
      child: LayoutBuilder(
        builder: (context, constraints) => AstryxAppShell(
          navLabel: 'Connections',
          sidebar: const ConnectionsRail(),
          sidebarWidth: collapsed && constraints.maxWidth >= _compactBelow
              ? railCollapsedWidth
              : railExpandedWidth,
          // Below this the rail moves into a drawer. Chosen for this rail: the
          // widest connection name plus a table name indented under it stops
          // fitting beside a usable table at about here.
          compactBelow: _compactBelow,
          // The rail is the only surface that runs up into the caption; the
          // workspace beside it starts below the buttons like any other page.
          child: WindowCaptionInset(
            child: activeId == null
                ? const _NoConnection()
                : WorkspacePage(connectionId: activeId),
          ),
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
        // The component's default 380 is a ceiling on the whole block, and its
        // standard size spends 40 of that on padding either side — leaving 300
        // for text, which the title does not fit. It is set in display type at
        // 29px, so "No connection open" wrapped across two lines.
        //
        // 580 rather than the 480 that fits the title, because the actions row
        // does not wrap: the two buttons a first launch offers need about 480
        // between them, and a narrower ceiling overflows the row rather than
        // stacking it.
        maxWidth: 580,
        icon: const Icon(DextrIcons.newConnection),
        title: hasAny ? 'No connection open' : 'No connections yet',
        description: hasAny
            ? 'Pick one from the rail to browse its tables, collections or buckets.'
            : 'Add a database, an object store or an HTTP endpoint to get started.',
        actions: <Widget>[
          if (!hasAny) ...<Widget>[
            AstryxButton(
              label: 'New connection',
              variant: AstryxButtonVariant.primary,
              leading: const Icon(DextrIcons.newConnection),
              onPressed: () => context.go('/connection/new'),
            ),
            // The other thing somebody looking at an empty rail is after: the
            // page that says what any of this is. Offered here as well as in
            // the rail, because this is where a first launch lands.
            AstryxButton(
              label: 'Read the docs',
              leading: const Icon(DextrIcons.docs),
              onPressed: () => context.go('/docs'),
            ),
          ]
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
