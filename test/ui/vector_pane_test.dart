import 'dart:io';
import 'dart:math' as math;

import 'package:dextr/app.dart';
import 'package:dextr/connectors/data_source.dart';
import 'package:dextr/connectors/vector/vector_types.dart';
import 'package:dextr/core/capabilities.dart';
import 'package:dextr/core/cell_value.dart';
import 'package:dextr/core/page.dart' as core;
import 'package:dextr/core/query_spec.dart';
import 'package:dextr/domain/connection_record.dart';
import 'package:dextr/domain/connection_secrets.dart';
import 'package:dextr/router.dart';
import 'package:dextr/services/connections_repo.dart';
import 'package:dextr/services/secrets_store.dart';
import 'package:dextr/services/settings_repo.dart';
import 'package:dextr/state/active_source_provider.dart';
import 'package:dextr/state/providers.dart';
import 'package:dextr/ui/workspace/vector_pane.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mounts the vector pane against an in-memory space.
///
/// Reaching a real one would need a running engine and a credential, so the
/// source is faked at the [VectorSearchable] seam — which is the same seam the
/// pane itself is written against, so what is under test is the whole of it
/// except the wire format.
void main() {
  late Directory tmp;

  final record = ConnectionRecord(
    id: 'vec-1',
    name: 'embeddings',
    kind: DataSourceKind.vector,
    config: <String, Object?>{'provider': 'qdrant', 'mode': 'local'},
    secretsRef: 'none',
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_vector_test');
    await ConnectionsRepo(overridePath: tmp.path).upsert(record);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  ProviderScope appWith(DataSource source) => ProviderScope(
    overrides: [
      connectionsRepoProvider.overrideWithValue(
        ConnectionsRepo(overridePath: tmp.path),
      ),
      settingsRepoProvider.overrideWithValue(
        SettingsRepo(overridePath: tmp.path),
      ),
      secretsStoreProvider.overrideWithValue(_NoSecrets()),
      routerProvider.overrideWith((ref) => buildRouter()),
      activeDataSourceProvider.overrideWith((ref) async => source),
    ],
    child: const DextrApp(),
  );

  ProviderScope app() => appWith(_FakeSpace(record));

  /// Lets the isolate that runs the projection finish, and moves the test
  /// clock on as well.
  ///
  /// The clock matters as much as the isolate does here: the plot recognises a
  /// double tap, which makes a single tap wait out the double-tap timer before
  /// it is delivered. A bare `pump()` leaves that timer pending forever, so a
  /// tap on the plot would never arrive.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Opens the connection, then the collection. A vector collection opens
  /// straight onto its space rather than onto a grid, which is what the second
  /// tap is asserting by implication.
  ///
  /// The window is widened first: below the shell's breakpoint the rail is a
  /// drawer, and neither the connection nor the collection is on screen to tap.
  Future<void> openSpace(WidgetTester tester, {Widget? withApp}) async {
    final view = tester.view;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(withApp ?? app());
    await settle(tester);
    await tester.tap(find.text('embeddings').first);
    await settle(tester);
    await tester.tap(find.text('documents').first);
    await settle(tester);
  }

  Finder inPane(String text) => find.descendant(
    of: find.byType(VectorPane),
    matching: find.text(text),
  );

  testWidgets('a vector collection opens on its space', (tester) async {
    await openSpace(tester);

    expect(find.byType(VectorPane), findsOneWidget);
    // What the space is: how wide, how it measures closeness, how much of it
    // is on screen.
    expect(inPane('64-d'), findsOneWidget);
    expect(inPane('cosine'), findsOneWidget);
    expect(inPane('120 plotted'), findsOneWidget);
  });

  testWidgets('it opens in three dimensions, with a plane to fall back to', (
    tester,
  ) async {
    await openSpace(tester);

    // Both axes counts are offered; 3D is where it starts, because a volume
    // that opens face-on looks exactly like a plane.
    expect(inPane('3D'), findsOneWidget);
    expect(inPane('2D'), findsOneWidget);

    await tester.tap(inPane('2D'));
    await settle(tester);
    // Re-projecting keeps the space; it is the axes that changed.
    expect(inPane('120 plotted'), findsOneWidget);
  });

  testWidgets('the projection reports how much of the spread it kept', (
    tester,
  ) async {
    await openSpace(tester);

    // The fake's points lie on a circle inside a 64-dimensional space, so a
    // correct projection loses essentially none of the spread and says so.
    final banner = tester.widget<Text>(
      find.descendant(
        of: find.byType(VectorPane),
        matching: find.textContaining('of the spread kept'),
      ),
    );
    expect(banner.data, contains('100%'));
  });

  testWidgets('nothing is selected until something is', (tester) async {
    await openSpace(tester);
    expect(inPane('No point selected'), findsOneWidget);
  });

  testWidgets('the plot is reachable from the keyboard', (tester) async {
    await openSpace(tester);

    // A canvas cannot be tapped by a screen reader and cannot be tabbed into
    // by anyone; the arrow keys are what make every mark reachable.
    await tester.tap(find.byKey(const ValueKey('vector-plot')));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);

    expect(inPane('No point selected'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(VectorPane),
        matching: find.textContaining('doc-'),
      ),
      findsWidgets,
    );
  });

  testWidgets('text search finds one point and makes it the probe', (
    tester,
  ) async {
    await openSpace(tester);

    // Exactly one document mentions invoices, so there is no list to choose
    // from — the single hit becomes the probe on its own.
    await tester.enterText(find.byType(EditableText).first, 'invoices');
    await settle(tester);
    await tester.tap(inPane('Search text'));
    await settle(tester);

    expect(inPane('1 matched'), findsOneWidget);
    expect(inPane('probe'), findsWidgets);
    // And the point of the whole exercise: what is near it.
    expect(find.textContaining('closest to the probe'), findsOneWidget);
  });

  testWidgets('several matches are offered rather than guessed between', (
    tester,
  ) async {
    await openSpace(tester);

    await tester.enterText(find.byType(EditableText).first, 'general matters');
    await settle(tester);
    await tester.tap(inPane('Search text'));
    await settle(tester);

    // 119 of the 120 documents say this. The search asks for at most fifty, so
    // the panel says it is showing the first fifty rather than claiming that
    // fifty is how many there are.
    expect(
      find.textContaining('The first 50 matches in this collection'),
      findsOneWidget,
    );
    expect(find.textContaining('closest to the probe'), findsNothing);

    // Choosing one is what sets the probe going.
    await tester.tap(find.textContaining('doc-1').first);
    await settle(tester);
    expect(find.textContaining('closest to the probe'), findsOneWidget);
  });

  testWidgets('a search that matches nothing says so', (tester) async {
    await openSpace(tester);

    await tester.enterText(find.byType(EditableText).first, 'zzzz-not-here');
    await settle(tester);
    await tester.tap(inPane('Search text'));
    await settle(tester);

    expect(inPane('Nothing in this collection matched'), findsOneWidget);
  });

  testWidgets('an engine with no text search says what it actually looked at', (
    tester,
  ) async {
    // The distinction the panel has to keep: "nothing in this collection" and
    // "nothing in the points on screen" are different answers, and reporting
    // the second as the first sends someone away believing their document is
    // not there.
    await openSpace(
      tester,
      withApp: appWith(_FakeSpace(record, textSearchable: false)),
    );

    await tester.enterText(find.byType(EditableText).first, 'zzzz-not-here');
    await settle(tester);
    await tester.tap(inPane('Search text'));
    await settle(tester);

    expect(
      find.textContaining('Nothing in the 120 plotted points matched'),
      findsOneWidget,
    );
    expect(
      find.textContaining('This engine has no text search of its own'),
      findsOneWidget,
    );
  });

  testWidgets('a selected point can be made the probe', (tester) async {
    await openSpace(tester);

    await tester.tap(find.byKey(const ValueKey('vector-plot')));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);

    await tester.tap(inPane('Make this the probe'));
    await settle(tester);

    expect(find.textContaining('closest to the probe'), findsOneWidget);
  });

  testWidgets('a query vector of the wrong width is refused, not sent', (
    tester,
  ) async {
    await openSpace(tester);

    // The raw-vector box is folded away, because searching by text is the
    // usual way in and pasting 384 floats is not.
    await tester.tap(inPane('Search by raw vector'));
    await settle(tester);

    await tester.enterText(find.byType(EditableText).last, '[0.1, 0.2]');
    await settle(tester);
    await tester.tap(inPane('Search'));
    await settle(tester);

    expect(
      find.textContaining('This space is 64-dimensional'),
      findsOneWidget,
    );
    expect(find.textContaining('closest to the probe'), findsNothing);
  });

  testWidgets('text in the raw-vector box is rejected as text, not embedded', (
    tester,
  ) async {
    await openSpace(tester);

    await tester.tap(inPane('Search by raw vector'));
    await settle(tester);
    await tester.enterText(find.byType(EditableText).last, 'a red bicycle');
    await settle(tester);
    await tester.tap(inPane('Search'));
    await settle(tester);

    expect(find.textContaining('That is not a vector'), findsOneWidget);
  });

  testWidgets('an empty collection says so rather than drawing nothing', (
    tester,
  ) async {
    await openSpace(
      tester,
      withApp: appWith(_FakeSpace(record, count: 0)),
    );

    // The collection exists — the rail listed it — so this is emptiness, not a
    // failure to reach the engine.
    expect(find.text('Nothing in this collection'), findsOneWidget);
  });
}

