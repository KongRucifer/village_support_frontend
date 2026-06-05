// Basic smoke test: the app boots to the login screen.
import 'package:flutter_test/flutter_test.dart';

import 'package:village_support_app/main.dart';

void main() {
  testWidgets('Login screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Village Support'), findsOneWidget);
    expect(find.text('Login'), findsWidgets);
  });
}
