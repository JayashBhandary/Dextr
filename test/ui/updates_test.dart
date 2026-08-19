import 'dart:convert';
import 'dart:io';

import 'package:astryx_ui/astryx_ui.dart';
import 'package:dextr/app.dart';
import 'package:dextr/domain/connection_secrets.dart';
import 'package:dextr/router.dart';
import 'package:dextr/services/connections_repo.dart';
import 'package:dextr/services/external_open.dart';
import 'package:dextr/services/secrets_store.dart';
import 'package:dextr/services/settings_repo.dart';
import 'package:dextr/services/update_service.dart';
import 'package:dextr/state/providers.dart';
import 'package:dextr/state/update_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The settings page's update section, against a stubbed release feed.
///
/// The service's own behaviour is pinned in `test/services/update_service_test`;
/// what these cover is the wiring — that the button reaches the feed, that each
/// of the three outcomes draws the right thing, and that "Update now" opens the
/// release this application built the URL for rather than anything else.
void main() {
  late Directory tmp;

  /// What the fake browser was handed instead of a browser.
  late List<String> launched;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_updates_test');
    launched = <String>[];
  });

  tearDown(() async => tmp.delete(recursive: true));

  void sizeWindow(WidgetTester tester) {
    final view = tester.view;
    view.physicalSize = const Size(1280, 900);
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  }

  ProviderScope app({
    String? tag,
    int status = 200,
    String currentVersion = '0.1.4',
  }) => ProviderScope(
    overrides: [
      connectionsRepoProvider.overrideWithValue(
        ConnectionsRepo(overridePath: tmp.path),
      ),
      settingsRepoProvider.overrideWithValue(
        SettingsRepo(overridePath: tmp.path),
      ),
      secretsStoreProvider.overrideWithValue(_NoSecrets()),
      externalOpenProvider.overrideWithValue(
        ExternalOpen(
          launch: (target) async {
            launched.add(target);
          },
        ),
      ),
      updateServiceProvider.overrideWithValue(
        UpdateService(
          currentVersion: currentVersion,
          client: MockClient(
            (_) async => http.Response(
              tag == null
                  ? '{}'
                  : jsonEncode(<String, Object?>{'tag_name': tag}),
              status,
              headers: <String, String>{'content-type': 'application/json'},
            ),
          ),
        ),
      ),
      routerProvider.overrideWith(
        (ref) => buildRouter(initialLocation: '/settings'),
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

  Future<void> pressCheck(WidgetTester tester) async {
    final button = find.widgetWithText(AstryxButton, 'Check for updates');
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await settle(tester);
  }

  testWidgets('the section reports the version before anything is checked', (
    tester,
  ) async {
    sizeWindow(tester);
    await tester.pumpWidget(app());
    await settle(tester);

    expect(find.text('Updates'), findsOneWidget);
    expect(find.text('Version'), findsWidgets);
    // Nothing has been asked yet, so nothing is claimed either way.
    expect(find.text('Dextr is up to date'), findsNothing);
    expect(find.textContaining('is available'), findsNothing);
  });

  testWidgets('a newer release offers the update and the command', (
    tester,
  ) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(tag: 'v9.9.9'));
    await settle(tester);

    await pressCheck(tester);

    expect(find.text('v9.9.9 is available'), findsOneWidget);
    // The one-liner is on the page, not described: it is what actually installs
    // the release, and the block carries its own copy button.
    expect(find.textContaining(UpdateService.installCommand()), findsWidgets);

    final update = find.widgetWithText(AstryxButton, 'Update now');
    await tester.ensureVisible(update);
    await tester.pump();
    await tester.tap(update);
    await settle(tester);

    // The URL this application built from the tag, and nothing out of the reply.
    expect(launched, <String>[
      'https://github.com/JayashBhandary/dextr/releases/tag/v9.9.9',
    ]);
  });

  testWidgets('the newest release already installed says so', (tester) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(tag: 'v0.1.4'));
    await settle(tester);

    await pressCheck(tester);

    expect(find.text('Dextr is up to date'), findsOneWidget);
    expect(find.widgetWithText(AstryxButton, 'Update now'), findsNothing);
    expect(launched, isEmpty);
  });

  testWidgets('a feed that will not answer explains itself', (tester) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(tag: 'v9.9.9', status: 403));
    await settle(tester);

    await pressCheck(tester);

    expect(find.text('Could not check for updates'), findsOneWidget);
    expect(find.textContaining('rate-limiting'), findsOneWidget);
    // A failed check must never read as "up to date".
    expect(find.text('Dextr is up to date'), findsNothing);
  });
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
