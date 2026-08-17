import 'dart:async';

import '../core/capabilities.dart';
import '../core/cell_value.dart';
import '../core/page.dart';
import '../core/query_spec.dart';
import 'vector/vector_types.dart';

/// A pointer to a container (table / collection / bucket / saved-op).
class ContainerRef {
  const ContainerRef({
    required this.name,
    this.path,
    this.namespace,
    this.subtype,
  });
  final String name;
  final String? path;
  final String? namespace;
  final String? subtype; // 'table', 'view', 'collection', 'bucket', etc.

  String get qualified =>
      [if (namespace != null) namespace, name].whereType<String>().join('.');
}

/// A row id as the backend understands it.
class RowId {
  const RowId(this.fields);
  final Map<String, CellValue> fields;
}

class ColumnSchema {
  const ColumnSchema({
    required this.name,
    required this.typeLabel,
    this.nullable = true,
    this.isPrimaryKey = false,
    this.defaultExpr,
    this.frequency,
  });
  final String name;
  final String typeLabel;
  final bool nullable;
  final bool isPrimaryKey;
  final String? defaultExpr;
  final double? frequency; // for inferred schemas
}

class ContainerSchema {
  const ContainerSchema({required this.container, required this.columns});
  final ContainerRef container;
  final List<ColumnSchema> columns;

  List<String> get pkColumns =>
      columns.where((c) => c.isPrimaryKey).map((c) => c.name).toList();
}

class QueryResult {
  const QueryResult({
    required this.columns,
    required this.rows,
    this.affectedRows,
    this.elapsed,
  });
  final List<String> columns;
  final List<RowData> rows;
  final int? affectedRows;
  final Duration? elapsed;
}

/// Core abstract.
abstract class DataSource {
  String get id;
  String get displayName;
  DataSourceKind get kind;
  Set<Capability> get capabilities;

  Future<void> connect();
  Future<void> disconnect();
  Future<void> ping();
  Future<void> dispose();

  /// Config that [connect] found to be out of date and that the saved record
  /// should adopt — a sandbox bookmark reissued for a file that moved, say.
  /// Empty for sources with nothing to correct, which is most of them.
  Map<String, Object?> get correctedConfig => const {};

  Future<List<ContainerRef>> listContainers();
  Future<Page<RowData>> listRows(ContainerRef container, QuerySpec spec);
  Future<RowData?> getRow(ContainerRef container, RowId id);
}

/// Capability mixins. UI uses `is X` checks.
mixin RawQueryable on DataSource {
  Future<QueryResult> runRawQuery(String text, [List<Object?> params = const []]);
}

mixin Writable on DataSource {
  Future<RowId> insertRow(ContainerRef container, Map<String, CellValue> values);
  Future<int> updateRow(
      ContainerRef container, RowId id, Map<String, CellValue> values);
  Future<int> deleteRow(ContainerRef container, RowId id);
}

mixin SchemaReadable on DataSource {
  Future<ContainerSchema> getSchema(ContainerRef container);
}

mixin SchemaMutable on DataSource, SchemaReadable {
  Future<void> createContainer(ContainerSchema schema);
  Future<void> dropContainer(ContainerRef container);
  Future<void> alterColumn(
      ContainerRef container, String columnName, ColumnSchema newDef);
}

mixin Transactional on DataSource {
  Future<void> beginTx();
  Future<void> commit();
  Future<void> rollback();
}

/// A source whose containers are spaces of vectors rather than rows.
///
/// Three questions, which is all a vector space is asked: how wide is it and
/// how much is in it, give me a representative handful of it, and what is near
/// this. Everything the vector pane draws comes from these.
///
/// Kept here beside the other capability mixins so the UI gates on it the same
/// way it gates on everything else — `source is VectorSearchable` — rather than
/// on the connection's kind. A future engine that is not a vector database but
/// can still answer these gets the pane for free.
mixin VectorSearchable on DataSource {
  /// Width, size and distance function of one collection.
  Future<VectorSpaceInfo> describeVectors(ContainerRef container);

  /// Up to [limit] points, in whatever order the engine walks them.
  ///
  /// Not a random sample: no engine offers one cheaply, and the first N points
  /// of a collection are representative enough to project. Implementations cap
  /// [limit] at their own ceiling rather than trusting the caller.
  Future<List<VectorPoint>> sampleVectors(
    ContainerRef container, {
    int limit = 1000,
  });

  /// The [topK] points nearest [query], scored by the space's own metric.
  Future<List<VectorPoint>> nearestVectors(
    ContainerRef container,
    List<double> query, {
    int topK = 20,
  });

  /// Points whose text matches [query], across the whole collection.
  ///
  /// Null when the engine has no text search of its own — see
  /// [TextMatches.searchedWholeCollection] for why the caller has to know the
  /// difference between that and finding nothing.
  Future<List<VectorPoint>?> searchVectorText(
    ContainerRef container,
    String query, {
    int limit = 50,
  });
}

