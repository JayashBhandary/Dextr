import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/settings_provider.dart';
import 'docs_chapters.dart';
import 'docs_content.dart';

/// The manual, inside the application.
///
/// Three columns, each answering a different question: the rail says where you
/// are in the manual, the outline says where you are in the chapter, and the
/// body is the only one that scrolls under either of them.
///
/// The content is data — see `docs_chapters.dart` — so the rail, the outline and
/// the next/previous pair are all derived from one list rather than maintained
/// beside it.
class DocsPage extends ConsumerStatefulWidget {
  const DocsPage({super.key, this.initialChapterId});

  /// Which chapter to open on. Null starts at the beginning, which is what a
  /// first-time reader wants.
  final String? initialChapterId;

  @override
  ConsumerState<DocsPage> createState() => _DocsPageState();
}

class _DocsPageState extends ConsumerState<DocsPage> {
  /// The body's scroll view, handed to the layout so the outline can track it.
  final ScrollController _scroll = ScrollController();

  late DocsChapter _chapter = widget.initialChapterId == null
      ? docsHome
      : docsChapterById(widget.initialChapterId!);

  /// A key on each section's heading in the open chapter, for the outline to
  /// scroll to. Rebuilt per chapter: the keys belong to widgets that no longer
  /// exist once the chapter changes.
  late Map<String, GlobalKey> _anchors = _anchorsFor(_chapter);

