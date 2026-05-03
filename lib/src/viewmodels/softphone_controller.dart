import 'dart:async';

import 'package:flutter/material.dart';

import '../models/audio_device_option.dart';
import '../models/call_log_entry.dart';
import '../models/codec_option.dart';
import '../models/general_settings.dart';
import '../models/privacy_permission_status.dart';
import '../models/sip_account.dart';
import '../models/softphone_status.dart';
import '../services/dtmf_tone_service.dart';
import '../services/preferences_service.dart';
import '../services/ringtone_service.dart';
import '../services/softphone_service.dart';
import '../services/system_settings_service.dart';

class SoftphoneController extends ChangeNotifier {
  SoftphoneController(
    this._preferencesService, {
    SoftphoneService? service,
    DtmfToneService? toneService,
    RingtoneService? ringtoneService,
    SystemSettingsService? systemSettingsService,
  })  : _service = service ?? SoftphoneService(),
        _toneService = toneService ?? DtmfToneService(),
        _ringtoneService = ringtoneService ?? RingtoneService(),
        _systemSettingsService =
            systemSettingsService ?? SystemSettingsService() {
    _serviceEventsSubscription = _service.events.listen(_handleServiceEvent);
  }

  final PreferencesService _preferencesService;
  final SoftphoneService _service;
  final DtmfToneService _toneService;
  final RingtoneService _ringtoneService;
  final SystemSettingsService _systemSettingsService;
  late final StreamSubscription<SoftphoneServiceEvent>
      _serviceEventsSubscription;

  SipAccount _account = SipAccount.empty;
  SoftphoneConnectionStatus _status = SoftphoneConnectionStatus.offline;
  final List<CallLogEntry> _history = <CallLogEntry>[];
  String _destination = '';
  String _statusMessage = 'Softphone prêt à être configuré.';
  String _settingsStatusMessage = '';
  String _activeRemoteIdentity = '';
  bool _isMuted = false;
  bool _isOnHold = false;
  int _requestVersion = 0;
  Timer? _settingsStatusClearTimer;
  GeneralSettings _generalSettings = GeneralSettings.defaults;
  List<AudioDeviceOption> _audioInputs = const <AudioDeviceOption>[];
  List<AudioDeviceOption> _audioOutputs = const <AudioDeviceOption>[];
  List<AudioDeviceOption> _ringtoneOutputs = const <AudioDeviceOption>[];
  List<CodecOption> _audioCodecs = const <CodecOption>[];
  List<PrivacyPermissionStatus> _privacyPermissions =
      const <PrivacyPermissionStatus>[];

  SipAccount get account => _account;
  SoftphoneConnectionStatus get status => _status;
  List<CallLogEntry> get history => List.unmodifiable(_history);
  String get destination => _destination;
  String get statusMessage => _statusMessage;
  String get settingsStatusMessage => _settingsStatusMessage;
  String get activeRemoteIdentity => _activeRemoteIdentity;
  bool get isMuted => _isMuted;
  bool get isOnHold => _isOnHold;
  GeneralSettings get generalSettings => _generalSettings;
  List<AudioDeviceOption> get audioInputs => List.unmodifiable(_audioInputs);
  List<AudioDeviceOption> get audioOutputs => List.unmodifiable(_audioOutputs);
  List<AudioDeviceOption> get ringtoneOutputs =>
      List.unmodifiable(_ringtoneOutputs);
  List<CodecOption> get audioCodecs => List.unmodifiable(_audioCodecs);
  List<PrivacyPermissionStatus> get privacyPermissions =>
      List.unmodifiable(_privacyPermissions);
  ThemeMode get themeMode => _generalSettings.themeMode;

