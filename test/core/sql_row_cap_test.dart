import 'package:dextr/core/capabilities.dart';
import 'package:dextr/core/sql/sql_row_cap.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the row ceiling does to a statement before it is sent.
void main() {
  test('a bare SELECT is capped, one row past the ceiling', () {
    expect(
      sqlWithRowCap('SELECT * FROM orders WHERE coupon_code IS NOT NULL'),
      'SELECT * FROM orders WHERE coupon_code IS NOT NULL\n'
      'LIMIT ${maxQueryRows + 1}',
    );
  });

  test('a trailing semicolon is replaced rather than kept', () {
    // `... orders; LIMIT 10001` is a syntax error, and the semicolon is the
    // shape every editor's query ends in.
    expect(
      sqlWithRowCap('SELECT * FROM orders;', cap: 5),
      'SELECT * FROM orders\nLIMIT 6',
    );
  });

  test('a CTE is a read and is capped', () {
    expect(
      sqlWithRowCap('WITH paid AS (SELECT 1) SELECT * FROM paid', cap: 5),
      'WITH paid AS (SELECT 1) SELECT * FROM paid\nLIMIT 6',
    );
  });

  test("the user's own LIMIT or OFFSET is left alone", () {
    expect(sqlWithRowCap('SELECT * FROM orders LIMIT 20'), isNull);
    expect(sqlWithRowCap('SELECT * FROM orders OFFSET 40'), isNull);
    expect(
      sqlWithRowCap('SELECT * FROM orders FETCH FIRST 10 ROWS ONLY'),
      isNull,
    );
  });

  test('a LIMIT inside a subquery is not the outer statement\'s own', () {
    expect(
      sqlWithRowCap(
        'SELECT * FROM (SELECT id FROM orders LIMIT 3) AS recent',
        cap: 5,
      ),
      'SELECT * FROM (SELECT id FROM orders LIMIT 3) AS recent\nLIMIT 6',
    );
  });

  test('the word limit in a comment or a string is not a clause', () {
    expect(
      sqlWithRowCap('-- limit this to coupons\nSELECT * FROM orders', cap: 5),
      '-- limit this to coupons\nSELECT * FROM orders\nLIMIT 6',
    );
    expect(
      sqlWithRowCap("SELECT * FROM orders WHERE code = 'limit'", cap: 5),
      "SELECT * FROM orders WHERE code = 'limit'\nLIMIT 6",
    );
  });

  test('anything that is not one read-only statement is left alone', () {
    expect(sqlWithRowCap('INSERT INTO orders (id) VALUES (1)'), isNull);
    expect(sqlWithRowCap('UPDATE orders SET total = 0'), isNull);
    expect(sqlWithRowCap('CREATE TABLE t (id INT)'), isNull);
    expect(sqlWithRowCap('SELECT 1; SELECT 2'), isNull);
    expect(sqlWithRowCap('   '), isNull);
  });

  test('only the SQL dialects take a LIMIT clause', () {
    for (final kind in <DataSourceKind>[
      DataSourceKind.sqlite,
      DataSourceKind.postgres,
      DataSourceKind.redshift,
      DataSourceKind.mysql,
      DataSourceKind.snowflake,
      DataSourceKind.bigquery,
    ]) {
      expect(dialectTakesLimitClause(kind), isTrue, reason: '$kind');
    }
    // A Redis command, a Mongo pipeline and a REST path each ask for fewer
    // results their own way; appending words to them makes nonsense.
    for (final kind in <DataSourceKind>[
      DataSourceKind.redis,
      DataSourceKind.mongo,
      DataSourceKind.rest,
      DataSourceKind.graphql,
      DataSourceKind.firestore,
    ]) {
      expect(dialectTakesLimitClause(kind), isFalse, reason: '$kind');
    }
  });
}
