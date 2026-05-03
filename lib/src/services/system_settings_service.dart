import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

    final nativeDeviceId = option?.callDeviceId ?? option?.id ?? deviceId;
    if (nativeDeviceId.startsWith('pjsip:')) {
      await _nativeSoftphoneChannel.invokeMethod<void>(
        'setAudioInput',
        {'deviceId': nativeDeviceId},
      );
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

    final nativeDeviceId = option?.callDeviceId ?? option?.id ?? deviceId;
    if (nativeDeviceId.startsWith('pjsip:')) {
      await _nativeSoftphoneChannel.invokeMethod<void>(
        'setAudioOutput',
        {'deviceId': nativeDeviceId},
      );
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
      return _listPjsipDevices('listAudioInputs', 'Micro');
    } catch (_) {
      return const <AudioDeviceOption>[];
    }
  }

  Future<List<AudioDeviceOption>> _listCallOutputDevices() async {
    if (!_isNativeDesktop) {
      return const <AudioDeviceOption>[];
    }

    try {
      return _listPjsipDevices('listAudioOutputs', 'Sortie');
    } catch (_) {
      return const <AudioDeviceOption>[];
    }
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

  PrivacyPermissionKind _privacyKindFromNative(String? value) {
    return switch (value) {
      'launchAtStartup' => PrivacyPermissionKind.launchAtStartup,
      _ => PrivacyPermissionKind.microphone,
    };
  }
}
