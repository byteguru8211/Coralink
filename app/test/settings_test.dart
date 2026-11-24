import 'package:coralink/data/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('retired advanced notification mode migrates to standard', () async {
    SharedPreferences.setMockInitialValues({
      'coralink.settings.v1': '{"notification":"advanced"}',
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsStore(prefs).load();
    expect(settings.notificationMode, NotificationMode.medium);
    expect(NotificationMode.values, hasLength(3));
  });
}
