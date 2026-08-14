import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/export/export_format.dart';
import '../../core/export/tabular_export.dart';
import '../../core/logger.dart';
import '../../services/export_service.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';
import 'dextr_icons.dart';

/// One thing an export could be taken from.
///
/// A pane offers one or more of these — "this page" and "every row" are two
/// sources over the same table — and the dialog asks which. [load] does the
/// fetching, because only the pane knows how: one already has the rows in hand,
/// another has to page through a connection to get them.
class ExportSource {
  const ExportSource({
    required this.label,
    required this.load,
    this.description,
    this.capped = false,
  });

  /// What the choice is called: "This page", "Every row", "The result set".
  final String label;

  /// One line on what it means, and on what it costs where that is not obvious.
  final String? description;

  /// Whether [rowLimit] applies. False for a source that is already in memory —
  /// a limit on rows the pane is holding anyway is a limit that only truncates.
  final bool capped;

  /// Fetches the rows. Given the limit the user set, which a capped source is
  /// expected to honour and to report through [ExportTable.truncated].
  final Future<ExportTable> Function(int rowLimit) load;
}

/// The export dialog: what to take, what shape to write it in, and where.
///
/// One widget for every pane that exports rows. Two copies of "how is a NULL
/// written in a CSV" is two places for the answer to differ, and a user who
/// learned the dialog in one pane has learned it in all of them.
///
/// A widget in the tree driven by a controller, like every other modal here —
/// put it beside whatever opens it.
class ExportDialog extends ConsumerStatefulWidget {
  const ExportDialog({
    required this.controller,
    required this.baseName,
    required this.sources,
    super.key,
    this.title = 'Export',
    this.description,
    this.tableName,
    this.formats = ExportFormat.values,
  });

  final AstryxDialogController controller;

  /// What the saved file is called before the timestamp — a table name, a
  /// connection name.
  final String baseName;

  /// Where the rows come from. One is common; two when a pane can offer both
  /// what is on screen and everything behind it.
  final List<ExportSource> sources;

  final String title;
  final String? description;

  /// What the `INSERT` statements should name, when SQL is chosen. Defaults to
  /// [baseName], which is usually the table the rows came out of.
  final String? tableName;

  /// Which formats to offer. All of them unless a caller has a reason — schema
  /// rows have no meaningful `INSERT`, for instance.
  final List<ExportFormat> formats;

  @override
  ConsumerState<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends ConsumerState<ExportDialog> {
  late ExportFormat _format;
  late bool _includeHeader;
  late TextEditingController _nullText;
  bool _prettyJson = true;
  bool _byteOrderMark = false;
  int _sourceIndex = 0;
  num _rowLimit = 50000;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Seeded from the settings once, not watched: a preference changing under an
    // open dialog would silently rewrite what the user is about to export.
    final defaults = ref.read(settingsProvider).exportOptions;
    _format = widget.formats.contains(defaults.format)
        ? defaults.format
        : widget.formats.first;
    _includeHeader = defaults.includeHeader;
    _nullText = TextEditingController(text: defaults.nullText);
  }

  @override
  void dispose() {
    _nullText.dispose();
    super.dispose();
  }

  ExportSource get _source =>
      widget.sources[_sourceIndex.clamp(0, widget.sources.length - 1)];

