import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../core/sql/sql_lexer.dart';

/// A [TextEditingController] that paints SQL in the theme's syntax colours,
/// and the hint the editor writes ahead of the caret.
///
/// astryx_ui deliberately ships no highlighter — `AstryxCodeBlock` says as much,
/// on the grounds that code coloured by the wrong grammar lies about what it
/// means. It does ship the *colours*, one per `AstryxSyntaxToken`, per theme.
/// So the grammar is the part that lives here, and it is the one grammar this
/// application actually has: SQL. Every colour still comes from the token layer,
/// which is why switching theme or colour mode recolours the editor.
class SqlHighlightController extends TextEditingController {
  SqlHighlightController({super.text});

  String _ghost = '';

  /// What the editor believes is about to be typed — the rest of the best
  /// suggestion, painted dimmed after the caret.
  ///
  /// Only ever shown with the caret at the very end of the text. The span the
  /// editor paints has to line up character for character with the text being
  /// edited, so a hint in the *middle* would move every offset after it: the
  /// caret would draw in the wrong place and a click would land on the wrong
  /// character. At the end there is nothing after it to move.
  String get ghost => _ghost;

  set ghost(String value) {
    final showable = _canShow(value) ? value : '';
    if (showable == _ghost) return;
    _ghost = showable;
    notifyListeners();
  }

  bool _canShow(String value) {
    if (value.isEmpty) return false;
    final at = selection;
    return at.isValid && at.isCollapsed && at.baseOffset == text.length;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final theme = AstryxTheme.of(context);
    final base = style ?? theme.textStyle(AstryxTypeRole.code);

    Color colorFor(AstryxSyntaxToken token) =>
        theme.syntaxColor(token) ?? theme.color(AstryxColorToken.textPrimary);

    return TextSpan(
      style: base,
      children: <InlineSpan>[
        for (final token in tokenizeSql(text))
          TextSpan(
            text: token.text,
            style: token.token == null
                ? null
                : TextStyle(color: colorFor(token.token!)),
          ),
        if (_canShow(_ghost))
          TextSpan(
            text: _ghost,
            style: TextStyle(color: theme.color(AstryxColorToken.textDisabled)),
          ),
      ],
    );
  }
}
