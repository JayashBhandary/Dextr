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
  firestore,
  mongo,
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
        firestore => 'Firestore',
        mongo => 'MongoDB',
        s3 => 'S3 / MinIO',
        rest => 'REST API',
        graphql => 'GraphQL API',
        vector => 'Vector DB',
      };
}
