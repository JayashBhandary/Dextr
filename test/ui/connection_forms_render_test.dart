import 'dart:io';

import 'package:dextr/app.dart';
import 'package:dextr/core/capabilities.dart';
import 'package:dextr/domain/connection_secrets.dart';
import 'package:dextr/router.dart';
import 'package:dextr/services/connections_repo.dart';
import 'package:dextr/services/secrets_store.dart';
import 'package:dextr/services/settings_repo.dart';
import 'package:dextr/state/providers.dart';
import 'package:dextr/ui/connection_form/forms/bigquery_form.dart';
import 'package:dextr/ui/connection_form/forms/firestore_form.dart';
import 'package:dextr/ui/connection_form/forms/graphql_form.dart';
import 'package:dextr/ui/connection_form/forms/mongo_form.dart';
import 'package:dextr/ui/connection_form/forms/mysql_form.dart';
import 'package:dextr/ui/connection_form/forms/postgres_form.dart';
import 'package:dextr/ui/connection_form/forms/redis_form.dart';
import 'package:dextr/ui/connection_form/forms/redshift_form.dart';
import 'package:dextr/ui/connection_form/forms/rest_form.dart';
import 'package:dextr/ui/connection_form/forms/s3_form.dart';
import 'package:dextr/ui/connection_form/forms/snowflake_form.dart';
import 'package:dextr/ui/connection_form/forms/sqlite_form.dart';
import 'package:dextr/ui/connection_form/forms/vector_form.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mounts the new-connection form for every backend.
///
/// A layout test, like `screens_render_test`: a form fails here by throwing
/// during layout — an unbounded height, a row that overflows its box — and
/// those failures do not show up in an analyzer run and do not show up until
/// the form is on screen. Picking each kind in turn also exercises the switch
/// in `ConnectionFormPage`, so a kind added to the enum without a form is a
/// failure here rather than a blank card in the picker.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_form_test');
  });

  tearDown(() async => tmp.delete(recursive: true));

  void sizeWindow(WidgetTester tester) {
    final view = tester.view;
    // Tall, so a form with several banners fits without the picker scrolling
    // out of reach.
    view.physicalSize = const Size(1280, 2400);
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  }

  ProviderScope app() => ProviderScope(
    overrides: [
      connectionsRepoProvider.overrideWithValue(
        ConnectionsRepo(overridePath: tmp.path),
      ),
      settingsRepoProvider.overrideWithValue(
        SettingsRepo(overridePath: tmp.path),
      ),
      secretsStoreProvider.overrideWithValue(_NoSecrets()),
      routerProvider.overrideWith(
        (ref) => buildRouter(initialLocation: '/connection/new'),
      ),
    ],
    child: const DextrApp(),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  /// The form each kind is supposed to produce.
  ///
  /// Asserted by type rather than by a label on screen: a label can be shared
  /// by two backends — Postgres and MySQL both have an "SSL mode" — and can be
  /// carried in semantics rather than in visible text, so matching on one
  /// proves less than it looks. The widget type is exactly the thing the
  /// switch in `ConnectionFormPage` chooses.
  const forms = <DataSourceKind, Type>{
    DataSourceKind.sqlite: SqliteForm,
    DataSourceKind.postgres: PostgresForm,
    DataSourceKind.mysql: MysqlForm,
    DataSourceKind.redshift: RedshiftForm,
    DataSourceKind.snowflake: SnowflakeForm,
    DataSourceKind.bigquery: BigqueryForm,
    DataSourceKind.firestore: FirestoreForm,
    DataSourceKind.mongo: MongoForm,
    DataSourceKind.redis: RedisForm,
    DataSourceKind.s3: S3Form,
    DataSourceKind.rest: RestForm,
    DataSourceKind.graphql: GraphqlForm,
    DataSourceKind.vector: VectorForm,
  };

  test('every kind is mapped to the form it should build', () {
    // Keeps the table above honest as the enum grows: a kind added without a
    // form fails here rather than showing a blank card in the picker.
    expect(forms.keys, containsAll(DataSourceKind.values));
    expect(forms.values.toSet(), hasLength(DataSourceKind.values.length));
  });

  for (final kind in DataSourceKind.values) {
    testWidgets('the ${kind.label} form lays out', (tester) async {
      sizeWindow(tester);
      await tester.pumpWidget(app());
      await settle(tester);

      final card = find.text(kind.label).first;
      await tester.ensureVisible(card);
      await settle(tester);
      await tester.tap(card);
      await settle(tester);

      expect(
        find.byType(forms[kind]!),
        findsOneWidget,
        reason: 'the ${kind.label} form did not appear',
      );
      // The shell is the same for every backend, so its absence means the
      // form threw rather than rendered.
      expect(find.text('Connection name'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

class _NoSecrets implements SecretsStore {
  @override
  Future<void> delete(String ref) async {}

  @override
  Future<ConnectionSecrets?> read(String ref) async => null;

  @override
  Future<void> write(String ref, ConnectionSecrets secrets) async {}

  @override
  Future<int> sweepOrphans(Iterable<String> liveRefs) async => 0;

  @override
  Future<({int removed, bool complete})> deleteAll() async =>
      (removed: 0, complete: true);
}
