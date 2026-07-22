import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import '../services/database_service.dart';

/// App-wide ViewModel — app state, user settings, transport preferences,
/// emergency contacts, fake-call configuration, favorites, the
/// app_state prompts (incomplete-setup and SOS low-load warnings,
/// Table 15) and the Settings Data Backup import/export (Figure 33).
class AppViewModel extends ChangeNotifier {
  final _db = DatabaseService.instance;
  static const _uuid = Uuid();

  AppState appState = AppState();
  UserSettings settings = UserSettings();
  TransportPreferences transportPrefs = TransportPreferences();
  FakeCallConfig fakeCallConfig = FakeCallConfig();
  List<EmergencyContact> contacts = [];
  List<Recording> recordings = [];
  List<Favorite> favorites = [];
  bool loaded = false;

  Future<void> load() async {
    appState = await _db.getAppState();
    settings = await _db.getUserSettings();
    transportPrefs = await _db.getTransportPreferences();
    fakeCallConfig = await _db.getFakeCallConfig();
    contacts = await _db.getContacts();
    recordings = await _db.getRecordings();
    favorites = await _db.getFavorites();
    loaded = true;
    notifyListeners();
  }

  Future<void> completeOnboarding() async {
    appState.onboardingCompleted = true;
    appState.tutorialCompleted = true;
    await _db.saveAppState(appState);
    notifyListeners();
  }

  // ---------- app_state prompts (Table 15) ----------
  /// Home banner shown while onboarding was skipped without contacts.
  bool get showIncompleteSetupPrompt =>
      contacts.isEmpty && !appState.incompleteSetupDismissed;

  Future<void> dismissIncompleteSetupPrompt() async {
    appState.incompleteSetupDismissed = true;
    await _db.saveAppState(appState);
    notifyListeners();
  }

  /// Activity Diagram — "Insufficient Load Warning": the emergency SMS
  /// feature requires sufficient prepaid load to function.
  bool get showSosLowLoadWarning => !appState.sosLowLoadWarningDismissed;

  Future<void> dismissSosLowLoadWarning() async {
    appState.sosLowLoadWarningDismissed = true;
    await _db.saveAppState(appState);
    notifyListeners();
  }

  Future<void> saveSettings() async {
    await _db.saveUserSettings(settings);
    notifyListeners();
  }

  Future<void> saveTransportPrefs() async {
    await _db.saveTransportPreferences(transportPrefs);
    notifyListeners();
  }

  Future<void> saveFakeCallConfig() async {
    await _db.saveFakeCallConfig(fakeCallConfig);
    notifyListeners();
  }

  // ---------- emergency contacts ----------
  Future<void> saveContact(
      {String? contactId, required String name, required String phone,
      required int order}) async {
    await _db.upsertContact(EmergencyContact(
      contactId: contactId ?? _uuid.v4(),
      name: name,
      phoneNumber: phone,
      contactOrder: order,
    ));
    contacts = await _db.getContacts();
    notifyListeners();
  }

  Future<void> removeContact(String id) async {
    await _db.deleteContact(id);
    contacts = await _db.getContacts();
    notifyListeners();
  }

  // ---------- recordings ----------
  Future<void> addRecording(String title, String filePath,
      {double durationSeconds = 0}) async {
    await _db.insertRecording(Recording(
      recordingId: _uuid.v4(),
      title: title,
      filePath: filePath,
      durationSeconds: durationSeconds,
    ));
    recordings = await _db.getRecordings();
    notifyListeners();
  }

  Future<void> removeRecording(String id) async {
    await _db.deleteRecording(id);
    recordings = await _db.getRecordings();
    if (fakeCallConfig.recordingId == id) {
      fakeCallConfig.recordingId = null;
      await _db.saveFakeCallConfig(fakeCallConfig);
    }
    notifyListeners();
  }

  Recording? get selectedRecording {
    if (recordings.isEmpty) return null;
    return recordings.firstWhere(
        (r) => r.recordingId == fakeCallConfig.recordingId,
        orElse: () => recordings.first);
  }

  // ---------- favorites ----------
  Future<Favorite> addFavorite(
      String name, String address, double lat, double lng) async {
    final f = Favorite(
        favoriteId: _uuid.v4(), name: name, address: address, lat: lat, lng: lng);
    await _db.insertFavorite(f);
    favorites = await _db.getFavorites();
    notifyListeners();
    return f;
  }

