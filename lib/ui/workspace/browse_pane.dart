import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../connectors/data_source.dart';
import '../../core/cell_value.dart';
import '../../core/query_spec.dart';
import '../../state/active_source_provider.dart';
import '../../state/schema_provider.dart';
import '../../state/settings_provider.dart';
import '../../theme/tokens.dart';
import '../widgets/data_grid.dart';
import '../widgets/error_banner.dart';
import '../widgets/row_form.dart';

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
  List<RowData> _rows = const [];
  List<String> _cols = const [];
  bool _isObjectStorage = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final src = await ref.read(activeDataSourceProvider.future);
      if (src == null) throw StateError('No active source');
      _isObjectStorage = src is ObjectStorage;
      final page = await src.listRows(
        widget.container,
        QuerySpec(limit: _limit, offset: _offset),
      );
      _rows = page.items;
      _cols = _rows.isEmpty ? const [] : _rows.first.keys.toList();
      if (_cols.isEmpty && !_isObjectStorage) {
        final schema = await ref.read(
          containerSchemaProvider(widget.container).future,
        );
        _cols = schema.columns.map((c) => c.name).toList();
      }
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _insertRow() async {
    final schema = await ref.read(
      containerSchemaProvider(widget.container).future,
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: RowForm(
          schema: schema,
          submitLabel: 'Insert',
          onSubmit: (r) async {
            try {
              final src = await ref.read(activeDataSourceProvider.future);
              if (src is! Writable) {
                throw StateError('Source is read-only');
              }
              await src.insertRow(widget.container, r.values);
              if (mounted) Navigator.of(context).pop();
              await _load();
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Insert failed: $e')),
                );
              }
            }
          },
        ),
      ),
    );
  }

  Future<void> _editRow(int index, RowData row) async {
    if (_isObjectStorage) {
      await _showObjectActions(row);
      return;
    }
    final schema = await ref.read(
      containerSchemaProvider(widget.container).future,
    );
    if (!mounted) return;
    final pkCols = schema.pkColumns;
    final RowId rowId;
    if (pkCols.isNotEmpty) {
      rowId = RowId({for (final c in pkCols) c: row[c] ?? const NullCell()});
    } else {
      rowId = RowId({'rowid': row['rowid'] ?? const NullCell()});
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: RowForm(
          schema: schema,
          initial: row,
          submitLabel: 'Update',
          onSubmit: (r) async {
            try {
              final src = await ref.read(activeDataSourceProvider.future);
              if (src is! Writable) {
                throw StateError('Source is read-only');
              }
              await src.updateRow(widget.container, rowId, r.values);
              if (mounted) Navigator.of(context).pop();
              await _load();
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Update failed: $e')),
                );
              }
            }
          },
        ),
      ),
    );
  }

  Future<void> _uploadObject() async {
    final pick = await FilePicker.platform.pickFiles(
      dialogTitle: 'Pick file to upload',
      withData: false,
    );
    final path = pick?.files.single.path;
    if (path == null) return;
    final key = p.basename(path);
    try {
      final src = await ref.read(activeDataSourceProvider.future);
      if (src is! ObjectStorage) {
        throw StateError('Not an object store');
      }
      await src.putObjectFromFile(widget.container, key, path);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Uploaded $key')));
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    }
  }

  Future<void> _showObjectActions(RowData row) async {
    final key = row['key']?.display() ?? '';
    if (key.isEmpty) return;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Download'),
              onTap: () async {
                Navigator.of(context).pop();
                await _downloadObject(key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Presigned GET URL'),
              onTap: () async {
                Navigator.of(context).pop();
                await _presignGet(key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.of(context).pop();
                await _deleteObject(key);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadObject(String key) async {
    final outPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save object as',
      fileName: p.basename(key),
    );
    if (outPath == null) return;
    try {
      final src = await ref.read(activeDataSourceProvider.future) as ObjectStorage;
      await src.getObjectToFile(widget.container, key, outPath);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Saved to $outPath')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  Future<void> _presignGet(String key) async {
    try {
      final src = await ref.read(activeDataSourceProvider.future) as ObjectStorage;
      final url = await src.presignGet(widget.container, key);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Presigned GET URL'),
          content: SelectableText(url),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('URL copied')),
                );
              },
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Presign failed: $e')));
      }
    }
  }

  Future<void> _deleteObject(String key) async {
    try {
      final src = await ref.read(activeDataSourceProvider.future);
      if (src is! Writable) throw StateError('Not writable');
      await src.deleteRow(widget.container, RowId({'key': StringCell(key)}));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Deleted $key')));
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md, vertical: Spacing.xs),
          child: Row(
            children: [
              Text(
                widget.container.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: Spacing.md),
              Text('rows ${_offset + 1}–${_offset + _rows.length}',
                  style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _load,
              ),
              IconButton(
                tooltip: 'Previous page',
                icon: const Icon(Icons.chevron_left),
                onPressed: _offset == 0 || _loading
                    ? null
                    : () {
                        setState(() => _offset = (_offset - _limit).clamp(0, 1 << 30));
                        _load();
                      },
              ),
              IconButton(
                tooltip: 'Next page',
                icon: const Icon(Icons.chevron_right),
                onPressed: _rows.length < _limit || _loading
                    ? null
                    : () {
                        setState(() => _offset += _limit);
                        _load();
                      },
              ),
              const SizedBox(width: Spacing.sm),
              if (_isObjectStorage)
                FilledButton.icon(
                  onPressed: _uploadObject,
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: const Text('Upload'),
                )
              else
                FilledButton.icon(
                  onPressed: _insertRow,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Insert'),
                ),
            ],
          ),
        ),
        if (_error != null) ErrorBanner(error: _error!, onDismiss: () => setState(() => _error = null)),
        if (_loading)
          const LinearProgressIndicator(minHeight: 2)
        else
          const Divider(height: 1),
        Expanded(
          child: _rows.isEmpty && _error == null
              ? const Center(child: Text('No rows'))
              : DextrDataGrid(
                  columns: _cols,
                  rows: _rows,
                  onRowTap: _editRow,
                ),
        ),
      ],
    );
  }
}
