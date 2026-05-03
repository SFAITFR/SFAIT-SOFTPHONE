import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/app_update.dart';

typedef UpdateProgressCallback = void Function(int downloaded, int? total);

class UpdateService {
  static const currentVersion = String.fromEnvironment(
    'SFAIT_APP_VERSION',
    defaultValue: '1.0.0',
  );
  static const _repository = 'SFAITFR/SFAIT-SOFTPHONE';
  static const _releaseAssetPrefix = 'sfait-softphone';
  static const _updaterChannel = MethodChannel('sfait/updater');

  bool get isSupported => !kIsWeb && Platform.isMacOS;

  Future<AppUpdateInfo?> checkForUpdate() async {
    if (!isSupported) {
      return null;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$_repository/releases/latest'),
      );
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'SFAIT Softphone');

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Impossible de vérifier les mises à jour (${response.statusCode}).',
        );
      }

      final release = jsonDecode(body) as Map<String, dynamic>;
      if (release['draft'] == true || release['prerelease'] == true) {
        return null;
      }

      final tagName = (release['tag_name'] as String? ?? '').trim();
      if (tagName.isEmpty) {
        return null;
      }

      final latestVersion = tagName.replaceFirst(RegExp(r'^[vV]'), '');
      if (_compareVersions(latestVersion, currentVersion) <= 0) {
        return null;
      }

      final assets = (release['assets'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      final asset = _selectAsset(assets, latestVersion);
      if (asset == null) {
        throw StateError(
          'Aucun installateur compatible trouvé pour la version $tagName.',
        );
      }

      return AppUpdateInfo(
        version: latestVersion,
        tagName: tagName,
        releaseUrl: release['html_url'] as String? ??
            'https://github.com/$_repository/releases/tag/$tagName',
        downloadUrl: asset['browser_download_url'] as String? ?? '',
        assetName: asset['name'] as String? ?? '',
        releaseNotes: release['body'] as String? ?? '',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<File> downloadUpdate(
    AppUpdateInfo update, {
    UpdateProgressCallback? onProgress,
  }) async {
    if (update.downloadUrl.isEmpty) {
      throw StateError('URL de téléchargement absente.');
    }

    final updatesDirectory = Directory(
      '${Directory.systemTemp.path}/sfait-softphone-updates/${update.tagName}',
    );
    await updatesDirectory.create(recursive: true);
    final target = File('${updatesDirectory.path}/${update.assetName}');
    if (await target.exists()) {
      await target.delete();
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(update.downloadUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'SFAIT Softphone');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Téléchargement impossible (${response.statusCode}).',
        );
      }

      final total = response.contentLength > 0 ? response.contentLength : null;
      var downloaded = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in response) {
          downloaded += chunk.length;
          sink.add(chunk);
          onProgress?.call(downloaded, total);
        }
      } finally {
        await sink.close();
      }

      onProgress?.call(downloaded, total);
      return target;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> installUpdate(File installer) async {
    if (!isSupported) {
      throw StateError('Les mises à jour automatiques macOS uniquement.');
    }

    await _updaterChannel.invokeMethod<void>(
      'installUpdateFromDmg',
      {'dmgPath': installer.path},
    );
  }

  Map<String, dynamic>? _selectAsset(
    List<Map<String, dynamic>> assets,
    String version,
  ) {
    final arch = Abi.current() == Abi.macosArm64 ? 'arm64' : 'x86_64';
    final expectedName = '$_releaseAssetPrefix-$version-$arch.dmg';

    Map<String, dynamic>? byName(String name) {
      return assets.cast<Map<String, dynamic>?>().firstWhere(
            (asset) => asset?['name'] == name,
            orElse: () => null,
          );
    }

    final exact = byName(expectedName);
    if (exact != null) {
      return exact;
    }

    return assets.cast<Map<String, dynamic>?>().firstWhere(
      (asset) {
        final name = (asset?['name'] as String? ?? '').toLowerCase();
        return name.endsWith('.dmg') &&
            name.contains(version.toLowerCase()) &&
            name.contains(arch.toLowerCase());
      },
      orElse: () => null,
    );
  }

  int _compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    final maxLength = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;

    for (var index = 0; index < maxLength; index += 1) {
      final leftValue = index < leftParts.length ? leftParts[index] : 0;
      final rightValue = index < rightParts.length ? rightParts[index] : 0;
      if (leftValue != rightValue) {
        return leftValue.compareTo(rightValue);
      }
    }
    return 0;
  }

  List<int> _versionParts(String version) {
    return version
        .split(RegExp(r'[.+-]'))
        .take(3)
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
  }
}
