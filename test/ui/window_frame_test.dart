import 'package:astryx_ui/astryx_ui.dart';
import 'package:dextr/theme/app_theme.dart';
import 'package:dextr/ui/shell/window_frame.dart';
import 'package:dextr/ui/widgets/page_surface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

/// The window has no title bar, so the app draws the top of it.
///
/// These run the frame at each platform's shape on whatever host the suite is
/// on, which is what `WindowFrame.caption` is for: the behaviour is a property
/// of the platform, not of the machine running the test.
void main() {
  /// The accessible names of the window controls the app drew itself.
  Iterable<String> captionButtonLabels(WidgetTester tester) => tester
      .widgetList<AstryxIconButton>(find.byType(AstryxIconButton))
      .map((button) => button.label);

  Future<AstryxThemeData> pump(
    WidgetTester tester,
    WindowCaptionStyle caption, {
    Size size = const Size(1280, 820),
    DextrTheme scheme = DextrTheme.neutral,
    bool insetPage = false,
  }) async {
    final view = tester.view;
    view.physicalSize = size;
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    late AstryxThemeData theme;
    await tester.pumpWidget(
      AstryxApp(
        theme: buildDextrTheme(theme: scheme),
        mode: AstryxColorMode.dark,
        builder: (context, child) => DextrPageSurface(
          child: WindowFrame(
            caption: caption,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: Builder(
          builder: (context) {
            theme = AstryxTheme.of(context);
            const page = AstryxText('page');
            return insetPage
                ? const WindowCaptionInset(child: page)
                : page;
          },
        ),
      ),
    );
    await tester.pump();
    return theme;
  }

  testWidgets('a platform with no window chrome gets no band', (tester) async {
    await pump(tester, WindowCaptionStyle.none);

    // The page fills the window: nothing was reserved and nothing was drawn.
    expect(find.byType(DragToMoveArea), findsNothing);
    expect(tester.getTopLeft(find.text('page')).dy, 0);
  });

  testWidgets('macOS gets a draggable band and no buttons of its own', (
    tester,
  ) async {
    final theme = await pump(tester, WindowCaptionStyle.nativeButtons);

    // Somewhere to drag the window from, since the title bar is gone.
    expect(find.byType(DragToMoveArea), findsOneWidget);
    // The band reserves exactly the height the traffic lights need, so the
    // page's own content starts clear of them.
    expect(
      tester.getSize(find.byType(DragToMoveArea)).height,
      theme.size(AstryxSizeToken.elementLg),
    );
    // The OS still draws the buttons, so the app must not draw a second set.
    expect(captionButtonLabels(tester), isEmpty);
  });

  testWidgets('Windows and Linux get the controls the OS stopped drawing', (
    tester,
  ) async {
    await pump(tester, WindowCaptionStyle.customButtons);

    expect(find.byType(DragToMoveArea), findsOneWidget);
    // Named, not just drawn: an icon button carries its accessible name in
    // `label`, and a glyph has none of its own.
    expect(
      captionButtonLabels(tester),
      containsAll(<String>['Minimise', 'Maximise', 'Close']),
    );
  });

  testWidgets('the strip survives a resize, and a page stays clear of it', (
    tester,
  ) async {
    final theme = await pump(
      tester,
      WindowCaptionStyle.customButtons,
      insetPage: true,
    );
    final bandHeight = theme.size(AstryxSizeToken.elementLg);

    for (final size in const <Size>[
      Size(1600, 1000),
      Size(1280, 820),
      // Narrower than the shell's own breakpoint, and short.
      Size(700, 480),
      Size(420, 320),
    ]) {
      tester.view.physicalSize = size;
      await tester.pump();

      expect(
        tester.getSize(find.byType(DragToMoveArea)).height,
        bandHeight,
        reason: 'the strip changed height at $size',
      );
      expect(
        tester.getTopLeft(find.text('page')).dy,
        greaterThanOrEqualTo(bandHeight),
        reason: 'the page ran under the strip at $size',
      );
      // A strip that overflowed would have thrown by now; this states it.
      expect(tester.takeException(), isNull, reason: 'overflow at $size');
    }
  });

  /// How far down the window macOS's traffic lights reach: a 12-pixel button
  /// centred about 20 below the top edge. An OS measurement, not a design value,
  /// which is why it is written here rather than dressed up as a token.
  const trafficLightExtent = 26.0;

  for (final scheme in DextrTheme.values) {
    testWidgets('${scheme.name} leaves room for the traffic lights', (
      tester,
    ) async {
      // The band takes its height from a theme token, so a theme is free to
      // make it shorter — and a band shorter than the buttons would clip them
      // against the content below.
      final theme = await pump(
        tester,
        WindowCaptionStyle.nativeButtons,
        scheme: scheme,
      );

      expect(
        theme.size(AstryxSizeToken.elementLg),
        greaterThanOrEqualTo(trafficLightExtent),
      );
    });
  }

  testWidgets('a page held clear of the caption clears the drag strip', (
    tester,
  ) async {
    // On macOS the caption is an inset rather than a band, so a page asks to be
    // held clear of it. Every route but the shell does, at the router.
    final theme = await pump(
      tester,
      WindowCaptionStyle.nativeButtons,
      insetPage: true,
    );
    final band = tester.getRect(find.byType(DragToMoveArea));
    final page = tester.getRect(find.text('page'));

    expect(band.top, 0);
    expect(band.height, theme.size(AstryxSizeToken.elementLg));
    expect(page.top, greaterThanOrEqualTo(band.bottom));
  });

  testWidgets('a surface that does not ask runs up under the strip', (
    tester,
  ) async {
    // Which is what the connections rail wants: its colour reaches the top of
    // the window and it insets its own rows instead.
    await pump(tester, WindowCaptionStyle.nativeButtons);

    expect(tester.getRect(find.byType(DragToMoveArea)).top, 0);
    expect(tester.getTopLeft(find.text('page')).dy, 0);
  });

  testWidgets('the app-drawn buttons get the same inset as the OS ones', (
    tester,
  ) async {
    // The caption is an inset on every platform that has one, not a band on
    // some of them: a band would push the router — and the overlay every menu
    // portals into — down the window, and every anchored overlay in the app
    // with it.
    await pump(
      tester,
      WindowCaptionStyle.customButtons,
      insetPage: true,
    );

    final band = tester.getRect(find.byType(DragToMoveArea));
    expect(tester.getTopLeft(find.text('page')).dy, band.bottom);
  });
}
