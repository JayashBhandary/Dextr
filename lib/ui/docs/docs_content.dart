/// Everything the documentation page says, as data.
///
/// Content rather than widgets, for two reasons. The page can then draw an
/// outline, a chapter list and a next/previous pair from the same source
/// without any of them going stale when a section is added; and a paragraph
/// that has to be reworded is a string edit rather than a widget-tree edit.
///
/// `docs_page.dart` is the only thing that renders this, and it decides what
/// each block looks like — nothing here imports the widget set.
library;

/// Where a chapter sits in the rail.
enum DocsGroup {
  start,
  connect,
  work,
  reference;

  String get label => switch (this) {
    start => 'Getting started',
    connect => 'Connections',
    work => 'Working with data',
    reference => 'Reference',
  };
}

/// One page of the manual: a title, a line about it, and its sections.
class DocsChapter {
  const DocsChapter({
    required this.id,
    required this.group,
    required this.title,
    required this.summary,
    required this.sections,
  });

  /// What the rail selects on and the router could carry.
  final String id;
  final DocsGroup group;
  final String title;

  /// The line under the title. What the reader gets out of this chapter.
  final String summary;

  final List<DocsSection> sections;
}

/// One heading inside a chapter, and everything under it.
class DocsSection {
  const DocsSection({
    required this.id,
    required this.title,
    required this.blocks,
  });

  /// Unique within its chapter. The outline entry's id and anchor key.
  final String id;
  final String title;
  final List<DocsBlock> blocks;
}

/// A run of content inside a section.
sealed class DocsBlock {
  const DocsBlock();
}

/// A paragraph.
final class DocsProse extends DocsBlock {
  const DocsProse(this.text);
  final String text;
}

/// Points that are a set rather than a sequence.
final class DocsBullets extends DocsBlock {
  const DocsBullets(this.points);
  final List<String> points;
}

/// Points that are a sequence — do this, then this. Numbered.
final class DocsSteps extends DocsBlock {
  const DocsSteps(this.steps);
  final List<String> steps;
}

/// Label-and-value pairs about one thing: the fields of a form, the defaults of
/// a setting.
final class DocsFacts extends DocsBlock {
  const DocsFacts(this.facts);
  final List<DocsFact> facts;
}

class DocsFact {
  const DocsFact(this.label, this.value);
  final String label;
  final String value;
}

/// A comparison across several things, where the columns line up.
final class DocsTable extends DocsBlock {
  const DocsTable({
    required this.label,
    required this.headers,
    required this.rows,
  });

  /// The table's accessible name. Never painted, always required.
  final String label;
  final List<String> headers;
  final List<List<String>> rows;
}

/// Shortcuts, drawn as key caps.
final class DocsKeys extends DocsBlock {
  const DocsKeys(this.rows);
  final List<DocsKey> rows;
}

class DocsKey {
  const DocsKey(this.keys, this.meaning, {this.spoken});

  /// The caps, in the order they are pressed together.
  final List<String> keys;
  final String meaning;

  /// What a screen reader says instead of the glyphs. Required whenever a cap
  /// is a symbol: "⌘ ⌥ W" read out as glyphs is not a shortcut anyone can
  /// follow.
  final String? spoken;
}

/// Something to type, or something the application expects to be given.
final class DocsCode extends DocsBlock {
  const DocsCode(this.code, {this.language});
  final String code;
  final String? language;
}

/// A fact that changes what the reader should do, set apart from the prose.
final class DocsNote extends DocsBlock {
  const DocsNote({
    required this.title,
    this.description,
    this.kind = DocsNoteKind.info,
  });
  final String title;
  final String? description;
  final DocsNoteKind kind;
}

enum DocsNoteKind { info, warning, danger }
