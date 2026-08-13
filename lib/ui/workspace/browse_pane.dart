import 'package:astryx_ui/astryx_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../connectors/data_source.dart';
import '../../core/cell_value.dart';
import '../../core/query_spec.dart';
import '../../state/active_source_provider.dart';
import '../../state/schema_provider.dart';
import '../../state/settings_provider.dart';
import '../widgets/data_grid.dart';
import '../widgets/dextr_icons.dart';
import '../widgets/row_form.dart';

/// A page of rows from one table or collection, with the row editor.
class BrowsePane extends ConsumerStatefulWidget {
  const BrowsePane({super.key, required this.container});

  final ContainerRef container;

  @override
  ConsumerState<BrowsePane> createState() => _BrowsePaneState();
}

class _BrowsePaneState extends ConsumerState<BrowsePane> {
  int _offset = 0;
  late final int _limit = ref.read(settingsProvider).pageSize;
  bool _loading = false;
  Object? _error;
  List<RowData> _rows = const <RowData>[];
  List<String> _columns = const <String>[];
  bool _isObjectStorage = false;

  final AstryxDialogController _editor = AstryxDialogController();
  final RowFormController _form = RowFormController();
  ContainerSchema? _editorSchema;
  RowData? _editorRow;
  RowId? _editorRowId;
  bool _saving = false;
  String? _editorError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _editor.dispose();
    _form.dispose();
    super.dispose();
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final source = await ref.read(activeDataSourceProvider.future);
      if (source == null) throw StateError('No active source');
      _isObjectStorage = source is ObjectStorage;
      final page = await source.listRows(
        widget.container,
        QuerySpec(limit: _limit, offset: _offset),
      );
      _rows = page.items;
      _columns = _rows.isEmpty ? const <String>[] : _rows.first.keys.toList();
      // An empty page still has columns, which the schema knows even when no
      // row does — otherwise a table with nothing in it looks broken.
      if (_columns.isEmpty && !_isObjectStorage) {
        final schema = await ref.read(
          containerSchemaProvider(widget.container).future,
        );
        _columns = schema.columns.map((c) => c.name).toList();
      }
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // --- The row editor -------------------------------------------------------

  Future<void> _openEditor({RowData? row}) async {
    late final ContainerSchema schema;
    try {
      schema = await ref.read(containerSchemaProvider(widget.container).future);
    } catch (e) {
      _toast('Could not read the schema: $e', error: true);
      return;
    }
    if (!mounted) return;

    RowId? rowId;
    if (row != null) {
      final pkColumns = schema.pkColumns;
      rowId = RowId(<String, CellValue>{
        if (pkColumns.isNotEmpty)
          for (final column in pkColumns)
            column: row[column] ?? const NullCell()
        // With no declared key, SQLite's implicit rowid is the only handle
        // there is.
        else
          'rowid': row['rowid'] ?? const NullCell(),
      });
    }

    // A fresh controller per opening, so the previous row's text does not leak
    // into the next one.
    _form.dispose();
    setState(() {
      _editorSchema = schema;
      _editorRow = row;
      _editorRowId = rowId;
      _editorError = null;
    });
    _editor.show();
  }

