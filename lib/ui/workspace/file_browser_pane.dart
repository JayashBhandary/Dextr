import 'dart:convert';

import 'package:astryx_ui/astryx_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../connectors/data_source.dart';
import '../../state/active_source_provider.dart';
import '../../state/settings_provider.dart';
import '../widgets/dextr_icons.dart';
import '../widgets/dextr_more_menu.dart';

enum _SortKey { name, size, modified }

/// Hierarchical file browser for any [FileBrowsable] source (S3/MinIO today;
/// Drive/Dropbox later). Talks only to the [FileBrowsable] contract and gates
/// every action on [FileBrowsable.fileOps].
class FileBrowserPane extends ConsumerStatefulWidget {
  const FileBrowserPane({super.key, required this.container});

  final ContainerRef container;

  @override
  ConsumerState<FileBrowserPane> createState() => _FileBrowserPaneState();
}

class _FileBrowserPaneState extends ConsumerState<FileBrowserPane> {
  String _path = ''; // current folder prefix, '' = container root
  List<FileEntry> _entries = const <FileEntry>[];
  Set<Object> _selected = const <Object>{};
  Set<FileOp> _ops = const <FileOp>{};
  bool _loading = false;
  Object? _error;
  String _query = '';
  _SortKey _sort = _SortKey.name;

  final TextEditingController _filter = TextEditingController();

  // One prompt dialog, reused: a text field in a modal is the same shape
  // whether it is naming a folder or a destination.
  final AstryxDialogController _prompt = AstryxDialogController();
  final TextEditingController _promptValue = TextEditingController();
  String _promptTitle = '';
  String _promptLabel = '';
  String _promptConfirm = 'OK';
  void Function(String value)? _promptSubmit;

  final AstryxDialogController _confirmDelete = AstryxDialogController();
  List<String> _pendingDelete = const <String>[];

  final AstryxDialogController _previewDialog = AstryxDialogController();
  FileEntry? _previewEntry;
  FileBytes? _previewData;
  Object? _previewError;
  bool _previewLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _filter.dispose();
    _prompt.dispose();
    _promptValue.dispose();
    _confirmDelete.dispose();
    _previewDialog.dispose();
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

