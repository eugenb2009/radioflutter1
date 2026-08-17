// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:walkie_talkie/main.dart';

void main() {
  testWidgets('WalkieTalkieApp smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const WalkieTalkieApp());

    // Verify that the app renders its title bar.
    expect(find.text('Рация'), findsWidgets);

    // The push-to-talk button is shown when the app is not initialized.
    expect(find.text('НАЖМИ'), findsOneWidget);
  });
}