/// The result of looking for a point by its text, and how far the look went.
class TextMatches {
  const TextMatches({
    required this.points,
    required this.searchedWholeCollection,
  });

  final List<VectorPoint> points;

  /// Whether the engine searched everything, or only the sample already read.
  ///
  /// The distinction matters more than it looks: "no matches in the 1,000
  /// points on screen" and "no matches in this collection" are different
  /// answers, and showing the first as though it were the second sends someone
  /// away believing their document is not there.
  final bool searchedWholeCollection;

  bool get isEmpty => points.isEmpty;
}

mixin EndpointInvocable on DataSource {
  /// Run a saved operation by name with override params, return its raw payload.
  Future<QueryResult> invoke(ContainerRef container,
      {Map<String, Object?>? variables});
}

mixin ObjectStorage on DataSource {
  /// Upload a local file to the given container under [key].
  Future<void> putObjectFromFile(
      ContainerRef container, String key, String localFilePath);

  /// Download an object to [localFilePath].
  Future<void> getObjectToFile(
      ContainerRef container, String key, String localFilePath);

  /// Presigned GET URL valid for [expires].
  Future<String> presignGet(ContainerRef container, String key,
      {Duration expires = const Duration(hours: 1)});

  /// Presigned PUT URL valid for [expires].
  Future<String> presignPut(ContainerRef container, String key,
      {Duration expires = const Duration(hours: 1)});
}

/// Operations a [FileBrowsable] source may support. The UI uses
/// [FileBrowsable.fileOps] to show/hide actions, so providers can advertise
/// only what they implement (e.g. Drive/Dropbox may omit [share]).
enum FileOp { upload, download, delete, makeFolder, rename, move, copy, share, preview }

/// A single node in a hierarchical object/file store: a folder or a file.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isFolder,
    this.size,
    this.modified,
    this.etag,
    this.contentType,
  });

  /// Last path segment, for display.
  final String name;

  /// Full path/key from the container root. Folders end with '/'.
  final String path;
  final bool isFolder;
  final int? size;
  final DateTime? modified;
  final String? etag;
  final String? contentType;
}

/// One level of a folder listing. Folders first, then files.
class FileListing {
  const FileListing({required this.entries, this.cursor});
  final List<FileEntry> entries;

  /// Opaque continuation token; null when there is no more to fetch.
  final String? cursor;
}

/// Result of a capped preview read.
class FileBytes {
  const FileBytes({required this.bytes, required this.truncated});
  final List<int> bytes;

  /// True if the object was larger than the requested cap.
  final bool truncated;
}

/// Provider-agnostic hierarchical file browser contract. Implemented by S3 /
/// MinIO today; Google Drive / Dropbox connectors can implement the same
/// contract and reuse the entire browser UI.
mixin FileBrowsable on DataSource {
  /// Which [FileOp]s this source actually supports.
  Set<FileOp> get fileOps;

  /// List one level under [path] ('' = container root). Implementations use
  /// delimiter semantics so [FileEntry.isFolder] reflects sub-prefixes.
  Future<FileListing> listEntries(ContainerRef container, String path,
      {String? cursor});

  /// Metadata for a single file at [path], or null if absent.
  Future<FileEntry?> statEntry(ContainerRef container, String path);

  /// Read up to [maxBytes] of an object, for inline preview.
  Future<FileBytes> readBytes(ContainerRef container, String path,
      {int maxBytes = 5 << 20});

  Future<void> uploadFile(
      ContainerRef container, String path, String localFilePath);
  Future<void> downloadFile(
      ContainerRef container, String path, String localFilePath);

  /// Delete the given paths. A folder path (trailing '/') removes everything
  /// beneath it.
  Future<void> deleteEntries(ContainerRef container, List<String> paths);

  /// Create an empty folder at [path] (without trailing '/').
  Future<void> createFolder(ContainerRef container, String path);

  Future<void> copyEntry(ContainerRef container, String from, String to);
  Future<void> moveEntry(ContainerRef container, String from, String to);

  /// A shareable URL for [path], or null if unsupported.
  Future<String?> shareLink(ContainerRef container, String path,
      {Duration expires = const Duration(hours: 1)});
}