  Future<FileBrowsable?> _src() async {
    final source = await ref.read(activeDataSourceProvider.future);
    return source is FileBrowsable ? source : null;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _selected = const <Object>{};
    });
    try {
      final source = await _src();
      if (source == null) throw StateError('Source is not file-browsable');
      _ops = source.fileOps;
      final listing = await source.listEntries(widget.container, _path);
      _entries = listing.entries;
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _navigateTo(String path) {
    setState(() {
      _path = path;
      _query = '';
      _filter.clear();
    });
    _load();
  }

  // --- Filtering and sorting ------------------------------------------------

  List<FileEntry> get _visible {
    var list = _entries;
    if (_query.isNotEmpty) {
      final query = _query.toLowerCase();
      list = list.where((e) => e.name.toLowerCase().contains(query)).toList();
    }
    final folders = list.where((e) => e.isFolder).toList();
    final files = list.where((e) => !e.isFolder).toList();
    int compare(FileEntry a, FileEntry b) => switch (_sort) {
      _SortKey.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      _SortKey.size => (a.size ?? 0).compareTo(b.size ?? 0),
      _SortKey.modified => (a.modified ?? DateTime(0)).compareTo(
        b.modified ?? DateTime(0),
      ),
    };
    // Folders always sort by name and always come first: they are the structure
    // of the listing, not rows in it.
    folders.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    files.sort(compare);
    return <FileEntry>[...folders, ...files];
  }

  // --- Prompts ---------------------------------------------------------------

  void _ask({
    required String title,
    required String label,
    required String confirmLabel,
    String initial = '',
    required void Function(String value) onSubmit,
  }) {
    setState(() {
      _promptTitle = title;
      _promptLabel = label;
      _promptConfirm = confirmLabel;
      _promptSubmit = onSubmit;
      _promptValue.text = initial;
    });
    _prompt.show();
  }

  void _submitPrompt() {
    final value = _promptValue.text.trim();
    if (value.isEmpty) return;
    _prompt.hide();
    _promptSubmit?.call(value);
  }

  // --- Mutations -------------------------------------------------------------

  void _newFolder() => _ask(
    title: 'New folder',
    label: 'Folder name',
    confirmLabel: 'Create folder',
    onSubmit: (name) async {
      try {
        final source = await _src();
        await source!.createFolder(widget.container, '$_path$name');
        _toast('Created $name/');
        await _load();
      } catch (e) {
        _toast('Could not create $name: $e', error: true);
      }
    },
  );

  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Pick files to upload',
    );
    final files = picked?.files ?? const <PlatformFile>[];
    if (files.isEmpty) return;
    try {
      final source = await _src();
      var uploaded = 0;
      for (final file in files) {
        final path = file.path;
        if (path == null) continue;
        await source!.uploadFile(
          widget.container,
          '$_path${p.basename(path)}',
          path,
        );
        uploaded++;
      }
      _toast(uploaded == 1 ? 'Uploaded 1 file' : 'Uploaded $uploaded files');
      await _load();
    } catch (e) {
      _toast('Upload failed: $e', error: true);
    }
  }

  /// Downloads into a folder the user picks.
  ///
  /// file_picker 12's `saveFile` writes bytes it is given rather than handing
  /// back a path, and a download that had to be buffered in memory first would
  /// cap the size of file this tool can fetch. Asking for the folder keeps the
  /// transfer streaming to disk.
  Future<void> _download(List<FileEntry> entries) async {
    final files = entries.where((e) => !e.isFolder).toList();
    if (files.isEmpty) return;
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: files.length == 1
          ? 'Where should ${files.single.name} go?'
          : 'Save ${files.length} files into folder',
    );
    if (directory == null) return;
    try {
      final source = await _src();
      var saved = 0;
      for (final entry in files) {
        await source!.downloadFile(
          widget.container,
          entry.path,
          p.join(directory, entry.name),
        );
        saved++;
      }
      _toast(
        saved == 1 ? 'Saved to $directory' : 'Saved $saved files to $directory',
      );
    } catch (e) {
      _toast('Download failed: $e', error: true);
    }
  }

  void _requestDelete(List<String> paths) {
    if (paths.isEmpty) return;
    if (!ref.read(settingsProvider).confirmDeletes) {
      _delete(paths);
      return;
    }
    setState(() => _pendingDelete = paths);
    _confirmDelete.show();
  }

  Future<void> _delete(List<String> paths) async {
    try {
      final source = await _src();
      await source!.deleteEntries(widget.container, paths);
      _toast(
        paths.length == 1 ? 'Deleted 1 item' : 'Deleted ${paths.length} items',
      );
      await _load();
    } catch (e) {
      _toast('Delete failed: $e', error: true);
    }
  }

  void _rename(FileEntry entry) => _ask(
    title: 'Rename',
    label: 'New name',
    confirmLabel: 'Rename',
    initial: entry.name,
    onSubmit: (name) async {
      if (name == entry.name) return;
      final to = entry.isFolder ? '$_path$name/' : '$_path$name';
      try {
        final source = await _src();
        await source!.moveEntry(widget.container, entry.path, to);
        _toast('Renamed to $name');
        await _load();
      } catch (e) {
        _toast('Rename failed: $e', error: true);
      }
    },
  );

  void _moveOrCopy(FileEntry entry, {required bool move}) => _ask(
    title: move ? 'Move to' : 'Copy to',
    label: 'Destination path',
    confirmLabel: move ? 'Move' : 'Copy',
    initial: entry.path,
    onSubmit: (destination) async {
      if (destination == entry.path) return;
      var to = destination;
      if (entry.isFolder && !to.endsWith('/')) to = '$to/';
      try {
        final source = await _src();
        if (move) {
          await source!.moveEntry(widget.container, entry.path, to);
        } else {
          await source!.copyEntry(widget.container, entry.path, to);
        }
        _toast(move ? 'Moved to $to' : 'Copied to $to');
        await _load();
      } catch (e) {
        _toast('${move ? 'Move' : 'Copy'} failed: $e', error: true);
      }
    },
  );

  Future<void> _share(FileEntry entry) async {
    try {
      final source = await _src();
      final url = await source!.shareLink(widget.container, entry.path);
      if (url == null) {
        _toast('This source does not offer share links', error: true);
        return;
      }
      await Clipboard.setData(ClipboardData(text: url));
      _toast('Share link copied to the clipboard');
    } catch (e) {
      _toast('Could not build a share link: $e', error: true);
    }
  }

  // --- Preview ---------------------------------------------------------------

  Future<void> _preview(FileEntry entry) async {
    setState(() {
      _previewEntry = entry;
      _previewData = null;
      _previewError = null;
      _previewLoading = _isPreviewable(entry);
    });
    _previewDialog.show();
    if (!_isPreviewable(entry)) return;
    try {
      final source = await _src();
      final data = await source!.readBytes(widget.container, entry.path);
      if (mounted) setState(() => _previewData = data);
    } catch (e) {
      if (mounted) setState(() => _previewError = e);
    } finally {
      if (mounted) setState(() => _previewLoading = false);
    }
  }

  static bool _isPreviewable(FileEntry entry) =>
      !entry.isFolder && (_isImage(entry.name) || _isText(entry.name));

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final density = ref.watch(settingsProvider).density;
    final visible = _visible;
    final error = _error;

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing3,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        _breadcrumbs(),
        _toolbar(),
        if (_selected.isNotEmpty) _selectionBanner(),
        if (_loading)
          AstryxProgressBar(
            label: 'Listing ${widget.container.name}',
            showLabel: false,
          ),
        if (error != null)
          AstryxBanner(
            status: AstryxBannerStatus.error,
            title: 'Could not list this folder',
            description: '$error',
            onDismiss: () => setState(() => _error = null),
          ),
        Expanded(child: _table(visible, density)),
        _promptHost(),
        _deleteHost(),
        _previewHost(),
      ],
    );
  }

  Widget _breadcrumbs() {
    final segments = _path.split('/').where((s) => s.isNotEmpty).toList();
    var accumulated = '';
    return AstryxBreadcrumbs(
      label: 'Folder path',
      items: <AstryxBreadcrumb>[
        AstryxBreadcrumb(
          label: widget.container.name,
          icon: const DextrIcon(
            DextrIcons.bucket,
            color: AstryxIconColor.secondary,
          ),
          onPressed: _path.isEmpty ? null : () => _navigateTo(''),
        ),
        for (final segment in segments)
          () {
            accumulated = '$accumulated$segment/';
            final target = accumulated;
            return AstryxBreadcrumb(
              label: segment,
              onPressed: _path == target ? null : () => _navigateTo(target),
            );
          }(),
      ],
    );
  }

  Widget _toolbar() {
    return AstryxHStack(
      gap: AstryxSpacingToken.spacing2,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        AstryxToolbar(
          label: 'Folder',
          children: <Widget>[
            AstryxIconButton.custom(
              label: 'Up one folder',
              tooltip: 'Up one folder',
              variant: AstryxButtonVariant.ghost,
              size: AstryxButtonSize.sm,
              onPressed: _path.isEmpty || _loading
                  ? null
                  : () {
                      final segments =
                          _path.split('/').where((s) => s.isNotEmpty).toList()
                            ..removeLast();
                      _navigateTo(
                        segments.isEmpty ? '' : '${segments.join('/')}/',
                      );
                    },
              child: const Icon(DextrIcons.up),
            ),
            AstryxIconButton.custom(
              label: 'Refresh',
              tooltip: 'Refresh',
              variant: AstryxButtonVariant.ghost,
              size: AstryxButtonSize.sm,
              onPressed: _loading ? null : _load,
              child: const Icon(DextrIcons.refresh),
            ),
            if (_ops.contains(FileOp.makeFolder))
              AstryxIconButton.custom(
                label: 'New folder',
                tooltip: 'New folder',
                variant: AstryxButtonVariant.ghost,
                size: AstryxButtonSize.sm,
                onPressed: _loading ? null : _newFolder,
                child: const Icon(DextrIcons.folderPlus),
              ),
          ],
        ),
        Expanded(
          child: AstryxTextInput(
            label: 'Filter this folder',
            labelHidden: true,
            placeholder: 'Filter this folder…',
            size: AstryxInputSize.sm,
            controller: _filter,
            showClear: true,
            leading: const AstryxIcon(AstryxIconName.search),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        AstryxSelector<_SortKey>(
          label: 'Sort files by',
          labelHidden: true,
          value: _sort,
          width: 150,
          size: AstryxInputSize.sm,
          onChanged: (value) => setState(() => _sort = value ?? _SortKey.name),
          options: const <AstryxSelectorEntry<_SortKey>>[
            AstryxSelectorOption(value: _SortKey.name, label: 'Name'),
            AstryxSelectorOption(value: _SortKey.size, label: 'Size'),
            AstryxSelectorOption(value: _SortKey.modified, label: 'Modified'),
          ],
        ),
        if (_ops.contains(FileOp.upload))
          AstryxButton(
            label: 'Upload',
            variant: AstryxButtonVariant.primary,
            size: AstryxButtonSize.sm,
            leading: const Icon(DextrIcons.upload),
            onPressed: _loading ? null : _upload,
          ),
      ],
    );
  }

  Widget _selectionBanner() {
    final selectedEntries = _entries
        .where((e) => _selected.contains(e.path))
        .toList();
    return AstryxBanner(
      status: AstryxBannerStatus.info,
      // Not announced: the count is already on the checkboxes the user just
      // ticked, and interrupting on every tick is noise.
      announce: false,
      title: _selected.length == 1
          ? '1 item selected'
          : '${_selected.length} items selected',
      onDismiss: () => setState(() => _selected = const <Object>{}),
      actions: <Widget>[
        if (_ops.contains(FileOp.download))
          AstryxButton(
            label: 'Download',
            size: AstryxButtonSize.sm,
            leading: const Icon(DextrIcons.download),
            onPressed: () => _download(selectedEntries),
          ),
        if (_ops.contains(FileOp.delete))
          AstryxButton(
            label: 'Delete',
            variant: AstryxButtonVariant.destructive,
            size: AstryxButtonSize.sm,
            leading: const Icon(DextrIcons.delete),
            onPressed: () =>
                _requestDelete(selectedEntries.map((e) => e.path).toList()),
          ),
      ],
    );
  }

  Widget _table(List<FileEntry> entries, AstryxTableDensity density) {
    return AstryxTable<FileEntry>(
      label:
          'Files in ${widget.container.name}${_path.isEmpty ? '' : '/$_path'}',
      rows: entries,
      density: density,
      keyOf: (entry) => entry.path,
      rowLabelOf: (entry) =>
          entry.isFolder ? 'folder ${entry.name}' : entry.name,
      selectionMode: AstryxTableSelectionMode.multiple,
      selected: _selected,
      onSelectionChanged: (selected) => setState(() => _selected = selected),
      onRowPressed: (entry) =>
          entry.isFolder ? _navigateTo(entry.path) : _preview(entry),
      rowActionsBuilder: _rowActions,
      rowActionsWidth: 48,
      emptyState: AstryxEmptyState(
        icon: const Icon(DextrIcons.bucket),
        title: _query.isEmpty ? 'Empty folder' : 'No matches',
        description: _query.isEmpty
            ? 'Upload something, or create a folder to organise it first.'
            : 'Nothing here matches “$_query”.',
        size: AstryxEmptyStateSize.compact,
        actions: <Widget>[
          if (_query.isEmpty && _ops.contains(FileOp.upload))
            AstryxButton(
              label: 'Upload',
              variant: AstryxButtonVariant.primary,
              leading: const Icon(DextrIcons.upload),
              onPressed: _upload,
            ),
        ],
      ),
      columns: <AstryxTableColumn<FileEntry>>[
        AstryxTableColumn<FileEntry>(
          id: 'name',
          header: 'Name',
          width: const AstryxTableColumnWidth.flex(2),
          cellBuilder: (context, entry) => AstryxHStack(
            gap: AstryxSpacingToken.spacing2,
            children: <Widget>[
              DextrIcon(
                DextrIcons.forFile(entry),
                color: AstryxIconColor.secondary,
              ),
              Flexible(child: AstryxText(entry.name, maxLines: 1)),
            ],
          ),
        ),
        AstryxTableColumn<FileEntry>(
          id: 'size',
          header: 'Size',
          width: const AstryxTableColumnWidth.fixed(110),
          alignment: AstryxTableAlignment.end,
          cellBuilder: (context, entry) => entry.isFolder || entry.size == null
              ? const AstryxText('—', color: AstryxTextColor.disabled)
              : AstryxText(
                  _humanSize(entry.size!),
                  type: AstryxTextType.supporting,
                  tabularNumbers: true,
                ),
        ),
        AstryxTableColumn<FileEntry>(
          id: 'modified',
          header: 'Modified',
          width: const AstryxTableColumnWidth.fixed(150),
          cellBuilder: (context, entry) => entry.modified == null
              ? const AstryxText('—', color: AstryxTextColor.disabled)
              : AstryxTimestamp(entry.modified!),
        ),
      ],
    );
  }

  Widget _rowActions(BuildContext context, FileEntry entry) {
    return DextrMoreMenu(
      label: 'Actions for ${entry.name}',
      entries: <AstryxMenuEntry>[
        if (entry.isFolder)
          AstryxMenuItem(
            label: 'Open',
            icon: const Icon(DextrIcons.bucket),
            onSelected: () => _navigateTo(entry.path),
          ),
        if (!entry.isFolder && _ops.contains(FileOp.preview))
          AstryxMenuItem(
            label: 'Preview',
            icon: const Icon(DextrIcons.preview),
            onSelected: () => _preview(entry),
          ),
        if (!entry.isFolder && _ops.contains(FileOp.download))
          AstryxMenuItem(
            label: 'Download',
            icon: const Icon(DextrIcons.download),
            onSelected: () => _download(<FileEntry>[entry]),
          ),
        if (!entry.isFolder && _ops.contains(FileOp.share))
          AstryxMenuItem(
            label: 'Copy share link',
            icon: const Icon(DextrIcons.link),
            onSelected: () => _share(entry),
          ),
        if (_ops.contains(FileOp.rename))
          AstryxMenuItem(
            label: 'Rename…',
            icon: const Icon(DextrIcons.edit),
            onSelected: () => _rename(entry),
          ),
        if (_ops.contains(FileOp.move))
          AstryxMenuItem(
            label: 'Move to…',
            icon: const Icon(DextrIcons.move),
            onSelected: () => _moveOrCopy(entry, move: true),
          ),
        if (_ops.contains(FileOp.copy))
          AstryxMenuItem(
            label: 'Copy to…',
            icon: const Icon(DextrIcons.copy),
            onSelected: () => _moveOrCopy(entry, move: false),
          ),
        if (_ops.contains(FileOp.delete)) const AstryxMenuDivider(),
        if (_ops.contains(FileOp.delete))
          AstryxMenuItem(
            label: 'Delete',
            icon: const Icon(DextrIcons.delete),
            destructive: true,
            onSelected: () => _requestDelete(<String>[entry.path]),
          ),
      ],
    );
  }

  // --- The dialogs -----------------------------------------------------------

  Widget _promptHost() => AstryxDialog(
    controller: _prompt,
    title: _promptTitle,
    width: 420,
    footer: AstryxHStack(
      gap: AstryxSpacingToken.spacing2,
      justify: AstryxStackJustify.end,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        AstryxButton(label: 'Cancel', onPressed: _prompt.hide),
        AstryxButton(
          label: _promptConfirm,
          variant: AstryxButtonVariant.primary,
          onPressed: _submitPrompt,
        ),
      ],
    ),
    child: AstryxTextInput(
      label: _promptLabel,
      controller: _promptValue,
      autofocus: true,
      onSubmitted: (_) => _submitPrompt(),
    ),
  );

  Widget _deleteHost() => AstryxAlertDialog(
    controller: _confirmDelete,
    title: _pendingDelete.length == 1
        ? 'Delete this item?'
        : 'Delete ${_pendingDelete.length} items?',
    description: _pendingDelete.length == 1
        ? '“${_pendingDelete.single}” is removed. A folder takes everything '
              'beneath it. This cannot be undone.'
        : 'Every selected item is removed, and a folder takes everything '
              'beneath it. This cannot be undone.',
    confirmLabel: 'Delete',
    destructive: true,
    onConfirm: () => _delete(_pendingDelete),
  );

  Widget _previewHost() {
    final entry = _previewEntry;
    return AstryxDialog(
      controller: _previewDialog,
      title: entry?.name ?? 'Preview',
      width: 720,
      footer: AstryxHStack(
        gap: AstryxSpacingToken.spacing2,
        justify: AstryxStackJustify.end,
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          if (entry != null && _ops.contains(FileOp.share))
            AstryxButton(
              label: 'Copy share link',
              size: AstryxButtonSize.sm,
              leading: const Icon(DextrIcons.link),
              onPressed: () => _share(entry),
            ),
          if (entry != null && _ops.contains(FileOp.download))
            AstryxButton(
              label: 'Download',
              variant: AstryxButtonVariant.primary,
              size: AstryxButtonSize.sm,
              leading: const Icon(DextrIcons.download),
              onPressed: () => _download(<FileEntry>[entry]),
            ),
        ],
      ),
      child: entry == null
          ? const SizedBox.shrink()
          : AstryxVStack(
              gap: AstryxSpacingToken.spacing4,
              align: AstryxStackAlign.stretch,
              children: <Widget>[
                AstryxMetadataList(
                  direction: AstryxMetadataListDirection.inline,
                  items: <AstryxMetadataItem>[
                    AstryxMetadataItem.text(label: 'Path', value: entry.path),
                    if (entry.size != null)
                      AstryxMetadataItem.text(
                        label: 'Size',
                        value: _humanSize(entry.size!),
                      ),
                    if (entry.contentType != null)
                      AstryxMetadataItem.text(
                        label: 'Type',
                        value: entry.contentType!,
                      ),
                    if (entry.etag != null)
                      AstryxMetadataItem.text(
                        label: 'ETag',
                        value: entry.etag!,
                      ),
                    if (entry.modified != null)
                      AstryxMetadataItem(
                        label: 'Modified',
                        value: AstryxTimestamp(entry.modified!),
                        semanticsValue: entry.modified!.toLocal().toString(),
                      ),
                  ],
                ),
                const AstryxDivider(),
                _previewBody(entry),
              ],
            ),
    );
  }

  Widget _previewBody(FileEntry entry) {
    if (_previewLoading) {
      return const AstryxCenter(
        padding: AstryxSpacingToken.spacing6,
        child: AstryxSpinner(label: 'Reading the file'),
      );
    }
    if (_previewError case final error?) {
      return AstryxBanner(
        status: AstryxBannerStatus.error,
        title: 'Could not read this file',
        description: '$error',
      );
    }
    final data = _previewData;
    if (data == null) {
      return const AstryxBanner(
        title: 'No inline preview',
        description:
            'Download the file to open it in something that '
            'understands the format.',
        announce: false,
      );
    }

    if (_isImage(entry.name)) {
      return AstryxVStack(
        gap: AstryxSpacingToken.spacing2,
        align: AstryxStackAlign.stretch,
        children: <Widget>[
          if (data.truncated) const _TruncatedNote(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: Image.memory(
              Uint8List.fromList(data.bytes),
              fit: BoxFit.contain,
              semanticLabel: entry.name,
              errorBuilder: (context, error, stack) => const AstryxBanner(
                status: AstryxBannerStatus.warning,
                title: 'This image could not be decoded',
                description:
                    'The bytes arrived, but not in a format Flutter reads.',
              ),
            ),
          ),
        ],
      );
    }

    var text = utf8.decode(data.bytes, allowMalformed: true);
    if (entry.name.toLowerCase().endsWith('.json')) {
      try {
        text = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
      } catch (_) {
        // Not valid JSON after all — show it as it came.
      }
    }
    return AstryxVStack(
      gap: AstryxSpacingToken.spacing2,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        if (data.truncated) const _TruncatedNote(),
        AstryxCodeBlock(
          text,
          language: p.extension(entry.name).replaceFirst('.', ''),
          maxHeight: 360,
        ),
      ],
    );
  }
}

class _TruncatedNote extends StatelessWidget {
  const _TruncatedNote();

  @override
  Widget build(BuildContext context) => const AstryxBanner(
    status: AstryxBannerStatus.warning,
    title: 'Preview truncated',
    description:
        'The file is larger than the preview limit, so this is '
        'only the beginning of it.',
    announce: false,
  );
}

const _imageExtensions = <String>{'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

const _textExtensions = <String>{
  'txt',
  'json',
  'csv',
  'tsv',
  'md',
  'log',
  'yaml',
  'yml',
  'xml',
  'html',
  'htm',
  'dart',
  'js',
  'ts',
  'jsx',
  'tsx',
  'py',
  'java',
  'c',
  'cpp',
  'h',
  'hpp',
  'go',
  'rs',
  'rb',
  'sh',
  'sql',
  'ini',
  'toml',
  'conf',
  'env',
  'css',
};

bool _isImage(String name) => _imageExtensions.contains(_extensionOf(name));

bool _isText(String name) => _textExtensions.contains(_extensionOf(name));

String _extensionOf(String name) =>
    p.extension(name).toLowerCase().replaceFirst('.', '');

String _humanSize(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