/// A vector space of [count] points lying on a plane inside a 64-dimensional
/// space, so the projection has something definite to find.
class _FakeSpace extends DataSource with VectorSearchable {
  _FakeSpace(this.record, {this.count = 120, this.textSearchable = true});

  final ConnectionRecord record;
  final int count;

  /// Whether this engine can search its own text, or leaves the pane to
  /// filter what it has already read.
  final bool textSearchable;

  static const _dimension = 64;

  late final List<VectorPoint> _points = <VectorPoint>[
    for (var i = 0; i < count; i++)
      VectorPoint(
        id: 'doc-$i',
        vector: <double>[
          for (var j = 0; j < _dimension; j++)
            switch (j) {
              0 => math.cos(i * 0.05) * 10,
              1 => math.sin(i * 0.05) * 10,
              _ => 0.0,
            },
        ],
        payload: <String, Object?>{
          'source': i.isEven ? 'wiki' : 'blog',
          'chroma:document': 'document number $i about '
              '${i == 7 ? 'quarterly invoices' : 'general matters'}',
        },
      ),
  ];

  @override
  String get id => record.id;

  @override
  String get displayName => record.name;

  @override
  DataSourceKind get kind => DataSourceKind.vector;

  @override
  Set<Capability> get capabilities => const <Capability>{
    Capability.vectorSearch,
  };

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> ping() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<List<ContainerRef>> listContainers() async => const <ContainerRef>[
    ContainerRef(name: 'documents', subtype: 'collection'),
  ];