  static Map<String, GlobalKey> _anchorsFor(DocsChapter chapter) =>
      <String, GlobalKey>{
        for (final section in chapter.sections) section.id: GlobalKey(),
      };

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _open(String id) {
    final chapter = docsChapterById(id);
    if (chapter.id == _chapter.id) return;
    setState(() {
      _chapter = chapter;
      _anchors = _anchorsFor(chapter);
    });
    // A new chapter starts at its own beginning. Without this the reader lands
    // three sections down because that is where the last chapter had got to.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  /// The chapter before and after this one, in reading order.
  (DocsChapter?, DocsChapter?) get _neighbours {
    final index = docsChapters.indexWhere((c) => c.id == _chapter.id);
    return (
      index > 0 ? docsChapters[index - 1] : null,
      index >= 0 && index < docsChapters.length - 1
          ? docsChapters[index + 1]
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final density = ref.watch(settingsProvider).itemDensity;
    final (previous, next) = _neighbours;

    return AstryxAppShell(
      // Wider than the workspace's threshold: this page carries a rail *and* an
      // outline, and the prose column stops being readable before the window
      // stops being wide.
      compactBelow: 1000,
      navLabel: 'Documentation',
      sidebarWidth: 248,
      sidebar: _ChapterRail(
        selectedId: _chapter.id,
        density: density,
        onSelected: _open,
      ),
      child: AstryxLayout(
        scrollController: _scroll,
        // Prose is the content here, and a paragraph that runs the width of a
        // monitor is a paragraph nobody finishes.
        maxContentWidth: 760,
        panelWidth: 208,
        header: _Header(chapter: _chapter),
        panel: AstryxOutline(
          label: 'On this page',
          controller: _scroll,
          entries: <AstryxOutlineEntry>[
            for (final section in _chapter.sections)
              AstryxOutlineEntry(
                id: section.id,
                label: section.title,
                anchor: _anchors[section.id],
              ),
          ],
        ),
        footer: _Footer(previous: previous, next: next, onOpen: _open),
        child: AstryxVStack(
          gap: AstryxSpacingToken.spacing6,
          align: AstryxStackAlign.stretch,
          children: <Widget>[
            for (final section in _chapter.sections)
              AstryxSection(
                title: section.title,
                headerKey: _anchors[section.id],
                child: AstryxVStack(
                  gap: AstryxSpacingToken.spacing4,
                  align: AstryxStackAlign.stretch,
                  children: <Widget>[
                    for (final block in section.blocks) DocsBlockView(block),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The chapter list, grouped.
class _ChapterRail extends StatelessWidget {
  const _ChapterRail({
    required this.selectedId,
    required this.density,
    required this.onSelected,
  });

  final String selectedId;
  final AstryxItemDensity density;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    // The shell fills the rail only in the drawer layout, so the wide one fills
    // itself — otherwise the rail is the same surface as the page beside it and
    // only the divider says where one ends.
    return ColoredBox(
      color: AstryxTheme.of(context).color(AstryxColorToken.backgroundSurface),
      child: AstryxSideNav(
        label: 'Documentation',
        density: density,
        selectedId: selectedId,
        onSelected: onSelected,
        entries: <AstryxNavEntry>[
          for (final group in DocsGroup.values)
            AstryxNavSection(
              label: group.label,
              items: <AstryxNavItem>[
                for (final chapter in docsChapters.where(
                  (c) => c.group == group,
                ))
                  AstryxNavItem(id: chapter.id, label: chapter.title),
              ],
            ),
        ],
      ),
    );
  }
}

/// The chapter's title, its summary, and the way back to the workspace.
class _Header extends StatelessWidget {
  const _Header({required this.chapter});

  final DocsChapter chapter;

  @override
  Widget build(BuildContext context) {
    final shell = AstryxAppShell.of(context);

    return AstryxHStack(
      gap: AstryxSpacingToken.spacing3,
      align: AstryxStackAlign.start,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        // In the drawer layout the rail is off screen, so the way to it has to
        // be on it.
        if (shell.compact)
          AstryxIconButton(
            icon: AstryxIconName.menu,
            label: 'Show the chapter list',
            tooltip: 'Chapters',
            variant: AstryxButtonVariant.ghost,
            onPressed: shell.controller.toggle,
          ),
        Expanded(
          child: AstryxVStack(
            gap: AstryxSpacingToken.spacing2,
            align: AstryxStackAlign.stretch,
            children: <Widget>[
              AstryxHeading(chapter.title, level: 1),
              AstryxText(
                chapter.summary,
                type: AstryxTextType.large,
                color: AstryxTextColor.secondary,
              ),
            ],
          ),
        ),
        AstryxIconButton(
          icon: AstryxIconName.close,
          label: 'Close the documentation',
          tooltip: 'Close',
          variant: AstryxButtonVariant.ghost,
          onPressed: () => context.go('/'),
        ),
      ],
    );
  }
}

/// The chapter before and after, so the manual can be read straight through.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.previous,
    required this.next,
    required this.onOpen,
  });

  final DocsChapter? previous;
  final DocsChapter? next;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final previous = this.previous;
    final next = this.next;

    return AstryxHStack(
      gap: AstryxSpacingToken.spacing3,
      justify: AstryxStackJustify.between,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        if (previous != null)
          Flexible(
            child: AstryxButton(
              label: previous.title,
              variant: AstryxButtonVariant.ghost,
              size: AstryxButtonSize.sm,
              leading: const AstryxIcon(
                AstryxIconName.chevronLeft,
                size: AstryxIconSize.sm,
              ),
              onPressed: () => onOpen(previous.id),
            ),
          )
        else
          const SizedBox.shrink(),
        if (next != null)
          Flexible(
            child: AstryxButton(
              label: next.title,
              variant: AstryxButtonVariant.ghost,
              size: AstryxButtonSize.sm,
              trailing: const AstryxIcon(
                AstryxIconName.chevronRight,
                size: AstryxIconSize.sm,
              ),
              onPressed: () => onOpen(next.id),
            ),
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }
}

/// One block of a section, as the widget that block means.
///
/// Public because it is the whole rendering contract between the content and
/// the page: a new [DocsBlock] is a new case here and nothing else.
class DocsBlockView extends StatelessWidget {
  const DocsBlockView(this.block, {super.key});

  final DocsBlock block;

  @override
  Widget build(BuildContext context) => switch (block) {
    DocsProse(:final text) => AstryxText(text),
    DocsBullets(:final points) => _Points(points: points),
    DocsSteps(:final steps) => _Steps(steps: steps),
    DocsFacts(:final facts) => AstryxMetadataList(
      items: <AstryxMetadataItem>[
        for (final fact in facts)
          AstryxMetadataItem.text(label: fact.label, value: fact.value),
      ],
    ),
    DocsTable(:final label, :final headers, :final rows) => _Reference(
      label: label,
      headers: headers,
      rows: rows,
    ),
    DocsKeys(:final rows) => _Keys(rows: rows),
    DocsCode(:final code, :final language) => AstryxCodeBlock(
      code,
      language: language,
      wrap: true,
    ),
    DocsNote(:final title, :final description, :final kind) => AstryxBanner(
      title: title,
      description: description,
      status: switch (kind) {
        DocsNoteKind.info => AstryxBannerStatus.info,
        DocsNoteKind.warning => AstryxBannerStatus.warning,
        DocsNoteKind.danger => AstryxBannerStatus.error,
      },
      // A page of prose is not a page of events: announcing every note on it
      // would read the whole chapter out before the reader reached it.
      announce: false,
    ),
  };
}

/// Points that are a set. A marker and a line of text, wrapping.
class _Points extends StatelessWidget {
  const _Points({required this.points});

  final List<String> points;

  @override
  Widget build(BuildContext context) {
    return AstryxVStack(
      gap: AstryxSpacingToken.spacing2,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        for (final point in points)
          AstryxHStack(
            gap: AstryxSpacingToken.spacing2,
            align: AstryxStackAlign.start,
            children: <Widget>[
              // Decorative: the list reads as a list without the bullet being
              // spoken before every item.
              const ExcludeSemantics(
                child: AstryxText('•', color: AstryxTextColor.secondary),
              ),
              Flexible(child: AstryxText(point)),
            ],
          ),
      ],
    );
  }
}

/// Points that are a sequence, numbered.
class _Steps extends StatelessWidget {
  const _Steps({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return AstryxVStack(
      gap: AstryxSpacingToken.spacing3,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        for (var i = 0; i < steps.length; i++)
          AstryxHStack(
            gap: AstryxSpacingToken.spacing3,
            align: AstryxStackAlign.start,
            children: <Widget>[
              // The number is read out, because "step four" is part of the
              // instruction rather than decoration around it.
              AstryxBadge('${i + 1}', semanticsLabel: 'Step ${i + 1}'),
              Flexible(child: AstryxText(steps[i])),
            ],
          ),
      ],
    );
  }
}

/// A comparison table, where lining the columns up is the point.
class _Reference extends StatelessWidget {
  const _Reference({
    required this.label,
    required this.headers,
    required this.rows,
  });

  final String label;
  final List<String> headers;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    return AstryxTable<List<String>>(
      label: label,
      density: AstryxTableDensity.balanced,
      rows: rows,
      keyOf: (row) => row.first,
      // The first cell of a reference row is what identifies it — the source,
      // the format, the engine — so it is what a row announces itself as.
      rowLabelOf: (row) => row.first,
      showRowDividers: true,
      columns: <AstryxTableColumn<List<String>>>[
        for (var i = 0; i < headers.length; i++)
          AstryxTableColumn<List<String>>(
            id: '$i',
            header: headers[i],
            cellBuilder: (context, row) =>
                AstryxText(i < row.length ? row[i] : '—', maxLines: 4),
          ),
      ],
    );
  }
}

/// Shortcuts: the caps, and what pressing them does.
class _Keys extends StatelessWidget {
  const _Keys({required this.rows});

  final List<DocsKey> rows;

  @override
  Widget build(BuildContext context) {
    return AstryxVStack(
      gap: AstryxSpacingToken.spacing3,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        for (final row in rows)
          AstryxHStack(
            gap: AstryxSpacingToken.spacing3,
            align: AstryxStackAlign.start,
            children: <Widget>[
              SizedBox(
                width: 116,
                child: AstryxHStack(
                  children: <Widget>[
                    AstryxKbd.chord(
                      row.keys,
                      size: AstryxKbdSize.sm,
                      semanticsLabel: row.spoken,
                    ),
                  ],
                ),
              ),
              Flexible(child: AstryxText(row.meaning)),
            ],
          ),
      ],
    );
  }
}
