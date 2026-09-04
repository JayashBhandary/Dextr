enum Capability {
  rawQuery,
  write,
  schemaRead,
  schemaMutate,
  objectStorage,
  fileBrowse,
  endpointInvoke,
  transactions,
  vectorSearch,
}

enum DataSourceKind {
  sqlite,
  postgres,
  mysql,

  /// Amazon Redshift. Its own kind rather than a Postgres connection with a
  /// different port: it speaks the Postgres wire protocol, so the driver is
  /// shared (see `PgWireDataSource`), but it is a different database with
  /// different defaults and a smaller SQL surface — no `RETURNING`, and almost
  /// no `ALTER COLUMN`. A kind of its own is what lets the connector say so.
  redshift,

  /// Snowflake, over its SQL REST API rather than a socket. There is no
  /// Snowflake wire-protocol driver for Dart, and the REST API is the
  /// documented alternative; what it costs is transactions, which are a
  /// session and this has none.
  snowflake,

  /// Google BigQuery, over the REST API with a service-account key — the same
  /// way [firestore] is reached.
  bigquery,

  firestore,
  mongo,

  /// Redis. Keys rather than rows: a container is one of the server's numbered
  /// databases, and what the grid shows for each key is its type, its TTL and
  /// as much of its value as fits.
  redis,

  s3,
  rest,
  graphql,

  /// One entry for four engines — Qdrant, Chroma, Pinecone, Weaviate — because
  /// what distinguishes them is a field on the connection, not a different kind
  /// of thing to connect to. Which one a record means lives in its config under
  /// `provider`; see `VectorProvider`.
  vector;

  String get label => switch (this) {
        sqlite => 'SQLite',
        postgres => 'PostgreSQL',
        mysql => 'MySQL',
        redshift => 'Amazon Redshift',
        snowflake => 'Snowflake',
        bigquery => 'BigQuery',
        firestore => 'Firestore',
        mongo => 'MongoDB',
        redis => 'Redis',
        s3 => 'S3 / MinIO',
        rest => 'REST API',
        graphql => 'GraphQL API',
        vector => 'Vector DB',
      };
}
