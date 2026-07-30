import 'package:flutter_test/flutter_test.dart';
import 'package:obexvault/main.dart';

void main() {
  testWidgets('ObexVault smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ObexVaultApp());
  });
}