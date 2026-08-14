import 'package:astryx_ui/astryx_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../connectors/data_source.dart';
import '../../core/cell_value.dart';
import '../../core/export/export_format.dart';
import '../../core/export/tabular_export.dart';
import '../../core/files/file_kind.dart';
import '../../state/active_source_provider.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';
import '../../state/workspace_provider.dart';
import '../widgets/dextr_icons.dart';
import '../widgets/dextr_more_menu.dart';
import '../widgets/export_dialog.dart';
import 'file_preview.dart';

enum _SortKey { name, size, modified }

/// Hierarchical file browser for any [FileBrowsable] source (S3/MinIO today;
/// Drive/Dropbox later). Talks only to the [FileBrowsable] contract and gates
/// every action on [FileBrowsable.fileOps].
///
/// **The buckets are the top level of this pane, not only of the rail.** A
/// bucket used to be reachable in one place — a row in the rail — so collapsing
/// the rail took the whole store out of reach. Here they are folder rows like
/// any other, one level above the prefixes inside them, and walking into one
/// points the tab at it so the rail, the tab strip and the pane all agree about
/// where the user is.
class FileBrowserPane extends ConsumerStatefulWidget {
  const FileBrowserPane({super.key, this.container, this.tabId});

  /// The bucket to open in. Null starts at the list of buckets, which is what
  /// the pane shows when nothing has been picked yet.
  final ContainerRef? container;

  /// The tab this pane belongs to, so navigating can move the tab with it.
  /// Null leaves the tab alone — for a pane mounted outside the workspace.
  final String? tabId;

  @override
  ConsumerState<FileBrowserPane> createState() => _FileBrowserPaneState();
}

class _FileBrowserPaneState extends ConsumerState<FileBrowserPane> {
  /// The bucket being looked inside, or null at the list of buckets.
  ContainerRef? _bucket;

  String _path = ''; // current folder prefix, '' = bucket root
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

  final AstryxDialogController _exportListing = AstryxDialogController();

  final AstryxDialogController _previewDialog = AstryxDialogController();

  /// Which row the preview is showing. The dialog owns everything else about it
  /// — the fetch, the parse, the errors — so this pane no longer has to know
  /// which formats can be drawn.
  FileEntry? _previewEntry;

