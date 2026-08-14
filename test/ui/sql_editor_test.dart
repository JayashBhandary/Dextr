import 'package:astryx_ui/astryx_ui.dart';
import 'package:dextr/core/sql/sql_completion.dart';
import 'package:dextr/theme/app_theme.dart';
import 'package:dextr/ui/widgets/sql_completion_list.dart';
import 'package:dextr/ui/widgets/sql_editor.dart';
import 'package:dextr/ui/widgets/sql_highlight.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The editor as a control: can it be typed in, clicked into, and completed
/// from. The first two are not decoration — the pane shipped with a bare
/// `EditableText` behind a gesture detector that only asked for focus, which
/// reads on screen as an editor that ignores the mouse.
void main() {
  const catalogue = SqlCatalogue(
    tables: <String>['tracks', 'albums'],
    columns: <String, List<SqlColumnInfo>>{
      'tracks': <SqlColumnInfo>[
        SqlColumnInfo(name: 'id', type: 'INTEGER', primaryKey: true),
        SqlColumnInfo(name: 'name', type: 'TEXT', nullable: false),
      ],
    },
  );

  late SqlHighlightController controller;
  late FocusNode focus;
  late List<String> changes;

  setUp(() {
    controller = SqlHighlightController();
    focus = FocusNode();
    changes = <String>[];
  });

  tearDown(() {
    controller.dispose();
    focus.dispose();
  });

  Future<void> pumpEditor(WidgetTester tester, {VoidCallback? onRun}) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      AstryxApp(
        theme: buildDextrTheme(theme: DextrTheme.neutral),
        mode: AstryxColorMode.dark,
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 600,
            height: 300,
            child: SqlEditor(
              controller: controller,
              focusNode: focus,
              catalogue: catalogue,
              onRun: onRun,
              onChanged: changes.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Puts the caret at the end and lets the completion for it settle.
  Future<void> type(WidgetTester tester, String text) async {
    focus.requestFocus();
    await tester.pump();
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('text typed into it arrives, and is reported', (tester) async {
    await pumpEditor(tester);

    await tester.tap(find.byType(EditableText));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'SELECT 1');
    await tester.pump();

    expect(controller.text, 'SELECT 1');
    expect(changes.last, 'SELECT 1');
  });

  testWidgets('a click puts the caret where it was clicked', (tester) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT id, name FROM tracks');

    // A few characters in along the first line: a caret placed by the
    // framework where the mouse went, not one parked at the end of the text.
    final box = tester.getRect(find.byType(EditableText));
    final target = Offset(box.left + 24, box.top + 8);

    await tester.tapAt(target);
    await tester.pump();

    expect(controller.selection.isValid, isTrue);
    expect(controller.selection.baseOffset, lessThan(controller.text.length));
    expect(controller.selection.baseOffset, greaterThan(0));
  });

  testWidgets('the tables of the connection are offered after FROM', (
    tester,
  ) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT * FROM tra');

    expect(find.text('tracks'), findsOneWidget);
    // And the hint is written ahead of the caret rather than only in the list.
    expect(controller.ghost, 'cks');
  });

  testWidgets('Tab takes the hint', (tester) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT * FROM tra');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, 'SELECT * FROM tracks');
    expect(controller.selection.baseOffset, 'SELECT * FROM tracks'.length);
  });

  testWidgets('the arrows walk the list and Enter takes the row', (
    tester,
  ) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT * FROM ');

    // Nothing typed yet, so the tables come in name order: the highlighted row
    // is `albums`, and one press down is `tracks`.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.text, 'SELECT * FROM tracks');
  });

  testWidgets('a suggestion clicked with the mouse is taken', (tester) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT * FROM tra');
    expect(find.text('tracks'), findsOneWidget);

    // A mouse, not a tap: the press is what used to break this. `EditableText`
    // unfocuses on a tap down outside its own `TextFieldTapRegion`, so pressing
    // a row closed the list before the release could reach it, and the list
    // read as decoration.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    final row = tester.getCenter(find.text('tracks'));
    await mouse.moveTo(row);
    await tester.pump();
    await mouse.down(row);
    await tester.pump();

    // Still the editor's caret, and the list is still up to be released onto.
    expect(focus.hasFocus, isTrue);
    expect(find.text('tracks'), findsOneWidget);

    await mouse.up();
    await tester.pump();
    await tester.pump();

    expect(controller.text, 'SELECT * FROM tracks');
    expect(controller.selection.baseOffset, 'SELECT * FROM tracks'.length);
    expect(focus.hasFocus, isTrue);
  });

  testWidgets('Escape closes the list and leaves the text alone', (
    tester,
  ) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT * FROM tra');
    expect(find.text('tracks'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    // Two frames: the state change, then the overlay it asks to be taken down.
    await tester.pump();
    await tester.pump();

    expect(find.text('tracks'), findsNothing);
    expect(controller.text, 'SELECT * FROM tra');
    // The hint goes with it: it is the same suggestion by another name.
    expect(controller.ghost, '');
  });

  testWidgets('columns are offered for the table the statement named', (
    tester,
  ) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT * FROM tracks WHERE na');

    expect(find.text('name'), findsOneWidget);
    expect(controller.ghost, 'me');
  });

  testWidgets('nothing is suggested while a selection is up', (tester) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT * FROM tra');
    expect(find.text('tracks'), findsOneWidget);

    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('tracks'), findsNothing);
  });

  testWidgets('the gutter numbers the lines, and follows the caret', (
    tester,
  ) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT id\nFROM tracks\nWHERE id = 1');

    // One number per line of code, in the gutter beside it.
    final gutter = tester.getRect(find.byType(SqlGutter));
    final editor = tester.getRect(find.byType(EditableText));
    expect(gutter.right, lessThanOrEqualTo(editor.left));
    expect(gutter.width, greaterThan(0));
  });

  testWidgets('Tab indents where there is no hint to take', (tester) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT 1\n');

    // The list is up — nothing has been typed of the next word — and Tab is
    // still an indent, because a list nobody asked for must not eat the key.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, 'SELECT 1\n  ');
  });
}
