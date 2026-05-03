import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class DtmfToneService {
  DtmfToneService() {
    _player
      ..setPlayerMode(PlayerMode.lowLatency)
      ..setReleaseMode(ReleaseMode.stop);
  }

  static const int _sampleRate = 16000;
  static const int _durationMs = 120;
  static const double _volume = 0.32;

  final AudioPlayer _player = AudioPlayer();
  final Map<String, String> _cache = <String, String>{};

  static const Map<String, (double, double)> _dtmfMap =
      <String, (double, double)>{
    '1': (697, 1209),
    '2': (697, 1336),
    '3': (697, 1477),
    '4': (770, 1209),
    '5': (770, 1336),
    '6': (770, 1477),
    '7': (852, 1209),
    '8': (852, 1336),
    '9': (852, 1477),
    '*': (941, 1209),
    '0': (941, 1336),
    '#': (941, 1477),
  };

  Future<void> play(String digit) async {
    final pair = _dtmfMap[digit];
    if (pair == null) {
      return;
    }

    final filePath = await _resolveToneFile(
      digit,
      () => _generateTone(pair.$1, pair.$2),
    );

    await _player.stop();
    await _player.play(
      DeviceFileSource(filePath, mimeType: 'audio/wav'),
      volume: _volume,
    );
  }

  Future<void> dispose() async {
    await _player.dispose();
  }

  Future<String> _resolveToneFile(
    String digit,
    Uint8List Function() generateBytes,
  ) async {
    final existingPath = _cache[digit];
    if (existingPath != null && await File(existingPath).exists()) {
      return existingPath;
    }

    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/sfait_dtmf_$digit.wav');
    if (!await file.exists()) {
      await file.writeAsBytes(generateBytes(), flush: true);
    }
    _cache[digit] = file.path;
    return file.path;
  }

  Uint8List _generateTone(double firstFrequency, double secondFrequency) {
    final sampleCount = (_sampleRate * _durationMs / 1000).round();
    final pcmLength = sampleCount * 2;
    final byteData = ByteData(44 + pcmLength);

    void writeString(int offset, String value) {
      for (var index = 0; index < value.length; index++) {
        byteData.setUint8(offset + index, value.codeUnitAt(index));
      }
    }

    writeString(0, 'RIFF');
    byteData.setUint32(4, 36 + pcmLength, Endian.little);
    writeString(8, 'WAVE');
    writeString(12, 'fmt ');
    byteData.setUint32(16, 16, Endian.little);
    byteData.setUint16(20, 1, Endian.little);
    byteData.setUint16(22, 1, Endian.little);
    byteData.setUint32(24, _sampleRate, Endian.little);
    byteData.setUint32(28, _sampleRate * 2, Endian.little);
    byteData.setUint16(32, 2, Endian.little);
    byteData.setUint16(34, 16, Endian.little);
    writeString(36, 'data');
    byteData.setUint32(40, pcmLength, Endian.little);

    const amplitude = 0.34;
    for (var sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
      final time = sampleIndex / _sampleRate;
      final attack = sampleIndex < 80 ? sampleIndex / 80 : 1.0;
      final release = sampleIndex > sampleCount - 140
          ? (sampleCount - sampleIndex) / 140
          : 1.0;
      final envelope = math.min(attack, release).clamp(0.0, 1.0);
      final signal = ((math.sin(2 * math.pi * firstFrequency * time) +
                  math.sin(2 * math.pi * secondFrequency * time)) /
              2) *
          amplitude *
          envelope;
      final value = (signal * 32767).round().clamp(-32768, 32767);
      byteData.setInt16(44 + sampleIndex * 2, value, Endian.little);
    }

    return byteData.buffer.asUint8List();
  }
}
