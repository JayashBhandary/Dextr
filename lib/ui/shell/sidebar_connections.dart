import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/connection_record.dart';
import '../../state/active_source_provider.dart';
import '../../state/connections_provider.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';

class SidebarConnections extends ConsumerWidget {
  const SidebarConnections({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final conns = ref.watch(connectionsProvider);
    final activeId = ref.watch(activeConnectionIdProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              Spacing.lg, Spacing.lg, Spacing.sm, Spacing.sm),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.asset(
                  'assets/icon/icon.png',
                  width: 24,
                  height: 24,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text('Dextr',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: 'New connection',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_rounded),
                onPressed: () => context.go('/connection/new'),
              ),
              IconButton(
                tooltip: 'Settings',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => context.go('/settings'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: conns.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: Text('Failed to load:\n$e',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
            ),
            data: (list) {
              if (list.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.lg),
                    child: Text(
                      'No connections yet.\nTap + to add one.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ),
                );
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final c = list[i];
                  return _ConnectionTile(record: c, active: c.id == activeId);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ConnectionTile extends ConsumerWidget {
  const _ConnectionTile({required this.record, required this.active});
  final ConnectionRecord record;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      dense: true,
      selected: active,
      leading: const Icon(Icons.storage, size: 18),
      title: Text(record.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(record.kind.label,
          style: Theme.of(context).textTheme.bodySmall),
      onTap: () {
        ref.read(activeConnectionIdProvider.notifier).state = record.id;
      },
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (v) async {
          switch (v) {
            case 'edit':
              context.go('/connection/edit', extra: record);
            case 'close':
              await ref
                  .read(connectionManagerProvider)
                  .close(record.id);
              if (ref.read(activeConnectionIdProvider) == record.id) {
                ref.read(activeConnectionIdProvider.notifier).state = null;
              }
            case 'delete':
              await ref
                  .read(connectionManagerProvider)
                  .close(record.id);
              await ref
                  .read(connectionsProvider.notifier)
                  .remove(record.id);
              if (ref.read(activeConnectionIdProvider) == record.id) {
                ref.read(activeConnectionIdProvider.notifier).state = null;
              }
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'close', child: Text('Disconnect')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
