import 'package:dextr/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App shell renders with empty state', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: DextrApp()));
    await tester.pump();

    expect(find.text('Dextr'), findsOneWidget);
    expect(find.text('No connection open'), findsOneWidget);
  });
}
