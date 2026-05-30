import 'package:dextr/connectors/mongo/mongo_query_translator.dart';
import 'package:dextr/core/cell_value.dart';
import 'package:dextr/core/query_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('querySpecToFilter', () {
    test('empty spec yields empty filter', () {
      expect(querySpecToFilter(const QuerySpec()), isEmpty);
    });

    test('single eq clause is unwrapped (no \$and)', () {
      final filter = querySpecToFilter(const QuerySpec(
        where: [FilterClause('age', FilterOp.eq, NumCell(30))],
      ));
      expect(filter, {'age': 30});
    });

    test('comparison operators map to mongo operators', () {
      expect(
        querySpecToFilter(const QuerySpec(
          where: [FilterClause('a', FilterOp.ne, NumCell(1))],
        )),
        {
          'a': {r'$ne': 1}
        },
      );
      expect(
        querySpecToFilter(const QuerySpec(
          where: [FilterClause('a', FilterOp.gte, NumCell(5))],
        )),
        {
          'a': {r'$gte': 5}
        },
      );
    });

    test('like/contains become case-insensitive regex', () {
      final filter = querySpecToFilter(const QuerySpec(
        where: [FilterClause('name', FilterOp.contains, StringCell('ali'))],
      ));
      expect(filter, {
        'name': {r'$regex': 'ali', r'$options': 'i'}
      });
    });

    test('inList maps to \$in', () {
      final filter = querySpecToFilter(const QuerySpec(
        where: [FilterClause('id', FilterOp.inList, UnknownCell([1, 2]))],
      ));
      expect(filter, {
        'id': {r'$in': [1, 2]}
      });
    });

    test('isNull and notNull', () {
      expect(
        querySpecToFilter(const QuerySpec(
          where: [FilterClause('c', FilterOp.isNull)],
        )),
        {'c': null},
      );
      expect(
        querySpecToFilter(const QuerySpec(
          where: [FilterClause('c', FilterOp.notNull)],
        )),
        {
          'c': {r'$ne': null}
        },
      );
    });

    test('multiple clauses combine under \$and', () {
      final filter = querySpecToFilter(const QuerySpec(where: [
        FilterClause('a', FilterOp.eq, NumCell(1)),
        FilterClause('b', FilterOp.gt, NumCell(2)),
      ]));
      expect(filter, {
        r'$and': [
          {'a': 1},
          {
            'b': {r'$gt': 2}
          },
        ]
      });
    });
  });

  group('querySpecToSort', () {
    test('empty orderBy yields empty sort', () {
      expect(querySpecToSort(const QuerySpec()), isEmpty);
    });

    test('asc -> 1, desc -> -1', () {
      final sort = querySpecToSort(const QuerySpec(orderBy: [
        SortClause('a'),
        SortClause('b', SortDir.desc),
      ]));
      expect(sort, {'a': 1, 'b': -1});
    });
  });
}
