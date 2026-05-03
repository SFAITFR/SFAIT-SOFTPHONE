import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  });

  final SoftphoneConnectionStatus status;
  final String message;
  final String? remoteIdentity;
  final CallDirection? historyDirection;
  final String? historySummary;
  final bool? isMuted;
  final bool? isOnHold;
}

class SoftphoneService {
  SoftphoneService() {
    _channel.setMethodCallHandler(_handleNativeMethodCall);
  }

  static const MethodChannel _channel = MethodChannel(
    'sfait/native_softphone',
  );

  final StreamController<SoftphoneServiceEvent> _events =
      StreamController<SoftphoneServiceEvent>.broadcast();

  Stream<SoftphoneServiceEvent> get events => _events.stream;

  SipAccount? _account;
  Completer<void>? _registrationCompleter;
  bool _disposed = false;
  bool _intentionalDisconnect = false;
  bool _registered = false;

  Future<void> connect(SipAccount account) async {
    _assertConfigured(account);
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

  Future<void> disconnect() async {
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

    await _channel.invokeMethod<void>('makeCall', {
      'destination': _normalizeTarget(destination, account.domain),
    });
  }

  Future<void> answer() async {
    await _channel.invokeMethod<void>('answer');
  }

  Future<void> hangup() async {
    await _channel.invokeMethod<void>('hangup');
  }

  Future<void> toggleMute() async {
    await _channel.invokeMethod<void>('toggleMute');
  }

  Future<void> toggleHold() async {
    await _channel.invokeMethod<void>('toggleHold');
  }

  Future<void> sendDtmf(String tone) async {
    await _channel.invokeMethod<void>('sendDtmf', {'tone': tone});
  }

  Future<void> transfer(String destination) async {
    final account = _account;
    if (account == null) {
      throw StateError('Aucun compte SIP actif pour transférer.');
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
        'Le moteur SIP natif est disponible sur macOS et Windows.',
      );
    }
  }
}
