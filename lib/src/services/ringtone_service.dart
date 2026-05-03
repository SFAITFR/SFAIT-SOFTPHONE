import 'package:flutter/services.dart';

class ImportedRingtone {
  const ImportedRingtone({
    required this.path,
    required this.name,
  });

  final String path;
  final String name;
}

class RingtoneService {
  static const MethodChannel _channel = MethodChannel('sfait/ringtone');

  Future<void> play({
    String outputDeviceId = '',
    String filePath = '',
    double volume = 1.0,
  }) {
    return _channel.invokeMethod<void>('playRingtone', {
      'outputDeviceId': outputDeviceId,
      'filePath': filePath,
      'volume': volume.clamp(0.0, 1.0),
    });
  }

  Future<void> stop() {
    return _channel.invokeMethod<void>('stopRingtone');
  }

  Future<void> setVolume(double volume) {
    return _channel.invokeMethod<void>('setRingtoneVolume', {
      'volume': volume.clamp(0.0, 1.0),
    });
  }

  Future<ImportedRingtone?> importCustomRingtone() async {
    final result =
        await _channel.invokeMethod<Map<Object?, Object?>>('importRingtone');
    if (result == null) {
      return null;
    }

    final path = result['path'] as String? ?? '';
    final name = result['name'] as String? ?? '';
    if (path.isEmpty || name.isEmpty) {
      return null;
    }

    return ImportedRingtone(path: path, name: name);
  }
}
