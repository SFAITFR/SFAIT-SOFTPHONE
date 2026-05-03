import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sfait_softphone/src/app.dart';
import 'package:sfait_softphone/src/services/preferences_service.dart';
import 'package:sfait_softphone/src/viewmodels/softphone_controller.dart';

void main() {
  testWidgets('shows softphone shell', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(860, 1520);
    binding.platformDispatcher.views.first.devicePixelRatio = 2.0;
    addTearDown(() {
      binding.platformDispatcher.views.first.resetPhysicalSize();
      binding.platformDispatcher.views.first.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({});
    final preferences = PreferencesService();
    await preferences.init();

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SoftphoneController(preferences)..bootstrap(),
        child: const SfaitSoftphoneApp(),
      ),
    );

    expect(find.text('SFAIT Softphone'), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.text('Clavier'), findsOneWidget);
    expect(find.text('Journal'), findsOneWidget);
    expect(find.text('Réglages'), findsOneWidget);
  });
}
