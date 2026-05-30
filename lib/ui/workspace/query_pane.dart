import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/query_runner_provider.dart';
import '../../state/workspace_provider.dart';
import '../../theme/tokens.dart';
import '../widgets/data_grid.dart';
import '../widgets/error_banner.dart';
import '../widgets/sql_editor.dart';

class QueryPane extends ConsumerWidget {
  const QueryPane({super.key, required this.tabId, required this.initialText});
  final String tabId;
  final String initialText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exec = ref.watch(queryRunnerProvider);
    final runner = ref.read(queryRunnerProvider.notifier);
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md, vertical: Spacing.xs),
          child: Row(
            children: [
              Text('Query', style: theme.textTheme.titleMedium),
              const Spacer(),
              if (exec.result?.elapsed != null)
                Text(
                  '${exec.result!.elapsed!.inMilliseconds}ms · ${exec.result!.rows.length} rows',
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(width: Spacing.sm),
              FilledButton.icon(
                onPressed: exec.running
                    ? null
                    : () {
                        final text = ref
                            .read(workspaceProvider)
                            .tabs
                            .firstWhere((t) => t.id == tabId)
                            .queryText;
                        runner.run(text);
                      },
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Run'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.sm),
            child: SqlEditor(
              initial: initialText,
              onChanged: (t) =>
                  ref.read(workspaceProvider.notifier).updateQueryText(tabId, t),
            ),
          ),
        ),
        const Divider(height: 1),
        if (exec.error != null)
          ErrorBanner(error: exec.error!, onDismiss: runner.clear),
        Expanded(
          flex: 3,
          child: exec.result == null
              ? const Center(child: Text('Run a query to see results'))
              : exec.result!.rows.isEmpty
                  ? Center(
                      child: Text(
                        exec.result!.affectedRows != null
                            ? '${exec.result!.affectedRows} rows affected'
                            : 'No rows',
                      ),
                    )
                  : DextrDataGrid(
                      columns: exec.result!.columns,
                      rows: exec.result!.rows,
                    ),
        ),
      ],
    );
  }
}
