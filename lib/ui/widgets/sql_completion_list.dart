import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../core/sql/sql_completion.dart';
import 'sql_highlight.dart';

/// The suggestion list, floating at the caret.
///
/// An overlay rather than a panel below the editor: a list that appears where
/// the eye already is can be read without leaving the word being typed, and one
/// pinned to the bottom of the pane cannot.
///
/// It never takes focus. The keys that drive it — the arrows, Enter, Tab,
/// Escape — are handled by the editor while the caret stays where it is, which
/// is what keeps typing through the list possible.
class SqlCompletionOverlay extends StatefulWidget {
  const SqlCompletionOverlay({
    required this.open,
    required this.result,
    required this.selectedIndex,
    required this.anchor,
    required this.onSelected,
    required this.child,
    super.key,
    this.maxHeight = 240,
    this.width = 320,
  });

  final bool open;
  final SqlCompletionResult result;
  final int selectedIndex;

  /// Where the caret is, in global coordinates. A callback rather than a value
  /// because it is only knowable after the editor has laid out.
  final Rect? Function() anchor;

  final ValueChanged<SqlCompletion> onSelected;
  final Widget child;
  final double maxHeight;
  final double width;

  @override
  State<SqlCompletionOverlay> createState() => _SqlCompletionOverlayState();
}

