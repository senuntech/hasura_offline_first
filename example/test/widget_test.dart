import 'package:flutter_test/flutter_test.dart';
import 'package:example/app_widget.dart';

void main() {
  testWidgets('AppWidget renders smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AppWidget());
    expect(find.byType(AppWidget), findsOneWidget);
  });
}
