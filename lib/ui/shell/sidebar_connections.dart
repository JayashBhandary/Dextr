import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../connectors/data_source.dart';
import '../../domain/connection_record.dart';
import '../../state/active_source_provider.dart';
import '../../state/connections_provider.dart';
import '../../state/rail_provider.dart';
import '../../state/settings_provider.dart';
import '../../state/workspace_provider.dart';
import '../widgets/connection_actions.dart';
import '../widgets/dextr_icons.dart';
import 'window_frame.dart';

/// Row ids the rail reports back. A rail reports one string, so the two kinds
/// of row are told apart by a prefix rather than by two callbacks.
const _connectionPrefix = 'connection:';
const _containerPrefix = 'container:';

/// The connections rail: every connection, and the objects inside the open one.
///
/// One tree rather than a list of connections beside a list of objects. A
/// connection and its tables are one hierarchy, and splitting them across two
/// panels made the reader hold the relationship in their head.
class ConnectionsRail extends ConsumerWidget {
  const ConnectionsRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connections = ref.watch(connectionsProvider);
    final activeId = ref.watch(activeConnectionIdProvider);
    final containers = ref.watch(activeContainersProvider);
    final workspace = ref.watch(workspaceProvider);
    final density = ref.watch(settingsProvider).itemDensity;
    // A rail inside the drawer is there because it was asked for, so it shows
    // its labels whatever the collapsed state of the one beside the content is.
    final collapsed =
        ref.watch(railCollapsedProvider) &&
        !(AstryxAppShellScope.maybeOf(context)?.compact ?? false);

    // The rail marks the object being looked at, falling back to the
    // connection when no object is open — so something is always current.
    final activeContainer = workspace.activeTab?.container?.name;
    final selectedId = activeId == null
        ? null
        : activeContainer == null
        ? '$_connectionPrefix$activeId'
        : '$_containerPrefix$activeId/$activeContainer';

