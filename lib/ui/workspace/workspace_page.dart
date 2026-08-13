import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../connectors/data_source.dart';
import '../../domain/connection_record.dart';
import '../../domain/workspace_tab.dart';
import '../../state/active_source_provider.dart';
import '../../state/connections_provider.dart';
import '../../state/providers.dart';
import '../../state/workspace_provider.dart';
import '../shell/tab_bar.dart';
import '../widgets/dextr_icons.dart';
import '../widgets/dextr_more_menu.dart';
import 'browse_pane.dart';
import 'file_browser_pane.dart';
import 'query_pane.dart';
import 'schema_pane.dart';

/// The page inside the shell: the strip of open objects, the view switcher, the
/// view itself, and a status line about the connection underneath it.
class WorkspacePage extends ConsumerWidget {
  const WorkspacePage({super.key, required this.connectionId});

  final String connectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(workspaceProvider);
    final tab = workspace.activeTab;

    return AstryxLayout(
      padding: AstryxSpacingToken.spacing4,
      // The body owns its own scrolling — a table pins its header row and
      // scrolls its own rows, and two scroll views inside one another is one
      // too many.
      scrollable: false,
      header: AstryxVStack(
        gap: AstryxSpacingToken.spacing3,
        align: AstryxStackAlign.stretch,
        children: <Widget>[
          const WorkspaceTabBar(),
          _ViewBar(connectionId: connectionId, tab: tab),
        ],
      ),
      footer: _StatusBar(connectionId: connectionId),
      child: tab == null
          ? _NoTab(connectionId: connectionId)
          : _PaneFor(tab: tab),
    );
  }
}

/// Browse / Query / Schema, plus what is being looked at and what can be done
/// to the connection.
class _ViewBar extends ConsumerWidget {
  const _ViewBar({required this.connectionId, required this.tab});

  final String connectionId;
  final WorkspaceTab? tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = this.tab;
    final source = ref.watch(activeDataSourceProvider).value;
    final hasContainer = tab?.container != null;
    // A view is offered only where the backend has it: an object store has no
    // schema to read, and an HTTP endpoint has no SQL to run. Disabled rather
    // than absent — a control that vanishes moves everything beside it.
    final canQuery = source is RawQueryable;
    final canReadSchema = source is SchemaReadable && hasContainer;

    return AstryxHStack(
      gap: AstryxSpacingToken.spacing3,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        AstryxSegmentedControl<WorkspaceView>(
          label: 'View',
          size: AstryxButtonSize.sm,
          value: tab?.view,
          onChanged: tab == null
              ? null
              : (view) =>
                    ref.read(workspaceProvider.notifier).setView(tab.id, view),
          segments: <AstryxSegment<WorkspaceView>>[
            AstryxSegment(
              value: WorkspaceView.browse,
              label: 'Browse',
              enabled: hasContainer,
            ),
            AstryxSegment(
              value: WorkspaceView.query,
              label: 'Query',
              enabled: canQuery,
            ),
            AstryxSegment(
              value: WorkspaceView.schema,
              label: 'Schema',
              enabled: canReadSchema,
            ),
          ],
        ),
        // The gap and the object's name are one flex child rather than a
        // `Spacer` beside a `Flexible`: those two share the free space, which
        // pulls the menu in from the edge it belongs on.
        Expanded(
          child: tab?.container == null
              ? const SizedBox.shrink()
              : Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: AstryxText(
                    tab!.container!.qualified,
                    type: AstryxTextType.code,
                    color: AstryxTextColor.secondary,
                    maxLines: 1,
                    truncateTooltip: true,
                  ),
                ),
        ),
        _ConnectionMenu(connectionId: connectionId),
      ],
    );
  }
}

/// What can be done to the connection this workspace is showing.
class _ConnectionMenu extends ConsumerStatefulWidget {
  const _ConnectionMenu({required this.connectionId});

  final String connectionId;

  @override
  ConsumerState<_ConnectionMenu> createState() => _ConnectionMenuState();
}

class _ConnectionMenuState extends ConsumerState<_ConnectionMenu> {
  final AstryxDialogController _confirmDelete = AstryxDialogController();

  @override
  void dispose() {
    _confirmDelete.dispose();
    super.dispose();
  }

  ConnectionRecord? get _record =>
      (ref.watch(connectionsProvider).value ?? const <ConnectionRecord>[])
          .cast<ConnectionRecord?>()
          .firstWhere((r) => r?.id == widget.connectionId, orElse: () => null);

  Future<void> _disconnect() async {
    await ref.read(connectionManagerProvider).close(widget.connectionId);
    ref.read(workspaceProvider.notifier).closeTabsFor(widget.connectionId);
    if (ref.read(activeConnectionIdProvider) == widget.connectionId) {
      ref.read(activeConnectionIdProvider.notifier).state = null;
    }
  }

