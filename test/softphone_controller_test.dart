import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sfait_softphone/src/models/call_log_entry.dart';
import 'package:sfait_softphone/src/models/softphone_status.dart';
import 'package:sfait_softphone/src/services/preferences_service.dart';
import 'package:sfait_softphone/src/services/ringtone_service.dart';
import 'package:sfait_softphone/src/services/softphone_service.dart';
import 'package:sfait_softphone/src/viewmodels/softphone_controller.dart';

class _FakeSoftphoneService extends SoftphoneService {
  final StreamController<SoftphoneServiceEvent> _eventsController =
      StreamController<SoftphoneServiceEvent>.broadcast();

  @override
  Stream<SoftphoneServiceEvent> get events => _eventsController.stream;

  void emit(SoftphoneServiceEvent event) {
    _eventsController.add(event);
  }

  @override
  Future<void> dispose() async {
    await _eventsController.close();
  }
}

class _FakeRingtoneService extends RingtoneService {
  @override
  Future<void> play({
    String outputDeviceId = '',
    String filePath = '',
    double volume = 1.0,
  }) async {}

  @override
  Future<void> stop() async {}
}

void main() {
  test('keeps call controls available during SIP registration refresh',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final preferences = PreferencesService();
    await preferences.init();

    final service = _FakeSoftphoneService();
    final controller = SoftphoneController(
      preferences,
      service: service,
      ringtoneService: _FakeRingtoneService(),
    )..bootstrap();
    addTearDown(controller.dispose);

    service.emit(
      const SoftphoneServiceEvent(
        status: SoftphoneConnectionStatus.inCall,
        message: 'Communication active avec 0612345678',
        remoteIdentity: '0612345678',
        isMuted: false,
        isOnHold: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.inCall, isTrue);
    expect(controller.canHangup, isTrue);
    expect(controller.activeRemoteIdentity, '0612345678');

    service.emit(
      const SoftphoneServiceEvent(
        status: SoftphoneConnectionStatus.registered,
        message: 'Compte 101 enregistré et prêt à recevoir des appels.',
        isMuted: false,
        isOnHold: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.inCall, isTrue);
    expect(controller.canHangup, isTrue);
    expect(controller.activeRemoteIdentity, '0612345678');

    service.emit(
      const SoftphoneServiceEvent(
        status: SoftphoneConnectionStatus.registered,
        message: 'Appel terminé.',
        remoteIdentity: '0612345678',
        historyDirection: CallDirection.outgoing,
        historySummary: 'Appel terminé',
        isMuted: false,
        isOnHold: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.inCall, isFalse);
    expect(controller.canHangup, isFalse);
    expect(controller.history, hasLength(1));
  });
}
