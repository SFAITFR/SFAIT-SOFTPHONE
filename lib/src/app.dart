import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/softphone_home_page.dart';
import 'theme/app_theme.dart';
import 'viewmodels/softphone_controller.dart';

class SfaitSoftphoneApp extends StatelessWidget {
  const SfaitSoftphoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SoftphoneController>(
      builder: (context, controller, _) {
        return MaterialApp(
          title: 'SFAIT Softphone',
          debugShowCheckedModeBanner: false,
          themeMode: controller.themeMode,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          home: const SoftphoneHomePage(),
        );
      },
    );
  }
}
