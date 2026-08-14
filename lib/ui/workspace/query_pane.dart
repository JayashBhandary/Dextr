import 'dart:async';

import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connectors/data_source.dart';
import '../../core/export/tabular_export.dart';
import '../../core/sql/sql_completion.dart';
import '../../domain/workspace_tab.dart';
import '../../services/export_service.dart';
import '../../state/active_source_provider.dart';
import '../../state/providers.dart';
import '../../state/query_runner_provider.dart';
import '../../state/settings_provider.dart';
import '../../state/sql_catalogue_provider.dart';
import '../../state/workspace_provider.dart';
import '../widgets/data_grid.dart';
import '../widgets/dextr_icons.dart';
import '../widgets/dextr_more_menu.dart';
import '../widgets/export_dialog.dart';
import '../widgets/sql_editor.dart';
import '../widgets/sql_highlight.dart';

/// Write a query, run it, read what came back.
///
/// One card: the query and its result are one thing, and a border around each
/// half would say they were two.
///
/// The text lives here rather than in the workspace store. It used to be
/// pushed into the store on every keystroke, which rebuilt the whole workspace
/// — including the results table, which does not virtualise — between one
/// character and the next: with a few hundred rows on screen, typing stopped
/// working. The store is now written to when the typing pauses, which is all
/// it was ever for: keeping the text when the tab is left and come back to.
class QueryPane extends ConsumerStatefulWidget {
  const QueryPane({
    super.key,
    required this.tabId,
    required this.initialText,
    this.container,
  });

  final String tabId;
  final String initialText;

  /// The object this tab is open on, when it has one — the table picked in the
  /// rail. What it is for here is the suggestions: a query written against the
  /// table on screen should offer that table's columns before a `FROM` clause
  /// has been typed, which means its schema has to be fetched when the pane
  /// opens rather than when the text happens to name it.
  final ContainerRef? container;

  @override
  ConsumerState<QueryPane> createState() => _QueryPaneState();
}