class _SqlCompletionOverlayState extends State<SqlCompletionOverlay> {
  final OverlayPortalController _portal = OverlayPortalController();
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(SqlCompletionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Shown and hidden after the frame: both call into the overlay, and doing
    // that during a build is what "setState during build" is made of.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.open && !_portal.isShowing) {
        _portal.show();
      } else if (!widget.open && _portal.isShowing) {
        _portal.hide();
      }
      if (widget.open && widget.selectedIndex != oldWidget.selectedIndex) {
        _revealSelected();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Keeps the highlighted row on screen as the arrows walk past the edge.
  void _revealSelected() {
    if (!_scroll.hasClients) return;
    const rowHeight = 44.0;
    final target = widget.selectedIndex * rowHeight;
    final position = _scroll.position;
    if (target < position.pixels) {
      _scroll.jumpTo(target);
    } else if (target + rowHeight > position.pixels + position.viewportDimension) {
      _scroll.jumpTo(
        (target + rowHeight - position.viewportDimension).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: _buildOverlay,
    child: widget.child,
  );

  Widget _buildOverlay(BuildContext context) {
    final caret = widget.anchor();
    if (caret == null || widget.result.isEmpty) return const SizedBox.shrink();

    final theme = AstryxTheme.of(context);
    final media = MediaQuery.of(context);
    final gap = theme.spacing(AstryxSpacingToken.spacing1);

    // Below the caret line by default, above it when there is no room — the
    // same rule every anchored surface in the design system follows.
    final below = caret.bottom + gap;
    final fits = below + widget.maxHeight < media.size.height;
    final top = fits ? below : null;
    final bottom = fits ? null : media.size.height - caret.top + gap;
    final left = caret.left.clamp(
      0.0,
      (media.size.width - widget.width).clamp(0.0, double.infinity),
    );

    return Stack(
      children: <Widget>[
        Positioned(
          left: left,
          top: top,
          bottom: bottom,
          width: widget.width,
          // Part of the text field as far as taps are concerned.
          //
          // Without this the list cannot be clicked at all: `EditableText`
          // wraps itself in a `TextFieldTapRegion` whose default
          // `onTapOutside` unfocuses on desktop, so the *press* on a row took
          // focus off the editor, which closed the list — and the release
          // landed on nothing. Declaring the overlay a member of the same
          // region is what tells Flutter this press is still inside the field.
          child: TextFieldTapRegion(
            child: _Surface(
              maxHeight: widget.maxHeight,
              child: ListView.builder(
                controller: _scroll,
                padding: EdgeInsets.all(
                  theme.spacing(AstryxSpacingToken.spacing1),
                ),
                itemCount: widget.result.items.length,
                itemBuilder: (context, index) {
                  final item = widget.result.items[index];
                  return _CompletionRow(
                    completion: item,
                    prefix: widget.result.prefix,
                    selected: index == widget.selectedIndex,
                    onPressed: () => widget.onSelected(item),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The floating panel itself: the design system's menu surface, by hand,
/// because the overlay is positioned at a caret rather than against a widget.
class _Surface extends StatelessWidget {
  const _Surface({required this.child, required this.maxHeight});

  final Widget child;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = AstryxTheme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.color(AstryxColorToken.backgroundPopover),
        borderRadius: theme.borderRadius(AstryxRadiusToken.container),
        border: Border.all(color: theme.color(AstryxColorToken.border)),
        boxShadow: <BoxShadow>[
          for (final shadow in theme.shadow(AstryxShadowToken.med))
            ?shadow.toBoxShadowOrNull(),
        ],
      ),
      child: ClipRRect(
        borderRadius: theme.borderRadius(AstryxRadiusToken.container),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: child,
        ),
      ),
    );
  }
}

/// One suggestion: what it is, what it would insert, and what it means.
class _CompletionRow extends StatelessWidget {
  const _CompletionRow({
    required this.completion,
    required this.prefix,
    required this.selected,
    required this.onPressed,
  });

  final SqlCompletion completion;
  final String prefix;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AstryxItem(
      label: completion.label,
      description: completion.detail,
      density: AstryxItemDensity.compact,
      selected: selected,
      onPressed: onPressed,
      maxLines: 1,
      leading: AstryxBadge(
        _shortKind(completion.kind),
        variant: AstryxBadgeVariant.neutral,
      ),
      trailing: completion.kind == SqlCompletionKind.column
          ? null
          : AstryxText(
              completion.kind.name,
              type: AstryxTextType.supporting,
              color: AstryxTextColor.secondary,
            ),
      // The label is the name; the type of thing is said in the badge beside
      // it, and a screen reader gets both.
      semanticsLabel: '${completion.label}, ${completion.kind.name}',
    );
  }

  static String _shortKind(SqlCompletionKind kind) => switch (kind) {
    SqlCompletionKind.column => 'col',
    SqlCompletionKind.table => 'tbl',
    SqlCompletionKind.alias => 'as',
    SqlCompletionKind.function => 'fn',
    SqlCompletionKind.keyword => 'kw',
  };
}

/// Line numbers beside the code, aligned to the lines as they are *drawn*.
///
/// Not one number per row of the box: the editor soft-wraps, so a logical line
/// can take three rows on screen and every number after it would sit a row too
/// high. Each number is placed at the offset the editor's own text layout
/// gives for the first character of its line, measured with the same style and
/// the same width, so they stay level at any window size.
class SqlGutter extends StatefulWidget {
  const SqlGutter({
    required this.controller,
    required this.scroll,
    required this.style,
    required this.textWidth,
    super.key,
    this.width = 44,
  });

  final SqlHighlightController controller;
  final ScrollController scroll;
  final TextStyle style;

  /// How wide the code itself is laid out, which is what decides where it
  /// wraps.
  final double textWidth;

  final double width;

  @override
  State<SqlGutter> createState() => _SqlGutterState();
}

class _SqlGutterState extends State<SqlGutter> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    widget.scroll.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(SqlGutter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
    if (oldWidget.scroll != widget.scroll) {
      oldWidget.scroll.removeListener(_onChanged);
      widget.scroll.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    widget.scroll.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = AstryxTheme.of(context);
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final caret = selection.isValid
        ? selection.baseOffset.clamp(0, text.length)
        : -1;
    final caretLine = caret < 0
        ? -1
        : '\n'.allMatches(text.substring(0, caret)).length;

    return SizedBox(
      width: widget.width,
      child: ClipRect(
        child: CustomPaint(
          painter: _GutterPainter(
            text: text,
            caretLine: caretLine,
            textWidth: widget.textWidth,
            scrollOffset: widget.scroll.hasClients ? widget.scroll.offset : 0,
            textStyle: widget.style,
            style: widget.style.copyWith(
              color: theme.color(AstryxColorToken.textDisabled),
            ),
            activeStyle: widget.style.copyWith(
              color: theme.color(AstryxColorToken.textSecondary),
            ),
            padding: theme.spacing(AstryxSpacingToken.spacing2),
          ),
        ),
      ),
    );
  }
}

class _GutterPainter extends CustomPainter {
  _GutterPainter({
    required this.text,
    required this.caretLine,
    required this.textWidth,
    required this.scrollOffset,
    required this.textStyle,
    required this.style,
    required this.activeStyle,
    required this.padding,
  });

  final String text;
  final int caretLine;
  final double textWidth;
  final double scrollOffset;

  /// The editor's style, for measuring. [style] is the numbers' own.
  final TextStyle textStyle;
  final TextStyle style;
  final TextStyle activeStyle;
  final double padding;

  @override
  void paint(Canvas canvas, Size size) {
    if (textWidth <= 0) return;

    final layout = TextPainter(
      text: TextSpan(text: text.isEmpty ? ' ' : text, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textWidth);

    var lineStart = 0;
    var line = 0;
    while (true) {
      final y =
          layout.getOffsetForCaret(
            TextPosition(offset: lineStart),
            Rect.zero,
          ).dy -
          scrollOffset;

      if (y > size.height) break;
      if (y + (textStyle.fontSize ?? 14) >= 0) {
        final painter = TextPainter(
          text: TextSpan(
            text: '${line + 1}',
            style: line == caretLine ? activeStyle : style,
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(canvas, Offset(size.width - painter.width - padding, y));
      }

      final next = text.indexOf('\n', lineStart);
      if (next == -1) break;
      lineStart = next + 1;
      line++;
    }
  }

  @override
  bool shouldRepaint(_GutterPainter old) =>
      old.text != text ||
      old.caretLine != caretLine ||
      old.scrollOffset != scrollOffset ||
      old.textWidth != textWidth ||
      old.style != style;
}
