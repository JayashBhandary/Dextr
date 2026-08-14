import 'package:dextr/core/files/delimited_table.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reading a CSV back.
///
/// The cases here are the ones a real export from another tool contains: a comma
/// inside a quoted value, a doubled quote, a value that spans lines, a ragged
/// row, CRLF endings. Getting any of them wrong shifts a column, and a preview
/// that shifts a column is worse than no preview — it looks right.
void main() {
  test('a header and rows, split on commas', () {
    final table = parseDelimited('id,name\n1,Intro\n2,Verse\n');

    expect(table.columns, <String>['id', 'name']);
    expect(table.rows, <List<String>>[
      <String>['1', 'Intro'],
      <String>['2', 'Verse'],
    ]);
    expect(table.delimiter, ',');
    expect(table.truncated, isFalse);
  });

  test('a quoted value keeps its commas, quotes and newlines', () {
    final table = parseDelimited(
      'a,b,c\n'
      '"has,comma","say ""hi""","two\nlines"\n',
    );

    expect(table.rows.single, <String>['has,comma', 'say "hi"', 'two\nlines']);
    // The newline inside the quotes did not end the row.
    expect(table.rows, hasLength(1));
  });

  test('CRLF is one line break', () {
    final table = parseDelimited('id,name\r\n1,Intro\r\n2,Verse\r\n');

    expect(table.rows, hasLength(2));
    expect(table.rows.last, <String>['2', 'Verse']);
  });

  test('a short row is padded rather than throwing', () {
    final table = parseDelimited('a,b,c\n1\n1,2,3\n');

    expect(table.rows.first, <String>['1', '', '']);
    expect(table.rows.last, <String>['1', '2', '3']);
  });

  test('a row wider than the header widens every row', () {
    final table = parseDelimited('a,b\n1,2,3\n');

    expect(table.columns, <String>['a', 'b', 'column 3']);
    expect(table.rows.single, <String>['1', '2', '3']);
  });

  test('an unnamed header cell is named by its position', () {
    final table = parseDelimited('a,,c\n1,2,3\n');

    expect(table.columns, <String>['a', 'column 2', 'c']);
  });

  test('the delimiter is sniffed, and consistency beats frequency', () {
    // Nine commas on one line, one tab on every line: the tab is the separator.
    final table = parseDelimited(
      'a\tb\n'
      '"x,y,z,1,2,3,4,5,6"\t2\n'
      'p\tq\n',
    );

    expect(table.delimiter, '\t');
    expect(table.columns, <String>['a', 'b']);
    expect(table.rows.first, <String>['x,y,z,1,2,3,4,5,6', '2']);
  });

  test('a semicolon file — what a European Excel writes — is read', () {
    final table = parseDelimited('id;name\n1;Intro\n');

    expect(table.delimiter, ';');
    expect(table.rows.single, <String>['1', 'Intro']);
  });

  test('the row cap stops the read and says so', () {
    final text = <String>[
      'id',
      for (var i = 1; i <= 50; i++) '$i',
    ].join('\n');

    final table = parseDelimited(text, maxRows: 10);

    expect(table.rows, hasLength(10));
    expect(table.truncated, isTrue);
  });

  test('a trailing newline is not an empty last row', () {
    expect(parseDelimited('a\n1\n').rows, hasLength(1));
    expect(parseDelimited('a\n1').rows, hasLength(1));
  });

  test('empty text is an empty table, not an exception', () {
    expect(parseDelimited('').isEmpty, isTrue);
    expect(parseDelimited('\n').isEmpty, isTrue);
  });

  test('without a header the columns are positions', () {
    final table = parseDelimited('1,Intro\n2,Verse\n', hasHeader: false);

    expect(table.columns, <String>['column 1', 'column 2']);
    expect(table.rows, hasLength(2));
  });
}
