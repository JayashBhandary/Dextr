import 'package:dextr/core/sql/sql_completion.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the engine offers is decided by *where the caret is*, not by what has
/// been typed: these fix the clause rules, because a list that offers columns
/// after `FROM` is worse than no list at all.
void main() {
  const catalogue = SqlCatalogue(
    tables: <String>['tracks', 'albums', 'playlist_track'],
    columns: <String, List<SqlColumnInfo>>{
      'tracks': <SqlColumnInfo>[
        SqlColumnInfo(name: 'id', type: 'INTEGER', primaryKey: true),
        SqlColumnInfo(name: 'name', type: 'TEXT', nullable: false),
        SqlColumnInfo(name: 'album_id', type: 'INTEGER'),
      ],
      'albums': <SqlColumnInfo>[
        SqlColumnInfo(name: 'id', type: 'INTEGER', primaryKey: true),
        SqlColumnInfo(name: 'title', type: 'TEXT'),
      ],
    },
  );

  SqlCompletionResult completeAt(String source, {String? contextTable}) {
    final caret = source.indexOf('|');
    expect(caret, isNot(-1), reason: 'mark the caret with |');
    return completeSql(
      text: source.replaceFirst('|', ''),
      caret: caret,
      catalogue: catalogue,
      contextTable: contextTable,
    );
  }

  List<String> labelsAt(String source, {String? contextTable}) =>
      completeAt(source, contextTable: contextTable)
          .items
          .map((i) => i.label)
          .toList();

  test('after FROM only tables are offered', () {
    final labels = labelsAt('SELECT * FROM |');

    expect(labels, containsAll(<String>['tracks', 'albums']));
    expect(labels, isNot(contains('WHERE')));
    expect(labels, isNot(contains('name')));
  });

  test('after SELECT the columns of the tables in the statement come first', () {
    final labels = labelsAt('SELECT | FROM tracks');

    expect(labels.take(3), containsAll(<String>['id', 'name']));
    // A column of a table this statement never named is not in scope.
    expect(labels, isNot(contains('title')));
  });

  test('a prefix filters, and prefix matches beat matches in the middle', () {
    final labels = labelsAt('SELECT na| FROM tracks');

    expect(labels.first, 'name');
  });

  test('a qualifier offers that table alone', () {
    final labels = labelsAt('SELECT t.| FROM tracks t JOIN albums a ON 1=1');

    expect(labels, containsAll(<String>['id', 'name', 'album_id']));
    expect(labels, isNot(contains('title')));
    // Nothing but a column can follow a dot.
    expect(labels, isNot(contains('SELECT')));
  });

  test('an alias resolves through AS', () {
    final labels = labelsAt('SELECT al.| FROM albums AS al');

    expect(labels, containsAll(<String>['id', 'title']));
    expect(labels, isNot(contains('album_id')));
  });

  test('WHERE sees every table the statement joined', () {
    final labels = labelsAt(
      'SELECT * FROM tracks t JOIN albums a ON a.id = t.album_id WHERE |',
    );

    expect(labels, containsAll(<String>['name', 'title']));
    // And the aliases themselves, for someone about to type `t.`
    expect(labels, containsAll(<String>['t', 'a']));
  });

  test('an empty editor offers the statements it could start with', () {
    final labels = labelsAt('|');

    expect(labels, contains('SELECT'));
    expect(labels, contains('INSERT INTO'));
  });

  test('nothing is offered inside a comment or a string', () {
    expect(completeAt('-- SELECT | FROM').items, isEmpty);
    expect(completeAt("SELECT 'na|' FROM tracks").items, isEmpty);
  });

  test('each statement is completed in its own scope', () {
    final labels = labelsAt('SELECT * FROM albums; SELECT | FROM tracks');

    expect(labels, contains('album_id'));
    // `title` belongs to the statement before the semicolon.
    expect(labels, isNot(contains('title')));
  });

  test('the ghost is the rest of the best suggestion, or nothing', () {
    expect(completeAt('SELECT * FROM tra|').ghost, 'cks');
    // Nothing typed yet: there is no "rest" to show, only a guess.
    expect(completeAt('SELECT * FROM |').ghost, '');
    // A match that is not a continuation would have to be read, not glanced at.
    expect(completeAt('SELECT * FROM ck|').ghost, '');
  });

  test('the range it replaces is the word being typed', () {
    final result = completeAt('SELECT * FROM tra|');

    expect(result.replaceStart, 'SELECT * FROM '.length);
    expect(result.replaceEnd, 'SELECT * FROM tra'.length);
    expect(result.prefix, 'tra');
  });

  group('the table selected in the rail', () {
    test('stands in for a FROM clause that has not been written', () {
      final labels = labelsAt('SELECT |', contextTable: 'tracks');

      expect(labels.take(3), containsAll(<String>['id', 'name']));
      // Not every column in the database — only the selected table's.
      expect(labels, isNot(contains('title')));
    });

    test('is overridden the moment the statement names its own table', () {
      final labels = labelsAt('SELECT | FROM albums', contextTable: 'tracks');

      expect(labels, contains('title'));
      expect(labels, isNot(contains('album_id')));
    });

    test('is the first table offered after FROM, and says it is selected', () {
      final result = completeAt('SELECT * FROM |', contextTable: 'albums');
      final tables = result.items
          .where((i) => i.kind == SqlCompletionKind.table)
          .toList();

      // `tracks` sorts first alphabetically and is shorter, so this is the
      // preference winning rather than the ordinary tie-break.
      expect(tables.first.label, 'albums');
      expect(tables.first.detail, 'table · selected');
      expect(tables.map((t) => t.label), contains('tracks'));
    });

    test('does not outrank the columns of the statement it is in', () {
      final labels = labelsAt(
        'SELECT | FROM tracks',
        contextTable: 'tracks',
      );

      // The column comes first: a table name at the top of a `SELECT` list is
      // never what was wanted.
      expect(labels.first, isNot('tracks'));
      expect(labels.take(3), contains('id'));
    });

    test('is matched by its bare name when the catalogue qualifies it', () {
      // `main.tracks` selected in the rail, `tracks` in the catalogue.
      final labels = labelsAt('SELECT |', contextTable: 'main.tracks');

      expect(labels.take(3), containsAll(<String>['id', 'name']));
    });

    test('changes nothing after FROM but the order', () {
      final withContext = labelsAt('SELECT * FROM |', contextTable: 'albums')
        ..sort();
      final without = labelsAt('SELECT * FROM |')..sort();

      expect(withContext, without);
    });
  });

  test('a table with no schema loaded yet simply offers nothing for it', () {
    final labels = labelsAt('SELECT | FROM playlist_track');

    expect(labels, isNot(contains('id')));
    // The keywords are still there, so the list never goes silent.
    expect(labels, contains('FROM'));
  });
}
