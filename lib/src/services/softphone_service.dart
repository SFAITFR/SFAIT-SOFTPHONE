import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sip_ua/sip_ua.dart' as sip;

import '../models/call_log_entry.dart';
import '../models/sip_account.dart';
import '../models/softphone_status.dart';

class SoftphoneServiceEvent {
  const SoftphoneServiceEvent({
    required this.status,
    required this.message,
    this.remoteIdentity,
    this.historyDirection,
    this.historySummary,
    this.isMuted,
    this.isOnHold,
    this.isSpeakerEnabled,
  });

  final SoftphoneConnectionStatus status;
  final String message;
  final String? remoteIdentity;
  final CallDirection? historyDirection;
  final String? historySummary;
  final bool? isMuted;
  final bool? isOnHold;
  final bool? isSpeakerEnabled;
}

class SoftphoneService implements sip.SipUaHelperListener {
  SoftphoneService() {
    _channel.setMethodCallHandler(_handleNativeMethodCall);
    if (_isAndroidWebRtc) {
      _androidCallUiChannel.setMethodCallHandler(
        _handleAndroidCallUiMethodCall,
      );
    }
  }

  static const MethodChannel _channel = MethodChannel(
    'sfait/native_softphone',
  );
  static const MethodChannel _androidAudioRouteChannel = MethodChannel(
    'sfait/android_audio_route',
  );
  static const MethodChannel _androidCallUiChannel =
      MethodChannel('sfait/android_call_ui');

  final StreamController<SoftphoneServiceEvent> _events =
      StreamController<SoftphoneServiceEvent>.broadcast();

  Stream<SoftphoneServiceEvent> get events => _events.stream;

  SipAccount? _account;
  Completer<void>? _registrationCompleter;
  bool _disposed = false;
  bool _intentionalDisconnect = false;
  bool _registered = false;
  sip.SIPUAHelper? _webRtcHelper;
  sip.Call? _webRtcCall;
  bool _webRtcCallIncoming = false;
  bool _webRtcCallEstablished = false;
  bool _webRtcMuted = false;
  bool _webRtcHeld = false;
  bool _webRtcSpeakerEnabled = false;
  String? _pendingAndroidCallAction;

  bool get _isAndroidWebRtc => !kIsWeb && Platform.isAndroid;

