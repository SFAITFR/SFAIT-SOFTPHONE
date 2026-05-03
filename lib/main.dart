import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/app.dart';
import 'src/services/preferences_service.dart';
import 'src/viewmodels/softphone_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final preferencesService = PreferencesService();
  await preferencesService.init();

  runApp(
    ChangeNotifierProvider(
      create: (_) => SoftphoneController(preferencesService)..bootstrap(),
      child: const SfaitSoftphoneApp(),
    ),
  );
}
