import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../core/cell_value.dart';

/// One cell of tabular data.
///
/// Values are drawn in the code role: a column of identifiers, timestamps and
/// numbers is only scannable when the digits line up, which is what the
/// monospace family and tabular figures are for.
///
/// No `truncateTooltip` on anything here. It measures with a `LayoutBuilder`,
/// `AstryxTable` wraps every row in an `IntrinsicHeight`, and a layout builder
/// cannot report an intrinsic dimension — the pair throws during layout. A long
/// value is reached by pressing the row, which opens it in full.
class CellRenderer extends StatelessWidget {
  const CellRenderer(this.value, {super.key});

  final CellValue value;

  @override
  Widget build(BuildContext context) {
    // NULL is not the empty string, and a database tool that draws them the
    // same way has hidden the difference that matters most.
    if (value is NullCell) {
      return const AstryxText(
        'NULL',
        type: AstryxTextType.code,
        color: AstryxTextColor.disabled,
        semanticsLabel: 'null',
      );
    }

    // A blob or a JSON document has no useful one-line form, so the badge says
    // what it is rather than pretending to show it.
    if (value case BlobCell(:final value)) {
      return AstryxBadge(
        value.lengthInBytes == 0 ? 'empty blob' : '${value.lengthInBytes} B',
        variant: AstryxBadgeVariant.neutral,
        semanticsLabel: 'binary, ${value.lengthInBytes} bytes',
      );
    }
    if (value is JsonCell) {
      return AstryxText(
        value.display(),
        type: AstryxTextType.code,
        color: AstryxTextColor.accent,
        maxLines: 1,
      );
    }
    if (value is BoolCell) {
      return AstryxBadge(
        value.display(),
        variant: (value as BoolCell).value
            ? AstryxBadgeVariant.success
            : AstryxBadgeVariant.neutral,
      );
    }

    return AstryxText(
      value.display(),
      type: AstryxTextType.code,
      maxLines: 1,
      tabularNumbers: value is NumCell,
    );
  }
}
