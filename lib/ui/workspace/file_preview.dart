import 'dart:convert';
import 'dart:typed_data';

import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connectors/data_source.dart';
import '../../core/files/delimited_table.dart';
import '../../core/files/file_kind.dart';
import '../../core/files/media_metadata.dart';
import '../../core/files/ooxml.dart';
import '../../core/logger.dart';
import '../../state/providers.dart';
import '../widgets/dextr_icons.dart';

/// Reads part of the object being previewed.
typedef ReadPreviewBytes = Future<FileBytes> Function(int maxBytes);

/// One object in a bucket, looked at without leaving the application.
///
/// What it can show, and what it says instead when it cannot, is decided by
/// [FileKind] rather than by a chain of extension checks here. Six kinds are
/// rendered — an image, text, a CSV, a spreadsheet, a document — and the rest
/// get their own facts, an honest sentence about why there is no picture, and
/// the two ways out: open it in the application that does understand it, or
/// download it.
///
/// The parsing is all in `core/files/`, none of it in this widget. That is what
/// makes "does a `.xlsx` with an empty first column line up" a unit test rather
/// than something to check by eye in a dialog.
class FilePreviewDialog extends ConsumerStatefulWidget {
  const FilePreviewDialog({
    required this.controller,
    required this.entry,
    required this.read,
    super.key,
    this.onDownload,
    this.onCopyLink,
  });

  final AstryxDialogController controller;

  /// What is being looked at. Null renders nothing, for a dialog that has not
  /// been opened yet.
  final FileEntry? entry;

  /// How to fetch the bytes. Owned by the caller, which is what knows the
  /// connection.
  final ReadPreviewBytes read;

  /// Offered in the footer when the source supports it.
  final VoidCallback? onDownload;
  final VoidCallback? onCopyLink;

  @override
  ConsumerState<FilePreviewDialog> createState() => _FilePreviewDialogState();
}