  @override
  void initState() {
    super.initState();
    _bucket = widget.container;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(FileBrowserPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Compared by name, and only reloaded when it actually differs: this pane is
    // what *writes* the tab's container when the user walks into a bucket, so an
    // unguarded adopt-and-reload here would reload on its own navigation.
    if (widget.container?.name != _bucket?.name) {
      _bucket = widget.container;
      _path = '';
      _load();
    }
  }

  /// Whether the pane is showing buckets rather than what is inside one.
  bool get _atBucketList => _bucket == null;

  @override
  void dispose() {
    _filter.dispose();
    _prompt.dispose();
    _promptValue.dispose();
    _confirmDelete.dispose();
    _exportListing.dispose();
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

  /// The bucket a file operation acts in.
  ///
  /// Non-null by construction: nothing that calls this is offered at the bucket
  /// list, because none of it means anything there — there is no "upload into
  /// the list of buckets".
  ContainerRef get _inBucket => _bucket!;

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
      final bucket = _bucket;
      _entries = bucket == null
          ? _bucketRows(await source.listContainers())
          : (await source.listEntries(bucket, _path)).entries;
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Buckets as folder rows.
  ///
  /// A bucket is a folder as far as this table is concerned — something with a
  /// name that you press to go inside — and giving it a row of its own kind
  /// would mean a second set of every rule about sorting, filtering and icons.
  /// It carries no size or date because a store does not report either for a
  /// bucket without walking the whole thing.
  static List<FileEntry> _bucketRows(List<ContainerRef> buckets) =>
      <FileEntry>[
        for (final bucket in buckets)
          FileEntry(
            name: bucket.name,
            path: '${bucket.name}/',
            isFolder: true,
            contentType: bucket.subtype ?? 'bucket',
          ),
      ];

  void _navigateTo(String path) {
    setState(() {
      _path = path;
      _query = '';
      _filter.clear();
    });
    _load();
  }

  /// Goes into a bucket, and takes the tab with it.
  void _openBucket(String name) {
    final bucket = ContainerRef(name: name, subtype: 'bucket');
    setState(() {
      _bucket = bucket;
      _path = '';
      _query = '';
      _filter.clear();
    });
    _reportContainer(bucket);
    _load();
  }

  /// Back out to the buckets.
  void _showBuckets() {
    setState(() {
      _bucket = null;
      _path = '';
      _query = '';
      _filter.clear();
    });
    _reportContainer(null);
    _load();
  }

  /// Tells the workspace where the pane went, so the tab's title and the rail's
  /// highlight follow the pane instead of contradicting it.
  ///
  /// Deferred a frame: this runs from a press handler, and writing to a store
  /// half the application watches while a build is in flight is how "setState
  /// called during build" happens.
  void _reportContainer(ContainerRef? container) {
    final tabId = widget.tabId;
    if (tabId == null) return;
    final notifier = ref.read(workspaceProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (notifier.mounted) notifier.setTabContainer(tabId, container);
    });
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
        await source!.createFolder(_inBucket, '$_path$name');
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
          _inBucket,
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

  /// Downloads into a folder the user picks — the unstructured export.
  ///
  /// A folder rather than a save dialog per file: `saveFile` writes bytes it is
  /// handed, and a download buffered in memory first would cap the size of file
  /// this tool can fetch. Asking for the folder keeps the transfer streaming to
  /// disk through the connector.
  Future<void> _download(List<FileEntry> entries) async {
    final files = entries.where((e) => !e.isFolder).toList();
    if (files.isEmpty) return;
    final directory = await ref.read(exportServiceProvider).chooseFolder(
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
          _inBucket,
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
      await source!.deleteEntries(_inBucket, paths);
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
        await source!.moveEntry(_inBucket, entry.path, to);
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
          await source!.moveEntry(_inBucket, entry.path, to);
        } else {
          await source!.copyEntry(_inBucket, entry.path, to);
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
      final url = await source!.shareLink(_inBucket, entry.path);
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

  // --- Exporting the listing -------------------------------------------------

  /// The folder listing as rows.
  ///
  /// Not the files — those are the download above. This is the inventory: what
  /// is in the bucket, how big, when it changed. An object store with fifty
  /// thousand keys is a thing people need a spreadsheet of, and reading it off
  /// the screen a page at a time is not that.
  ExportTable _listingTable(List<FileEntry> entries) => ExportTable(
    columns: const <String>[
      'name',
      'path',
      'kind',
      'size_bytes',
      'modified',
      'content_type',
      'etag',
    ],
    rows: <RowData>[
      for (final entry in entries)
        <String, CellValue>{
          'name': StringCell(entry.name),
          'path': StringCell(entry.path),
          'kind': StringCell(entry.isFolder ? 'folder' : 'file'),
          'size_bytes': entry.size == null
              ? const NullCell()
              : NumCell(entry.size!),
          'modified': entry.modified == null
              ? const NullCell()
              : TimestampCell(entry.modified!),
          'content_type': entry.contentType == null
              ? const NullCell()
              : StringCell(entry.contentType!),
          'etag': entry.etag == null
              ? const NullCell()
              : StringCell(entry.etag!),
        },
    ],
  );

  Widget _exportListingHost() {
    final visible = _visible;
    final selected = _entries.where((e) => _selected.contains(e.path)).toList();

    return ExportDialog(
      controller: _exportListing,
      title: _atBucketList ? 'Export the buckets' : 'Export the listing',
      description: _atBucketList
          ? 'Every bucket in this connection, as a file.'
          : 'What is in this folder, as a file. To export the objects '
                'themselves, use Download.',
      baseName: <String>[
        _bucket?.name ?? 'buckets',
        if (_path.isNotEmpty) _path,
        'listing',
      ].join('-'),
      // No SQL: a folder listing is not rows of a table anyone would insert it
      // into, and a script that pretended otherwise would name a table that
      // does not exist.
      formats: const <ExportFormat>[
        ExportFormat.csv,
        ExportFormat.tsv,
        ExportFormat.json,
        ExportFormat.jsonl,
        ExportFormat.markdown,
      ],
      sources: <ExportSource>[
        ExportSource(
          label: _query.isEmpty
              ? _atBucketList
                    ? 'Every bucket (${visible.length})'
                    : 'This folder (${visible.length} items)'
              : 'The ${visible.length} matches for “$_query”',
          description: 'One level, exactly as the table shows it.',
          load: (_) async => _listingTable(visible),
        ),
        if (selected.isNotEmpty)
          ExportSource(
            label: selected.length == 1
                ? 'The selected item'
                : 'The ${selected.length} selected items',
            description: 'Only the rows that are ticked.',
            load: (_) async => _listingTable(selected),
          ),
      ],
    );
  }

  // --- Preview ---------------------------------------------------------------

  void _preview(FileEntry entry) {
    setState(() => _previewEntry = entry);
    _previewDialog.show();
  }

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
            label: _bucket == null
                ? 'Listing the buckets'
                : 'Listing ${_bucket!.name}',
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
        _exportListingHost(),
        _previewHost(),
      ],
    );
  }

  Widget _breadcrumbs() {
    final segments = _path.split('/').where((s) => s.isNotEmpty).toList();
    final source = ref.watch(activeDataSourceProvider).value;
    final bucket = _bucket;
    var accumulated = '';

    return AstryxBreadcrumbs(
      label: 'Folder path',
      items: <AstryxBreadcrumb>[
        // The connection is the root of the trail now, because the buckets are
        // a level of this pane. It is also the way back to them, which is what a
        // reader with the rail collapsed has instead of the rail.
        AstryxBreadcrumb(
          label: source?.displayName ?? 'Buckets',
          icon: DextrIcon(
            source == null
                ? DextrIcons.bucket
                : DextrIcons.forKind(source.kind),
            color: AstryxIconColor.secondary,
          ),
          onPressed: _atBucketList ? null : _showBuckets,
        ),
        if (bucket != null)
          AstryxBreadcrumb(
            label: bucket.name,
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
          label: _atBucketList ? 'Buckets' : 'Folder',
          children: <Widget>[
            AstryxIconButton.custom(
              // The last step up is out of the bucket and into the list of
              // them, not a dead button at the top of a bucket.
              label: _path.isEmpty ? 'Back to the buckets' : 'Up one folder',
              tooltip: _path.isEmpty ? 'Back to the buckets' : 'Up one folder',
              variant: AstryxButtonVariant.ghost,
              size: AstryxButtonSize.sm,
              onPressed: _atBucketList || _loading
                  ? null
                  : () {
                      if (_path.isEmpty) {
                        _showBuckets();
                        return;
                      }
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
            // A folder is made inside a bucket. Making a *bucket* is another
            // operation with its own rules — region, policy, versioning — and
            // pretending this button does it would be a lie.
            if (!_atBucketList && _ops.contains(FileOp.makeFolder))
              AstryxIconButton.custom(
                label: 'New folder',
                tooltip: 'New folder',
                variant: AstryxButtonVariant.ghost,
                size: AstryxButtonSize.sm,
                onPressed: _loading ? null : _newFolder,
                child: const Icon(DextrIcons.folderPlus),
              ),
            AstryxIconButton.custom(
              label: _atBucketList
                  ? 'Export the bucket list'
                  : 'Export this listing',
              tooltip: 'Export listing',
              variant: AstryxButtonVariant.ghost,
              size: AstryxButtonSize.sm,
              onPressed: _loading ? null : _exportListing.show,
              child: const Icon(DextrIcons.export),
            ),
          ],
        ),
        Expanded(
          child: AstryxTextInput(
            label: _atBucketList ? 'Filter the buckets' : 'Filter this folder',
            labelHidden: true,
            placeholder: _atBucketList
                ? 'Filter the buckets…'
                : 'Filter this folder…',
            size: AstryxInputSize.sm,
            controller: _filter,
            showClear: true,
            leading: const AstryxIcon(AstryxIconName.search),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        if (!_atBucketList)
          AstryxSelector<_SortKey>(
            label: 'Sort files by',
            labelHidden: true,
            value: _sort,
            width: 150,
            size: AstryxInputSize.sm,
            onChanged: (value) =>
                setState(() => _sort = value ?? _SortKey.name),
            options: const <AstryxSelectorEntry<_SortKey>>[
              AstryxSelectorOption(value: _SortKey.name, label: 'Name'),
              AstryxSelectorOption(value: _SortKey.size, label: 'Size'),
              AstryxSelectorOption(value: _SortKey.modified, label: 'Modified'),
            ],
          ),
        if (!_atBucketList && _ops.contains(FileOp.upload))
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
        if (!_atBucketList && _ops.contains(FileOp.download))
          AstryxButton(
            label: 'Download',
            size: AstryxButtonSize.sm,
            leading: const Icon(DextrIcons.download),
            onPressed: () => _download(selectedEntries),
          ),
        // The rows about these items rather than the items themselves — two
        // different exports, named differently so they cannot be confused.
        AstryxButton(
          label: 'Export listing',
          size: AstryxButtonSize.sm,
          leading: const Icon(DextrIcons.export),
          onPressed: _exportListing.show,
        ),
        if (!_atBucketList && _ops.contains(FileOp.delete))
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
      label: _atBucketList
          ? 'Buckets'
          : 'Files in ${_inBucket.name}${_path.isEmpty ? '' : '/$_path'}',
      rows: entries,
      density: density,
      keyOf: (entry) => entry.path,
      rowLabelOf: (entry) => _atBucketList
          ? 'bucket ${entry.name}'
          : entry.isFolder
          ? 'folder ${entry.name}'
          : entry.name,
      // No tick boxes on the buckets: none of what a selection is for here —
      // download, delete, move — is something to do to a bucket from this pane.
      selectionMode: _atBucketList
          ? AstryxTableSelectionMode.none
          : AstryxTableSelectionMode.multiple,
      selected: _selected,
      onSelectionChanged: (selected) => setState(() => _selected = selected),
      onRowPressed: (entry) => _atBucketList
          ? _openBucket(entry.name)
          : entry.isFolder
          ? _navigateTo(entry.path)
          : _preview(entry),
      rowActionsBuilder: _rowActions,
      rowActionsWidth: 48,
      emptyState: AstryxEmptyState(
        icon: const Icon(DextrIcons.bucket),
        title: _query.isNotEmpty
            ? 'No matches'
            : _atBucketList
            ? 'No buckets'
            : 'Empty folder',
        description: _query.isNotEmpty
            ? 'Nothing here matches “$_query”.'
            : _atBucketList
            ? 'This connection has no buckets, or the key it uses cannot list '
                  'them.'
            : 'Upload something, or create a folder to organise it first.',
        size: AstryxEmptyStateSize.compact,
        actions: <Widget>[
          if (_query.isEmpty &&
              !_atBucketList &&
              _ops.contains(FileOp.upload))
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
                _atBucketList ? DextrIcons.bucket : DextrIcons.forFile(entry),
                color: AstryxIconColor.secondary,
              ),
              Flexible(child: AstryxText(entry.name, maxLines: 1)),
              // What kind of thing this row is, said in words rather than left
              // to the glyph — a bucket and a folder draw the same icon, and at
              // this level every row is the former.
              if (_atBucketList)
                AstryxBadge(
                  entry.contentType ?? 'bucket',
                  variant: AstryxBadgeVariant.neutral,
                ),
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
                  humanFileSize(entry.size!),
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
    // A bucket has one action from here, and it is the one the row already does.
    // Renaming, moving or deleting a bucket is a different operation from doing
    // it to a key inside one, and offering the key's version would be wrong.
    if (_atBucketList) {
      return DextrMoreMenu(
        label: 'Actions for ${entry.name}',
        width: 200,
        entries: <AstryxMenuEntry>[
          AstryxMenuItem(
            label: 'Open',
            icon: const Icon(DextrIcons.bucket),
            onSelected: () => _openBucket(entry.name),
          ),
          AstryxMenuItem(
            label: 'Export the bucket list…',
            icon: const Icon(DextrIcons.export),
            onSelected: _exportListing.show,
          ),
        ],
      );
    }

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

    return FilePreviewDialog(
      controller: _previewDialog,
      entry: entry,
      // The reader is this pane's, because the connection is: the dialog knows
      // what to do with bytes and nothing about where they come from.
      read: (maxBytes) async {
        final source = await _src();
        if (source == null) throw StateError('Source is not file-browsable');
        return source.readBytes(_inBucket, entry!.path, maxBytes: maxBytes);
      },
      onCopyLink: entry != null && _ops.contains(FileOp.share)
          ? () => _share(entry)
          : null,
      onDownload: entry != null && _ops.contains(FileOp.download)
          ? () => _download(<FileEntry>[entry])
          : null,
    );
  }
}
