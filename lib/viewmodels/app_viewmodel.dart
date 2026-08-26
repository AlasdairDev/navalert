import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import '../services/database_service.dart';
import '../services/sound_service.dart';

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

  /// Set when the initial load could not read the local database (e.g. a device
  /// where the encrypted store fails). Surfaced to the user; the app still opens
  /// with default settings rather than hanging on the splash.
  String? loadError;

  /// Map tile style only — the rest of the app keeps its single dark theme.
  /// Kept in SharedPreferences rather than the encrypted SQLCipher store: it's
  /// a cosmetic toggle, not app data, and loading it must never be gated
  /// behind (or block) the splash's DB-load wait.
  bool mapDarkMode = false;

  AppViewModel() {
    _loadMapDarkMode();
  }

  Future<void> _loadMapDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    mapDarkMode = prefs.getBool('map_dark_mode') ?? false;
    notifyListeners();
  }

  Future<void> setMapDarkMode(bool value) async {
    mapDarkMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('map_dark_mode', value);
  }

  // DO NOT MODIFY LOGIC: the splash gate ([LaunchView]) waits on `loaded`, so
  // this MUST always finish and set loaded=true — otherwise the app hangs on
  // the loading screen forever (groupmate-reported). Every DB read is wrapped:
  // on failure the default-constructed models above are kept, an error is
  // recorded, and the app proceeds instead of getting stuck.
  Future<void> load() async {
    // One silent retry: the first open also creates/keys the encrypted
    // database, which can lose a race with secure-storage on a cold, loaded
    // device. A transient failure must not leave the app running on empty
    // data for the rest of the session.
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        appState = await _db.getAppState();
        settings = await _db.getUserSettings();
        transportPrefs = await _db.getTransportPreferences();
        fakeCallConfig = await _db.getFakeCallConfig();
        contacts = await _db.getContacts();
        recordings = await _db.getRecordings();
        favorites = await _db.getFavorites();
        loadError = null;
        break;
      } catch (e, st) {
        debugPrint('NavAlert: load attempt $attempt failed — $e\n$st');
        loadError = 'Could not open local storage. Your contacts and '
            'recordings are unavailable - tap Retry.';
        if (attempt == 1) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
      }
    }
    loaded = true; // NEVER leave the splash spinning.
    _applyEarphoneRouting();
    notifyListeners();
  }

  /// True when the local database could not be read, so the app is running on
  /// empty defaults. The setup screens surface this instead of silently
  /// showing an empty contact form and an untappable recordings dropdown.
  bool get dataUnavailable => loadError != null;

  /// Re-runs [load] after a failure (the Retry action on the setup screens).
  Future<void> retryLoad() async {
    loadError = null;
    notifyListeners();
    await load();
  }

  /// DO NOT MODIFY LOGIC: mirrors the "Bluetooth / ear-phone only detection"
  /// toggle into SoundService so the alarm can route through the earphones when
  /// enabled. Called on load and after every settings save.
  void _applyEarphoneRouting() =>
      SoundService.instance.earphoneOnlyAlarm = settings.bluetoothEnabled == 'Allow';

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

  /// DO NOT MODIFY LOGIC: the three preference saves below are called
  /// fire-and-forget from switch and dropdown handlers (Settings, Trip
  /// Settings, the fake-call recording picker). If they threw, it would become
  /// an UNHANDLED async error and the change would silently fail to persist —
  /// the control flips, then reverts on the next launch with no explanation.
  /// They report through [loadError] instead, which the setup screens already
  /// surface with a Retry action. Contact/favorite/recording writes are
  /// deliberately NOT included: those are awaited by callers that show their
  /// own specific error, and must keep throwing.
  Future<void> _savePreference(
      Future<void> Function() write, String failureMessage) async {
    try {
      await write();
      loadError = null;
    } catch (e) {
      debugPrint('NavAlert: $failureMessage — $e');
      loadError = failureMessage;
    }
    notifyListeners();
  }

  Future<void> saveSettings() async {
    await _savePreference(() => _db.saveUserSettings(settings),
        'Could not save your settings - storage is unavailable.');
    _applyEarphoneRouting();
  }

  Future<void> saveTransportPrefs() => _savePreference(
      () => _db.saveTransportPreferences(transportPrefs),
      'Could not save your transport preferences - storage is unavailable.');

  Future<void> saveFakeCallConfig() => _savePreference(
      () => _db.saveFakeCallConfig(fakeCallConfig),
      'Could not save the fake-call settings - storage is unavailable.');

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

  // ---------- custom alarm sound ----------
  /// Lets the rider pick an audio file (e.g. an MP3) from their device and
  /// copies it into app storage, so it keeps working even if the original
  /// file is later moved or deleted. Returns the `SoundService`-formatted
  /// `custom:<path>` value to store as `alarmSound` (Settings' global default
  /// or a single trip's choice — the caller decides which), or null if the
  /// rider cancelled the picker or the pick/copy failed.
  Future<String?> pickCustomAlarmSound() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(type: FileType.audio);
    } catch (_) {
      return null;
    }
    final pickedPath = result?.files.single.path;
    if (pickedPath == null) return null;

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final soundsDir = Directory('${docsDir.path}/alarm_sounds');
      if (!await soundsDir.exists()) await soundsDir.create(recursive: true);
      // Keep the rider's own filename — SoundService.customLabel shows it
      // in the dropdown, and a generated id there read as a bug, not a
      // filename. A repeat upload of the same name simply replaces it.
      final destPath = '${soundsDir.path}/${p.basename(pickedPath)}';
      await File(pickedPath).copy(destPath);
      return SoundService.toCustom(destPath);
    } catch (_) {
      return null;
    }
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

  /// Deletes a CUSTOM recording: the database row, the audio file on disk, and
  /// the selection if it pointed here.
  ///
  /// DO NOT MODIFY LOGIC: all four guards below are load-bearing.
  ///  * Presets are never deletable — they are bundled assets, not user files,
  ///    and deleting the row would leave the app with no fallback clip at all.
  ///  * The .m4a must be removed too, or every delete leaks a multi-megabyte
  ///    file that nothing will ever reference again.
  ///  * The selection must land on a recording that still EXISTS. Leaving
  ///    fakeCallConfig.recordingId pointing at a deleted row makes the fake
  ///    call — a safety feature — play nothing at the moment it is needed.
  ///  * The config write is best-effort: a storage failure must not undo a
  ///    deletion the rider already confirmed.
  Future<void> removeRecording(String id) async {
    final target = recordings.where((r) => r.recordingId == id);
    if (target.isEmpty || target.first.isPreset) return;
    final path = target.first.filePath;

    await _db.deleteRecording(id);
    recordings = await _db.getRecordings();

    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {/* row is gone either way — storage cleanup is secondary */}

    if (fakeCallConfig.recordingId == id) {
      fakeCallConfig.recordingId =
          recordings.isEmpty ? null : recordings.first.recordingId;
      try {
        await _db.saveFakeCallConfig(fakeCallConfig);
      } catch (_) {/* not persisted — the in-memory selection is still valid */}
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
      // A real "Save As" dialog — the rider picks where the file actually
      // goes (Downloads, a folder, wherever), rather than it silently
      // landing in a hidden app-private folder they can't find or share.
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save NavAlert backup',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(utf8.encode(payload)),
      );
      return path;
    } catch (e) {
      debugPrint('NavAlert: backup export failed — $e');
      return null;
    }
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
