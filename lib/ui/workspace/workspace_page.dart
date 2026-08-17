import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connectors/data_source.dart';
import '../../domain/workspace_tab.dart';
import '../../state/active_source_provider.dart';
import '../../state/workspace_provider.dart';
import '../shell/tab_bar.dart';
import '../widgets/connection_actions.dart';
import '../widgets/dextr_icons.dart';
import 'browse_pane.dart';
import 'file_browser_pane.dart';
import 'query_pane.dart';
import 'schema_pane.dart';
import 'vector_pane.dart';

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
    //
    // Browse needs no object on a file-browsable source: with nothing picked it
    // is the list of buckets, which is a view of the connection itself.
    final canBrowse = hasContainer || source is FileBrowsable;
    final canQuery = source is RawQueryable;
    final canReadSchema = source is SchemaReadable && hasContainer;
    // A vector space is a view *of a collection*, so it needs one picked —
    // there is nothing to project at the level above.
    final canSeeVectors = source is VectorSearchable && hasContainer;

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
              enabled: canBrowse,
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
            AstryxSegment(
              value: WorkspaceView.vectors,
              label: 'Vectors',
              enabled: canSeeVectors,
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
        ConnectionActionsMenu(connectionId: connectionId),
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
    // An object store can be browsed with nothing picked: the buckets are the
    // first level of the pane. Offered here because with the rail collapsed this
    // empty state is the only way in.
    final browsable = source.value is FileBrowsable;

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
            _ when browsable =>
              'Open the buckets here, or choose one in the rail.',
            _ =>
              'Choose a table, collection or bucket in the rail to browse it.',
          },
          actions: <Widget>[
            if (browsable)
              AstryxButton(
                label: 'Browse buckets',
                variant: AstryxButtonVariant.primary,
                leading: const Icon(DextrIcons.bucket),
                onPressed: () => ref
                    .read(workspaceProvider.notifier)
                    .openBrowseTab(connectionId, null),
              ),
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
        // A file or object store gets the hierarchical browser; anything
        // tabular keeps the row grid.
        //
        // Keyed by the tab alone, not by the object: the browser walks between
        // buckets itself and reports where it went, and a key that included the
        // container would throw the pane away — and its filter, its scroll and
        // its selection with it — on every step.
        if (source is FileBrowsable) {
          return FileBrowserPane(
            key: ValueKey('files-${tab.id}'),
            container: container,
            tabId: tab.id,
          );
        }
        if (container == null) return const _MissingContainer();
        return BrowsePane(
          key: ValueKey('browse-${tab.id}-${container.name}'),
          container: container,
        );
      case WorkspaceView.query:
        // Keyed by the tab: the pane holds the text being edited, so without a
        // key two query tabs would share one editor and the text of whichever
        // was opened first.
        return QueryPane(
          key: ValueKey('query-${tab.id}'),
          tabId: tab.id,
          initialText: tab.queryText,
          // What the tab is open on, which is what the suggestions are about
          // until the query names something else.
          container: tab.container,
        );
      case WorkspaceView.schema:
        final container = tab.container;
        if (container == null) return const _MissingContainer();
        return SchemaPane(container: container);
      case WorkspaceView.vectors:
        final container = tab.container;
        if (container == null) return const _MissingContainer();
        // Keyed by the collection, not by the tab: the projection is of one
        // space, and pointing the tab at another collection has to throw away
        // the zoom, the selection and the neighbour list along with the plot.
        return VectorPane(
          key: ValueKey('vectors-${tab.id}-${container.name}'),
          container: container,
        );
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