    // The shell fills the rail only in the drawer layout, so the wide one has
    // to fill it here — otherwise the rail is the same surface as the content
    // beside it and only the divider says where one ends.
    return ColoredBox(
      color: AstryxTheme.of(context).color(AstryxColorToken.backgroundSurface),
      // The colour runs to the top of the window and the rows start below the
      // window's buttons. Padding inside the fill rather than outside it is the
      // whole point: a rail that stopped where its first row starts would leave
      // the window's own colour showing above it.
      child: Padding(
        padding: EdgeInsets.only(top: WindowCaptionScope.insetOf(context)),
        child: _nav(
          context,
          ref,
          density,
          selectedId,
          connections,
          activeId,
          containers,
          collapsed: collapsed,
        ),
      ),
    );
  }

  Widget _nav(
    BuildContext context,
    WidgetRef ref,
    AstryxItemDensity density,
    String? selectedId,
    AsyncValue<List<ConnectionRecord>> connections,
    String? activeId,
    AsyncValue<List<ContainerRef>> containers, {
    required bool collapsed,
  }) {
    return AstryxSideNav(
      label: 'Connections',
      density: density,
      selectedId: selectedId,
      collapsed: collapsed,
      onCollapsedChanged: (value) =>
          ref.read(railCollapsedProvider.notifier).state = value,
      onSelected: (id) => _onSelected(context, ref, id),
      footer: _RailFooter(collapsed: collapsed),
      entries: <AstryxNavEntry>[
        // The heading is a section with nothing in it, and the connections are
        // top-level entries after it. A rail only indents `children` for a
        // top-level item — an item nested inside a section has its children
        // dropped — so the objects inside a connection would never appear if
        // the connections lived in the section's `items`.
        AstryxNavSection(
          label: 'Connections',
          // A collapsed rail drops the heading, and its trailing action with
          // it, so Settings moves down beside the other one action the rail
          // carries rather than disappearing.
          trailing: collapsed ? null : const _SettingsButton(),
        ),
        ..._connectionEntries(
          connections,
          activeId,
          containers,
          collapsed: collapsed,
        ),
      ],
    );
  }

  /// One row per connection, with the open one's objects indented under it.
  ///
  /// A disabled row rather than nothing while loading or on failure: the rail is
  /// where a connection is expected to be, so it is where the reason it is not
  /// there belongs.
  ///
  /// Every one of those rows carries an icon, because a collapsed rail shows
  /// nothing else — a row whose only content is a hidden label is a blank gap
  /// where the explanation was meant to be.
  List<AstryxNavEntry> _connectionEntries(
    AsyncValue<List<ConnectionRecord>> connections,
    String? activeId,
    AsyncValue<List<ContainerRef>> containers, {
    required bool collapsed,
  }) {
    return switch (connections) {
      AsyncError(:final error) => <AstryxNavEntry>[
        AstryxNavItem(
          id: 'connections-error',
          label: 'Could not load connections',
          description: '$error',
          icon: const AstryxNavIcon(Icon(DextrIcons.alert)),
          enabled: false,
        ),
      ],
      AsyncData(value: final records) when records.isEmpty =>
        const <AstryxNavEntry>[
          AstryxNavItem(
            id: 'connections-empty',
            label: 'Nothing here yet',
            description: 'Add one below',
            icon: AstryxNavIcon(Icon(DextrIcons.info)),
            enabled: false,
          ),
        ],
      AsyncData(value: final records) => <AstryxNavEntry>[
        for (final record in records)
          _itemFor(
            record: record,
            open: record.id == activeId,
            containers: record.id == activeId
                ? containers.value ?? const <ContainerRef>[]
                : const <ContainerRef>[],
            loadingContainers: record.id == activeId && containers.isLoading,
            collapsed: collapsed,
          ),
      ],
      _ => const <AstryxNavEntry>[
        AstryxNavItem(
          id: 'connections-loading',
          label: 'Loading…',
          icon: AstryxNavIcon(Icon(DextrIcons.refresh)),
          enabled: false,
        ),
      ],
    };
  }

  AstryxNavItem _itemFor({
    required ConnectionRecord record,
    required bool open,
    required List<ContainerRef> containers,
    required bool loadingContainers,
    required bool collapsed,
  }) {
    return AstryxNavItem(
      id: '$_connectionPrefix${record.id}',
      label: record.name,
      description: record.kind.label,
      icon: AstryxNavIcon(
        Icon(DextrIcons.forKind(record.kind)),
        selected: open,
      ),
      // The same three actions the workspace's bar carries, on the row itself:
      // editing, disconnecting or deleting a connection should not require
      // opening it first. Named after the connection, because a rail of ten of
      // these is otherwise ten identical "Connection actions".
      trailing: ConnectionActionsMenu(
        connectionId: record.id,
        label: 'Actions for ${record.name}',
      ),
      // Collapsed, the rail is the connections and nothing else. The objects
      // inside one lose their indent when the labels go — twenty identical
      // table glyphs in a column say less than the connection they belong to,
      // and the way to them is to expand the rail again.
      children: collapsed
          ? const <AstryxNavItem>[]
          : <AstryxNavItem>[
              if (loadingContainers)
                const AstryxNavItem(
                  id: 'loading',
                  label: 'Loading…',
                  enabled: false,
                ),
              for (final container in containers)
                AstryxNavItem(
                  id: '$_containerPrefix${record.id}/${container.name}',
                  label: container.name,
                  icon: AstryxNavIcon(Icon(DextrIcons.forContainer(container))),
                ),
            ],
    );
  }

  void _onSelected(BuildContext context, WidgetRef ref, String id) {
    if (id.startsWith(_connectionPrefix)) {
      final connectionId = id.substring(_connectionPrefix.length);
      ref.read(activeConnectionIdProvider.notifier).state = connectionId;
      return;
    }
    if (!id.startsWith(_containerPrefix)) return;

    // "container:<connectionId>/<name>" — a container name may itself contain
    // a slash, so only the first one separates the two halves.
    final rest = id.substring(_containerPrefix.length);
    final split = rest.indexOf('/');
    if (split < 0) return;
    final connectionId = rest.substring(0, split);
    final name = rest.substring(split + 1);

    final container =
        (ref.read(activeContainersProvider).value ?? const <ContainerRef>[])
            .cast<ContainerRef?>()
            .firstWhere((c) => c?.name == name, orElse: () => null);
    if (container == null) return;
    ref.read(workspaceProvider.notifier).openBrowseTab(connectionId, container);
  }
}

/// The way to the settings page, in the heading of the wide rail and in the
/// footer of the collapsed one.
class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) => AstryxIconButton.custom(
    label: 'Settings',
    tooltip: 'Settings',
    variant: AstryxButtonVariant.ghost,
    size: AstryxButtonSize.sm,
    onPressed: () => context.go('/settings'),
    child: const Icon(DextrIcons.settings),
  );
}

/// Pinned below the rows: the one action an empty rail needs.
///
/// Collapsed it is the same two actions as icons — a button with a label in a
/// 64-pixel column is a button with its label clipped, and dropping the action
/// instead would mean a collapsed rail could not add a connection at all.
class _RailFooter extends StatelessWidget {
  const _RailFooter({required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    if (collapsed) {
      return const AstryxVStack(
        gap: AstryxSpacingToken.spacing1,
        align: AstryxStackAlign.center,
        children: <Widget>[_NewConnectionButton(), _SettingsButton()],
      );
    }

    return AstryxButton(
      label: 'New connection',
      variant: AstryxButtonVariant.secondary,
      size: AstryxButtonSize.sm,
      width: double.infinity,
      leading: const Icon(DextrIcons.newConnection),
      onPressed: () => context.go('/connection/new'),
    );
  }
}

/// The footer's action with its label hidden, for the collapsed rail.
class _NewConnectionButton extends StatelessWidget {
  const _NewConnectionButton();

  @override
  Widget build(BuildContext context) => AstryxIconButton.custom(
    label: 'New connection',
    tooltip: 'New connection',
    variant: AstryxButtonVariant.secondary,
    size: AstryxButtonSize.sm,
    onPressed: () => context.go('/connection/new'),
    child: const Icon(DextrIcons.newConnection),
  );
}
