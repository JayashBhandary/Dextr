/// Quoting and placeholders for the Postgres wire protocol.
///
/// Shared by every backend that speaks it — PostgreSQL itself and Amazon
/// Redshift, which is a fork of it old enough to have diverged in its SQL but
/// not in how an identifier is written down.
library;

import 'sql_query_builder.dart';

/// Standard double-quoting, which is what Postgres does.
String pgQuoteIdent(String identifier) => ansiQuoteIdent(identifier);

/// Postgres parameter placeholder: $1, $2, ...
String pgPlaceholder(int index) => '\$$index';

/// Quote a possibly-schema-qualified name like 'public.users'.
String pgQuoteQualified(String? schema, String name) {
  if (schema == null || schema.isEmpty) return pgQuoteIdent(name);
  return '${pgQuoteIdent(schema)}.${pgQuoteIdent(name)}';
}
