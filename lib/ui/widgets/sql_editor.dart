import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/sql/sql_completion.dart';
import '../../core/sql/sql_lexer.dart';
import 'sql_completion_list.dart';
import 'sql_highlight.dart';

/// The query surface: a syntax-coloured code area with a gutter, completion and
/// a hint written ahead of the caret.
///
/// Not an `AstryxTextInput`: a bordered control with a label is the right shape
/// for a host name, and the wrong one for the body of a query pane, where the
/// code *is* the content of the card. What it does keep is the token layer —
/// the code type role, the accent caret, the muted selection, and the syntax
/// colours from [SqlHighlightController] — so it changes with the theme like
/// everything else.
///
/// The editing behaviour is Flutter's own: a
/// [TextSelectionGestureDetectorBuilder] drives the same clicks, drags,
/// double-click-for-word and shift-click-to-extend that a `TextField` has. It
/// is not decoration. Before it, the pane put a bare `EditableText` behind a
/// `GestureDetector` that only asked for focus, so a click could not place the
/// caret, nothing could be selected with the mouse, and the editor read as
/// frozen.
class SqlEditor extends StatefulWidget {
  const SqlEditor({
    required this.controller,
    super.key,
    this.focusNode,
    this.onChanged,
    this.onRun,
    this.catalogue = SqlCatalogue.empty,
    this.contextTable,
    this.onCatalogueRequest,
    this.enabled = true,
    this.placeholder = '-- SELECT * FROM …',
  });

  /// The text being edited. Owned by the caller, because the caller is what
  /// runs the query and has to read the selection to know *what* to run.
  final SqlHighlightController controller;

  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;

  /// Runs the query. Bound to ⌘/Ctrl+Enter, and offered in the context menu.
  final VoidCallback? onRun;

  /// What the connection knows about itself, for the suggestions.
  final SqlCatalogue catalogue;

  /// The table the editor is pointed at from outside the text — the one open in
  /// this tab, which is the one selected in the rail.
  ///
  /// Its columns are offered before a `FROM` clause exists, and it is the first
  /// table offered once one is being written. A statement that names its own
  /// tables overrides it.
  final String? contextTable;

  /// Asks the owner to fetch the columns of these tables, because the caret
  /// has reached a statement that names them. Called only when the set the
  /// statement mentions changes, not on every keystroke.
  final ValueChanged<Set<String>>? onCatalogueRequest;

  final bool enabled;
  final String placeholder;

  @override
  State<SqlEditor> createState() => _SqlEditorState();
}