  Future<void> connect(
    SipAccount account, {
    Map<String, dynamic>? sipPushContactUriParams,
  }) async {
    _assertConfigured(account);
    if (_isAndroidWebRtc) {
      await _connectWebRtc(
        account,
        sipPushContactUriParams: sipPushContactUriParams,
      );
      return;
    }
    _assertNativeDesktop();

    if (_account != null || _registered) {
      await disconnect();
    }

    _intentionalDisconnect = false;
    _registered = false;
    _account = account;
    _registrationCompleter = Completer<void>();

    await _channel.invokeMethod<void>('register', {
      'domain': account.domain,
      'extension': account.extension,
      'authorizationId': account.authorizationId.isNotEmpty
          ? account.authorizationId
          : account.extension,
      'password': account.password,
      'displayName': account.displayName.isNotEmpty
          ? account.displayName
          : account.extension,
    });

    try {
      await _registrationCompleter!.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw TimeoutException(
            'Le PBX ne répond pas à temps pour l’enregistrement SIP natif.',
          );
        },
      );
    } finally {
      _registrationCompleter = null;
    }
  }

  Future<void> disconnect({bool keepRegistrationForPush = false}) async {
    if (_isAndroidWebRtc) {
      await _disconnectWebRtc(unregister: !keepRegistrationForPush);
      return;
    }

    _intentionalDisconnect = true;
    _registered = false;
    await _channel.invokeMethod<void>('disconnect');
    _account = null;
  }

  Future<void> placeCall(String destination) async {
    final account = _account;
    if (account == null || !_registered) {
      throw StateError('Le compte SIP n’est pas encore enregistré.');
    }

    if (_isAndroidWebRtc) {
      final helper = _webRtcHelper;
      if (helper == null) {
        throw StateError('Le moteur SIP WebRTC Android n’est pas prêt.');
      }
      await _setAndroidSpeakerEnabled(false);
      final placed = await helper.call(
        _normalizeTarget(destination, account.domain),
        voiceOnly: true,
      );
      if (!placed) {
        throw StateError('Impossible de lancer l’appel SIP WebRTC.');
      }
      return;
    }

    await _channel.invokeMethod<void>('makeCall', {
      'destination': _normalizeTarget(destination, account.domain),
    });
  }

  Future<void> answer() async {
    if (_isAndroidWebRtc) {
      final helper = _webRtcHelper;
      final call = _webRtcCall;
      if (helper == null || call == null) {
        throw StateError('Aucun appel entrant à accepter.');
      }
      await _setAndroidSpeakerEnabled(false);
      call.answer(helper.buildCallOptions(true));
      return;
    }

    await _channel.invokeMethod<void>('answer');
  }

  Future<void> hangup() async {
    if (_isAndroidWebRtc) {
      final call = _webRtcCall;
      if (call == null) {
        throw StateError('Aucun appel actif à raccrocher.');
      }
      call.hangup();
      return;
    }

    await _channel.invokeMethod<void>('hangup');
  }

  Future<void> toggleMute() async {
    if (_isAndroidWebRtc) {
      final call = _webRtcCall;
      if (call == null) {
        throw StateError('Aucun appel actif pour gérer le micro.');
      }
      _webRtcMuted = !_webRtcMuted;
      if (_webRtcMuted) {
        call.mute(true, false);
      } else {
        call.unmute(true, false);
      }
      _emitWebRtc(
        status: SoftphoneConnectionStatus.inCall,
        message: _webRtcMuted ? 'Micro coupé.' : 'Micro réactivé.',
      );
      return;
    }

    await _channel.invokeMethod<void>('toggleMute');
  }

  Future<void> toggleHold() async {
    if (_isAndroidWebRtc) {
      final call = _webRtcCall;
      if (call == null) {
        throw StateError('Aucun appel actif pour la mise en attente.');
      }
      if (_webRtcHeld) {
        call.unhold();
      } else {
        call.hold();
      }
      return;
    }

    await _channel.invokeMethod<void>('toggleHold');
  }

  Future<void> toggleSpeaker() async {
    if (_isAndroidWebRtc) {
      if (_webRtcCall == null) {
        throw StateError('Aucun appel actif pour gérer le haut-parleur.');
      }
      await _setAndroidSpeakerEnabled(!_webRtcSpeakerEnabled);
      _emitWebRtc(
        status: SoftphoneConnectionStatus.inCall,
        message: _webRtcSpeakerEnabled
            ? 'Haut-parleur activé.'
            : 'Écouteur interne activé.',
      );
      return;
    }

    throw UnsupportedError(
      'La bascule haut-parleur est disponible sur Android.',
    );
  }

  Future<void> sendDtmf(String tone) async {
    if (_isAndroidWebRtc) {
      final call = _webRtcCall;
      if (call == null) {
        throw StateError('Aucun appel actif pour envoyer une tonalité.');
      }
      call.sendDTMF(tone);
      return;
    }

    await _channel.invokeMethod<void>('sendDtmf', {'tone': tone});
  }

  Future<void> transfer(String destination) async {
    final account = _account;
    if (account == null) {
      throw StateError('Aucun compte SIP actif pour transférer.');
    }
    if (_isAndroidWebRtc) {
      final call = _webRtcCall;
      if (call == null) {
        throw StateError('Aucun appel actif à transférer.');
      }
      call.refer(_normalizeTarget(destination, account.domain));
      return;
    }

    await _channel.invokeMethod<void>('transfer', {
      'destination': _normalizeTarget(destination, account.domain),
    });
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      await disconnect();
    } catch (_) {
      // Best effort cleanup.
    }
    await _events.close();
  }

  Future<void> _connectWebRtc(
    SipAccount account, {
    Map<String, dynamic>? sipPushContactUriParams,
  }) async {
    if (_account != null || _registered || _webRtcHelper != null) {
      await _disconnectWebRtc(emitOffline: false);
    }

    _intentionalDisconnect = false;
    _registered = false;
    _account = account;
    _registrationCompleter = Completer<void>();
    _resetWebRtcCallState();

    final helper = sip.SIPUAHelper();
    helper.addSipUaHelperListener(this);
    _webRtcHelper = helper;

    _emitWebRtc(
      status: SoftphoneConnectionStatus.connecting,
      message: 'Connexion SIP WebRTC Android en cours...',
      includeCallState: false,
    );

    final settings = sip.UaSettings()
      ..transportType = sip.TransportType.WS
      ..webSocketUrl = _webSocketUrlForDomain(account.domain)
      ..uri = 'sip:${account.extension}@${account.domain}'
      ..authorizationUser = account.authorizationId.isNotEmpty
          ? account.authorizationId
          : account.extension
      ..password = account.password
      ..displayName = account.displayName.isNotEmpty
          ? account.displayName
          : account.extension
      ..registrarServer = 'sip:${account.domain}'
      ..userAgent = 'SFAIT Softphone Android'
      ..dtmfMode = sip.DtmfMode.RFC2833
      ..register = true
      ..register_expires =
          sipPushContactUriParams == null || sipPushContactUriParams.isEmpty
              ? 300
              : 3600
      ..sessionTimers = false
      ..iceGatheringTimeout = 1000;

    if (sipPushContactUriParams != null && sipPushContactUriParams.isNotEmpty) {
      settings.registerParams.extraContactUriParams.addAll(
        sipPushContactUriParams,
      );
    }

    await helper.start(settings);

    try {
      await _registrationCompleter!.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw TimeoutException(
            'Le PBX ne répond pas à temps pour l’enregistrement SIP WebRTC Android.',
          );
        },
      );
    } finally {
      _registrationCompleter = null;
    }
  }

  Future<void> _disconnectWebRtc({
    bool emitOffline = true,
    bool unregister = true,
  }) async {
    _intentionalDisconnect = true;
    _registered = false;
    final helper = _webRtcHelper;
    final call = _webRtcCall;
    if (call != null) {
      try {
        call.hangup();
      } catch (_) {
        // Best effort cleanup.
      }
    }
    if (helper != null) {
      helper.removeSipUaHelperListener(this);
      try {
        if (unregister && helper.registered) {
          await helper.unregister(true);
        }
      } catch (_) {
        // Best effort cleanup.
      }
      helper.stop();
    }
    _webRtcHelper = null;
    _account = null;
    _resetWebRtcCallState();
    unawaited(_resetAndroidAudioRoute());
    if (emitOffline) {
      _emitWebRtc(
        status: SoftphoneConnectionStatus.offline,
        message: 'Softphone déconnecté.',
      );
    }
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    if (call.method != 'onNativeSoftphoneEvent') {
      return;
    }

    final raw = call.arguments;
    if (raw is! Map) {
      return;
    }

    final event = _eventFromNative(raw.cast<Object?, Object?>());
    _registered = event.status == SoftphoneConnectionStatus.registered ||
        (_registered &&
            event.status != SoftphoneConnectionStatus.offline &&
            event.status != SoftphoneConnectionStatus.error);

    if (event.status == SoftphoneConnectionStatus.registered) {
      _completeRegistration();
    } else if (event.status == SoftphoneConnectionStatus.error) {
      _completeRegistrationError(event.message);
    } else if (event.status == SoftphoneConnectionStatus.offline &&
        !_intentionalDisconnect) {
      _completeRegistrationError(event.message);
    }

    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  Future<void> _handleAndroidCallUiMethodCall(MethodCall call) async {
    if (call.method != 'onCallAction') {
      return;
    }

    final rawArguments = call.arguments;
    final action = rawArguments is Map ? rawArguments['action'] as String? : '';

    try {
      switch (action) {
        case 'answer':
          if (_webRtcCall == null) {
            _pendingAndroidCallAction = action;
          } else if (!_webRtcCallEstablished) {
            await answer();
          }
          break;
        case 'reject':
        case 'hangup':
          if (_webRtcCall != null) {
            await hangup();
          } else {
            _pendingAndroidCallAction = action;
          }
          break;
      }
    } catch (_) {
      // Android can close its native call UI a fraction after the SIP dialog
      // has already moved on. The SIP callbacks remain authoritative.
    }
  }

  SoftphoneServiceEvent _eventFromNative(Map<Object?, Object?> raw) {
    return SoftphoneServiceEvent(
      status: _statusFromNative(raw['status'] as String?),
      message: raw['message'] as String? ?? '',
      remoteIdentity: raw['remoteIdentity'] as String?,
      historyDirection:
          _historyDirectionFromNative(raw['historyDirection'] as String?),
      historySummary: raw['historySummary'] as String?,
      isMuted: raw['isMuted'] as bool?,
      isOnHold: raw['isOnHold'] as bool?,
      isSpeakerEnabled: raw['isSpeakerEnabled'] as bool?,
    );
  }

  SoftphoneConnectionStatus _statusFromNative(String? value) {
    return switch (value) {
      'connecting' => SoftphoneConnectionStatus.connecting,
      'registered' => SoftphoneConnectionStatus.registered,
      'calling' => SoftphoneConnectionStatus.calling,
      'ringing' => SoftphoneConnectionStatus.ringing,
      'inCall' => SoftphoneConnectionStatus.inCall,
      'error' => SoftphoneConnectionStatus.error,
      _ => SoftphoneConnectionStatus.offline,
    };
  }

  CallDirection? _historyDirectionFromNative(String? value) {
    return switch (value) {
      'incoming' => CallDirection.incoming,
      'outgoing' => CallDirection.outgoing,
      'missed' => CallDirection.missed,
      _ => null,
    };
  }

  void _completeRegistration() {
    final completer = _registrationCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _completeRegistrationError(String message) {
    final completer = _registrationCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError(message));
    }
  }

  String _normalizeTarget(String destination, String domain) {
    final trimmed = destination.trim();
    if (trimmed.isEmpty) {
      throw StateError('Destination vide.');
    }

    if (trimmed.startsWith('sip:')) {
      return trimmed;
    }

    if (trimmed.contains('@')) {
      return 'sip:$trimmed';
    }

    return 'sip:$trimmed@$domain';
  }

  String _webSocketUrlForDomain(String domain) {
    final trimmed = domain.trim();
    if (trimmed.startsWith('ws://') || trimmed.startsWith('wss://')) {
      return trimmed.endsWith('/') ? trimmed : '$trimmed/';
    }

    final withoutScheme = trimmed
        .replaceFirst(RegExp(r'^sip:', caseSensitive: false), '')
        .split('@')
        .last;
    return 'wss://$withoutScheme/appels-ws/';
  }

  void _assertConfigured(SipAccount account) {
    if (account.domain.trim().isEmpty ||
        account.extension.trim().isEmpty ||
        account.password.isEmpty) {
      throw StateError('Configuration SIP incomplète.');
    }
  }

  void _assertNativeDesktop() {
    if (kIsWeb || !(Platform.isMacOS || Platform.isWindows)) {
      throw UnsupportedError(
        'Le moteur SIP est disponible sur macOS, Windows et Android.',
      );
    }
  }

  @override
  void transportStateChanged(sip.TransportState state) {
    if (_disposed || !_isAndroidWebRtc) {
      return;
    }

    switch (state.state) {
      case sip.TransportStateEnum.CONNECTING:
        _emitWebRtc(
          status: SoftphoneConnectionStatus.connecting,
          message: 'Connexion au WebSocket SIP...',
          includeCallState: false,
        );
      case sip.TransportStateEnum.CONNECTED:
        _emitWebRtc(
          status: SoftphoneConnectionStatus.connecting,
          message: 'WebSocket SIP connecté. Enregistrement...',
          includeCallState: false,
        );
      case sip.TransportStateEnum.DISCONNECTED:
        if (!_intentionalDisconnect && !_registered) {
          final message = _formatSipCause(
            state.cause?.cause,
            fallback: 'Connexion WebSocket SIP interrompue.',
          );
          _completeRegistrationError(message);
          _emitWebRtc(
            status: SoftphoneConnectionStatus.error,
            message: message,
            includeCallState: false,
          );
        }
      case sip.TransportStateEnum.NONE:
        break;
    }
  }

  @override
  void registrationStateChanged(sip.RegistrationState state) {
    if (_disposed || !_isAndroidWebRtc) {
      return;
    }

    switch (state.state) {
      case sip.RegistrationStateEnum.REGISTERED:
        _registered = true;
        _completeRegistration();
        _emitWebRtc(
          status: SoftphoneConnectionStatus.registered,
          message:
              'Compte ${_account?.extension ?? ''} enregistré et prêt à recevoir des appels.',
        );
      case sip.RegistrationStateEnum.REGISTRATION_FAILED:
        _registered = false;
        final message = _formatSipCause(
          state.cause?.cause,
          fallback: 'Échec de l’enregistrement SIP WebRTC.',
        );
        _completeRegistrationError(message);
        _emitWebRtc(
          status: SoftphoneConnectionStatus.error,
          message: message,
          includeCallState: false,
        );
      case sip.RegistrationStateEnum.UNREGISTERED:
        _registered = false;
        final message = _intentionalDisconnect
            ? 'Softphone déconnecté.'
            : _formatSipCause(
                state.cause?.cause,
                fallback: 'Compte SIP désenregistré.',
              );
        if (!_intentionalDisconnect) {
          _completeRegistrationError(message);
        }
        _emitWebRtc(
          status: _intentionalDisconnect
              ? SoftphoneConnectionStatus.offline
              : SoftphoneConnectionStatus.error,
          message: message,
          includeCallState: false,
        );
      case sip.RegistrationStateEnum.NONE:
      case null:
        break;
    }
  }

  @override
  void callStateChanged(sip.Call call, sip.CallState state) {
    if (_disposed || !_isAndroidWebRtc) {
      return;
    }

    final remoteIdentity = _remoteIdentityForCall(call);
    switch (state.state) {
      case sip.CallStateEnum.CALL_INITIATION:
        _webRtcCall = call;
        _webRtcCallIncoming = call.direction == sip.Direction.incoming;
        _webRtcCallEstablished = false;
        _webRtcMuted = false;
        _webRtcHeld = false;
        _webRtcSpeakerEnabled = false;
        _emitWebRtc(
          status: _webRtcCallIncoming
              ? SoftphoneConnectionStatus.ringing
              : SoftphoneConnectionStatus.calling,
          message: _webRtcCallIncoming
              ? 'Appel entrant de $remoteIdentity'
              : 'Appel vers $remoteIdentity...',
          remoteIdentity: remoteIdentity,
        );
        _applyPendingAndroidCallActionIfNeeded();
      case sip.CallStateEnum.CONNECTING:
      case sip.CallStateEnum.PROGRESS:
      case sip.CallStateEnum.ACCEPTED:
        _webRtcCall ??= call;
        _emitWebRtc(
          status: _webRtcCallIncoming
              ? SoftphoneConnectionStatus.ringing
              : SoftphoneConnectionStatus.calling,
          message: _webRtcCallIncoming
              ? 'Appel entrant de $remoteIdentity'
              : 'Ça sonne chez $remoteIdentity...',
          remoteIdentity: remoteIdentity,
        );
        _applyPendingAndroidCallActionIfNeeded();
      case sip.CallStateEnum.CONFIRMED:
      case sip.CallStateEnum.STREAM:
        _webRtcCall = call;
        _webRtcCallEstablished = true;
        unawaited(_setAndroidSpeakerEnabled(_webRtcSpeakerEnabled));
        _emitWebRtc(
          status: SoftphoneConnectionStatus.inCall,
          message: 'Communication active.',
          remoteIdentity: remoteIdentity,
        );
      case sip.CallStateEnum.HOLD:
        _webRtcHeld = true;
        _emitWebRtc(
          status: SoftphoneConnectionStatus.inCall,
          message: 'Appel mis en attente.',
          remoteIdentity: remoteIdentity,
        );
      case sip.CallStateEnum.UNHOLD:
        _webRtcHeld = false;
        _emitWebRtc(
          status: SoftphoneConnectionStatus.inCall,
          message: 'Communication reprise.',
          remoteIdentity: remoteIdentity,
        );
      case sip.CallStateEnum.MUTED:
        _webRtcMuted = true;
        _emitWebRtc(
          status: SoftphoneConnectionStatus.inCall,
          message: 'Micro coupé.',
          remoteIdentity: remoteIdentity,
        );
      case sip.CallStateEnum.UNMUTED:
        _webRtcMuted = false;
        _emitWebRtc(
          status: SoftphoneConnectionStatus.inCall,
          message: 'Micro réactivé.',
          remoteIdentity: remoteIdentity,
        );
      case sip.CallStateEnum.FAILED:
      case sip.CallStateEnum.ENDED:
        final wasIncoming = _webRtcCallIncoming;
        final wasEstablished = _webRtcCallEstablished;
        _resetWebRtcCallState();
        unawaited(_resetAndroidAudioRoute());
        _emitWebRtc(
          status: _registered
              ? SoftphoneConnectionStatus.registered
              : SoftphoneConnectionStatus.offline,
          message: wasEstablished
              ? 'Appel terminé.'
              : _formatSipCause(
                  state.cause?.cause,
                  fallback: 'Appel manqué ou échoué.',
                ),
          remoteIdentity: remoteIdentity,
          historyDirection: wasIncoming
              ? (wasEstablished ? CallDirection.incoming : CallDirection.missed)
              : CallDirection.outgoing,
          historySummary:
              wasEstablished ? 'Appel terminé' : 'Appel manqué ou échoué',
          includeCallState: false,
        );
      case sip.CallStateEnum.REFER:
      case sip.CallStateEnum.NONE:
        break;
    }
  }

  @override
  void onNewMessage(sip.SIPMessageRequest msg) {}

  @override
  void onNewNotify(sip.Notify ntf) {}

  @override
  void onNewReinvite(sip.ReInvite event) {}

  void _emitWebRtc({
    required SoftphoneConnectionStatus status,
    required String message,
    String? remoteIdentity,
    CallDirection? historyDirection,
    String? historySummary,
    bool includeCallState = true,
  }) {
    if (_events.isClosed) {
      return;
    }
    _events.add(
      SoftphoneServiceEvent(
        status: status,
        message: message,
        remoteIdentity: remoteIdentity ?? _currentWebRtcRemoteIdentity(),
        historyDirection: historyDirection,
        historySummary: historySummary,
        isMuted: includeCallState ? _webRtcMuted : false,
        isOnHold: includeCallState ? _webRtcHeld : false,
        isSpeakerEnabled: includeCallState ? _webRtcSpeakerEnabled : false,
      ),
    );
  }

  void _resetWebRtcCallState() {
    _webRtcCall = null;
    _webRtcCallIncoming = false;
    _webRtcCallEstablished = false;
    _webRtcMuted = false;
    _webRtcHeld = false;
    _webRtcSpeakerEnabled = false;
    _pendingAndroidCallAction = null;
  }

  void _applyPendingAndroidCallActionIfNeeded() {
    final action = _pendingAndroidCallAction;
    final call = _webRtcCall;
    if (action == null || call == null || !_webRtcCallIncoming) {
      return;
    }

    _pendingAndroidCallAction = null;
    switch (action) {
      case 'answer':
        if (!_webRtcCallEstablished) {
          unawaited(answer());
        }
        break;
      case 'reject':
      case 'hangup':
        unawaited(hangup());
        break;
    }
  }

  String _currentWebRtcRemoteIdentity() {
    final call = _webRtcCall;
    return call == null ? '' : _remoteIdentityForCall(call);
  }

  String _remoteIdentityForCall(sip.Call call) {
    final displayName = call.remote_display_name?.trim() ?? '';
    if (displayName.isNotEmpty) {
      return displayName;
    }
    final remoteIdentity = call.remote_identity?.trim() ?? '';
    return remoteIdentity.isNotEmpty ? remoteIdentity : 'Inconnu';
  }

  String _formatSipCause(String? cause, {required String fallback}) {
    final cleaned = cause?.trim();
    if (cleaned == null || cleaned.isEmpty) {
      return fallback;
    }
    return cleaned;
  }

  Future<void> _setAndroidSpeakerEnabled(bool enabled) async {
    if (!_isAndroidWebRtc) {
      return;
    }

    _webRtcSpeakerEnabled = enabled;
    final targetOutput = enabled ? 'speaker' : 'earpiece';

    try {
      await _androidAudioRouteChannel.invokeMethod<void>(
        'setSpeakerEnabled',
        {'enabled': enabled},
      );
    } catch (_) {
      // The WebRTC route below still gives us a plugin-level fallback.
    }

    try {
      await Helper.selectAudioOutput(targetOutput);
    } catch (_) {
      try {
        await Helper.setSpeakerphoneOn(enabled);
      } catch (_) {
        // Audio routing is best effort across Android device vendors.
      }
    }
  }

  Future<void> _resetAndroidAudioRoute() async {
    if (!_isAndroidWebRtc) {
      return;
    }

    try {
      await _androidAudioRouteChannel.invokeMethod<void>('resetAudioRoute');
    } catch (_) {
      // Best effort cleanup.
    }
  }
}
