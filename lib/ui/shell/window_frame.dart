import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../widgets/dextr_icons.dart';

/// What the window needs from the application, once its title bar is gone.
enum WindowCaptionStyle {
  /// Nothing: the platform has no window chrome to replace — a phone, a
  /// browser tab — so the app fills what it is given.
  none,

  /// The OS still draws its own buttons over the app's surface, as macOS does
  /// with a hidden title bar. The app owes it somewhere to put them and a strip
  /// to drag.
  nativeButtons,

  /// Hiding the title bar took the buttons with it, as it does on Windows and
  /// Linux, so the app draws its own.
  customButtons;

  /// What this platform needs. Read once per build from
  /// [defaultTargetPlatform] rather than `dart:io`, so the answer is also
  /// correct on the web, where there is no `Platform`.
  static WindowCaptionStyle forPlatform() {
    if (kIsWeb) return none;
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS => nativeButtons,
      TargetPlatform.windows || TargetPlatform.linux => customButtons,
      _ => none,
    };
  }
}

/// How much room at the top of the window the caption has taken, for the
/// surfaces that run up into it.
///
/// Only the macOS case reserves anything here. Where the app draws its own
/// buttons it draws a band above everything and nothing underneath has to know;
/// where the *OS* draws them over the app, the room they need is an inset that
/// each surface honours itself — which is what lets the rail paint to the top
/// of the window and still start its rows below the traffic lights.
class WindowCaptionScope extends InheritedWidget {
  const WindowCaptionScope({
    required this.inset,
    required super.child,
    super.key,
  });

  /// The height at the top of the window that belongs to the caption. Zero
  /// when the caption is a band of its own, or when there is no caption.
  final double inset;

  static double insetOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<WindowCaptionScope>()
          ?.inset ??
      0;

  @override
  bool updateShouldNotify(WindowCaptionScope oldWidget) =>
      inset != oldWidget.inset;
}

/// Holds [child] clear of the window's caption.
///
/// For everything that is not the rail: a page that starts at the top of the
/// window would otherwise put its heading under the traffic lights.
class WindowCaptionInset extends StatelessWidget {
  const WindowCaptionInset({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: WindowCaptionScope.insetOf(context)),
    child: child,
  );
}

/// The band across the top of the window, in place of a title bar.
///
/// The title bar is hidden at startup (see `main.dart`), which leaves two
/// problems this solves: a window with no title bar cannot be moved, and on
/// macOS the traffic lights now float over whatever the app happens to draw at
/// the top left. So the app draws a strip of its own — draggable, tall enough
/// for the native buttons to sit inside, and carrying the window controls itself
/// on the platforms that no longer have any.
///
/// It is installed through `AstryxApp.builder`, above the router: one band for
/// the whole application, so it cannot go missing when the page changes, and
/// nothing in any page has to reserve space for it. The band is a fixed height
/// and the content takes what is left, so resizing only ever changes the
/// content's share.
class WindowFrame extends StatefulWidget {
  const WindowFrame({super.key, required this.child, this.caption});

  final Widget child;

  /// Overrides what the platform would ask for. For tests, which run on the
  /// host platform whatever they are testing.
  @visibleForTesting
  final WindowCaptionStyle? caption;

