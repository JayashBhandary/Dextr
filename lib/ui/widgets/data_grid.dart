import 'package:flutter/material.dart';

import '../../core/cell_value.dart';
import 'cell_renderer.dart';

/// Simple virtualized grid using DataTable inside nested ScrollViews.
/// Replaceable with PlutoGrid post-v0.1 without changing the call sites.
class DextrDataGrid extends StatefulWidget {
  const DextrDataGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.onRowTap,
  });

  final List<String> columns;
  final List<RowData> rows;
  final void Function(int rowIndex, RowData row)? onRowTap;

  @override
  State<DextrDataGrid> createState() => _DextrDataGridState();
}

class _DextrDataGridState extends State<DextrDataGrid> {
  final ScrollController _v = ScrollController();
  final ScrollController _h = ScrollController();

  @override
  void dispose() {
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.columns.isEmpty) {
      return const Center(child: Text('No columns'));
    }
    return Scrollbar(
      controller: _v,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _v,
        scrollDirection: Axis.vertical,
        child: Scrollbar(
          controller: _h,
          thumbVisibility: true,
          notificationPredicate: (n) => n.depth == 1,
          child: SingleChildScrollView(
            controller: _h,
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 36,
              dataRowMinHeight: 32,
              dataRowMaxHeight: 40,
              columnSpacing: 24,
              columns: [
                for (final c in widget.columns)
                  DataColumn(
                    label: Text(c, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
              ],
              rows: [
                for (var i = 0; i < widget.rows.length; i++)
                  DataRow(
                    onSelectChanged: widget.onRowTap == null
                        ? null
                        : (_) => widget.onRowTap!(i, widget.rows[i]),
                    cells: [
                      for (final c in widget.columns)
                        DataCell(
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 360),
                            child: CellRenderer(widget.rows[i][c] ?? const NullCell()),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
