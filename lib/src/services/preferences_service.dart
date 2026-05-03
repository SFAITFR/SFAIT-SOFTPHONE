import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/call_log_entry.dart';
import '../models/general_settings.dart';
import '../models/sip_account.dart';

class PreferencesService {
  static const _accountKey = 'sfait_softphone.account.v1';
  static const _historyKey = 'sfait_softphone.history.v1';
  static const _generalSettingsKey = 'sfait_softphone.general_settings.v1';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  SipAccount loadAccount() {
    final raw = _prefs.getString(_accountKey);
    if (raw == null || raw.isEmpty) {
      return SipAccount.empty;
    }

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return SipAccount.fromJson(decoded);
    } catch (_) {
      return SipAccount.empty;
    }
  }

  Future<void> saveAccount(SipAccount account) {
    return _prefs.setString(_accountKey, jsonEncode(account.toJson()));
  }

  List<CallLogEntry> loadHistory() {
    final raw = _prefs.getString(_historyKey);
    if (raw == null || raw.isEmpty) {
      return const <CallLogEntry>[];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(CallLogEntry.fromJson)
          .toList(growable: false);
    } catch (_) {
      return const <CallLogEntry>[];
    }
  }

  Future<void> saveHistory(List<CallLogEntry> history) {
    final encoded =
        history.map((entry) => entry.toJson()).toList(growable: false);
    return _prefs.setString(_historyKey, jsonEncode(encoded));
  }

  Future<void> clearHistory() {
    return _prefs.remove(_historyKey);
  }

  GeneralSettings loadGeneralSettings() {
    final raw = _prefs.getString(_generalSettingsKey);
    if (raw == null || raw.isEmpty) {
      return GeneralSettings.defaults;
    }

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return GeneralSettings.fromJson(decoded);
    } catch (_) {
      return GeneralSettings.defaults;
    }
  }

  Future<void> saveGeneralSettings(GeneralSettings settings) {
    return _prefs.setString(
      _generalSettingsKey,
      jsonEncode(settings.toJson()),
    );
  }
}
