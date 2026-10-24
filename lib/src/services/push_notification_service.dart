import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sip_account.dart';

class PushNotificationService {
  static const _channel = MethodChannel('sfait/push_notifications');
  static const _gatewayUrl = String.fromEnvironment(
    'SFAIT_PUSH_GATEWAY_URL',
    defaultValue: 'http://192.168.1.80:8088',
  );
  static const _registrationKey = String.fromEnvironment(
    'SFAIT_PUSH_REGISTRATION_KEY',
    defaultValue: '',
  );
  static const _deviceIdPreferenceKey = 'sfait_android_push_device_id';

  bool get isSupported => !kIsWeb && Platform.isAndroid;
  bool get isConfigured => _gatewayUrl.trim().isNotEmpty;

  Future<Map<String, dynamic>?> buildSipPushContactUriParams(
    SipAccount account,
  ) async {
    if (!isSupported || !isConfigured || _registrationKey.isEmpty) {
      return null;
    }

    final extension = account.extension.trim();
    if (extension.isEmpty) {
      return null;
    }

    return {
      'pn-provider': 'fcm',
      'pn-prid': await _loadOrCreateDeviceId(),
      'pn-param': extension,
    };
  }

  Future<void> registerAndroidDevice(SipAccount account) async {
    if (!isSupported || !isConfigured || _registrationKey.isEmpty) {
      return;
    }

    final extension = account.extension.trim();
    if (extension.isEmpty) {
      return;
    }

    final token = await _channel.invokeMethod<String>('getFcmToken');
    if (token == null || token.trim().isEmpty) {
      return;
    }

    final deviceId = await _loadOrCreateDeviceId();
    await _postJson('/v1/register', {
      'extension': extension,
      'fcmToken': token,
      'deviceId': deviceId,
      'platform': 'android',
      'label': 'SFAIT Softphone Android',
    });
  }

  Future<String> _loadOrCreateDeviceId() async {
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(_deviceIdPreferenceKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final created = 'android-${DateTime.now().microsecondsSinceEpoch}';
    await preferences.setString(_deviceIdPreferenceKey, created);
    return created;
  }

  Future<void> _postJson(String path, Map<String, Object?> body) async {
    final baseUri = Uri.parse(_gatewayUrl.trim());
    final uri = baseUri.replace(
      path: _joinPaths(baseUri.path, path),
    );
    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set('x-api-key', _registrationKey);
      request.write(jsonEncode(body));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final payload = await response.transform(utf8.decoder).join();
        throw StateError(
          'Enregistrement push refusé (${response.statusCode}) : $payload',
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  String _joinPaths(String basePath, String childPath) {
    final base = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    final child = childPath.startsWith('/') ? childPath : '/$childPath';
    return '$base$child';
  }
}
