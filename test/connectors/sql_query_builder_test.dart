import 'package:dextr/connectors/sql_common/sql_query_builder.dart';
import 'package:dextr/core/cell_value.dart';
import 'package:dextr/core/query_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Default builder: SQLite/MySQL style — double-quote identifiers, `?` params.
  SqlQueryBuilder sqliteBuilder() =>
      SqlQueryBuilder(quote: (id) => '"$id"');

  // Postgres style — `$N` positional placeholders.
  SqlQueryBuilder pgBuilder() => SqlQueryBuilder(
        quote: (id) => '"$id"',
        paramPlaceholder: (i) => '\$$i',
      );

  group('buildSelect — projection and pagination', () {
    test('selects * with default limit/offset', () {
      final built = sqliteBuilder().buildSelect('"users"', const QuerySpec());
      expect(built.sql, 'SELECT * FROM "users" LIMIT 100 OFFSET 0');
      expect(built.params, isEmpty);
    });

    test('applies projection columns', () {
      final built = sqliteBuilder().buildSelect(
        '"users"',
        const QuerySpec(projection: ['id', 'name']),
      );
      expect(built.sql, startsWith('SELECT "id", "name" FROM "users"'));
    });

    test('honors custom limit and offset', () {
      final built = sqliteBuilder().buildSelect(
        '"users"',
        const QuerySpec(limit: 25, offset: 50),
      );
      expect(built.sql, endsWith('LIMIT 25 OFFSET 50'));
    });
  });

  group('buildSelect — WHERE clauses', () {
    test('eq emits parameter binding', () {
      final built = sqliteBuilder().buildSelect(
        '"users"',
        const QuerySpec(
          where: [FilterClause('age', FilterOp.eq, NumCell(30))],
        ),
      );
      expect(built.sql, contains('WHERE "age" = ?'));
      expect(built.params, [30]);
    });

    test('comparison operators map to SQL symbols', () {
      final cases = {
        FilterOp.ne: '<>',
        FilterOp.gt: '>',
        FilterOp.gte: '>=',
        FilterOp.lt: '<',
        FilterOp.lte: '<=',
        FilterOp.like: 'LIKE',
      };
      cases.forEach((op, symbol) {
        final built = sqliteBuilder().buildSelect(
          '"t"',
          QuerySpec(where: [FilterClause('c', op, const NumCell(1))]),
        );
        expect(built.sql, contains('"c" $symbol ?'), reason: 'op $op');
      });
    });

    test('contains wraps value in % wildcards', () {
      final built = sqliteBuilder().buildSelect(
        '"t"',
        const QuerySpec(
          where: [FilterClause('name', FilterOp.contains, StringCell('ali'))],
        ),
      );
      expect(built.sql, contains('"name" LIKE ?'));
      expect(built.params, ['%ali%']);
    });

    test('inList expands a List value to multiple placeholders', () {
      // toBindable() must yield a real List for the builder to expand it;
      // UnknownCell passes its raw value through unchanged.
      final built = sqliteBuilder().buildSelect(
        '"t"',
        const QuerySpec(
          where: [FilterClause('id', FilterOp.inList, UnknownCell([1, 2, 3]))],
        ),
      );
      expect(built.sql, contains('"id" IN (?, ?, ?)'));
      expect(built.params, [1, 2, 3]);
    });

    test('inList wraps a scalar value in a single placeholder', () {
      final built = sqliteBuilder().buildSelect(
        '"t"',
        const QuerySpec(
          where: [FilterClause('id', FilterOp.inList, NumCell(7))],
        ),
      );
      expect(built.sql, contains('"id" IN (?)'));
      expect(built.params, [7]);
    });

    test('isNull / notNull emit no parameters', () {
      final isNull = sqliteBuilder().buildSelect(
        '"t"',
        const QuerySpec(where: [FilterClause('c', FilterOp.isNull)]),
      );
      expect(isNull.sql, contains('"c" IS NULL'));
      expect(isNull.params, isEmpty);

      final notNull = sqliteBuilder().buildSelect(
        '"t"',
        const QuerySpec(where: [FilterClause('c', FilterOp.notNull)]),
      );
      expect(notNull.sql, contains('"c" IS NOT NULL'));
      expect(notNull.params, isEmpty);
    });

    test('multiple clauses joined with AND', () {
      final built = sqliteBuilder().buildSelect(
        '"t"',
        const QuerySpec(where: [
          FilterClause('a', FilterOp.eq, NumCell(1)),
          FilterClause('b', FilterOp.gt, NumCell(2)),
        ]),
      );
      expect(built.sql, contains('"a" = ? AND "b" > ?'));
      expect(built.params, [1, 2]);
    });
  });

  group('buildSelect — ORDER BY', () {
    test('renders asc/desc directions', () {
      final built = sqliteBuilder().buildSelect(
        '"t"',
        const QuerySpec(orderBy: [
          SortClause('a'),
          SortClause('b', SortDir.desc),
        ]),
      );
      expect(built.sql, contains('ORDER BY "a" ASC, "b" DESC'));
    });
  });

  group('buildSelect — dialect placeholders', () {
    test('postgres uses positional \$N placeholders', () {
      final built = pgBuilder().buildSelect(
        '"t"',
        const QuerySpec(where: [
          FilterClause('a', FilterOp.eq, NumCell(1)),
          FilterClause('b', FilterOp.eq, NumCell(2)),
        ]),
      );
      expect(built.sql, contains(r'"a" = $1 AND "b" = $2'));
      expect(built.params, [1, 2]);
    });
  });
}