  bool get canConnect =>
      _account.domain.isNotEmpty &&
      _account.extension.isNotEmpty &&
      _account.password.isNotEmpty;
  bool get inCall => _status == SoftphoneConnectionStatus.inCall;
  bool get ringing => _status == SoftphoneConnectionStatus.ringing;
  bool get calling => _status == SoftphoneConnectionStatus.calling;
  bool get isRegistered => _status == SoftphoneConnectionStatus.registered;
  bool get canPlaceCall => isRegistered && _destination.trim().isNotEmpty;
  bool get canHangup => inCall || ringing || calling;
  bool get canToggleMute => inCall;
  bool get canToggleHold => inCall;
  bool get canSendDtmf => inCall;
  bool get showCallOverlay => ringing || inCall;
  bool get canTransfer => inCall;

  void bootstrap() {
    _account = _preferencesService.loadAccount();
    _generalSettings = _preferencesService.loadGeneralSettings();
    _history
      ..clear()
      ..addAll(_preferencesService.loadHistory());
    _statusMessage = canConnect
        ? 'Configuration SIP chargée. Prêt à se connecter.'
        : 'Renseignez vos identifiants SIP pour démarrer.';
    notifyListeners();

    if (canConnect) {
      unawaited(
        Future<void>.microtask(() => connect()),
      );
    }

    unawaited(_initializeGeneralSettings());
  }

  Future<void> saveAccount(SipAccount account) async {
    _account = account;
    await _preferencesService.saveAccount(account);
    _setSettingsStatusMessage('Configuration sauvegardée localement.');
    notifyListeners();
  }

  Future<void> saveAndConnect(
    SipAccount account, {
    String? preferredCodecId,
  }) async {
    final shouldReuseExistingSession = _hasSameConnectionSettings(account) &&
        (_status == SoftphoneConnectionStatus.registered ||
            _status == SoftphoneConnectionStatus.connecting);

    if (preferredCodecId != null) {
      try {
        await _saveAndApplyPreferredCodec(
          preferredCodecId,
          showStatusMessage: false,
        );
      } catch (error) {
        _setSettingsStatusMessage(_formatError(error));
        notifyListeners();
        return;
      }
    }

    await saveAccount(account);

    if (shouldReuseExistingSession) {
      _setSettingsStatusMessage(
        _status == SoftphoneConnectionStatus.registered
            ? 'Configuration appliquée. Compte déjà connecté.'
            : 'Configuration appliquée. Connexion déjà en cours...',
      );
      notifyListeners();
      return;
    }

    _setSettingsStatusMessage('Configuration appliquée. Connexion en cours...');
    notifyListeners();
    await connect();
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _preferencesService.clearHistory();
    notifyListeners();
  }

  void setDestination(String value) {
    _destination = value;
    notifyListeners();
  }

  void eraseLastDigit() {
    if (_destination.isEmpty) {
      return;
    }
    _destination = _destination.substring(0, _destination.length - 1);
    notifyListeners();
  }

  void clearDestination() {
    if (_destination.isEmpty) {
      return;
    }
    _destination = '';
    notifyListeners();
  }

  Future<void> handleDigit(String digit) async {
    unawaited(_toneService.play(digit));

    if (canSendDtmf) {
      try {
        await _service.sendDtmf(digit);
      } catch (error) {
        _status = SoftphoneConnectionStatus.error;
        _statusMessage = _formatError(error);
      }
      notifyListeners();
      return;
    }

    _destination = '$_destination$digit';
    notifyListeners();
  }

