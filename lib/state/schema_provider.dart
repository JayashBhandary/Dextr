import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connectors/data_source.dart';
import '../core/errors.dart';
import 'active_source_provider.dart';

final containerSchemaProvider = FutureProvider.autoDispose
    .family<ContainerSchema, ContainerRef>((ref, container) async {
      final src = await ref.watch(activeDataSourceProvider.future);
      if (src == null) throw const QueryError('No active connection');
      if (src is! SchemaReadable) {
        throw const CapabilityError('Source does not support schema read');
      }
      return src.getSchema(container);
    });
