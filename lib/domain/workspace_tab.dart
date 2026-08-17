import '../connectors/data_source.dart';

enum WorkspaceView { browse, query, schema, vectors }

class WorkspaceTab {
  WorkspaceTab({
    required this.id,
    required this.connectionId,
    required this.view,
    this.container,
    this.queryText = '',
  });

  final String id;
  final String connectionId;
  WorkspaceView view;
  ContainerRef? container;
  String queryText;

  String label() {
    switch (view) {
      case WorkspaceView.browse:
        return container?.name ?? 'Browse';
      case WorkspaceView.query:
        return 'Query';
      case WorkspaceView.schema:
        return container?.name == null ? 'Schema' : '${container!.name} · schema';
      case WorkspaceView.vectors:
        return container?.name == null
            ? 'Vectors'
            : '${container!.name} · vectors';
    }
  }
}
