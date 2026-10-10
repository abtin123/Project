import 'package:flutter_test/flutter_test.dart';

// The default Flutter counter test referenced a `MyApp` class that does not
// exist (the app root is `AbtinApp` and needs Riverpod, plugins and offline
// map assets), which made `flutter analyze` fail with an error.
// Keep a placeholder so the test folder analyzes cleanly.
void main() {
  test('placeholder', () {
    expect(1 + 1, 2);
  });
}