  Future<void> _submitEditor() async {
    final schema = _editorSchema;
    if (schema == null) return;
    setState(() {
      _saving = true;
      _editorError = null;
    });
    try {
      final source = await ref.read(activeDataSourceProvider.future);
      if (source is! Writable) throw StateError('This source is read-only');
      final values = _form.read().values;
      final rowId = _editorRowId;
      if (rowId == null) {
        await source.insertRow(widget.container, values);
      } else {
        await source.updateRow(widget.container, rowId, values);
      }
      if (!mounted) return;
      _editor.hide();
      _toast(rowId == null ? 'Row inserted' : 'Row updated');
      await _load();
    } catch (e) {
      // The message stays in the dialog rather than in a toast: the user is
      // still in the form, and this is what they have to act on.
      if (mounted) setState(() => _editorError = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // --- Object-store rows ----------------------------------------------------

  Future<void> _presignGet(RowData row) async {
    final key = row['key']?.display() ?? '';
    if (key.isEmpty) return;
    try {
      final source = await ref.read(activeDataSourceProvider.future);
      if (source is! ObjectStorage) throw StateError('Not an object store');
      final url = await source.presignGet(widget.container, key);
      await Clipboard.setData(ClipboardData(text: url));
      _toast('Presigned URL copied to the clipboard');
    } catch (e) {
      _toast('Could not presign $key: $e', error: true);
    }
  }

  Future<void> _uploadObject() async {
    // file_picker 12 exposes its methods statically; `pickFile` is the
    // single-selection entry point that replaced `pickFiles(allowMultiple:)`.
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Pick a file to upload',
    );
    final path = picked?.path;
    if (path == null) return;
    final key = p.basename(path);
    try {
      final source = await ref.read(activeDataSourceProvider.future);
      if (source is! ObjectStorage) throw StateError('Not an object store');
      await source.putObjectFromFile(widget.container, key, path);
      _toast('Uploaded $key');
      await _load();
    } catch (e) {
      _toast('Could not upload $key: $e', error: true);
    }
  }

  Future<void> _deleteRow(RowData row) async {
    final key = row['key']?.display() ?? '';
    if (key.isEmpty) return;
    try {
      final source = await ref.read(activeDataSourceProvider.future);
      if (source is! Writable) throw StateError('This source is read-only');
      await source.deleteRow(
        widget.container,
        RowId(<String, CellValue>{'key': StringCell(key)}),
      );
      _toast('Deleted $key');
      await _load();
    } catch (e) {
      _toast('Could not delete $key: $e', error: true);
    }
  }

  // --- Build ----------------------------------------------------------------

  bool get _canGoBack => _offset > 0 && !_loading;
  bool get _canGoForward => _rows.length == _limit && !_loading;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final error = _error;

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing3,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        _toolbar(),
        if (_loading)
          AstryxProgressBar(
            label: 'Loading ${widget.container.name}',
            showLabel: false,
          ),
        if (error != null)
          AstryxBanner(
            status: AstryxBannerStatus.error,
            title: 'Could not read ${widget.container.name}',
            description: '$error',
            onDismiss: () => setState(() => _error = null),
          ),
        Expanded(
          child: DextrDataGrid(
            label: 'Rows of ${widget.container.qualified}',
            columns: _columns,
            rows: _rows,
            density: settings.density,
            onRowPressed: _isObjectStorage
                ? null
                : (row) => _openEditor(row: row),
            rowActionsBuilder: _isObjectStorage ? _objectActions : null,
            emptyState: AstryxEmptyState(
              icon: const Icon(DextrIcons.column),
              title: error == null ? 'No rows' : 'Nothing loaded',
              description: error == null
                  ? 'This ${widget.container.subtype ?? 'table'} is empty on this page.'
                  : 'Fix the error above and refresh.',
              size: AstryxEmptyStateSize.compact,
            ),
          ),
        ),
        _editorDialog(),
      ],
    );
  }

  Widget _toolbar() {
    final shown = _rows.isEmpty
        ? 'no rows'
        : 'rows ${_offset + 1}–${_offset + _rows.length}';

    return AstryxHStack(
      gap: AstryxSpacingToken.spacing2,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        AstryxToolbar(
          label: 'Rows',
          children: <Widget>[
            AstryxIconButton.custom(
              label: 'Refresh',
              tooltip: 'Refresh',
              variant: AstryxButtonVariant.ghost,
              size: AstryxButtonSize.sm,
              onPressed: _loading ? null : _load,
              child: const Icon(DextrIcons.refresh),
            ),
            AstryxIconButton(
              icon: AstryxIconName.chevronLeft,
              label: 'Previous page',
              tooltip: 'Previous page',
              variant: AstryxButtonVariant.ghost,
              size: AstryxButtonSize.sm,
              onPressed: _canGoBack
                  ? () {
                      setState(
                        () => _offset = (_offset - _limit).clamp(0, 1 << 30),
                      );
                      _load();
                    }
                  : null,
            ),
            AstryxIconButton(
              icon: AstryxIconName.chevronRight,
              label: 'Next page',
              tooltip: 'Next page',
              variant: AstryxButtonVariant.ghost,
              size: AstryxButtonSize.sm,
              onPressed: _canGoForward
                  ? () {
                      setState(() => _offset += _limit);
                      _load();
                    }
                  : null,
            ),
          ],
        ),
        AstryxText(
          shown,
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
          tabularNumbers: true,
        ),
        const Spacer(),
        if (_isObjectStorage)
          AstryxButton(
            label: 'Upload',
            variant: AstryxButtonVariant.primary,
            size: AstryxButtonSize.sm,
            leading: const Icon(DextrIcons.upload),
            onPressed: _loading ? null : _uploadObject,
          )
        else
          AstryxButton(
            label: 'Insert row',
            variant: AstryxButtonVariant.primary,
            size: AstryxButtonSize.sm,
            leading: const Icon(DextrIcons.insert),
            onPressed: _loading ? null : () => _openEditor(),
          ),
      ],
    );
  }

  /// Always visible, never behind hover: touch has no hover, and a row action
  /// that appears on approach is one nobody can find.
  Widget _objectActions(BuildContext context, RowData row) {
    final key = row['key']?.display() ?? 'this object';
    return AstryxHStack(
      gap: AstryxSpacingToken.spacing1,
      children: <Widget>[
        AstryxIconButton.custom(
          label: 'Copy a presigned URL for $key',
          tooltip: 'Copy presigned URL',
          variant: AstryxButtonVariant.ghost,
          size: AstryxButtonSize.sm,
          onPressed: () => _presignGet(row),
          child: const Icon(DextrIcons.link),
        ),
        AstryxIconButton.custom(
          label: 'Delete $key',
          tooltip: 'Delete',
          variant: AstryxButtonVariant.ghost,
          size: AstryxButtonSize.sm,
          onPressed: () => _deleteRow(row),
          child: const Icon(DextrIcons.delete),
        ),
      ],
    );
  }

  Widget _editorDialog() {
    final schema = _editorSchema;
    final inserting = _editorRowId == null;
    final error = _editorError;

    return AstryxDialog(
      controller: _editor,
      title: inserting
          ? 'Insert into ${widget.container.name}'
          : 'Edit row in ${widget.container.name}',
      description: inserting
          ? 'Leave a field empty to store NULL.'
          : 'Only the columns you change are written back.',
      width: 560,
      footer: AstryxHStack(
        gap: AstryxSpacingToken.spacing2,
        justify: AstryxStackJustify.end,
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          AstryxButton(
            label: 'Cancel',
            enabled: !_saving,
            onPressed: _editor.hide,
          ),
          AstryxButton(
            label: inserting ? 'Insert' : 'Save changes',
            variant: AstryxButtonVariant.primary,
            loading: _saving,
            onPressed: _submitEditor,
          ),
        ],
      ),
      child: schema == null
          ? const AstryxSpinner(label: 'Reading the schema')
          : AstryxVStack(
              gap: AstryxSpacingToken.spacing4,
              align: AstryxStackAlign.stretch,
              children: <Widget>[
                if (error != null)
                  AstryxBanner(
                    status: AstryxBannerStatus.error,
                    title: inserting ? 'Insert failed' : 'Update failed',
                    description: error,
                  ),
                RowForm(
                  key: ValueKey(_editorRow ?? 'insert'),
                  schema: schema,
                  controller: _form,
                  initial: _editorRow,
                ),
              ],
            ),
    );
  }
}