class _QueryPaneState extends ConsumerState<QueryPane> {
  late final SqlHighlightController _controller = SqlHighlightController(
    text: widget.initialText,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'QueryEditor');
  final AstryxDialogController _export = AstryxDialogController();
  Timer? _persist;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    _warmContainer();
  }

  @override
  void didUpdateWidget(QueryPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The same tab can be pointed at another object without being rebuilt from
    // scratch — its key is the tab, not the table.
    if (oldWidget.container?.qualified != widget.container?.qualified) {
      _warmContainer();
    }
  }

  /// Fetches the columns of the open table, so they are already there when the
  /// first word is typed.
  ///
  /// Cheap to call more than once: the catalogue skips tables it already knows
  /// and tables whose fetch is in flight, and does nothing at all until the
  /// connection is open — which is why this is also called from the listener on
  /// the connection in [build].
  void _warmContainer() {
    final container = widget.container;
    if (container == null) return;
    ref
        .read(sqlCatalogueProvider.notifier)
        .warm(<String>[container.qualified]);
  }

  /// Leaving the editor is the end of the typing, whatever the timer thinks.
  ///
  /// Deferred a frame: focus moves *during* a build, and writing to a store
  /// half the application is watching from inside one is how "setState called
  /// during build" happens.
  void _onFocusChanged() {
    if (_focus.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _flush();
    });
  }

  void _flush() {
    _persist?.cancel();
    if (!mounted) return;
    ref
        .read(workspaceProvider.notifier)
        .updateQueryText(widget.tabId, _controller.text);
  }

  @override
  void deactivate() {
    // Switching tabs takes this pane out of the tree; the text has to survive
    // that even if the last keystroke was a moment ago. The notifier is read
    // *now*, while this is still in the tree, and written to once the frame
    // that is removing it has finished.
    _persist?.cancel();
    final notifier = ref.read(workspaceProvider.notifier);
    final tabId = widget.tabId;
    final text = _controller.text;
    final stored = ref
        .read(workspaceProvider)
        .tabs
        .cast<WorkspaceTab?>()
        .firstWhere((t) => t?.id == tabId, orElse: () => null)
        ?.queryText;
    if (stored != text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // The store outlives this pane in every ordinary case; it does not
        // when the whole connection is being torn down, and a write then is
        // both pointless and an error.
        if (notifier.mounted) notifier.updateQueryText(tabId, text);
      });
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _persist?.cancel();
    _controller.dispose();
    _focus.dispose();
    _export.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _persist?.cancel();
    _persist = Timer(const Duration(milliseconds: 400), _flush);
  }

  /// What ⌘↵ runs: the selection if there is one, otherwise the statement the
  /// caret is in.
  ///
  /// Running the whole editor is rarely what is wanted once there is more than
  /// one statement in it, and selecting a fragment to run is how every other
  /// SQL client works.
  String _sqlToRun() {
    final text = _controller.text;
    final selection = _controller.selection;
    if (selection.isValid && !selection.isCollapsed) {
      return selection.textInside(text).trim();
    }
    final caret = selection.isValid ? selection.baseOffset : text.length;
    final (start, end) = sqlStatementRange(text, caret);
    final statement = text.substring(start, end).trim();
    return statement.isEmpty ? text.trim() : statement;
  }

  void _run() {
    final sql = _sqlToRun();
    if (sql.isEmpty) return;
    // The store may be a keystroke behind, and what is run is what is on
    // screen.
    _flush();
    ref.read(queryRunnerProvider.notifier).run(sql);
  }

  // --- Export ---------------------------------------------------------------

  /// The rows the last run returned. Nothing is fetched: a result set is
  /// already in memory, and re-running the query to export it could return
  /// something different from what is on screen.
  Future<ExportTable> _exportResult(int _) async {
    final result = ref.read(queryRunnerProvider).result;
    if (result == null) {
      throw StateError('Run the query first — there is no result to export.');
    }
    return ExportTable(columns: result.columns, rows: result.rows);
  }

  /// The query text itself, as a `.sql` file.
  ///
  /// The unstructured half of exporting: no format to choose and no rows to
  /// encode, just the bytes the editor is holding. Straight to the save dialog
  /// rather than through the export dialog, because a dialog that offers one
  /// choice of one thing is a dialog in the way.
  Future<void> _exportSql() async {
    final sql = _controller.text.trim();
    if (sql.isEmpty) {
      _toast('There is no query to export', error: true);
      return;
    }
    final source = ref.read(activeDataSourceProvider).value;
    try {
      final outcome = await ref.read(exportServiceProvider).saveText(
        fileName: ExportService.suggestFileName(
          source?.displayName ?? 'query',
          'sql',
          at: DateTime.now(),
        ),
        text: sql.endsWith(';') ? '$sql\n' : '$sql;\n',
        dialogTitle: 'Export the query',
      );
      _toast(
        outcome == null ? 'Export cancelled' : 'Query saved to ${outcome.path}',
      );
    } catch (e) {
      _toast('Could not save the query: $e', error: true);
    }
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    AstryxToastScope.of(context).show(
      AstryxToast(
        message: message,
        type: error ? AstryxToastType.error : AstryxToastType.neutral,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(
      queryRunnerProvider.select((execution) => execution.running),
    );
    final source = ref.watch(activeDataSourceProvider).value;
    final catalogue = ref.watch(sqlCatalogueProvider);
    final canRun = !running && source != null;

    // The pane is usually built before the connection has finished opening, and
    // a schema cannot be read from a connection that is not there yet.
    ref.listen(activeDataSourceProvider, (previous, next) {
      if (next.value != null) _warmContainer();
    });

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
              loading: running,
              onPressed: canRun ? _run : null,
            ),
            // Two exports, and they are different things: the rows that came
            // back, and the query that produced them.
            DextrMoreMenu(
              label: 'Export',
              iconWidget: const Icon(DextrIcons.export),
              width: 240,
              entries: <AstryxMenuEntry>[
                AstryxMenuItem(
                  label: 'Export results…',
                  icon: const Icon(DextrIcons.export),
                  // Nothing to export before a run, and a dialog that opens onto
                  // "there is no result" is a dialog that should not have opened.
                  enabled: ref.watch(
                    queryRunnerProvider.select((e) => e.result != null),
                  ),
                  onSelected: _export.show,
                ),
                AstryxMenuItem(
                  label: 'Export the query…',
                  description: 'The SQL itself, as a .sql file',
                  icon: const Icon(DextrIcons.terminal),
                  onSelected: _exportSql,
                ),
              ],
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
                controller: _controller,
                focusNode: _focus,
                enabled: source != null,
                onRun: canRun ? _run : null,
                onChanged: _onChanged,
                catalogue: catalogue,
                contextTable: widget.container?.qualified,
                onCatalogueRequest: (tables) =>
                    ref.read(sqlCatalogueProvider.notifier).warm(tables),
              ),
            ),
            _EditorStatus(controller: _controller),
            const AstryxDivider(),
            // Const, and reading the providers it needs itself: a widget that
            // is identical between two builds of this pane is not rebuilt at
            // all, which is what keeps a results table of any size out of the
            // typing path.
            const _QueryResults(),
            ExportDialog(
              controller: _export,
              title: 'Export the results',
              description:
                  'The rows the last run returned. The query is not run again.',
              baseName: widget.container?.name ?? 'query-results',
              tableName: widget.container?.qualified ?? 'query_results',
              sources: <ExportSource>[
                ExportSource(
                  label: 'The result set',
                  description: 'Everything the run returned, already in memory.',
                  load: _exportResult,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Where the caret is, what would run, and how to run it.
class _EditorStatus extends StatefulWidget {
  const _EditorStatus({required this.controller});

  final SqlHighlightController controller;

  @override
  State<_EditorStatus> createState() => _EditorStatusState();
}

class _EditorStatusState extends State<_EditorStatus> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final caret = selection.isValid
        ? selection.baseOffset.clamp(0, text.length)
        : 0;
    final before = text.substring(0, caret);
    final line = '\n'.allMatches(before).length + 1;
    final column = caret - (before.lastIndexOf('\n') + 1) + 1;

    final statements = text
        .split(';')
        .where((s) => s.trim().isNotEmpty)
        .length;
    final selected = selection.isValid && !selection.isCollapsed;

    return AstryxHStack(
      gap: AstryxSpacingToken.spacing2,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        AstryxText(
          'Ln $line, Col $column',
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
          tabularNumbers: true,
        ),
        AstryxText(
          statements == 1 ? '1 statement' : '$statements statements',
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
        ),
        const Spacer(),
        // What ⌘↵ will actually run, said before it runs it.
        AstryxText(
          selected ? 'runs the selection' : 'runs the statement at the caret',
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
        ),
        const AstryxKbd.chord(<String>[
          '⌘',
          '↵',
        ], semanticsLabel: 'Command Return'),
      ],
    );
  }
}

/// The result half: what came back, or why nothing did.
class _QueryResults extends ConsumerWidget {
  const _QueryResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final execution = ref.watch(queryRunnerProvider);
    final density = ref.watch(
      settingsProvider.select((settings) => settings.density),
    );
    final result = execution.result;

    return Expanded(
      flex: 3,
      child: AstryxVStack(
        gap: AstryxSpacingToken.spacing3,
        align: AstryxStackAlign.stretch,
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          _ResultSummary(execution: execution),
          if (execution.error case final error?)
            AstryxBanner(
              status: AstryxBannerStatus.error,
              title: 'The query failed',
              description: '$error',
              onDismiss: ref.read(queryRunnerProvider.notifier).clear,
            ),
          Expanded(
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
                    density: density,
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
        // The dot is never the whole message: these are the words a reader who
        // cannot tell green from amber relies on.
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