  Future<void> _delete() async {
    final id = widget.connectionId;
    await ref.read(connectionManagerProvider).close(id);
    ref.read(workspaceProvider.notifier).closeTabsFor(id);
    await ref.read(connectionsProvider.notifier).remove(id);
    if (!mounted) return;
    if (ref.read(activeConnectionIdProvider) == id) {
      ref.read(activeConnectionIdProvider.notifier).state = null;
    }
    AstryxToastScope.of(
      context,
    ).show(const AstryxToast(message: 'Connection deleted'));
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    if (record == null) return const SizedBox.shrink();

    return AstryxHStack(
      children: <Widget>[
        DextrMoreMenu(
          label: 'Connection actions',
          entries: <AstryxMenuEntry>[
            AstryxMenuItem(
              label: 'Edit connection',
              icon: const Icon(DextrIcons.edit),
              onSelected: () => context.go('/connection/edit', extra: record),
            ),
            AstryxMenuItem(
              label: 'Disconnect',
              icon: const Icon(DextrIcons.unplug),
              onSelected: _disconnect,
            ),
            const AstryxMenuDivider(),
            AstryxMenuItem(
              label: 'Delete connection',
              icon: const Icon(DextrIcons.delete),
              destructive: true,
              onSelected: _confirmDelete.show,
            ),
          ],
        ),
        // A widget in the tree beside what opens it, not a `showDialog` call.
        // It renders nothing until the controller opens it.
        AstryxAlertDialog(
          controller: _confirmDelete,
          title: 'Delete ${record.name}?',
          description:
              'The connection and its stored credentials are removed from this '
              'machine. Nothing in the ${record.kind.label} itself is touched.',
          confirmLabel: 'Delete connection',
          destructive: true,
          onConfirm: _delete,
        ),
      ],
    );
  }
}

/// The connection's state, along the bottom of the page.
class _StatusBar extends ConsumerWidget {
  const _StatusBar({required this.connectionId});

  final String connectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(activeDataSourceProvider);
    final workspace = ref.watch(workspaceProvider);

    final (variant, label) = switch (source) {
      AsyncLoading() => (AstryxStatusDotVariant.accent, 'Connecting…'),
      AsyncError() => (AstryxStatusDotVariant.error, 'Not connected'),
      AsyncData(value: null) => (AstryxStatusDotVariant.neutral, 'Idle'),
      _ => (AstryxStatusDotVariant.success, 'Connected'),
    };
    final kind = source.value?.kind.label;

    return AstryxHStack(
      gap: AstryxSpacingToken.spacing2,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        AstryxStatusDot(variant, label: label),
        // The dot is never the whole message: these are the words a reader who
        // cannot tell green from amber relies on.
        AstryxText(
          kind == null ? label : '$label · $kind',
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
        ),
        const Spacer(),
        AstryxText(
          workspace.tabs.length == 1
              ? '1 object open'
              : '${workspace.tabs.length} objects open',
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
        ),
      ],
    );
  }
}

/// A connection is open but nothing inside it is.
class _NoTab extends ConsumerWidget {
  const _NoTab({required this.connectionId});

  final String connectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final containers = ref.watch(activeContainersProvider);
    final source = ref.watch(activeDataSourceProvider);

    return switch (source) {
      AsyncLoading() => const AstryxCenter(
        child: AstryxSpinner(label: 'Opening the connection'),
      ),
      AsyncError(:final error) => AstryxCenter(
        child: AstryxBanner(
          status: AstryxBannerStatus.error,
          title: 'Could not open this connection',
          description: '$error',
        ),
      ),
      _ => AstryxCenter(
        child: AstryxEmptyState(
          icon: const Icon(DextrIcons.column),
          title: switch (containers) {
            AsyncData(value: final list) when list.isEmpty =>
              'Nothing in this connection',
            _ => 'Pick an object',
          },
          description: switch (containers) {
            AsyncData(value: final list) when list.isEmpty =>
              'The connection opened, but it has no tables, collections or buckets.',
            _ =>
              'Choose a table, collection or bucket in the rail to browse it.',
          },
          actions: <Widget>[
            if (source.value is RawQueryable)
              AstryxButton(
                label: 'New query',
                variant: AstryxButtonVariant.primary,
                leading: const Icon(DextrIcons.terminal),
                onPressed: () => ref
                    .read(workspaceProvider.notifier)
                    .openQueryTab(connectionId),
              ),
          ],
        ),
      ),
    };
  }
}

/// The view the active tab asks for.
class _PaneFor extends ConsumerWidget {
  const _PaneFor({required this.tab});

  final WorkspaceTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(activeDataSourceProvider);

    return switch (source) {
      AsyncLoading() => const AstryxCenter(
        child: AstryxSpinner(label: 'Opening the connection'),
      ),
      AsyncError(:final error) => AstryxCenter(
        child: AstryxBanner(
          status: AstryxBannerStatus.error,
          title: 'Could not open this connection',
          description: '$error',
        ),
      ),
      AsyncData(:final value) => _viewFor(value, tab),
    };
  }

  Widget _viewFor(DataSource? source, WorkspaceTab tab) {
    switch (tab.view) {
      case WorkspaceView.browse:
        final container = tab.container;
        if (container == null) return const _MissingContainer();
        // A file or object store gets the hierarchical browser; anything
        // tabular keeps the row grid.
        if (source is FileBrowsable) {
          return FileBrowserPane(
            key: ValueKey('files-${tab.id}-${container.name}'),
            container: container,
          );
        }
        return BrowsePane(
          key: ValueKey('browse-${tab.id}-${container.name}'),
          container: container,
        );
      case WorkspaceView.query:
        return QueryPane(tabId: tab.id, initialText: tab.queryText);
      case WorkspaceView.schema:
        final container = tab.container;
        if (container == null) return const _MissingContainer();
        return SchemaPane(container: container);
    }
  }
}

class _MissingContainer extends StatelessWidget {
  const _MissingContainer();

  @override
  Widget build(BuildContext context) => const AstryxCenter(
    child: AstryxEmptyState(
      title: 'Nothing to show',
      description: 'This tab has no object attached to it.',
      size: AstryxEmptyStateSize.compact,
    ),
  );
}
