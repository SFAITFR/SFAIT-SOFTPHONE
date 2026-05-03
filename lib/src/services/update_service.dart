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
    defaultValue: '1.0.1',
  );
  static const _repository = 'SFAITFR/SFAIT-SOFTPHONE';
  static const _releaseAssetPrefix = 'sfait-softphone';
  static const _windowsInstallerAsset = 'SFAIT_Softphone_installer.msi';
  static const _windowsSetupAsset = 'SFAIT_Softphone_setup.exe';
  static const _windowsPortableAsset = 'SFAIT_Softphone_windows_x64.zip';
  static const _updaterChannel = MethodChannel('sfait/updater');

  bool get isSupported => !kIsWeb && (Platform.isMacOS || Platform.isWindows);

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
      throw StateError(
        'Les mises à jour automatiques ne sont pas disponibles sur cette plateforme.',
      );
    }

    if (Platform.isMacOS) {
      await _updaterChannel.invokeMethod<void>(
        'installUpdateFromDmg',
        {'dmgPath': installer.path},
      );
      return;
    }

    if (Platform.isWindows) {
      await _installWindowsUpdate(installer);
      return;
    }
  }

  Map<String, dynamic>? _selectAsset(
    List<Map<String, dynamic>> assets,
    String version,
  ) {
    if (Platform.isWindows) {
      return _selectWindowsAsset(assets, version);
    }

    final arch = Abi.current() == Abi.macosArm64 ? 'arm64' : 'x86_64';
    final expectedName = '$_releaseAssetPrefix-$version-$arch.dmg';

    final exact = _assetByName(assets, expectedName);
    if (exact != null) {
      return exact;
    }

    return _firstAssetWhere(
      assets,
      (asset) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        return name.endsWith('.dmg') &&
            name.contains(version.toLowerCase()) &&
            name.contains(arch.toLowerCase());
      },
    );
  }

  Map<String, dynamic>? _selectWindowsAsset(
    List<Map<String, dynamic>> assets,
    String version,
  ) {
    final arch = Abi.current() == Abi.windowsArm64 ? 'arm64' : 'x64';
    final expectedNames = <String>[
      _windowsInstallerAsset,
      _windowsSetupAsset,
      _windowsPortableAsset,
      '$_releaseAssetPrefix-$version-windows-$arch.msi',
      '$_releaseAssetPrefix-$version-$arch.msi',
      '$_releaseAssetPrefix-$version-windows-$arch.exe',
      '$_releaseAssetPrefix-$version-$arch.exe',
      '$_releaseAssetPrefix-$version-windows-$arch.zip',
      '$_releaseAssetPrefix-$version-$arch.zip',
    ];

    for (final expectedName in expectedNames) {
      final exact = _assetByName(assets, expectedName);
      if (exact != null) {
        return exact;
      }
    }

    final versionLower = version.toLowerCase();
    final archLower = arch.toLowerCase();
    final versionedInstaller = _firstAssetWhere(assets, (asset) {
      final name = (asset['name'] as String? ?? '').toLowerCase();
      return _isWindowsUpdateAsset(name) &&
          name.contains(versionLower) &&
          name.contains(archLower);
    });
    if (versionedInstaller != null) {
      return versionedInstaller;
    }

    return _firstAssetWhere(assets, (asset) {
      final name = (asset['name'] as String? ?? '').toLowerCase();
      return _isWindowsUpdateAsset(name) &&
          name.contains('sfait') &&
          name.contains('softphone');
    });
  }

  Map<String, dynamic>? _assetByName(
    List<Map<String, dynamic>> assets,
    String name,
  ) {
    return _firstAssetWhere(
      assets,
      (asset) => asset['name'] == name,
    );
  }

  Map<String, dynamic>? _firstAssetWhere(
    List<Map<String, dynamic>> assets,
    bool Function(Map<String, dynamic> asset) test,
  ) {
    for (final asset in assets) {
      if (test(asset)) {
        return asset;
      }
    }
    return null;
  }

  bool _isWindowsUpdateAsset(String name) {
    if (name.endsWith('.msi') || name.endsWith('.zip')) {
      return true;
    }

    return name.endsWith('.exe') &&
        (name.contains('setup') || name.contains('install'));
  }

  Future<void> _installWindowsUpdate(File installer) async {
    final path = installer.path;
    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('.msi')) {
      await _installWindowsMsiUpdate(installer);
      return;
    } else if (lowerPath.endsWith('.exe')) {
      await Process.start(
        path,
        const <String>[],
        mode: ProcessStartMode.detached,
      );
    } else if (lowerPath.endsWith('.zip')) {
      await _installWindowsZipUpdate(installer);
      return;
    } else {
      throw StateError('Installateur Windows non pris en charge.');
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }

  Future<void> _installWindowsMsiUpdate(File installer) async {
    final script = File(
      '${Directory.systemTemp.path}/sfait-softphone-updates/install-msi-${DateTime.now().millisecondsSinceEpoch}.ps1',
    );
    await script.parent.create(recursive: true);
    await script.writeAsString(
      _windowsMsiUpdateScript(
        msiPath: installer.path,
        processId: pid,
      ),
    );

    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
      ],
      mode: ProcessStartMode.detached,
    );

    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }

  Future<void> _installWindowsZipUpdate(File archive) async {
    final appDirectory = File(Platform.resolvedExecutable).parent;
    final script = File(
      '${Directory.systemTemp.path}/sfait-softphone-updates/install-${DateTime.now().millisecondsSinceEpoch}.ps1',
    );
    await script.parent.create(recursive: true);
    await script.writeAsString(
      _windowsZipUpdateScript(
        zipPath: archive.path,
        targetDirectory: appDirectory.path,
        processId: pid,
      ),
    );

    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
      ],
      mode: ProcessStartMode.detached,
    );

    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }

  String _windowsZipUpdateScript({
    required String zipPath,
    required String targetDirectory,
    required int processId,
  }) {
    final quotedZip = _powerShellSingleQuoted(zipPath);
    final quotedTarget = _powerShellSingleQuoted(targetDirectory);
    return '''
\$ErrorActionPreference = 'Stop'
\$zipPath = $quotedZip
\$targetDirectory = $quotedTarget
\$processId = $processId

try {
  Wait-Process -Id \$processId -Timeout 45 -ErrorAction SilentlyContinue
} catch {
}

\$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sfait-softphone-update-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path \$stageRoot -Force | Out-Null

try {
  Expand-Archive -LiteralPath \$zipPath -DestinationPath \$stageRoot -Force
  \$sourceDirectory = \$stageRoot
  \$nestedDirectory = Join-Path \$stageRoot 'SFAIT Softphone'
  if (Test-Path (Join-Path \$nestedDirectory 'sfait_softphone.exe')) {
    \$sourceDirectory = \$nestedDirectory
  }

  Copy-Item -Path (Join-Path \$sourceDirectory '*') -Destination \$targetDirectory -Recurse -Force
} finally {
  if (Test-Path \$stageRoot) {
    Remove-Item -LiteralPath \$stageRoot -Recurse -Force
  }
}

\$exePath = Join-Path \$targetDirectory 'sfait_softphone.exe'
if (Test-Path \$exePath) {
  Start-Process -FilePath \$exePath
}
''';
  }

  String _windowsMsiUpdateScript({
    required String msiPath,
    required int processId,
  }) {
    final quotedMsi = _powerShellSingleQuoted(msiPath);
    return '''
\$ErrorActionPreference = 'Stop'
\$msiPath = $quotedMsi
\$processId = $processId
\$logPath = Join-Path ([System.IO.Path]::GetTempPath()) 'sfait-softphone-msi-update.log'

try {
  Wait-Process -Id \$processId -Timeout 45 -ErrorAction SilentlyContinue
} catch {
}

\$quotedMsiPath = '"' + \$msiPath + '"'
\$quotedLogPath = '"' + \$logPath + '"'
\$arguments = "/i \$quotedMsiPath /qn /norestart /l*v \$quotedLogPath"
\$installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList \$arguments -Wait -PassThru

if (\$installer.ExitCode -ne 0 -and \$installer.ExitCode -ne 1641 -and \$installer.ExitCode -ne 3010) {
  \$interactiveArguments = "/i \$quotedMsiPath /l*v \$quotedLogPath"
  \$installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList \$interactiveArguments -Wait -PassThru
}

if (\$installer.ExitCode -eq 0 -or \$installer.ExitCode -eq 1641 -or \$installer.ExitCode -eq 3010) {
  \$installDirectory = Join-Path \$env:LOCALAPPDATA 'Programs\\SFAIT Softphone'
  \$exePath = Join-Path \$installDirectory 'sfait_softphone.exe'
  if (Test-Path -LiteralPath \$exePath) {
    Start-Process -FilePath \$exePath
  }
}
''';
  }

  String _powerShellSingleQuoted(String value) {
    return "'${value.replaceAll("'", "''")}'";
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