class _SqlEditorState extends State<SqlEditor>
    implements TextSelectionGestureDetectorBuilderDelegate {
  @override
  final GlobalKey<EditableTextState> editableTextKey =
      GlobalKey<EditableTextState>();

  late final _SqlSelectionGestureBuilder _gestures =
      _SqlSelectionGestureBuilder(state: this);

  FocusNode? _internalFocus;
  final ScrollController _scroll = ScrollController();

  SqlCompletionResult _completions = SqlCompletionResult.none;
  int _selectedCompletion = 0;
  bool _dismissed = false;

  /// Whether the arrows have been used since the list opened.
  ///
  /// What Enter and Tab mean depends on it. With something typed, or a row
  /// chosen by hand, they take the suggestion; with an untouched list over an
  /// empty word they are still a newline and an indent, because a list that
  /// appears on its own must never eat the keystroke that would have written
  /// code.
  bool _navigated = false;

  /// Set while the ghost is being written back to the controller, so the
  /// notification that causes does not read as the user typing.
  bool _syncingGhost = false;

  Set<String> _requestedTables = const <String>{};

  FocusNode get _focusNode => widget.focusNode ?? (_internalFocus ??= FocusNode(
    debugLabel: 'SqlEditor',
  ));

  SqlHighlightController get _controller => widget.controller;

  @override
  bool get forcePressEnabled => false;

  @override
  bool get selectionEnabled => widget.enabled;

  bool get _popupOpen => !_dismissed && _completions.items.isNotEmpty;

  /// Whether the list is the one that should answer Enter and Tab.
  bool get _popupTakesKeys =>
      _popupOpen && (_completions.prefix.isNotEmpty || _navigated);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onEditingChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(SqlEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onEditingChanged);
      widget.controller.addListener(_onEditingChanged);
    }
    // A catalogue that arrived while the caret sat still still changes what
    // could be suggested at it, and so does the tab being pointed at another
    // table.
    if (oldWidget.catalogue != widget.catalogue ||
        oldWidget.contextTable != widget.contextTable) {
      _refreshCompletions();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onEditingChanged);
    _focusNode.removeListener(_onFocusChanged);
    _internalFocus?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) _closePopup();
    _syncGhost();
    setState(() {});
  }

  void _onEditingChanged() {
    if (_syncingGhost) return;
    // Anything the user does — typing, moving the caret, selecting — changes
    // what is suggested, so this is the one place that recomputes.
    _dismissed = false;
    _refreshCompletions();
    widget.onChanged?.call(_controller.text);
  }

  void _refreshCompletions() {
    if (!widget.enabled) return;
    final selection = _controller.selection;
    final text = _controller.text;

    if (!selection.isValid || !selection.isCollapsed || !_focusNode.hasFocus) {
      _setCompletions(SqlCompletionResult.none);
      return;
    }

    final result = completeSql(
      text: text,
      caret: selection.baseOffset,
      catalogue: widget.catalogue,
      contextTable: widget.contextTable,
    );
    _setCompletions(result);
    _requestSchemas(text, selection.baseOffset);
  }

  /// Asks for the columns of whatever tables this statement names, once per
  /// set. Fetching a schema is a round trip, so it happens when the *statement*
  /// changes rather than when the text does.
  void _requestSchemas(String text, int caret) {
    final request = widget.onCatalogueRequest;
    if (request == null) return;
    final (start, end) = sqlStatementRange(text, caret);
    final refs = sqlTableRefs(
      tokenizeSqlRange(text, start, end),
      text,
    ).map((r) => r.table).toSet();
    if (refs.isEmpty || _setEquals(refs, _requestedTables)) return;
    _requestedTables = refs;
    request(refs);
  }

  void _setCompletions(SqlCompletionResult result) {
    // Compared by what is *in* the list, not by how long it is. The list is
    // capped, so a schema arriving mid-statement can add three columns and
    // leave the count exactly where it was — and the editor would go on
    // offering the list from before the connection answered.
    final sameItems =
        result.replaceStart == _completions.replaceStart &&
        result.prefix == _completions.prefix &&
        result.items.length == _completions.items.length &&
        _sameLabels(result.items, _completions.items);
    if (!sameItems) {
      setState(() {
        _completions = result;
        _selectedCompletion = 0;
        _navigated = false;
      });
    }
    _syncGhost();
  }

  /// Hands the hint to the controller, which is what paints it.
  void _syncGhost() {
    final ghost = _popupOpen && _focusNode.hasFocus ? _completions.ghost : '';
    if (ghost == _controller.ghost) return;
    _syncingGhost = true;
    _controller.ghost = ghost;
    _syncingGhost = false;
  }

  void _closePopup() {
    if (_completions.isEmpty && _dismissed) return;
    setState(() {
      _dismissed = true;
      _completions = SqlCompletionResult.none;
      _navigated = false;
    });
    _syncGhost();
  }

  void _moveSelection(int delta) {
    if (!_popupOpen) return;
    final count = _completions.items.length;
    setState(() {
      _selectedCompletion = (_selectedCompletion + delta + count) % count;
      _navigated = true;
    });
  }

  /// Puts [completion] in place of the word being typed.
  void _accept(SqlCompletion completion) {
    final text = _controller.text;
    final start = _completions.replaceStart.clamp(0, text.length);
    final end = _completions.replaceEnd.clamp(start, text.length);
    final insert = completion.insert;

    _controller.value = TextEditingValue(
      text: text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    _closePopup();
    // Taking a row with the mouse must leave the caret where the keyboard would
    // have left it: still in the editor, ready for the next word.
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
  }

  /// Takes the hint written ahead of the caret. The same keystroke that would
  /// accept the highlighted row in the list, for when the list is not open.
  bool _acceptGhost() {
    final ghost = _completions.ghost;
    if (ghost.isEmpty) return false;
    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return false;
    final at = selection.baseOffset;
    _controller.value = TextEditingValue(
      text: _controller.text.replaceRange(at, at, ghost),
      selection: TextSelection.collapsed(offset: at + ghost.length),
    );
    _closePopup();
    return true;
  }

  /// Where the caret is on screen, so the list can sit under it rather than
  /// under the pane.
  Rect? _caretRect() {
    final editable = editableTextKey.currentState?.renderEditable;
    final selection = _controller.selection;
    if (editable == null || !selection.isValid) return null;
    final local = editable.getLocalRectForCaret(
      TextPosition(offset: selection.baseOffset),
    );
    final origin = editable.localToGlobal(local.topLeft);
    return Rect.fromLTWH(origin.dx, origin.dy, local.width, local.height);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    if (_popupOpen) {
      switch (key) {
        case LogicalKeyboardKey.arrowDown:
          _moveSelection(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          _moveSelection(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.escape:
          _closePopup();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.tab:
          if (_popupTakesKeys) {
            _accept(_completions.items[_selectedCompletion]);
            return KeyEventResult.handled;
          }
      }
    }

    if (key == LogicalKeyboardKey.tab) {
      // Never a tab stop out of the editor: Tab in code means "more text".
      if (_acceptGhost()) return KeyEventResult.handled;
      _closePopup();
      _insert('  ');
      return KeyEventResult.handled;
    }

    // The hint is taken with the arrow that would walk over it anyway.
    if (key == LogicalKeyboardKey.arrowRight && _completions.ghost.isNotEmpty) {
      final selection = _controller.selection;
      if (selection.isCollapsed && selection.baseOffset == _controller.text.length) {
        if (_acceptGhost()) return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  void _insert(String text) {
    final selection = _controller.selection;
    final base = _controller.text;
    final start = selection.isValid ? selection.start : base.length;
    final end = selection.isValid ? selection.end : base.length;
    _controller.value = TextEditingValue(
      text: base.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  void _copy() {
    final selection = _controller.selection;
    final text = selection.isValid && !selection.isCollapsed
        ? selection.textInside(_controller.text)
        : _controller.text;
    if (text.isNotEmpty) Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _insert(text);
  }

  void _selectAll() => _controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: _controller.text.length,
  );

  /// Comments or uncomments every line the selection touches.
  void _toggleComment() {
    final text = _controller.text;
    final selection = _controller.selection;
    if (!selection.isValid) return;
    final start = text.lastIndexOf('\n', selection.start == 0 ? 0 : selection.start - 1) + 1;
    final nextBreak = text.indexOf('\n', selection.end);
    final end = nextBreak == -1 ? text.length : nextBreak;

    final lines = text.substring(start, end).split('\n');
    final allCommented = lines
        .where((l) => l.trim().isNotEmpty)
        .every((l) => l.trimLeft().startsWith('--'));
    final changed = lines
        .map(
          (line) => line.trim().isEmpty
              ? line
              : allCommented
              ? line.replaceFirst(RegExp(r'--\s?'), '')
              : '-- $line',
        )
        .join('\n');

    _controller.value = TextEditingValue(
      text: text.replaceRange(start, end, changed),
      selection: TextSelection.collapsed(offset: start + changed.length),
    );
  }

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
      key: editableTextKey,
      controller: _controller,
      focusNode: _focusNode,
      style: style,
      cursorColor: theme.color(AstryxColorToken.accent),
      backgroundCursorColor: theme.color(AstryxColorToken.textDisabled),
      selectionColor: theme.color(AstryxColorToken.accentMuted),
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
      showSelectionHandles: false,
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
        if (_controller.text.isEmpty)
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
        Positioned.fill(child: _gestures.buildGestureDetector(child: editable)),
      ],
    );

    final onRun = widget.onRun;

    final editor = AstryxContextMenu(
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
        const AstryxMenuDivider(),
        AstryxMenuItem(
          label: 'Toggle comment',
          enabled: widget.enabled,
          trailing: const AstryxKbd.chord(<String>[
            '⌘',
            '/',
          ], semanticsLabel: 'Command slash'),
          onSelected: _toggleComment,
        ),
      ],
      child: AstryxHotkeys(
        // `.mod` is ⌘ on macOS and Ctrl elsewhere, which is what "run this"
        // means on each platform.
        bindings: <AstryxHotkey, VoidCallback>{
          const AstryxHotkey.mod(LogicalKeyboardKey.enter): ?onRun,
          const AstryxHotkey.mod(LogicalKeyboardKey.slash): _toggleComment,
          const AstryxHotkey.mod(LogicalKeyboardKey.space): _refreshCompletions,
        },
        child: Semantics(
          textField: true,
          multiline: true,
          label: 'Query',
          enabled: widget.enabled,
          child: ExcludeSemantics(
            child: Focus(
              skipTraversal: true,
              canRequestFocus: false,
              onKeyEvent: _onKey,
              child: body,
            ),
          ),
        ),
      ),
    );

    const gutterWidth = 44.0;

    return LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SqlGutter(
            controller: _controller,
            scroll: _scroll,
            style: style,
            width: gutterWidth,
            // The numbers are placed from the editor's own layout, so the
            // gutter has to be told the width the code wraps at.
            textWidth: constraints.maxWidth - gutterWidth,
          ),
          Expanded(
            child: SqlCompletionOverlay(
              open: _popupOpen && _focusNode.hasFocus,
              result: _completions,
              selectedIndex: _selectedCompletion,
              anchor: _caretRect,
              onSelected: _accept,
              child: editor,
            ),
          ),
        ],
      ),
    );
  }
}

/// Flutter's own text gestures, pointed at this editor.
///
/// The whole class is the two overrides the builder needs; everything a click,
/// a drag, a double-click and a shift-click do comes from the framework, which
/// is the point — a hand-written approximation of caret placement is how an
/// editor ends up almost working.
class _SqlSelectionGestureBuilder extends TextSelectionGestureDetectorBuilder {
  _SqlSelectionGestureBuilder({required _SqlEditorState state})
    : _state = state,
      super(delegate: state);

  final _SqlEditorState _state;

  @override
  void onSingleTapUp(TapDragUpDetails details) {
    super.onSingleTapUp(details);
    _state._focusNode.requestFocus();
  }
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.every(b.contains);

bool _sameLabels(List<SqlCompletion> a, List<SqlCompletion> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i].label != b[i].label) return false;
  }
  return true;
}