  Future<void> removeFavorite(String id) async {
    await _db.deleteFavorite(id);
    favorites = await _db.getFavorites();
    notifyListeners();
  }

  Favorite? favoriteAt(double lat, double lng) {
    for (final f in favorites) {
      if ((f.lat - lat).abs() < 0.0005 && (f.lng - lng).abs() < 0.0005) {
        return f;
      }
    }
    return null;
  }

  // ---------- Data Backup (Figure 33 — Import / Export) ----------
  /// Exports settings, preferences, contacts, favorites and the fake-call
  /// caller name as a JSON backup file. Returns the saved path, or null if
  /// the backup could not be written — the caller must report that failure,
  /// never let it pass as success: a rider who believes their emergency
  /// contacts are backed up when nothing was saved is worse off than one
  /// who knows the export failed.
  Future<String?> exportBackup() async {
    final payload = jsonEncode({
      'navalert_backup': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'user_settings': settings.toMap(),
      'transport_preferences': transportPrefs.toMap(),
      'caller_name': fakeCallConfig.callerName,
      'emergency_contacts': contacts
          .map((c) => {
                'name': c.name,
                'phone_number': c.phoneNumber,
                'contact_order': c.contactOrder,
              })
          .toList(),
      'favorites': favorites
          .map((f) => {
                'name': f.name,
                'address': f.address,
                'lat': f.lat,
                'lng': f.lng,
              })
          .toList(),
    });
    final name =
        'navalert_backup_${DateTime.now().toIso8601String().substring(0, 10)}.json';
    try {
      final dir = await _backupDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsString(payload);
      return file.path;
    } catch (e) {
      debugPrint('NavAlert: backup export failed — $e');
      return null;
    }
  }

  /// Backups live in the app's external files folder so a file manager
  /// can copy them off the device.
  Future<Directory> _backupDirectory() async {
    Directory? dir;
    try {
      dir = await getExternalStorageDirectory();
    } catch (_) {}
    dir ??= await getApplicationDocumentsDirectory();
    final backups = Directory('${dir.path}/backups');
    if (!backups.existsSync()) backups.createSync(recursive: true);
    return backups;
  }

  /// Lists previously exported backup files (newest first) for Import.
  Future<List<File>> listBackups() async {
    final dir = await _backupDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  /// Imports a previously exported backup file. Returns an error message
  /// or null on success.
  Future<String?> importBackup(File file) async {
    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (data['navalert_backup'] != 1) {
        return 'Not a valid NavAlert backup file.';
      }

      final us = data['user_settings'] as Map<String, dynamic>?;
      if (us != null) {
        settings = UserSettings.fromMap(us);
        await _db.saveUserSettings(settings);
      }
      final tp = data['transport_preferences'] as Map<String, dynamic>?;
      if (tp != null) {
        transportPrefs = TransportPreferences.fromMap(tp);
        await _db.saveTransportPreferences(transportPrefs);
      }
      final caller = data['caller_name'] as String?;
      if (caller != null && caller.isNotEmpty) {
        fakeCallConfig.callerName = caller;
        await _db.saveFakeCallConfig(fakeCallConfig);
      }

      for (final raw in (data['emergency_contacts'] as List? ?? [])) {
        final c = raw as Map<String, dynamic>;
        final order = c['contact_order'] as int? ?? 1;
        final existing =
            contacts.where((x) => x.contactOrder == order).toList();
        await _db.upsertContact(EmergencyContact(
          contactId:
              existing.isEmpty ? _uuid.v4() : existing.first.contactId,
          name: c['name'] as String? ?? '',
          phoneNumber: c['phone_number'] as String? ?? '',
          contactOrder: order,
        ));
      }
      for (final raw in (data['favorites'] as List? ?? [])) {
        final f = raw as Map<String, dynamic>;
        final lat = (f['lat'] as num).toDouble();
        final lng = (f['lng'] as num).toDouble();
        if (favoriteAt(lat, lng) == null) {
          await _db.insertFavorite(Favorite(
            favoriteId: _uuid.v4(),
            name: f['name'] as String? ?? '',
            address: f['address'] as String? ?? '',
            lat: lat,
            lng: lng,
          ));
        }
      }
      await load();
      return null;
    } catch (_) {
      return 'Could not read the backup file.';
    }
  }
}