  Future<void> connect() async {
    final requestId = ++_requestVersion;
    _status = SoftphoneConnectionStatus.connecting;
    _statusMessage = 'Connexion au compte ${_account.extension}...';
    notifyListeners();

    try {
      await _service.connect(_account);
    } catch (error) {
      if (requestId != _requestVersion) {
        return;
      }
      _status = SoftphoneConnectionStatus.error;
      _statusMessage = _formatError(error);
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    final requestId = ++_requestVersion;
    try {
      await _service.disconnect();
    } catch (error) {
      if (requestId != _requestVersion) {
        return;
      }
      _status = SoftphoneConnectionStatus.error;
      _statusMessage = _formatError(error);
      notifyListeners();
    }
  }

  Future<void> placeCall() async {
    final requestId = ++_requestVersion;
    try {
      await _applyCallAudioRoutingBeforeMediaStart();
      await _service.placeCall(_destination);
    } catch (error) {
      if (requestId != _requestVersion) {
        return;
      }
      _status = SoftphoneConnectionStatus.error;
      _statusMessage = _formatError(error);
      notifyListeners();
    }
  }

  Future<void> answer() async {
    final requestId = ++_requestVersion;
    try {
      await _applyCallAudioRoutingBeforeMediaStart();
      await _service.answer();
    } catch (error) {
      if (requestId != _requestVersion) {
        return;
      }
      _status = SoftphoneConnectionStatus.error;
      _statusMessage = _formatError(error);
      notifyListeners();
    }
  }

  Future<void> hangup() async {
    final requestId = ++_requestVersion;
    try {
      await _service.hangup();
    } catch (error) {
      if (requestId != _requestVersion) {
        return;
      }
      _status = SoftphoneConnectionStatus.error;
      _statusMessage = _formatError(error);
      notifyListeners();
    }
  }

  Future<void> toggleMute() async {
    final requestId = ++_requestVersion;
    try {
      await _service.toggleMute();
    } catch (error) {
      if (requestId != _requestVersion) {
        return;
      }
      _status = SoftphoneConnectionStatus.error;
      _statusMessage = _formatError(error);
      notifyListeners();
    }
  }

  Future<void> toggleHold() async {
    final requestId = ++_requestVersion;
    try {
      await _service.toggleHold();
    } catch (error) {
      if (requestId != _requestVersion) {
        return;
      }
      _status = SoftphoneConnectionStatus.error;
      _statusMessage = _formatError(error);
      notifyListeners();
    }
  }

  Future<void> transfer(String destination) async {
    final requestId = ++_requestVersion;
    try {
      await _service.transfer(destination);
      if (requestId != _requestVersion) {
        return;
      }
      _statusMessage = 'Transfert demandé vers ${destination.trim()}.';
      notifyListeners();
    } catch (error) {
      if (requestId != _requestVersion) {
        return;
      }
      _status = SoftphoneConnectionStatus.error;
      _statusMessage = _formatError(error);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _settingsStatusClearTimer?.cancel();
    unawaited(_ringtoneService.stop());
    unawaited(_toneService.dispose());
    unawaited(_service.dispose());
    _serviceEventsSubscription.cancel();
    super.dispose();
  }

  void _handleServiceEvent(SoftphoneServiceEvent event) {
    final previousStatus = _status;
    final remoteIdentity = event.remoteIdentity?.trim();
    final isIdleStatus = event.status == SoftphoneConnectionStatus.registered ||
        event.status == SoftphoneConnectionStatus.offline;
    _status = event.status;
    _statusMessage = event.message;
    if (isIdleStatus) {
      _activeRemoteIdentity = '';
    } else if (remoteIdentity != null && remoteIdentity.isNotEmpty) {
      _activeRemoteIdentity = remoteIdentity;
    }
    if (event.isMuted != null) {
      _isMuted = event.isMuted!;
    }
    if (event.isOnHold != null) {
      _isOnHold = event.isOnHold!;
    }

    if (event.status == SoftphoneConnectionStatus.registered ||
        event.status == SoftphoneConnectionStatus.offline) {
      _isMuted = false;
      _isOnHold = false;
    }

    if (event.historyDirection != null && event.historySummary != null) {
      _history.insert(
        0,
        CallLogEntry(
          direction: event.historyDirection!,
          remoteIdentity: event.remoteIdentity ?? 'Inconnu',
          at: DateTime.now(),
          summary: event.historySummary!,
        ),
      );
      unawaited(_preferencesService.saveHistory(_history));
    }

    if (event.status == SoftphoneConnectionStatus.ringing &&
        previousStatus != SoftphoneConnectionStatus.ringing) {
      unawaited(_systemSettingsService.showWindowForIncomingCall());
      unawaited(
        _ringtoneService.play(
          outputDeviceId: _generalSettings.ringtoneOutputId,
          filePath: _generalSettings.ringtoneFilePath,
          volume: _generalSettings.ringtoneVolume,
        ),
      );
    } else if (previousStatus == SoftphoneConnectionStatus.ringing &&
        event.status != SoftphoneConnectionStatus.ringing) {
      unawaited(_ringtoneService.stop());
    } else if (event.status == SoftphoneConnectionStatus.inCall ||
        event.status == SoftphoneConnectionStatus.offline ||
        event.status == SoftphoneConnectionStatus.error ||
        event.status == SoftphoneConnectionStatus.registered ||
        event.status == SoftphoneConnectionStatus.calling) {
      unawaited(_ringtoneService.stop());
    }

    notifyListeners();
  }

  String _formatError(Object error) {
    final raw = error.toString();
    if (raw.startsWith('Bad state: ')) {
      return raw.substring('Bad state: '.length);
    }
    return raw;
  }

  bool _hasSameConnectionSettings(SipAccount next) {
    return _account.domain.trim() == next.domain.trim() &&
        _account.extension.trim() == next.extension.trim() &&
        _account.authorizationId.trim() == next.authorizationId.trim() &&
        _account.password == next.password &&
        _account.displayName.trim() == next.displayName.trim();
  }

  Future<void> updateThemePreference(AppThemePreference preference) async {
    _generalSettings = _generalSettings.copyWith(themePreference: preference);
    await _preferencesService.saveGeneralSettings(_generalSettings);
    notifyListeners();
  }

  Future<void> updateLaunchAtStartup(bool enabled) async {
    try {
      await _systemSettingsService.setLaunchAtStartupEnabled(enabled);
      final actualValue =
          await _systemSettingsService.getLaunchAtStartupEnabled();
      _generalSettings = _generalSettings.copyWith(
        launchAtStartup: actualValue,
      );
      await _preferencesService.saveGeneralSettings(_generalSettings);
      notifyListeners();
    } catch (_) {
      // Best effort on platform-specific startup integration.
    }
  }

  Future<void> updateMenuBarIconVisibility(bool enabled) async {
    var nextSettings = _generalSettings.copyWith(showMenuBarIcon: enabled);
    if (!nextSettings.showMenuBarIcon && !nextSettings.showDockIcon) {
      nextSettings = nextSettings.copyWith(showDockIcon: true);
    }

    await _saveAndApplyPresentationSettings(nextSettings);
  }

  Future<void> updateDockIconVisibility(bool enabled) async {
    var nextSettings = _generalSettings.copyWith(showDockIcon: enabled);
    if (!nextSettings.showMenuBarIcon && !nextSettings.showDockIcon) {
      nextSettings = nextSettings.copyWith(showMenuBarIcon: true);
    }

    await _saveAndApplyPresentationSettings(nextSettings);
  }

  Future<void> updateAudioInput(String deviceId) async {
    try {
      _generalSettings = _generalSettings.copyWith(audioInputId: deviceId);
      await _preferencesService.saveGeneralSettings(_generalSettings);
      if (!inCall && !calling && !ringing) {
        await _systemSettingsService.selectAudioInput(deviceId);
      } else {
        _setSettingsStatusMessage(
          'Micro mémorisé. Il sera appliqué au prochain appel.',
        );
      }
      notifyListeners();
    } catch (_) {
      // Best effort on audio routing.
    }
  }

  Future<void> updateAudioOutput(String deviceId) async {
    try {
      _generalSettings = _generalSettings.copyWith(audioOutputId: deviceId);
      await _preferencesService.saveGeneralSettings(_generalSettings);
      if (!inCall && !calling && !ringing) {
        await _systemSettingsService.selectAudioOutput(deviceId);
      } else {
        _setSettingsStatusMessage(
          'Haut-parleur mémorisé. Il sera appliqué au prochain appel.',
        );
      }
      notifyListeners();
    } catch (_) {
      // Best effort on audio routing.
    }
  }

  Future<void> updateRingtoneOutput(String deviceId) async {
    _generalSettings = _generalSettings.copyWith(ringtoneOutputId: deviceId);
    await _preferencesService.saveGeneralSettings(_generalSettings);
    notifyListeners();
  }

  Future<void> updateRingtoneVolume(double volume) async {
    final normalizedVolume = volume.clamp(0.0, 1.0).toDouble();
    _generalSettings = _generalSettings.copyWith(
      ringtoneVolume: normalizedVolume,
    );
    await _preferencesService.saveGeneralSettings(_generalSettings);
    if (ringing) {
      unawaited(_ringtoneService.setVolume(normalizedVolume));
    }
    notifyListeners();
  }

  Future<void> updatePreferredCodec(String codecId) async {
    try {
      await _saveAndApplyPreferredCodec(
        codecId,
        showStatusMessage: true,
      );
      notifyListeners();
    } catch (error) {
      _setSettingsStatusMessage(_formatError(error));
      notifyListeners();
    }
  }

  Future<void> importCustomRingtone() async {
    try {
      _setSettingsStatusMessage('Ouverture du sélecteur de fichier...');
      notifyListeners();

      final imported = await _ringtoneService.importCustomRingtone();
      if (imported == null) {
        _setSettingsStatusMessage('');
        notifyListeners();
        return;
      }

      _generalSettings = _generalSettings.copyWith(
        ringtoneFilePath: imported.path,
        ringtoneFileName: imported.name,
      );
      _setSettingsStatusMessage('');
      await _preferencesService.saveGeneralSettings(_generalSettings);
      notifyListeners();
    } catch (error) {
      _setSettingsStatusMessage(_formatError(error));
      notifyListeners();
    }
  }

  Future<void> refreshPrivacyPermissions() async {
    try {
      _privacyPermissions =
          await _systemSettingsService.getPrivacyPermissions();
      notifyListeners();
    } catch (_) {
      // Best effort on macOS-specific privacy status.
    }
  }

  Future<void> openPrivacyPermissionSettings(
    PrivacyPermissionKind kind,
  ) async {
    try {
      await _systemSettingsService.openPrivacyPermissionSettings(kind);
      unawaited(
          _refreshPrivacyPermissionsAfterDelay(const Duration(seconds: 1)));
      unawaited(
          _refreshPrivacyPermissionsAfterDelay(const Duration(seconds: 3)));
      unawaited(
          _refreshPrivacyPermissionsAfterDelay(const Duration(seconds: 6)));
    } catch (_) {
      // Best effort; macOS may reject old preference pane URLs.
    }
  }

  Future<void> _refreshPrivacyPermissionsAfterDelay(Duration delay) async {
    await Future<void>.delayed(delay);
    await refreshPrivacyPermissions();
  }

  Future<void> _initializeGeneralSettings() async {
    try {
      final launchEnabled =
          await _systemSettingsService.getLaunchAtStartupEnabled();
      final audioInputs = await _systemSettingsService.getAudioInputs();
      final audioOutputs = await _systemSettingsService.getAudioOutputs();
      final ringtoneOutputs = await _systemSettingsService.getRingtoneOutputs();
      final audioCodecs = await _systemSettingsService.getAudioCodecs();
      final privacyPermissions =
          await _systemSettingsService.getPrivacyPermissions();

      _audioInputs = audioInputs;
      _audioOutputs = audioOutputs;
      _ringtoneOutputs = ringtoneOutputs;
      _audioCodecs = audioCodecs;
      _privacyPermissions = privacyPermissions;
      _generalSettings = _generalSettings.copyWith(
        launchAtStartup: launchEnabled,
        audioInputId: _coerceSelectedDevice(
          _generalSettings.audioInputId,
          audioInputs,
        ),
        audioOutputId: _coerceSelectedDevice(
          _generalSettings.audioOutputId,
          audioOutputs,
        ),
        ringtoneOutputId: _coerceSelectedDevice(
          _generalSettings.ringtoneOutputId,
          ringtoneOutputs,
        ),
        preferredCodecId: _coerceSelectedCodec(
          _generalSettings.preferredCodecId,
          audioCodecs,
        ),
      );
      await _preferencesService.saveGeneralSettings(_generalSettings);
      await _systemSettingsService.selectPreferredCodec(
        _generalSettings.preferredCodecId,
      );
      await _applyPresentationSettings();
      notifyListeners();
    } catch (_) {
      // Best effort on desktop capabilities.
    }
  }

  String _coerceSelectedDevice(
    String currentId,
    List<AudioDeviceOption> devices,
  ) {
    if (currentId.isNotEmpty &&
        devices.any((device) => device.id == currentId)) {
      return currentId;
    }
    return devices.isNotEmpty ? devices.first.id : '';
  }

  String _coerceSelectedCodec(
    String currentId,
    List<CodecOption> codecs,
  ) {
    if (currentId.isNotEmpty && codecs.any((codec) => codec.id == currentId)) {
      return currentId;
    }
    return '';
  }

  Future<void> _saveAndApplyPreferredCodec(
    String codecId, {
    required bool showStatusMessage,
  }) async {
    final normalizedCodecId = codecId.trim();
    _generalSettings = _generalSettings.copyWith(
      preferredCodecId: normalizedCodecId,
    );
    await _preferencesService.saveGeneralSettings(_generalSettings);

    if (!inCall && !calling && !ringing) {
      await _systemSettingsService.selectPreferredCodec(normalizedCodecId);
      if (showStatusMessage) {
        _setSettingsStatusMessage(
          normalizedCodecId.isEmpty
              ? 'Codec automatique appliqué.'
              : 'Codec appliqué aux prochains appels.',
        );
      }
      return;
    }

    if (showStatusMessage) {
      _setSettingsStatusMessage(
        'Codec mémorisé. Il sera appliqué au prochain appel.',
      );
    }
  }

  void _setSettingsStatusMessage(String message) {
    _settingsStatusClearTimer?.cancel();
    _settingsStatusMessage = message;
    if (message.isEmpty) {
      return;
    }

    _settingsStatusClearTimer = Timer(const Duration(seconds: 3), () {
      if (_settingsStatusMessage != message) {
        return;
      }
      _settingsStatusMessage = '';
      notifyListeners();
    });
  }

  Future<void> _applyCallAudioRoutingBeforeMediaStart() async {
    try {
      await _systemSettingsService.selectPreferredCodec(
        _generalSettings.preferredCodecId,
      );
      if (_generalSettings.audioInputId.isNotEmpty) {
        await _systemSettingsService.selectAudioInput(
          _generalSettings.audioInputId,
        );
      }
      if (_generalSettings.audioOutputId.isNotEmpty) {
        await _systemSettingsService.selectAudioOutput(
          _generalSettings.audioOutputId,
        );
      }
    } catch (_) {
      // Best effort while the native audio route settles.
    }
  }

  Future<void> _saveAndApplyPresentationSettings(
    GeneralSettings settings,
  ) async {
    _generalSettings = settings;
    await _preferencesService.saveGeneralSettings(_generalSettings);
    await _applyPresentationSettings();
    notifyListeners();
  }

  Future<void> _applyPresentationSettings() async {
    try {
      await _systemSettingsService.setWindowPresentationOptions(
        showMenuBarIcon: _generalSettings.showMenuBarIcon,
        showDockIcon: _generalSettings.showDockIcon,
      );
    } catch (_) {
      // Best effort on macOS presentation integration.
    }
  }
}
