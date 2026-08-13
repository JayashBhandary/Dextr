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

  /// Names a row for assistive technology. The first column is nearly always
  /// the key in a database listing, so it is what identifies the row; without
  /// this every row would announce itself identically.
  String _rowLabel(RowData row) {
    if (columns.isEmpty) return 'row';
    final first = row[columns.first];
    final value = first == null || first is NullCell ? null : first.display();
    return value == null || value.isEmpty
        ? 'row ${rows.indexOf(row) + 1}'
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

    return AstryxTable<RowData>(
      label: label,
      rows: rows,
      density: density,
      // Identity is the row's position: a result set has no key of its own,
      // and two identical rows are still two rows.
      keyOf: (row) => rows.indexOf(row),
      rowLabelOf: _rowLabel,
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
            alignment: _alignmentOf(column),
            cellBuilder: (context, row) =>
                CellRenderer(row[column] ?? const NullCell()),
          ),
      ],
    );
  }

  /// Numbers read against the right edge; everything else against the start.
  AstryxTableAlignment _alignmentOf(String column) {
    final anyNumeric = rows.any((row) => row[column] is NumCell);
    final anyOther = rows.any((row) {
      final cell = row[column];
      return cell != null && cell is! NumCell && cell is! NullCell;
    });
    return anyNumeric && !anyOther
        ? AstryxTableAlignment.end
        : AstryxTableAlignment.start;
  }
}