  @override
  Future<core.Page<RowData>> listRows(
    ContainerRef container,
    QuerySpec spec,
  ) async => const core.Page<RowData>(items: <RowData>[]);

  @override
  Future<RowData?> getRow(ContainerRef container, RowId id) async => null;

  @override
  Future<VectorSpaceInfo> describeVectors(ContainerRef container) async =>
      VectorSpaceInfo(
        name: container.name,
        dimension: _dimension,
        count: count,
        metric: VectorMetric.cosine,
      );

  @override
  Future<List<VectorPoint>> sampleVectors(
    ContainerRef container, {
    int limit = 1000,
  }) async => _points.take(limit).toList();

  /// A literal search over the fake's own payloads, standing in for an engine
  /// that can search its whole collection.
  @override
  Future<List<VectorPoint>?> searchVectorText(
    ContainerRef container,
    String query, {
    int limit = 50,
  }) async {
    if (!textSearchable) return null;
    final needle = query.toLowerCase();
    return <VectorPoint>[
      for (final p in _points)
        if (p.id.toLowerCase().contains(needle) ||
            p.payload.values.any(
              (v) => '$v'.toLowerCase().contains(needle),
            ))
          p,
    ].take(limit).toList();
  }

  /// Nearest by squared distance, which is enough for the pane to have
  /// something ordered to show.
  @override
  Future<List<VectorPoint>> nearestVectors(
    ContainerRef container,
    List<double> query, {
    int topK = 20,
  }) async {
    final scored = <VectorPoint>[
      for (final p in _points)
        VectorPoint(
          id: p.id,
          vector: p.vector,
          payload: p.payload,
          score: _distance(query, p.vector),
        ),
    ]..sort((a, b) => a.score!.compareTo(b.score!));
    return scored.take(topK).toList();
  }

  double _distance(List<double> a, List<double> b) {
    var sum = 0.0;
    for (var i = 0; i < math.min(a.length, b.length); i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }
    return math.sqrt(sum);
  }
}

/// A secrets store that answers without a keychain.
class _NoSecrets extends SecretsStore {
  @override
  Future<void> write(String secretsRef, ConnectionSecrets secrets) async {}

  @override
  Future<ConnectionSecrets?> read(String secretsRef) async => null;

  @override
  Future<void> delete(String secretsRef) async {}
}
