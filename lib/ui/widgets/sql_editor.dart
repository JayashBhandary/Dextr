import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'sql_highlight.dart';

/// The query surface: a borderless, syntax-coloured code area that fills its box.
///
/// Not an `AstryxTextInput`: a bordered control with a label is the right shape
/// for a host name, and the wrong one for the body of a query pane, where the
/// code *is* the content of the card. What it does keep is the token layer —
/// the code type role, the accent caret, the muted selection, and the syntax
/// colours from [SqlHighlightController] — so it changes with the theme like
/// everything else.
class SqlEditor extends StatefulWidget {
  const SqlEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    this.onRun,
    this.enabled = true,
    this.placeholder = '-- SELECT * FROM …',
  });

  final String initial;
  final ValueChanged<String> onChanged;

  /// Runs the query. Bound to ⌘/Ctrl+Enter, and offered in the context menu.
  final VoidCallback? onRun;
  final bool enabled;
  final String placeholder;

  @override
  State<SqlEditor> createState() => _SqlEditorState();
}

class _SqlEditorState extends State<SqlEditor> {
  late final SqlHighlightController _controller;
  final FocusNode _focusNode = FocusNode(debugLabel: 'SqlEditor');
  final ScrollController _scroll = ScrollController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller = SqlHighlightController(text: widget.initial);
    _hasText = widget.initial.isNotEmpty;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final hasText = value.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    widget.onChanged(value);
  }

  void _copy() {
    final selection = _controller.selection;
    final text = selection.isCollapsed
        ? _controller.text
        : selection.textInside(_controller.text);
    if (text.isNotEmpty) Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final selection = _controller.selection;
    final base = _controller.text;
    final start = selection.isValid ? selection.start : base.length;
    final end = selection.isValid ? selection.end : base.length;
    final next = base.replaceRange(start, end, text);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _onChanged(next);
  }

  void _selectAll() => _controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: _controller.text.length,
  );

  @override
  Widget build(BuildContext context) {
    final theme = AstryxTheme.of(context);
    final style = theme
        .textStyle(AstryxTypeRole.code)
        .copyWith(
          color: theme.color(
            widget.enabled
                ? AstryxColorToken.textPrimary
                : AstryxColorToken.textDisabled,
          ),
        );

    final editable = EditableText(
      controller: _controller,
      focusNode: _focusNode,
      style: style,
      cursorColor: theme.color(AstryxColorToken.accent),
      backgroundCursorColor: theme.color(AstryxColorToken.textDisabled),
      selectionColor: theme.color(AstryxColorToken.accentMuted),
      onChanged: _onChanged,
      readOnly: !widget.enabled,
      maxLines: null,
      expands: true,
      scrollController: _scroll,
      scrollPhysics: const ClampingScrollPhysics(),
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      rendererIgnoresPointer: true,
      enableInteractiveSelection: widget.enabled,
      showCursor: widget.enabled,
      keyboardAppearance: theme.brightness,
      // No toolbar of its own: the actions live in the context menu below,
      // where they can be astryx rows, and on the keyboard, where they always
      // were.
      contextMenuBuilder: null,
    );

    final body = Stack(
      children: <Widget>[
        // The placeholder is excluded from semantics: read as content it would
        // sound like something the user had already typed.
        if (!_hasText)
          Positioned.fill(
            child: ExcludeSemantics(
              child: Text(
                widget.placeholder,
                style: style.copyWith(
                  color: theme.color(AstryxColorToken.textSecondary),
                ),
              ),
            ),
          ),
        Positioned.fill(child: editable),
      ],
    );

    final onRun = widget.onRun;

    return AstryxContextMenu(
      label: 'Query actions',
      entries: <AstryxMenuEntry>[
        if (onRun != null)
          AstryxMenuItem(
            label: 'Run query',
            trailing: const AstryxKbd.chord(<String>[
              '⌘',
              '↵',
            ], semanticsLabel: 'Command Return'),
            onSelected: onRun,
          ),
        if (onRun != null) const AstryxMenuDivider(),
        AstryxMenuItem(label: 'Copy', onSelected: _copy),
        AstryxMenuItem(
          label: 'Paste',
          enabled: widget.enabled,
          onSelected: _paste,
        ),
        AstryxMenuItem(label: 'Select all', onSelected: _selectAll),
      ],
      child: AstryxHotkeys(
        // `.mod` is ⌘ on macOS and Ctrl elsewhere, which is what "run this"
        // means on each platform.
        bindings: <AstryxHotkey, VoidCallback>{
          const AstryxHotkey.mod(LogicalKeyboardKey.enter): ?onRun,
        },
        child: Semantics(
          textField: true,
          multiline: true,
          label: 'Query',
          enabled: widget.enabled,
          child: ExcludeSemantics(
            // A tap anywhere in the pane puts the caret in the code, not just a
            // tap on the one line that has text in it.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _focusNode.requestFocus,
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}
