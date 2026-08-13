import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../connectors/data_source.dart';
import '../domain/connection_record.dart';
import 'connections_provider.dart';
import 'providers.dart';

/// Currently focused connection id (shown in the active workspace tab).
final activeConnectionIdProvider = StateProvider<String?>((ref) => null);

/// Opens the active connection on demand and returns the live DataSource.
final activeDataSourceProvider = FutureProvider.autoDispose<DataSource?>((
  ref,
) async {
  final id = ref.watch(activeConnectionIdProvider);
  if (id == null) return null;
  final conns = ref.watch(connectionsProvider).value ?? const [];
  final record = conns.cast<ConnectionRecord?>().firstWhere(
    (r) => r?.id == id,
    orElse: () => null,
  );
  if (record == null) return null;
  final mgr = ref.watch(connectionManagerProvider);
  return mgr.open(record);
});

/// Containers for the active source (tables / collections / buckets).
final activeContainersProvider = FutureProvider.autoDispose<List<ContainerRef>>(
  (ref) async {
    final src = await ref.watch(activeDataSourceProvider.future);
    if (src == null) return const [];
    return src.listContainers();
  },
);
