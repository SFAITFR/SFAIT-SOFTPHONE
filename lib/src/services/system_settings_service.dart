import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/audio_device_option.dart';
import '../models/codec_option.dart';
import '../models/privacy_permission_status.dart';

class SystemSettingsService {
  static const _launchChannel = MethodChannel('sfait/launch_at_startup');
  static const _channel = MethodChannel('sfait/system_settings');
  static const _nativeSoftphoneChannel = MethodChannel(
    'sfait/native_softphone',
  );

  List<AudioDeviceOption> _cachedInputs = const <AudioDeviceOption>[];
  List<AudioDeviceOption> _cachedOutputs = const <AudioDeviceOption>[];

  bool get _isNativeDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  Future<void> configureLaunchAtStartup() async {
    return;
  }

  Future<bool> getLaunchAtStartupEnabled() async {
    try {
      if (!_isNativeDesktop) {
        return false;
      }
      return await _launchChannel.invokeMethod<bool>(
            'launchAtStartupIsEnabled',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setLaunchAtStartupEnabled(bool enabled) async {
    if (!_isNativeDesktop) {
      return;
    }

    await _launchChannel.invokeMethod<void>(
      'launchAtStartupSetEnabled',
      {'setEnabledValue': enabled},
    );
  }

  Future<void> setWindowPresentationOptions({
    required bool showMenuBarIcon,
    required bool showDockIcon,
  }) async {
    if (!_isNativeDesktop) {
      return;
    }

    await _channel.invokeMethod<void>(
      'setWindowPresentationOptions',
      {
        'showMenuBarIcon': showMenuBarIcon,
        'showDockIcon': showDockIcon,
      },
    );
  }

  Future<void> showWindowForIncomingCall() async {
    if (!_isNativeDesktop) {
      return;
    }

    await _channel.invokeMethod<void>('showWindowForIncomingCall');
  }

  Future<List<PrivacyPermissionStatus>> getPrivacyPermissions() async {
    if (!_isNativeDesktop) {
      return const <PrivacyPermissionStatus>[];
    }

    final rawPermissions =
        await _channel.invokeMethod<List<Object?>>('listPrivacyPermissions');
    if (rawPermissions == null) {
      return const <PrivacyPermissionStatus>[];
    }

    return rawPermissions
        .whereType<Map<Object?, Object?>>()
        .map(
          (permission) => PrivacyPermissionStatus(
            kind: _privacyKindFromNative(permission['kind'] as String?),
            label: permission['label'] as String? ?? 'Autorisation',
            description: permission['description'] as String? ?? '',
            isActive: permission['isActive'] as bool? ?? false,
          ),
        )
        .toList(growable: false);
  }

  Future<void> openPrivacyPermissionSettings(
    PrivacyPermissionKind kind,
  ) async {
    if (!_isNativeDesktop) {
      return;
    }

    await _channel.invokeMethod<void>(
      'openPrivacyPermissionSettings',
      {'kind': kind.name},
    );
  }

  Future<List<AudioDeviceOption>> getAudioInputs() async {
    final devices = await _listCallInputDevices();
    _cachedInputs = devices;
    return devices;
  }

  Future<List<AudioDeviceOption>> getAudioOutputs() async {
    final devices = await _listCallOutputDevices();
    _cachedOutputs = devices;
    return devices;
  }

  Future<List<AudioDeviceOption>> getRingtoneOutputs() async {
    if (!_isNativeDesktop) {
      return const <AudioDeviceOption>[];
    }

    return _listNativeDevices('listAudioOutputs', 'Sortie');
  }

  Future<List<CodecOption>> getAudioCodecs() async {
    if (!_isNativeDesktop) {
      return const <CodecOption>[];
    }

    final rawCodecs = await _nativeSoftphoneChannel.invokeMethod<List<Object?>>(
      'listCodecs',
    );
    if (rawCodecs == null) {
      return const <CodecOption>[];
    }

    return rawCodecs
        .whereType<Map<Object?, Object?>>()
        .map(
          (codec) => CodecOption(
            id: codec['id'] as String? ?? '',
            label: codec['label'] as String? ?? 'Codec audio',
            priority: codec['priority'] as int? ?? 0,
          ),
        )
        .where((codec) => codec.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> selectPreferredCodec(String codecId) async {
    if (!_isNativeDesktop) {
      return;
    }

    await _nativeSoftphoneChannel.invokeMethod<void>(
      'setPreferredCodec',
      {'codecId': codecId},
    );
  }

  Future<void> selectAudioInput(String deviceId) async {
    if (deviceId.isEmpty) {
      return;
    }
    final option = _cachedInputs.cast<AudioDeviceOption?>().firstWhere(
          (device) => device?.id == deviceId,
          orElse: () => null,
        );

    if (option?.id.startsWith('pjsip:') ?? deviceId.startsWith('pjsip:')) {
      await _nativeSoftphoneChannel.invokeMethod<void>(
        'setAudioInput',
        {'deviceId': option?.id ?? deviceId},
      );
      return;
    }

    for (final candidate in await _inputDeviceCandidates(option)) {
      try {
        await Helper.selectAudioInput(candidate);
        return;
      } catch (_) {
        // Try the next known identifier for the same physical device.
      }
    }
  }

  Future<void> selectAudioOutput(String deviceId) async {
    if (deviceId.isEmpty) {
      return;
    }
    final option = _cachedOutputs.cast<AudioDeviceOption?>().firstWhere(
          (device) => device?.id == deviceId,
          orElse: () => null,
        );

    if (option?.id.startsWith('pjsip:') ?? deviceId.startsWith('pjsip:')) {
      await _nativeSoftphoneChannel.invokeMethod<void>(
        'setAudioOutput',
        {'deviceId': option?.id ?? deviceId},
      );
      return;
    }

    for (final candidate in await _outputDeviceCandidates(option)) {
      try {
        await Helper.selectAudioOutput(candidate);
        return;
      } catch (_) {
        // Try the next known identifier for the same physical device.
      }
    }
  }

  String _normalizeLabel(String raw, String fallbackPrefix) {
    final trimmed = raw.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
    return '$fallbackPrefix inconnu';
  }

  Future<List<AudioDeviceOption>> _listCallInputDevices() async {
    if (!_isNativeDesktop) {
      return const <AudioDeviceOption>[];
    }

    try {
      final nativeDevices = await _listPjsipDevices('listAudioInputs', 'Micro');
      if (nativeDevices.isNotEmpty) {
        return nativeDevices;
      }
    } catch (_) {
      // Fall through to WebRTC devices.
    }

    return _listWebRtcInputDevices();
  }

  Future<List<AudioDeviceOption>> _listCallOutputDevices() async {
    if (!_isNativeDesktop) {
      return const <AudioDeviceOption>[];
    }

    try {
      final nativeDevices =
          await _listPjsipDevices('listAudioOutputs', 'Sortie');
      if (nativeDevices.isNotEmpty) {
        return nativeDevices;
      }
    } catch (_) {
      // Fall through to WebRTC devices.
    }

    return _listWebRtcOutputDevices();
  }

  Future<List<AudioDeviceOption>> _listNativeDevices(
    String method,
    String fallbackPrefix,
  ) async {
    final rawDevices = await _channel.invokeMethod<List<Object?>>(method);
    if (rawDevices == null) {
      return const <AudioDeviceOption>[];
    }

    return rawDevices
        .whereType<Map<Object?, Object?>>()
        .map(
          (device) => AudioDeviceOption(
            id: (device['id'] as String?) ?? '',
            label: _normalizeLabel(
              (device['label'] as String?) ?? '',
              fallbackPrefix,
            ),
            systemDeviceId: (device['id'] as String?) ?? '',
          ),
        )
        .where((device) => device.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<AudioDeviceOption>> _listPjsipDevices(
    String method,
    String fallbackPrefix,
  ) async {
    final rawDevices =
        await _nativeSoftphoneChannel.invokeMethod<List<Object?>>(method);
    if (rawDevices == null) {
      return const <AudioDeviceOption>[];
    }

    return rawDevices
        .whereType<Map<Object?, Object?>>()
        .map(
          (device) => AudioDeviceOption(
            id: (device['id'] as String?) ?? '',
            label: _normalizeLabel(
              (device['label'] as String?) ?? '',
              fallbackPrefix,
            ),
            callDeviceId: (device['id'] as String?) ?? '',
          ),
        )
        .where((device) => device.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<AudioDeviceOption>> _listWebRtcInputDevices() async {
    final devices = await _listWebRtcDevices();
    return devices
        .where((device) => device.kind == 'audioinput')
        .map(
          (device) => AudioDeviceOption(
            id: device.deviceId,
            label: _normalizeLabel(device.label, 'Micro'),
            callDeviceId: device.deviceId,
          ),
        )
        .toList(growable: false);
  }

  Future<List<AudioDeviceOption>> _listWebRtcOutputDevices() async {
    final devices = await _listWebRtcDevices();
    return devices
        .where((device) => device.kind == 'audiooutput')
        .map(
          (device) => AudioDeviceOption(
            id: device.deviceId,
            label: _normalizeLabel(device.label, 'Sortie'),
            callDeviceId: device.deviceId,
          ),
        )
        .toList(growable: false);
  }

  Future<List<MediaDeviceInfo>> _listWebRtcDevices() async {
    await _primeWebRtcDeviceDiscovery();
    return (await navigator.mediaDevices.enumerateDevices())
        .whereType<MediaDeviceInfo>()
        .toList(growable: false);
  }

  Future<String?> _resolveCallInputDeviceId(AudioDeviceOption? option) async {
    if (option == null) {
      return null;
    }
    if (option.callDeviceId != null && option.callDeviceId!.isNotEmpty) {
      return option.callDeviceId;
    }

    final devices = await _listWebRtcInputDevices();
    return _matchWebRtcDeviceId(option.label, devices);
  }

  Future<String?> _resolveCallOutputDeviceId(AudioDeviceOption? option) async {
    if (option == null) {
      return null;
    }
    if (option.callDeviceId != null && option.callDeviceId!.isNotEmpty) {
      return option.callDeviceId;
    }

    final devices = await _listWebRtcOutputDevices();
    return _matchWebRtcDeviceId(option.label, devices);
  }

  Future<List<String>> _inputDeviceCandidates(AudioDeviceOption? option) async {
    if (option == null) {
      return const <String>[];
    }

    final candidates = <String>[
      if (option.callDeviceId != null) option.callDeviceId!,
      if (option.systemDeviceId != null) option.systemDeviceId!,
      option.id,
      if (await _resolveCallInputDeviceId(option) case final resolved?)
        resolved,
    ];

    return _dedupeDeviceCandidates(candidates);
  }

  Future<List<String>> _outputDeviceCandidates(
      AudioDeviceOption? option) async {
    if (option == null) {
      return const <String>[];
    }

    final candidates = <String>[
      if (option.callDeviceId != null) option.callDeviceId!,
      if (option.systemDeviceId != null) option.systemDeviceId!,
      option.id,
      if (await _resolveCallOutputDeviceId(option) case final resolved?)
        resolved,
    ];

    return _dedupeDeviceCandidates(candidates);
  }

  List<String> _dedupeDeviceCandidates(List<String> candidates) {
    final seen = <String>{};
    return candidates
        .where((candidate) => candidate.trim().isNotEmpty)
        .where((candidate) => seen.add(candidate))
        .toList(growable: false);
  }

  String? _matchWebRtcDeviceId(
    String label,
    List<AudioDeviceOption> devices,
  ) {
    final normalized = _normalizeComparisonLabel(label);

    for (final device in devices) {
      if (_normalizeComparisonLabel(device.label) == normalized) {
        return device.callDeviceId ?? device.id;
      }
    }

    for (final device in devices) {
      final candidate = _normalizeComparisonLabel(device.label);
      if (candidate.contains(normalized) || normalized.contains(candidate)) {
        return device.callDeviceId ?? device.id;
      }
    }

    return null;
  }

  Future<void> _primeWebRtcDeviceDiscovery() async {
    MediaStream? stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
    } catch (_) {
      return;
    } finally {
      if (stream != null) {
        for (final track in stream.getTracks()) {
          track.stop();
        }
        await stream.dispose();
      }
    }
  }

  String _normalizeComparisonLabel(String value) {
    return value.trim().toLowerCase();
  }

  PrivacyPermissionKind _privacyKindFromNative(String? value) {
    return switch (value) {
      'launchAtStartup' => PrivacyPermissionKind.launchAtStartup,
      _ => PrivacyPermissionKind.microphone,
    };
  }
}
