import 'package:flutter/material.dart';

enum AppThemePreference { light, dark }

class GeneralSettings {
  const GeneralSettings({
    required this.launchAtStartup,
    required this.showMenuBarIcon,
    required this.showDockIcon,
    required this.themePreference,
    required this.audioInputId,
    required this.audioOutputId,
    required this.ringtoneOutputId,
    required this.ringtoneVolume,
    required this.preferredCodecId,
    required this.ringtoneFilePath,
    required this.ringtoneFileName,
  });

  final bool launchAtStartup;
  final bool showMenuBarIcon;
  final bool showDockIcon;
  final AppThemePreference themePreference;
  final String audioInputId;
  final String audioOutputId;
  final String ringtoneOutputId;
  final double ringtoneVolume;
  final String preferredCodecId;
  final String ringtoneFilePath;
  final String ringtoneFileName;

  ThemeMode get themeMode => switch (themePreference) {
        AppThemePreference.light => ThemeMode.light,
        AppThemePreference.dark => ThemeMode.dark,
      };

  GeneralSettings copyWith({
    bool? launchAtStartup,
    bool? showMenuBarIcon,
    bool? showDockIcon,
    AppThemePreference? themePreference,
    String? audioInputId,
    String? audioOutputId,
    String? ringtoneOutputId,
    double? ringtoneVolume,
    String? preferredCodecId,
    String? ringtoneFilePath,
    String? ringtoneFileName,
  }) {
    return GeneralSettings(
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      showMenuBarIcon: showMenuBarIcon ?? this.showMenuBarIcon,
      showDockIcon: showDockIcon ?? this.showDockIcon,
      themePreference: themePreference ?? this.themePreference,
      audioInputId: audioInputId ?? this.audioInputId,
      audioOutputId: audioOutputId ?? this.audioOutputId,
      ringtoneOutputId: ringtoneOutputId ?? this.ringtoneOutputId,
      ringtoneVolume: ringtoneVolume ?? this.ringtoneVolume,
      preferredCodecId: preferredCodecId ?? this.preferredCodecId,
      ringtoneFilePath: ringtoneFilePath ?? this.ringtoneFilePath,
      ringtoneFileName: ringtoneFileName ?? this.ringtoneFileName,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'launchAtStartup': launchAtStartup,
      'showMenuBarIcon': showMenuBarIcon,
      'showDockIcon': showDockIcon,
      'themePreference': themePreference.name,
      'audioInputId': audioInputId,
      'audioOutputId': audioOutputId,
      'ringtoneOutputId': ringtoneOutputId,
      'ringtoneVolume': ringtoneVolume,
      'preferredCodecId': preferredCodecId,
      'ringtoneFilePath': ringtoneFilePath,
      'ringtoneFileName': ringtoneFileName,
    };
  }

  factory GeneralSettings.fromJson(Map<String, dynamic> json) {
    return GeneralSettings(
      launchAtStartup: json['launchAtStartup'] as bool? ?? false,
      showMenuBarIcon: json['showMenuBarIcon'] as bool? ?? false,
      showDockIcon: json['showDockIcon'] as bool? ?? true,
      themePreference: AppThemePreference.values.firstWhere(
        (value) => value.name == json['themePreference'],
        orElse: () => AppThemePreference.dark,
      ),
      audioInputId: json['audioInputId'] as String? ?? '',
      audioOutputId: json['audioOutputId'] as String? ?? '',
      ringtoneOutputId: json['ringtoneOutputId'] as String? ?? '',
      ringtoneVolume: ((json['ringtoneVolume'] as num?)?.toDouble() ?? 1.0)
          .clamp(0.0, 1.0)
          .toDouble(),
      preferredCodecId: json['preferredCodecId'] as String? ?? '',
      ringtoneFilePath: json['ringtoneFilePath'] as String? ?? '',
      ringtoneFileName: json['ringtoneFileName'] as String? ?? '',
    );
  }

  static const defaults = GeneralSettings(
    launchAtStartup: false,
    showMenuBarIcon: false,
    showDockIcon: true,
    themePreference: AppThemePreference.dark,
    audioInputId: '',
    audioOutputId: '',
    ringtoneOutputId: '',
    ringtoneVolume: 1.0,
    preferredCodecId: '',
    ringtoneFilePath: '',
    ringtoneFileName: '',
  );
}
