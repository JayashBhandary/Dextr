import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../connectors/data_source.dart';
import '../../connectors/sql_common/sql_type_mapper.dart';
import '../../core/cell_value.dart';

class RowFormResult {
  const RowFormResult(this.values);

  final Map<String, CellValue> values;
}

/// The fields of one row, for insert or update.
///
/// Just the fields: the dialog that holds this owns the Save and Cancel
/// buttons, because they belong in the dialog's pinned footer rather than
/// scrolling away with the last column of a wide table.
class RowForm extends StatefulWidget {
  const RowForm({
    super.key,
    required this.schema,
    required this.controller,
    this.initial,
  });

  final ContainerSchema schema;

  /// Owns the field values, so the dialog's footer button can read them.
  final RowFormController controller;
  final RowData? initial;

  @override
  State<RowForm> createState() => _RowFormState();
}

class _RowFormState extends State<RowForm> {
  @override
  void initState() {
    super.initState();
    widget.controller._attach(widget.schema, widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    return AstryxFormLayout(
      children: <Widget>[
        for (final column in widget.schema.columns)
          AstryxTextInput(
            label: column.name,
            controller: widget.controller._controllers[column.name],
            // The type and the constraints are what tell somebody what may go
            // in the box, so they are the description rather than a tooltip.
            description: _describe(column),
            // A primary key is shown, and shown as unchangeable — dimming it
            // would say the field does not apply, which is the opposite of true.
            readOnly: column.isPrimaryKey && widget.initial != null,
            required: !column.nullable && column.defaultExpr == null,
            optional: column.nullable,
            placeholder: column.nullable ? 'NULL' : null,
          ),
      ],
    );
  }

  String _describe(ColumnSchema column) => <String>[
    column.typeLabel,
    if (column.isPrimaryKey) 'primary key',
    if (!column.nullable) 'not null',
    if (column.defaultExpr != null) 'default ${column.defaultExpr}',
  ].join(' · ');
}

/// Holds a row form's editors, so the form and the dialog around it agree about
/// the values without either one owning the other.
class RowFormController {
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  ContainerSchema? _schema;

  void _attach(ContainerSchema schema, RowData? initial) {
    _schema = schema;
    for (final column in schema.columns) {
      _controllers.putIfAbsent(
        column.name,
        () => TextEditingController(
          text: switch (initial?[column.name]) {
            null => '',
            // An existing NULL stays empty rather than reading "NULL", which
            // would be saved back as the four-letter string.
            NullCell() => '',
            final cell => cell.display(),
          },
        ),
      );
    }
  }

  /// The row as the backend should receive it. Each string is parsed into the
  /// family its column declares, so "3" reaches an integer column as a number.
  RowFormResult read() {
    final schema = _schema;
    if (schema == null) return const RowFormResult(<String, CellValue>{});
    return RowFormResult(<String, CellValue>{
      for (final column in schema.columns)
        column.name: parseString(
          _controllers[column.name]!.text,
          familyForSqlType(column.typeLabel),
        ),
    });
  }

  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
  }
}