class _FilePreviewDialogState extends ConsumerState<FilePreviewDialog> {
  /// What the bytes turned out to contain, or why they did not.
  Object? _content;
  Object? _error;
  bool _loading = false;
  bool _truncated = false;
  Uint8List? _bytes;
  int _sheet = 0;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    if (widget.entry != null) _fetch();
  }

  @override
  void didUpdateWidget(FilePreviewDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The caller reuses one dialog for every row, so a new entry is a new fetch.
    if (oldWidget.entry?.path != widget.entry?.path) _fetch();
  }

  FileEntry? get _entry => widget.entry;

  FileKind get _kind =>
      _entry == null ? FileKind.binary : FileKind.of(_entry!);

  /// Whether the object is known to be bigger than this preview can take.
  ///
  /// Only meaningful for the formats a partial read is useless for: half a
  /// spreadsheet is not a spreadsheet, so there is no point fetching it.
  bool get _tooLarge {
    final size = _entry?.size;
    if (size == null) return false;
    return _kind.needsWholeFile && size > _kind.previewByteLimit;
  }

  Future<void> _fetch() async {
    final entry = _entry;
    setState(() {
      _content = null;
      _error = null;
      _bytes = null;
      _truncated = false;
      _sheet = 0;
      _loading = entry != null && _kind.hasInlinePreview && !_tooLarge;
    });
    if (entry == null || _tooLarge) return;

    // A kind with no inline preview still reads its head: that is where an MP4
    // keeps its duration and a PDF its version, and those are the facts shown
    // in place of the picture.
    try {
      final data = await widget.read(_kind.previewByteLimit);
      if (!mounted) return;
      final bytes = Uint8List.fromList(data.bytes);
      setState(() {
        _bytes = bytes;
        _truncated = data.truncated;
        _content = _decode(bytes, truncated: data.truncated);
      });
    } catch (e, stack) {
      log.w('Could not preview ${entry.path}: $e', error: e, stackTrace: stack);
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Turns the bytes into whatever this kind is shown as.
  ///
  /// Synchronous, and capped by [FileKind.previewByteLimit] because of it: this
  /// runs on the UI thread, so the limits are what keep a large workbook from
  /// costing a dropped frame instead of a dropped minute.
  Object? _decode(Uint8List bytes, {required bool truncated}) {
    switch (_kind) {
      case FileKind.image:
        return bytes;
      case FileKind.text:
        return _prettyText(utf8.decode(bytes, allowMalformed: true));
      case FileKind.delimited:
        return parseDelimited(utf8.decode(bytes, allowMalformed: true));
      case FileKind.document:
        return readDocx(bytes);
      case FileKind.spreadsheet:
        return readXlsx(bytes);
      case FileKind.video:
      case FileKind.audio:
        return readMp4Metadata(bytes);
      case FileKind.pdf:
        return readPdfFacts(bytes);
      case FileKind.archive:
      case FileKind.binary:
        return null;
    }
  }

  /// Indents JSON, and leaves everything else exactly as it arrived.
  String _prettyText(String text) {
    if (FileKind.extensionOf(_entry?.name ?? '') != 'json') return text;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } on FormatException {
      // Named `.json` and is not: showing the bytes is more useful than an error.
      return text;
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

  /// Hands the file to whatever the machine opens it with.
  Future<void> _openExternally() async {
    final entry = _entry;
    final bytes = _bytes;
    if (entry == null || bytes == null) return;
    setState(() => _opening = true);
    try {
      await ref
          .read(externalOpenProvider)
          .open(fileName: entry.name, bytes: bytes);
      // Said out loud: the viewer opens in another window, and on a busy desktop
      // that is not always obvious.
      _toast('Opened ${entry.name} in another application');
    } catch (e) {
      _toast('Could not open ${entry.name}: $e', error: true);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;

    return AstryxDialog(
      controller: widget.controller,
      title: entry?.name ?? 'Preview',
      // 860 rather than the default: three of these previews are tables, and a
      // table in a 480-pixel dialog is a column of ellipses.
      width: 860,
      footer: _footer(entry),
      child: entry == null
          ? const SizedBox.shrink()
          : AstryxVStack(
              gap: AstryxSpacingToken.spacing4,
              align: AstryxStackAlign.stretch,
              children: <Widget>[
                _facts(entry),
                const AstryxDivider(),
                _body(entry),
              ],
            ),
    );
  }

  Widget _footer(FileEntry? entry) {
    final canOpen =
        entry != null &&
        _bytes != null &&
        ref.read(externalOpenProvider).isSupported &&
        // The extension decides which program the system runs, so a format
        // this application will not vouch for gets no button. `ExternalOpen`
        // refuses the same names anyway; hiding it means nobody is offered an
        // action that cannot be taken.
        FileKind.canOpenExternally(entry);

    return AstryxHStack(
      gap: AstryxSpacingToken.spacing2,
      justify: AstryxStackJustify.end,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        if (entry != null && widget.onCopyLink != null)
          AstryxButton(
            label: 'Copy share link',
            size: AstryxButtonSize.sm,
            leading: const Icon(DextrIcons.link),
            onPressed: widget.onCopyLink,
          ),
        if (canOpen)
          AstryxButton(
            label: 'Open externally',
            size: AstryxButtonSize.sm,
            leading: const Icon(DextrIcons.preview),
            loading: _opening,
            onPressed: _openExternally,
          ),
        if (entry != null && widget.onDownload != null)
          AstryxButton(
            label: 'Download',
            variant: AstryxButtonVariant.primary,
            size: AstryxButtonSize.sm,
            leading: const Icon(DextrIcons.download),
            onPressed: widget.onDownload,
          ),
      ],
    );
  }

  /// What is known about the file, including whatever its own header said.
  Widget _facts(FileEntry entry) {
    final content = _content;

    return AstryxMetadataList(
      direction: AstryxMetadataListDirection.inline,
      items: <AstryxMetadataItem>[
        AstryxMetadataItem(
          label: 'Kind',
          value: AstryxBadge(_kind.label, variant: AstryxBadgeVariant.neutral),
          semanticsValue: _kind.label,
        ),
        AstryxMetadataItem.text(label: 'Path', value: entry.path),
        if (entry.size case final size?)
          AstryxMetadataItem.text(label: 'Size', value: humanFileSize(size)),
        if (entry.contentType case final type?)
          AstryxMetadataItem.text(label: 'Type', value: type),
        if (entry.modified case final modified?)
          AstryxMetadataItem(
            label: 'Modified',
            value: AstryxTimestamp(modified),
            semanticsValue: modified.toLocal().toString(),
          ),
        if (entry.etag case final etag?)
          AstryxMetadataItem.text(label: 'ETag', value: etag),
        // Facts read out of the file itself, which is the part that makes a
        // format this application cannot draw still worth opening.
        ..._formatFacts(content),
      ],
    );
  }

  List<AstryxMetadataItem> _formatFacts(Object? content) => switch (content) {
    Mp4Metadata(:final duration, :final resolution, :final brand) =>
      <AstryxMetadataItem>[
        if (duration != null)
          AstryxMetadataItem.text(
            label: 'Duration',
            value: formatMediaDuration(duration),
          ),
        if (resolution != null)
          AstryxMetadataItem.text(label: 'Resolution', value: resolution),
        if (brand != null && brand.isNotEmpty)
          AstryxMetadataItem.text(label: 'Container', value: brand),
      ],
    PdfFacts(:final version, :final encrypted, :final linearised) =>
      <AstryxMetadataItem>[
        AstryxMetadataItem.text(label: 'PDF version', value: version),
        if (encrypted)
          const AstryxMetadataItem(
            label: 'Security',
            value: AstryxBadge(
              'encrypted',
              variant: AstryxBadgeVariant.warning,
            ),
            semanticsValue: 'encrypted',
          ),
        if (linearised)
          AstryxMetadataItem.text(label: 'Layout', value: 'linearised'),
      ],
    WordDocument(:final paragraphs, :final words) => <AstryxMetadataItem>[
      AstryxMetadataItem.text(
        label: 'Paragraphs',
        value: '${paragraphs.length}',
      ),
      AstryxMetadataItem.text(label: 'Words', value: '$words'),
    ],
    Workbook(:final sheets) => <AstryxMetadataItem>[
      AstryxMetadataItem.text(label: 'Sheets', value: '${sheets.length}'),
    ],
    DelimitedTable(:final columns, :final rows, :final delimiter) =>
      <AstryxMetadataItem>[
        AstryxMetadataItem.text(label: 'Columns', value: '${columns.length}'),
        AstryxMetadataItem.text(
          label: 'Rows read',
          value: '${rows.length}',
        ),
        AstryxMetadataItem.text(
          label: 'Separator',
          value: switch (delimiter) {
            '\t' => 'tab',
            ',' => 'comma',
            ';' => 'semicolon',
            '|' => 'pipe',
            _ => delimiter,
          },
        ),
      ],
    _ => const <AstryxMetadataItem>[],
  };

  Widget _body(FileEntry entry) {
    if (_tooLarge) {
      return AstryxBanner(
        status: AstryxBannerStatus.warning,
        title: 'Too large to preview here',
        description:
            '${humanFileSize(entry.size!)} of ${_kind.label}. This format has '
            'to be read whole, and the limit for that is '
            '${humanFileSize(_kind.previewByteLimit)}. Download it instead.',
      );
    }
    // A wait whose result has a known shape, so a shape rather than a spinner.
    if (_loading) return const _PreviewSkeleton();
    if (_error case final error?) {
      return AstryxBanner(
        status: AstryxBannerStatus.error,
        title: 'Could not read this file',
        description: '$error',
      );
    }

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing3,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        if (_truncated && _kind.hasInlinePreview) const _TruncatedNote(),
        _contentFor(entry),
      ],
    );
  }

  Widget _contentFor(FileEntry entry) => switch (_content) {
    final Uint8List bytes => _image(entry, bytes),
    final String text => AstryxCodeBlock(
      text,
      language: FileKind.extensionOf(entry.name),
      maxHeight: 420,
      showLineNumbers: true,
    ),
    final DelimitedTable table => _delimited(table),
    final Workbook workbook => _workbook(workbook),
    final WordDocument document => _document(document),
    // The formats with facts but no picture. Their facts are already above; this
    // says plainly why there is nothing under them.
    _ => _noInlinePreview(entry),
  };

  Widget _image(FileEntry entry, Uint8List bytes) => AstryxCenter(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        semanticLabel: entry.name,
        errorBuilder: (context, error, stack) => const AstryxBanner(
          status: AstryxBannerStatus.warning,
          title: 'This image could not be decoded',
          description: 'The bytes arrived, but not in a format Flutter reads.',
        ),
      ),
    ),
  );

  Widget _delimited(DelimitedTable table) {
    if (table.isEmpty) {
      return const AstryxEmptyState(
        title: 'Nothing in this file',
        description: 'It parsed, and it has no rows.',
        size: AstryxEmptyStateSize.compact,
      );
    }
    return _CellTable(
      label: 'Rows of ${_entry?.name ?? 'the file'}',
      columns: table.columns,
      rows: table.rows,
      truncated: table.truncated,
    );
  }

  Widget _workbook(Workbook workbook) {
    if (workbook.sheets.isEmpty) {
      return const AstryxEmptyState(
        title: 'No sheets',
        description: 'The workbook opened, and there is nothing in it.',
        size: AstryxEmptyStateSize.compact,
      );
    }

    final index = _sheet.clamp(0, workbook.sheets.length - 1);
    final sheet = workbook.sheets[index];
    // The first row of a spreadsheet is a header in nearly every real file, and
    // treating it as one is what makes the table scannable.
    final header = sheet.rows.isEmpty ? const <String>[] : sheet.rows.first;
    final body = sheet.rows.length > 1 ? sheet.rows.sublist(1) : const <List<String>>[];

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing3,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        // Only where there is a choice to make: one sheet needs no picker.
        if (workbook.sheets.length > 1)
          AstryxSelector<int>(
            label: 'Sheet',
            value: index,
            width: 260,
            size: AstryxInputSize.sm,
            onChanged: (value) => setState(() => _sheet = value ?? 0),
            options: <AstryxSelectorEntry<int>>[
              for (var i = 0; i < workbook.sheets.length; i++)
                AstryxSelectorOption<int>(
                  value: i,
                  label: workbook.sheets[i].name,
                  description: workbook.sheets[i].rows.isEmpty
                      ? 'empty'
                      : '${workbook.sheets[i].rows.length} rows',
                ),
            ],
          ),
        if (sheet.rows.isEmpty)
          AstryxEmptyState(
            title: 'Sheet “${sheet.name}” is empty',
            description: 'Nothing has been written into it.',
            size: AstryxEmptyStateSize.compact,
          )
        else
          _CellTable(
            label: 'Cells of ${sheet.name}',
            columns: <String>[
              for (var i = 0; i < header.length; i++)
                header[i].trim().isEmpty ? _columnName(i) : header[i],
            ],
            rows: body,
            truncated: sheet.truncated,
          ),
      ],
    );
  }

  Widget _document(WordDocument document) {
    if (document.isEmpty) {
      return const AstryxEmptyState(
        title: 'No text in this document',
        description:
            'It opened, and everything in it is a picture, a chart or a '
            'drawing rather than words.',
        size: AstryxEmptyStateSize.compact,
      );
    }

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing2,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        if (document.truncated)
          const AstryxBanner(
            status: AstryxBannerStatus.warning,
            title: 'Only the beginning',
            description:
                'The document is longer than this preview shows. Download it '
                'to read the rest.',
            announce: false,
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: AstryxVStack(
              gap: AstryxSpacingToken.spacing3,
              align: AstryxStackAlign.stretch,
              children: <Widget>[
                for (final paragraph in document.paragraphs)
                  if (paragraph.trim().isNotEmpty)
                    AstryxText(paragraph, maxLines: null),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// What a format nobody here can draw says for itself.
  ///
  /// Named for what it is rather than dressed up as a failure: the file is fine,
  /// the facts above it are real, and the way to see it is the button below.
  Widget _noInlinePreview(FileEntry entry) {
    final (title, description) = switch (_kind) {
      FileKind.pdf => (
        'No page preview',
        'The facts above come from the file itself. Drawing its pages needs a '
            'PDF engine this application does not bundle — open it in a viewer, '
            'or download it.',
      ),
      FileKind.video => (
        'No player here',
        'The duration and size above were read from the file. Playing it needs '
            'a video decoder this application does not bundle.',
      ),
      FileKind.audio => (
        'No player here',
        'Open it in something that plays audio, or download it.',
      ),
      FileKind.archive => (
        'Archives are not opened here',
        'Download it and unpack it where you can see what came out.',
      ),
      _ => (
        'No inline preview',
        'Nothing here knows what these bytes mean. Download the file to open '
            'it in something that does.',
      ),
    };

    // Said plainly where it applies, because the alternative reads as a missing
    // feature. The name came from the store, and the extension is what would
    // choose the program — so an unrecognised one is downloaded, not launched.
    final withheld =
        !FileKind.canOpenExternally(entry) &&
        ref.read(externalOpenProvider).isSupported;

    return AstryxEmptyState(
      icon: Icon(DextrIcons.forFile(entry)),
      title: title,
      description: withheld
          ? '$description Dextr will not open this one for you: its extension '
                'is what would pick the program that runs, and that name came '
                'from the store rather than from you.'
          : description,
      size: AstryxEmptyStateSize.compact,
    );
  }
}

/// A grid of strings, as a table.
///
/// Shared by the CSV and the spreadsheet previews, because by the time either
/// has been parsed they are the same thing: a header and rows of cells.
class _CellTable extends StatelessWidget {
  const _CellTable({
    required this.label,
    required this.columns,
    required this.rows,
    this.truncated = false,
  });

  final String label;
  final List<String> columns;
  final List<List<String>> rows;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    // Numbered, so the row a value is on can be said out loud — and so two
    // identical rows are still two rows to the table's key.
    final numbered = <(int, List<String>)>[
      for (var i = 0; i < rows.length; i++) (i + 1, rows[i]),
    ];

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing2,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        if (truncated)
          AstryxBanner(
            status: AstryxBannerStatus.warning,
            title: 'First ${rows.length} rows',
            description:
                'The file has more. This preview stops where a table drawn '
                'without virtualisation stops being quick.',
            announce: false,
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: AstryxTable<(int, List<String>)>(
            label: label,
            rows: numbered,
            density: AstryxTableDensity.compact,
            keyOf: (row) => row.$1,
            rowLabelOf: (row) => 'row ${row.$1}',
            columns: <AstryxTableColumn<(int, List<String>)>>[
              AstryxTableColumn<(int, List<String>)>(
                id: '#',
                header: '#',
                width: const AstryxTableColumnWidth.fixed(56),
                alignment: AstryxTableAlignment.end,
                cellBuilder: (context, row) => AstryxText(
                  '${row.$1}',
                  type: AstryxTextType.supporting,
                  color: AstryxTextColor.disabled,
                  tabularNumbers: true,
                ),
              ),
              for (var i = 0; i < columns.length; i++)
                AstryxTableColumn<(int, List<String>)>(
                  id: 'c$i',
                  header: columns[i],
                  cellBuilder: (context, row) {
                    final value = i < row.$2.length ? row.$2[i] : '';
                    return AstryxText(
                      value.isEmpty ? '—' : value,
                      type: AstryxTextType.code,
                      color: value.isEmpty
                          ? AstryxTextColor.disabled
                          : AstryxTextColor.primary,
                      maxLines: 1,
                      semanticsLabel: value.isEmpty ? 'empty' : value,
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The shape of a preview, while the bytes are on their way.
class _PreviewSkeleton extends StatelessWidget {
  const _PreviewSkeleton();

  @override
  Widget build(BuildContext context) => const AstryxVStack(
    gap: AstryxSpacingToken.spacing2,
    align: AstryxStackAlign.stretch,
    children: <Widget>[
      AstryxSkeleton(height: 28),
      AstryxSkeleton.text(widthFactor: 0.9),
      AstryxSkeleton.text(widthFactor: 0.75),
      AstryxSkeleton.text(widthFactor: 0.85),
      AstryxSkeleton.text(widthFactor: 0.6),
    ],
  );
}

class _TruncatedNote extends StatelessWidget {
  const _TruncatedNote();

  @override
  Widget build(BuildContext context) => const AstryxBanner(
    status: AstryxBannerStatus.warning,
    title: 'Preview truncated',
    description:
        'The file is larger than the preview limit, so this is only the '
        'beginning of it.',
    announce: false,
  );
}

/// The spreadsheet name for a column with no header: `A`, `B`, … `AA`.
String _columnName(int index) {
  var value = index;
  final letters = <int>[];
  do {
    letters.insert(0, 0x41 + value % 26);
    value = value ~/ 26 - 1;
  } while (value >= 0);
  return String.fromCharCodes(letters);
}
