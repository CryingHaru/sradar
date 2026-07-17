import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/main.dart';

void main() {
  testWidgets('App renders test', (WidgetTester tester) async {
    await tester.pumpWidget(const RadarApp());
    expect(find.byType(RadarApp), findsOneWidget);
  });
}
