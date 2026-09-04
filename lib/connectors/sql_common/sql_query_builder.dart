import '../../core/query_spec.dart';

/// Quote an identifier the way the SQL standard does: double quotes, with an
/// embedded quote doubled.
///
/// Every dialect here writes an identifier this way — Postgres, Redshift,
/// Snowflake, BigQuery's standard SQL when it is not using backticks — so it
/// lives once rather than four times. A dialect that needs something else
/// passes its own [SqlQueryBuilder.quote].
String ansiQuoteIdent(String identifier) =>
    '"${identifier.replaceAll('"', '""')}"';

class BuiltSql {
  const BuiltSql(this.sql, this.params);
  final String sql;
  final List<Object?> params;
}

/// Translate a [QuerySpec] into a SELECT against [tableExpr].
/// Identifiers are quoted via [quote] for the target dialect.
class SqlQueryBuilder {
  SqlQueryBuilder({required this.quote, this.paramPlaceholder = _qmark});

  final String Function(String identifier) quote;
  final String Function(int index) paramPlaceholder;

  static String _qmark(int _) => '?';

  BuiltSql buildSelect(String tableExpr, QuerySpec spec) {
    final cols = spec.projection == null || spec.projection!.isEmpty
        ? '*'
        : spec.projection!.map(quote).join(', ');
    final buf = StringBuffer('SELECT $cols FROM $tableExpr');
    final params = <Object?>[];

    if (spec.where.isNotEmpty) {
      final parts = <String>[];
      for (final c in spec.where) {
        final ph = paramPlaceholder(params.length + 1);
        switch (c.op) {
          case FilterOp.eq:
            parts.add('${quote(c.field)} = $ph');
            params.add(c.value?.toBindable());
          case FilterOp.ne:
            parts.add('${quote(c.field)} <> $ph');
            params.add(c.value?.toBindable());
          case FilterOp.gt:
            parts.add('${quote(c.field)} > $ph');
            params.add(c.value?.toBindable());
          case FilterOp.gte:
            parts.add('${quote(c.field)} >= $ph');
            params.add(c.value?.toBindable());
          case FilterOp.lt:
            parts.add('${quote(c.field)} < $ph');
            params.add(c.value?.toBindable());
          case FilterOp.lte:
            parts.add('${quote(c.field)} <= $ph');
            params.add(c.value?.toBindable());
          case FilterOp.like:
            parts.add('${quote(c.field)} LIKE $ph');
            params.add(c.value?.toBindable());
          case FilterOp.contains:
            parts.add('${quote(c.field)} LIKE $ph');
            params.add('%${c.value?.toBindable() ?? ''}%');
          case FilterOp.inList:
            final raw = c.value?.toBindable();
            final list = raw is List ? raw : [raw];
            final placeholders = <String>[];
            for (final v in list) {
              final p = paramPlaceholder(params.length + 1);
              placeholders.add(p);
              params.add(v);
            }
            parts.add('${quote(c.field)} IN (${placeholders.join(', ')})');
          case FilterOp.isNull:
            parts.add('${quote(c.field)} IS NULL');
          case FilterOp.notNull:
            parts.add('${quote(c.field)} IS NOT NULL');
        }
      }
      buf.write(' WHERE ${parts.join(' AND ')}');
    }

    if (spec.orderBy.isNotEmpty) {
      final parts = spec.orderBy
          .map((s) => '${quote(s.field)} ${s.dir == SortDir.asc ? 'ASC' : 'DESC'}')
          .join(', ');
      buf.write(' ORDER BY $parts');
    }

    buf.write(' LIMIT ${spec.limit} OFFSET ${spec.offset}');
    return BuiltSql(buf.toString(), params);
  }
}
