/// The vocabulary every vector backend is described in.
///
/// Four engines sit behind one [DataSourceKind.vector]: they disagree about
/// almost everything at the wire level — Qdrant calls them points, Chroma calls
/// them embeddings, Pinecone calls them vectors, Weaviate calls them objects —
/// but they agree on the shape of the thing. An id, an array of floats, some
/// arbitrary payload beside it, and a distance when the array came back from a
/// search. That agreement is what this file writes down, and it is why the pane
/// that draws a vector space needs to know nothing about which engine it is
/// looking at.
library;

/// Which engine a vector connection talks to.
enum VectorProvider {
  qdrant,
  chroma,
  pinecone,
  weaviate;

  String get label => switch (this) {
    qdrant => 'Qdrant',
    chroma => 'Chroma',
    pinecone => 'Pinecone',
    weaviate => 'Weaviate',
  };

  /// What the reader is choosing between, one line each.
  String get blurb => switch (this) {
    qdrant => 'Points and payloads over the REST API.',
    chroma => 'Embeddings, documents and metadata.',
    pinecone => 'Serverless indexes, one host per index.',
    weaviate => 'Classes and objects, with vectors attached.',
  };

  /// The modes this engine can actually be reached in.
  ///
  /// Not every engine has all three, and offering one it does not have is a
  /// mode that fails every time it is used. Pinecone is hosted and has no local
  /// server at all; only Chroma writes an on-disk store this app can read
  /// without the engine itself (see `ChromaFileBackend`).
  Set<VectorMode> get modes => switch (this) {
    qdrant => const {VectorMode.local, VectorMode.cloud},
    chroma => const {VectorMode.local, VectorMode.cloud, VectorMode.file},
    pinecone => const {VectorMode.cloud},
    weaviate => const {VectorMode.local, VectorMode.cloud},
  };

  /// Where a local instance listens out of the box.
  String get defaultLocalUrl => switch (this) {
    qdrant => 'http://localhost:6333',
    chroma => 'http://localhost:8000',
    // Never local, but a form needs something in the box before the reader
    // types over it.
    pinecone => 'https://api.pinecone.io',
    weaviate => 'http://localhost:8080',
  };

  /// What the engine's own docs call the credential, so the form's label
  /// matches the page the reader copied it from.
  String get credentialLabel => switch (this) {
    qdrant => 'API key',
    chroma => 'Auth token',
    pinecone => 'API key',
    weaviate => 'API key',
  };

  /// Whether the cloud form must have a credential to be saveable. Chroma and
  /// Weaviate are routinely run open on a private network; Pinecone cannot be
  /// reached at all without a key.
  bool get requiresCredential => switch (this) {
    qdrant => false,
    chroma => false,
    pinecone => true,
    weaviate => false,
  };

  static VectorProvider fromName(Object? raw) {
    for (final p in VectorProvider.values) {
      if (p.name == raw) return p;
    }
    return VectorProvider.qdrant;
  }
}

/// How the engine is reached.
enum VectorMode {
  /// A server on this machine or this network, usually without credentials.
  local,

  /// A hosted endpoint, reached over TLS with a credential.
  cloud,

  /// An on-disk store, read directly with no server running.
  file;

  String get label => switch (this) {
    local => 'Local',
    cloud => 'Cloud',
    file => 'File',
  };

  String get blurb => switch (this) {
    local => 'A server you are running — Docker, or a binary on this machine.',
    cloud => 'A hosted endpoint, reached with a credential.',
    file => 'A persisted directory on disk, opened with no server running.',
  };

  static VectorMode fromName(Object? raw) {
    for (final m in VectorMode.values) {
      if (m.name == raw) return m;
    }
    return VectorMode.local;
  }
}

/// How closeness is measured in a space. Kept as an enum rather than the
/// engine's own string because the pane reports it and the file backend has to
/// compute in it.
enum VectorMetric {
  cosine,
  euclidean,
  dot,
  manhattan,
  unknown;

  String get label => switch (this) {
    cosine => 'cosine',
    euclidean => 'euclidean',
    dot => 'dot product',
    manhattan => 'manhattan',
    unknown => 'unknown',
  };

  /// Whether a bigger number means a closer point. Qdrant and Pinecone return
  /// a *similarity* for cosine and dot; Chroma and Weaviate return a distance.
  /// The pane sorts on this, so getting it wrong puts the worst match first.
  bool get higherIsCloser => this == cosine || this == dot;

  /// Reads whatever the engine calls it. Engines spell these differently —
  /// Qdrant `Cosine`, Chroma `l2`/`ip`, Pinecone `dotproduct`, Weaviate `l2-squared`.
  static VectorMetric parse(Object? raw) {
    final s = raw?.toString().trim().toLowerCase() ?? '';
    if (s.contains('cosine') || s == 'cos') return VectorMetric.cosine;
    if (s.contains('manhattan') || s == 'l1') return VectorMetric.manhattan;
    if (s.contains('dot') || s == 'ip') return VectorMetric.dot;
    if (s.contains('euclid') || s == 'l2' || s.startsWith('l2')) {
      return VectorMetric.euclidean;
    }
    return VectorMetric.unknown;
  }
}

/// One vector, and whatever the engine keeps beside it.
class VectorPoint {
  const VectorPoint({
    required this.id,
    required this.vector,
    this.payload = const {},
    this.score,
  });

  /// The engine's own id, as a string. Qdrant ids may be integers and Weaviate
  /// ids are UUIDs; both read fine as text, and the pane only ever displays
  /// them or hands them back.
  final String id;

  final List<double> vector;

  /// Metadata, payload, properties — the same idea under four names.
  final Map<String, Object?> payload;

  /// Distance or similarity, set only on results from [VectorBackend.nearest].
  /// Read together with the space's [VectorMetric] to know which way is closer.
  final double? score;
}

/// What is known about one collection as a space: how wide it is, how many
/// things are in it, and how closeness is measured.
class VectorSpaceInfo {
  const VectorSpaceInfo({
    required this.name,
    this.dimension,
    this.count,
    this.metric = VectorMetric.unknown,
  });

  final String name;

  /// Null when the engine will not say without a point to measure — some
  /// report it only once the collection has something in it.
  final int? dimension;
  final int? count;
  final VectorMetric metric;
}

/// Where Chroma's embedded text lands in a [VectorPoint.payload].
///
/// Chroma is the one engine that keeps the *document* an embedding was made
/// from, and it is the first thing anyone wants on clicking a point. Both
/// Chroma readers — the server one and the on-disk one — put it under this key,
/// which is namespaced so it cannot collide with user metadata.
const String chromaDocumentKey = 'chroma:document';

/// One page of a walk through a collection.
class VectorPage {
  const VectorPage({required this.points, this.cursor});

  final List<VectorPoint> points;

  /// Opaque continuation token; null when there is no more to fetch. Every
  /// engine paginates differently — a point id, an integer offset, a token —
  /// and every one of them fits in a string.
  final String? cursor;
}
