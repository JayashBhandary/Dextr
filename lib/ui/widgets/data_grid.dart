import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../core/cell_value.dart';
import 'cell_renderer.dart';

/// A page of rows from any backend, as an `AstryxTable`.
///
/// The table does not virtualise, which is exactly the contract the browse pane
/// already had: rows arrive one `pageSize` at a time and the caller pages. Feed
/// it a whole table and it will try to build every row.
class DextrDataGrid extends StatelessWidget {
  const DextrDataGrid({
    super.key,
    required this.columns,
    required this.rows,
    required this.label,
    this.density = AstryxTableDensity.compact,
    this.onRowPressed,
    this.rowActionsBuilder,
    this.emptyState,
  });

  final List<String> columns;
  final List<RowData> rows;

  /// The table's accessible name — "rows of public.users".
  final String label;
  final AstryxTableDensity density;
  final void Function(RowData row)? onRowPressed;
  final Widget Function(BuildContext, RowData row)? rowActionsBuilder;
  final Widget? emptyState;

  /// How many rows are read to decide a column's alignment.
  ///
  /// A column is one type in practice, and the answer is settled by the first
  /// screenful. Reading every row instead cost two full scans per column on
  /// every build, which on a wide result was more work than drawing it.
  static const _alignmentSample = 100;

  /// Names a row for assistive technology. The first column is nearly always
  /// the key in a database listing, so it is what identifies the row; without
  /// this every row would announce itself identically.
  String _rowLabel(RowData row, Map<RowData, int> positions) {
    if (columns.isEmpty) return 'row';
    final first = row[columns.first];
    final value = first == null || first is NullCell ? null : first.display();
    return value == null || value.isEmpty
        ? 'row ${(positions[row] ?? 0) + 1}'
        : '${columns.first} $value';
  }

  @override
  Widget build(BuildContext context) {
    if (columns.isEmpty) {
      return emptyState ??
          const AstryxEmptyState(
            title: 'No columns',
            description: 'The source returned rows with no columns in them.',
            size: AstryxEmptyStateSize.compact,
          );
    }

    // Row identity, resolved in one pass.
    //
    // This used to be `keyOf: (row) => rows.indexOf(row)`, and the table asks
    // for a key once for the whole list plus once per row it builds — so a
    // linear scan ran inside a linear pass, on every build. Measured: 20k rows
    // 160ms, 50k rows 4.2s, *per key pass*, which is the shape of a query pane
    // that stops responding rather than one that is merely slow.
    //
    // A `RowData` is a `Map` and does not define equality, so identity is the
    // only thing to key on — and it is the right thing: two identical rows are
    // still two rows. Identity is also why this is `Map.identity()` rather than
    // a plain map, which would hash every cell of every row to store it.
    final positions = Map<RowData, int>.identity();
    for (var i = 0; i < rows.length; i++) {
      positions[rows[i]] = i;
    }

    // Resolved once per build rather than once per row: `cellBuilder` runs for
    // every visible cell, and an alignment recomputed there would put the scan
    // back where it was taken out of.
    final alignments = <String, AstryxTableAlignment>{
      for (final column in columns) column: _alignmentOf(column),
    };

    return AstryxTable<RowData>(
      label: label,
      rows: rows,
      density: density,
      // Identity is the row's position: a result set has no key of its own,
      // and two identical rows are still two rows.
      keyOf: (row) => positions[row] ?? -1,
      rowLabelOf: (row) => _rowLabel(row, positions),
      onRowPressed: onRowPressed,
      rowActionsBuilder: rowActionsBuilder,
      emptyState: emptyState,
      showRowDividers: true,
      columns: <AstryxTableColumn<RowData>>[
        for (final column in columns)
          AstryxTableColumn<RowData>(
            id: column,
            header: column,
            // Clamped intrinsic width: an empty column does not collapse to
            // nothing, and one long JSON value cannot push the rest off-screen.
            width: const AstryxTableColumnWidth.intrinsic(min: 96, max: 360),
            alignment: alignments[column]!,
            cellBuilder: (context, row) =>
                CellRenderer(row[column] ?? const NullCell()),
          ),
      ],
    );
  }

  /// Numbers read against the right edge; everything else against the start.
  AstryxTableAlignment _alignmentOf(String column) {
    var anyNumeric = false;
    final sample = rows.length < _alignmentSample
        ? rows.length
        : _alignmentSample;
    for (var i = 0; i < sample; i++) {
      final cell = rows[i][column];
      if (cell is NumCell) {
        anyNumeric = true;
        continue;
      }
      // One value that is not a number settles it: a column read against the
      // right edge with words in it reads as broken.
      if (cell != null && cell is! NullCell) return AstryxTableAlignment.start;
    }
    return anyNumeric
        ? AstryxTableAlignment.end
        : AstryxTableAlignment.start;
  }
}
