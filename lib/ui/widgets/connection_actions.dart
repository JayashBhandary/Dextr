import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/connection_record.dart';
import '../../state/active_source_provider.dart';
import '../../state/connections_provider.dart';
import '../../state/providers.dart';
import '../../state/workspace_provider.dart';
import 'dextr_icons.dart';
import 'dextr_more_menu.dart';

/// What can be done to one connection: edit it, close it, remove it.
///
/// One widget rather than one per place it appears. The rail carries it on
/// every connection and the workspace carries it for the open one, and two
/// copies of "delete a connection" is two places for the tab-closing and the
/// key-clearing to fall out of step.
///
/// The menu is always visible — a row's actions are not allowed to live behind
/// a hover, because a touch screen has none.
class ConnectionActionsMenu extends ConsumerStatefulWidget {
  const ConnectionActionsMenu({
    required this.connectionId,
    super.key,
    this.label,
    this.size = AstryxButtonSize.sm,
  });

  /// Which connection the actions act on. Not the record itself: the record is
  /// read from the store on every build, so an edit made elsewhere shows here
  /// rather than being frozen into a widget the caller built once.
  final String connectionId;

  /// The trigger's accessible name. Where several of these are on screen at
  /// once — a row each, down the rail — it has to say *which* connection, or a
  /// screen reader reads the same three words all the way down.
  final String? label;

  /// The trigger's size.
  final AstryxButtonSize size;

  @override
  ConsumerState<ConnectionActionsMenu> createState() =>
      _ConnectionActionsMenuState();
}

class _ConnectionActionsMenuState extends ConsumerState<ConnectionActionsMenu> {
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
    final record = _record;
    if (record == null) return;
    final id = record.id;

    await ref.read(connectionManagerProvider).close(id);
    ref.read(workspaceProvider.notifier).closeTabsFor(id);

    // The secret goes before the record, and the order is the whole point: a
    // `secretsRef` is stored nowhere but on the record, so dropping the record
    // first would leave a credential in the keychain that nothing can name.
    // Failing this way round is recoverable — a record whose secret is already
    // gone asks for the password again.
    await ref.read(secretsStoreProvider).delete(record.secretsRef);
    await ref.read(connectionsProvider.notifier).remove(id);

    if (!mounted) return;
    if (ref.read(activeConnectionIdProvider) == id) {
      ref.read(activeConnectionIdProvider.notifier).state = null;
    }
    AstryxToastScope.of(context).show(
      const AstryxToast(message: 'Connection and its credentials deleted'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    if (record == null) return const SizedBox.shrink();

    return AstryxHStack(
      children: <Widget>[
        DextrMoreMenu(
          label: widget.label ?? 'Connection actions',
          size: widget.size,
          // Narrower than the default surface: these three labels are short,
          // and the rail is only so wide — a menu wider than the rail cannot
          // line up with a trigger inside it, and gets pushed across until it
          // fits the window instead.
          width: 220,
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