  ExportOptions get _options => ExportOptions(
    format: _format,
    includeHeader: _includeHeader,
    nullText: _nullText.text,
    prettyJson: _prettyJson,
    tableName: widget.tableName ?? widget.baseName,
    byteOrderMark: _byteOrderMark,
  );

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    AstryxToastScope.of(context).show(
      AstryxToast(
        message: message,
        type: error ? AstryxToastType.error : AstryxToastType.neutral,
      ),
    );
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final table = await _source.load(_rowLimit.toInt());
      if (table.columns.isEmpty) {
        throw StateError('There is nothing to export: no columns came back.');
      }
      final options = _options;
      final outcome = await ref.read(exportServiceProvider).saveText(
        fileName: ExportService.suggestFileName(
          widget.baseName,
          options.format.fileExtension,
          at: DateTime.now(),
        ),
        text: encodeTable(table, options),
        byteOrderMark: options.byteOrderMark,
        dialogTitle: 'Export ${widget.baseName} as ${options.format.label}',
      );
      if (!mounted) return;
      if (outcome == null) {
        // Cancelled. Not an error, and not silent either — the dialog closing
        // with nothing said would read as a failed export.
        _toast('Export cancelled');
      } else {
        _toast(
          '${_rowCount(table.rows.length)} to ${outcome.path}'
          '${table.truncated ? ' · stopped at the row limit' : ''}',
        );
      }
      widget.controller.hide();
    } catch (e, stack) {
      log.w('Export failed: $e', error: e, stackTrace: stack);
      // In the dialog rather than a toast: the user is still here, and this is
      // what they have to act on.
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _rowCount(int rows) =>
      rows == 1 ? 'Exported 1 row' : 'Exported $rows rows';

  @override
  Widget build(BuildContext context) {
    final format = _format;
    final source = _source;

    return AstryxDialog(
      controller: widget.controller,
      title: widget.title,
      description: widget.description,
      width: 560,
      footer: AstryxHStack(
        gap: AstryxSpacingToken.spacing2,
        justify: AstryxStackJustify.end,
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          AstryxButton(
            label: 'Cancel',
            enabled: !_busy,
            onPressed: widget.controller.hide,
          ),
          AstryxButton(
            label: 'Export',
            variant: AstryxButtonVariant.primary,
            leading: const Icon(DextrIcons.export),
            loading: _busy,
            onPressed: _export,
          ),
        ],
      ),
      child: AstryxVStack(
        gap: AstryxSpacingToken.spacing5,
        align: AstryxStackAlign.stretch,
        children: <Widget>[
          if (_error case final error?)
            AstryxBanner(
              status: AstryxBannerStatus.error,
              title: 'Could not export',
              description: error,
            ),
          if (widget.sources.length > 1)
            AstryxRadioList<int>(
              label: 'What to export',
              value: _sourceIndex,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _sourceIndex = value),
              options: <AstryxRadioOption<int>>[
                for (var i = 0; i < widget.sources.length; i++)
                  AstryxRadioOption<int>(
                    value: i,
                    label: widget.sources[i].label,
                    description: widget.sources[i].description,
                  ),
              ],
            ),
          AstryxSelector<ExportFormat>(
            label: 'Format',
            description: format.description,
            value: format,
            enabled: !_busy,
            onChanged: (value) =>
                setState(() => _format = value ?? widget.formats.first),
            options: <AstryxSelectorEntry<ExportFormat>>[
              for (final option in widget.formats)
                AstryxSelectorOption<ExportFormat>(
                  value: option,
                  label: option.label,
                  description: '.${option.fileExtension}',
                ),
            ],
          ),
          if (source.capped)
            AstryxNumberInput(
              label: 'Row limit',
              description:
                  'The file is built in memory before it is written, so this '
                  'is the ceiling on one export. The message afterwards says '
                  'if it was reached.',
              value: _rowLimit,
              min: 1,
              max: 1000000,
              step: 1000,
              integerOnly: true,
              width: 220,
              enabled: !_busy,
              onChanged: (value) =>
                  setState(() => _rowLimit = value ?? _rowLimit),
            ),
          ..._formatOptions(format),
        ],
      ),
    );
  }

  /// Only the options the chosen format actually has.
  ///
  /// A "include header row" switch beside a JSON export is a control that does
  /// nothing, and a dialog full of those teaches the user to stop reading it.
  List<Widget> _formatOptions(ExportFormat format) => <Widget>[
    if (format.supportsHeader)
      AstryxSwitch(
        label: 'Header row',
        description: 'Write the column names as the first line.',
        value: _includeHeader,
        enabled: !_busy,
        onChanged: (value) => setState(() => _includeHeader = value),
      ),
    if (format.supportsNullText)
      AstryxTextInput(
        label: 'Text for NULL',
        description:
            'What is written where a value is missing. Leave it empty for a '
            'blank cell, or set something like NULL where an empty string and '
            'a missing value must not look the same.',
        controller: _nullText,
        readOnly: _busy,
        width: 220,
        placeholder: 'empty',
      ),
    if (format.supportsPretty)
      AstryxSwitch(
        label: 'Indent the JSON',
        description: 'Readable, and about a third larger.',
        value: _prettyJson,
        enabled: !_busy,
        onChanged: (value) => setState(() => _prettyJson = value),
      ),
    if (format.isDelimited)
      AstryxSwitch(
        label: 'Byte-order mark',
        description:
            'For Excel on Windows, which otherwise reads a UTF-8 file as the '
            'local code page and mangles every accented character.',
        value: _byteOrderMark,
        enabled: !_busy,
        onChanged: (value) => setState(() => _byteOrderMark = value),
      ),
    if (format.needsTableName)
      AstryxBanner(
        title: 'Inserts into "${widget.tableName ?? widget.baseName}"',
        description:
            'Every row becomes one INSERT statement naming that table. '
            'Identifiers are double-quoted.',
        announce: false,
      ),
  ];
}