  @override
  State<WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends State<WindowFrame> with WindowListener {
  bool _maximized = false;
  bool _fullScreen = false;

  WindowCaptionStyle get _caption =>
      widget.caption ?? WindowCaptionStyle.forPlatform();

  @override
  void initState() {
    super.initState();
    if (_caption == WindowCaptionStyle.none) return;
    windowManager.addListener(this);
    _readWindowState();
  }

  @override
  void dispose() {
    if (_caption != WindowCaptionStyle.none) windowManager.removeListener(this);
    super.dispose();
  }

  /// The window may already be maximised or full screen when the app starts —
  /// restored by the OS, or launched that way — and no event fires for a state
  /// that was true before anyone was listening.
  Future<void> _readWindowState() async {
    try {
      final maximized = await windowManager.isMaximized();
      final fullScreen = await windowManager.isFullScreen();
      if (!mounted) return;
      setState(() {
        _maximized = maximized;
        _fullScreen = fullScreen;
      });
    } on Object {
      // No window to ask — a test, or a platform without the plugin. The
      // defaults above are the right answer there.
    }
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  void onWindowEnterFullScreen() => setState(() => _fullScreen = true);

  @override
  void onWindowLeaveFullScreen() => setState(() => _fullScreen = false);

  @override
  Widget build(BuildContext context) {
    final caption = _caption;

    // Full screen has no title bar to replace and nowhere to drag the window
    // to: the OS hides its buttons, so the band would be a strip of dead space
    // across the top of a screen the user asked to fill.
    if (caption == WindowCaptionStyle.none || _fullScreen) {
      return WindowCaptionScope(inset: 0, child: widget.child);
    }

    final theme = AstryxTheme.of(context);
    // Tall enough to contain macOS's buttons, and it grows with the theme's
    // control size rather than being a number of its own.
    final height = theme.size(AstryxSizeToken.elementLg);

    if (caption == WindowCaptionStyle.nativeButtons) {
      // The OS puts its buttons *over* the app, so the app owes them room
      // rather than a band. A band would be a strip of window-coloured nothing
      // above every surface, including the one surface — the rail — that is
      // meant to run the full height of the window.
      //
      // The drag strip is laid over the top instead. Everything under it is a
      // caption inset, so there is nothing there for it to steal a press from.
      return WindowCaptionScope(
        inset: height,
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: widget.child),
            PositionedDirectional(
              top: 0,
              start: 0,
              end: 0,
              height: height,
              child: const DragToMoveArea(child: SizedBox.expand()),
            ),
          ],
        ),
      );
    }

    // The app's own buttons have to be above the page rather than over it, and
    // a band is what gives them a row of their own. Nothing underneath needs an
    // inset, because the band already pushed it all down.
    return WindowCaptionScope(
      inset: 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: height,
            child: Row(
              children: <Widget>[
                // The drag target is everything the buttons do not cover, so a
                // press can never be both a drag and a click.
                const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
                _WindowButtons(maximized: _maximized),
              ],
            ),
          ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}

/// Minimise, maximise and close, for a window whose OS stopped drawing them.
///
/// A toolbar, so Tab reaches the set once and the arrows move inside it — three
/// separate tab stops in front of every page's content is three presses every
/// keyboard user pays on arrival.
class _WindowButtons extends StatelessWidget {
  const _WindowButtons({required this.maximized});

  final bool maximized;

  @override
  Widget build(BuildContext context) {
    final theme = AstryxTheme.of(context);

    return Padding(
      // Off the window's own edge, and logical so it follows the reading
      // direction — under RTL the controls move to the other end with it.
      padding: EdgeInsetsDirectional.only(
        end: theme.spacing(AstryxSpacingToken.spacing1),
      ),
      child: AstryxToolbar(
        label: 'Window',
        // No inset of its own: the band is already exactly as tall as a control,
        // so padding inside it would push the buttons past the bottom edge.
        padding: AstryxSpacingToken.spacing0,
        children: <Widget>[
          AstryxIconButton.custom(
            label: 'Minimise',
            tooltip: 'Minimise',
            variant: AstryxButtonVariant.ghost,
            size: AstryxButtonSize.sm,
            onPressed: windowManager.minimize,
            child: const Icon(DextrIcons.windowMinimize),
          ),
          AstryxIconButton.custom(
            label: maximized ? 'Restore' : 'Maximise',
            tooltip: maximized ? 'Restore' : 'Maximise',
            variant: AstryxButtonVariant.ghost,
            size: AstryxButtonSize.sm,
            onPressed: maximized
                ? windowManager.unmaximize
                : windowManager.maximize,
            child: Icon(
              maximized ? DextrIcons.windowRestore : DextrIcons.windowMaximize,
            ),
          ),
          AstryxIconButton.custom(
            label: 'Close',
            tooltip: 'Close',
            variant: AstryxButtonVariant.ghost,
            size: AstryxButtonSize.sm,
            onPressed: windowManager.close,
            child: const Icon(DextrIcons.windowClose),
          ),
        ],
      ),
    );
  }
}
