import 'package:dextr/app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The shell puts its rail behind a drawer below 820 logical pixels, and the
  // test surface defaults to 800 — so a test about the rail has to ask for a
  // window the rail fits in. This is the size main.dart opens.
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1280, 820);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('the shell renders the connections rail and an empty workspace', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: DextrApp()));
    await tester.pump();

    // The rail is there with nothing in it, and it offers the one action that
    // ends the emptiness.
    expect(find.text('Connections'), findsOneWidget);
    expect(find.text('New connection'), findsWidgets);

    // The workspace says why it is blank rather than just being blank.
    expect(find.text('No connections yet'), findsOneWidget);
  });

  testWidgets('the rail moves into a drawer on a narrow window', (
    tester,
  ) async {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(700, 820);

    await tester.pumpWidget(const ProviderScope(child: DextrApp()));
    await tester.pump();

    // No rail on screen, so the empty state carries the way back to it.
    expect(find.text('Connections'), findsNothing);
    expect(find.text('No connections yet'), findsOneWidget);
  });
}
