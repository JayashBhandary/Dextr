import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/workspace_tab.dart';
import '../../state/active_source_provider.dart';
import '../../state/query_runner_provider.dart';
import '../../state/settings_provider.dart';
import '../../state/workspace_provider.dart';
import '../widgets/data_grid.dart';
import '../widgets/dextr_icons.dart';
import '../widgets/sql_editor.dart';

/// Write a query, run it, read what came back.
///
/// One card: the query and its result are one thing, and a border around each
/// half would say they were two.
class QueryPane extends ConsumerWidget {
  const QueryPane({super.key, required this.tabId, required this.initialText});

  final String tabId;
  final String initialText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final execution = ref.watch(queryRunnerProvider);
    final runner = ref.read(queryRunnerProvider.notifier);
    final settings = ref.watch(settingsProvider);
    final source = ref.watch(activeDataSourceProvider).value;
    final result = execution.result;

    void run() {
      final tab = ref
          .read(workspaceProvider)
          .tabs
          .cast<WorkspaceTab?>()
          .firstWhere((t) => t?.id == tabId, orElse: () => null);
      if (tab != null) runner.run(tab.queryText);
    }

    final canRun = !execution.running && source != null;

    // The card needs a height before it will let its body flex: without one it
    // grows to fit its content, which hands the editor and the results an
    // unbounded box and neither can then take "the rest of the space".
    return LayoutBuilder(
      builder: (context, constraints) => AstryxCard(
        height: constraints.maxHeight,
        padding: AstryxSpacingToken.spacing4,
        header: AstryxHStack(
          gap: AstryxSpacingToken.spacing3,
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            // One flex child, not a Flexible and a Spacer: those share the free
            // space, which leaves Run somewhere in the middle of the bar.
            Expanded(
              child: AstryxText(
                source == null ? 'query' : '${source.displayName} · query',
                type: AstryxTextType.supporting,
                color: AstryxTextColor.secondary,
                maxLines: 1,
              ),
            ),
            AstryxButton(
              label: 'Run',
              variant: AstryxButtonVariant.primary,
              size: AstryxButtonSize.sm,
              leading: const Icon(DextrIcons.run),
              loading: execution.running,
              onPressed: canRun ? run : null,
            ),
          ],
        ),
        child: AstryxVStack(
          gap: AstryxSpacingToken.spacing3,
          align: AstryxStackAlign.stretch,
          // The stacks default to hugging their children; this one has to take
          // the height the card gave it, or the two flexible halves have
          // nothing to divide.
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            // The query takes two parts in five and the result three, because a
            // result nobody can see is the reason to have run it.
            Expanded(
              flex: 2,
              child: SqlEditor(
                initial: initialText,
                enabled: source != null,
                onRun: canRun ? run : null,
                onChanged: (text) => ref
                    .read(workspaceProvider.notifier)
                    .updateQueryText(tabId, text),
              ),
            ),
            const AstryxDivider(),
            _ResultSummary(execution: execution),
            if (execution.error case final error?)
              AstryxBanner(
                status: AstryxBannerStatus.error,
                title: 'The query failed',
                description: '$error',
                onDismiss: runner.clear,
              ),
            Expanded(
              flex: 3,
              child: result == null
                  ? const AstryxCenter(
                      child: AstryxEmptyState(
                        title: 'No results yet',
                        description: 'Run the query to see what comes back.',
                        size: AstryxEmptyStateSize.compact,
                      ),
                    )
                  : DextrDataGrid(
                      label: 'Query results',
                      columns: result.columns,
                      rows: result.rows,
                      density: settings.density,
                      emptyState: AstryxEmptyState(
                        title: result.affectedRows != null
                            ? '${result.affectedRows} rows affected'
                            : 'No rows',
                        description: result.affectedRows != null
                            ? 'The statement changed the data but returned '
                                  'nothing.'
                            : 'The query ran and matched nothing.',
                        size: AstryxEmptyStateSize.compact,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The line between the query and its result: what happened, and how long it took.
class _ResultSummary extends StatelessWidget {
  const _ResultSummary({required this.execution});

  final QueryExecution execution;

  @override
  Widget build(BuildContext context) {
    final result = execution.result;

    final (variant, label) = execution.running
        ? (AstryxStatusDotVariant.accent, 'Running…')
        : execution.error != null
        ? (AstryxStatusDotVariant.error, 'Failed')
        : result != null
        ? (AstryxStatusDotVariant.success, 'Succeeded')
        : (AstryxStatusDotVariant.neutral, 'Not run');

    final details = <String>[
      if (result != null)
        result.rows.length == 1 ? '1 row' : '${result.rows.length} rows',
      if (result?.affectedRows != null) '${result!.affectedRows} affected',
      if (result?.elapsed != null) '${result!.elapsed!.inMilliseconds} ms',
    ];

    return AstryxHStack(
      gap: AstryxSpacingToken.spacing2,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        AstryxStatusDot(variant, label: label),
        AstryxText(
          details.isEmpty ? label : '$label · ${details.join(' · ')}',
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
          tabularNumbers: true,
        ),
      ],
    );
  }
}
