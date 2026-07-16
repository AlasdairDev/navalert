import 'dart:convert';
import 'dart:math';

import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

/// Offline-first local storage (Requirement R5).
/// Implements the full NavAlert database schema — Figure 34 and
/// Data Dictionary Tables 15–29 of the capstone methodology.
///
/// The database file is encrypted at rest with SQLCipher (AES-256), as
/// specified in the paper's Development Tools section, to protect sensitive
/// commuter data (coordinates and emergency-contact details) in compliance
/// with the Data Privacy Act of 2012 (RA 10173). The 256-bit key is generated
/// once and held in the Android Keystore-backed secure storage.
class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  Database? _db;

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _keyName = 'navalert_db_key';

  /// Reads the SQLCipher key from secure storage, generating a random
  /// 256-bit key on first launch.
  Future<String> _databaseKey() async {
    var key = await _secure.read(key: _keyName);
    if (key == null || key.isEmpty) {
      final rnd = Random.secure();
      final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
      key = base64UrlEncode(bytes);
      await _secure.write(key: _keyName, value: key);
    }
    return key;
  }

  Future<Database> get db async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    final key = await _databaseKey();
    _db = await openDatabase(
      p.join(dir, 'navalert.db'),
      password: key, // SQLCipher AES-256 encryption at rest.
      version: 1,
      onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      onCreate: _createSchema,
    );
    return _db!;
  }

  Future<void> _createSchema(Database d, int version) async {
    await d.execute('''
      CREATE TABLE app_state (
        id INTEGER PRIMARY KEY DEFAULT 1,
        onboarding_completed INTEGER NOT NULL DEFAULT 0,
        tutorial_completed INTEGER NOT NULL DEFAULT 0,
        incomplete_setup_dismissed INTEGER NOT NULL DEFAULT 0,
        sos_low_load_warning_dismissed INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE user_settings (
        id INTEGER PRIMARY KEY DEFAULT 1,
        location_access TEXT NOT NULL DEFAULT 'Allow',
        optimize_battery_usage TEXT NOT NULL DEFAULT 'Allow',
        push_notifications TEXT NOT NULL DEFAULT 'Allow',
        bluetooth_enabled TEXT NOT NULL DEFAULT 'Allow',
        alarm_sound TEXT NOT NULL DEFAULT 'Digital Clock',
        updated_at TEXT NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE transport_preferences (
        id INTEGER PRIMARY KEY DEFAULT 1,
        bus_enabled INTEGER NOT NULL DEFAULT 1,
        uv_express_enabled INTEGER NOT NULL DEFAULT 1,
        jeepney_enabled INTEGER NOT NULL DEFAULT 1,
        updated_at TEXT NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE emergency_contacts (
        contact_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone_number TEXT NOT NULL,
        contact_order INTEGER NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE recordings (
        recording_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        file_path TEXT NOT NULL,
        duration_seconds REAL NOT NULL DEFAULT 0,
        is_preset INTEGER NOT NULL DEFAULT 0,
        recorded_at TEXT NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE favorites (
        favorite_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        address TEXT NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        created_at TEXT NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE fake_call_config (
        id INTEGER PRIMARY KEY DEFAULT 1,
        recording_id TEXT,
        caller_name TEXT NOT NULL DEFAULT 'Mom',
        updated_at TEXT NOT NULL,
        CONSTRAINT fk_fcc_recording FOREIGN KEY (recording_id)
          REFERENCES recordings (recording_id) ON DELETE SET NULL
      )''');
    await d.execute('''
      CREATE TABLE trips (
        trip_id TEXT PRIMARY KEY,
        destination_favorite_id TEXT,
        selected_route_suggestion_id TEXT,
        origin_label TEXT NOT NULL,
        origin_lat REAL NOT NULL,
        origin_lng REAL NOT NULL,
        destination_label TEXT NOT NULL,
        destination_lat REAL NOT NULL,
        destination_lng REAL NOT NULL,
        distance_km REAL NOT NULL DEFAULT 0,
        alarm_sound TEXT NOT NULL DEFAULT 'Digital Clock',
        vibration_only_mode INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'configured',
        eta_minutes REAL,
        highest_alarm_stage INTEGER,
        awake_seconds INTEGER,
        started_at TEXT,
        ended_at TEXT,
        created_at TEXT NOT NULL,
        CONSTRAINT fk_trips_fav FOREIGN KEY (destination_favorite_id)
          REFERENCES favorites (favorite_id) ON DELETE SET NULL
      )''');
    await d.execute('''
      CREATE TABLE route_suggestions (
        suggestion_id TEXT PRIMARY KEY,
        trip_id TEXT NOT NULL,
        rank INTEGER NOT NULL,
        route_label TEXT NOT NULL,
        tag_primary TEXT,
        tag_secondary TEXT,
        total_fare_php REAL NOT NULL DEFAULT 0,
        total_duration_minutes REAL NOT NULL DEFAULT 0,
        transport_summary TEXT,
        status TEXT NOT NULL DEFAULT 'suggested',
        generated_at TEXT NOT NULL,
        CONSTRAINT fk_rs_trip FOREIGN KEY (trip_id)
          REFERENCES trips (trip_id) ON DELETE CASCADE
      )''');
    await d.execute('''
      CREATE TABLE route_steps (
        step_id TEXT PRIMARY KEY,
        suggestion_id TEXT NOT NULL,
        step_number INTEGER NOT NULL,
        transport_mode TEXT NOT NULL,
        instruction TEXT NOT NULL,
        from_stop TEXT,
        to_stop TEXT,
        fare_php REAL NOT NULL DEFAULT 0,
        duration_minutes REAL NOT NULL DEFAULT 0,
        CONSTRAINT fk_rsteps_sugg FOREIGN KEY (suggestion_id)
          REFERENCES route_suggestions (suggestion_id) ON DELETE CASCADE
      )''');
    await d.execute('''
      CREATE TABLE alarm_events (
        alarm_id TEXT PRIMARY KEY,
        trip_id TEXT NOT NULL,
        stage INTEGER NOT NULL,
        stage_label TEXT NOT NULL,
        stage_message TEXT NOT NULL,
        km_from_destination REAL,
        nearest_stop_name TEXT,
        checklist_items TEXT,
        triggered_lat REAL NOT NULL,
        triggered_lng REAL NOT NULL,
        dismissed INTEGER NOT NULL DEFAULT 0,
        triggered_at TEXT NOT NULL,
        dismissed_at TEXT,
        CONSTRAINT fk_alarm_trip FOREIGN KEY (trip_id)
          REFERENCES trips (trip_id) ON DELETE CASCADE
      )''');
    await d.execute('''
      CREATE TABLE overshoot_events (
        overshoot_id TEXT PRIMARY KEY,
        trip_id TEXT NOT NULL UNIQUE,
        destination_name TEXT NOT NULL,
        nearest_stop_name TEXT,
        overshot_km REAL NOT NULL,
        triggered_lat REAL NOT NULL,
        triggered_lng REAL NOT NULL,
        acknowledged INTEGER NOT NULL DEFAULT 0,
        triggered_at TEXT NOT NULL,
        acknowledged_at TEXT,
        CONSTRAINT fk_oe_trip FOREIGN KEY (trip_id)
          REFERENCES trips (trip_id) ON DELETE CASCADE
      )''');
    await d.execute('''
      CREATE TABLE sos_events (
        sos_id TEXT PRIMARY KEY,
        trip_id TEXT,
        alarm_id TEXT,
        triggered_location_label TEXT,
        triggered_lat REAL NOT NULL,
        triggered_lng REAL NOT NULL,
        contacts_notified_count INTEGER NOT NULL DEFAULT 0,
        call_911_pressed INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'active',
        triggered_at TEXT NOT NULL,
        resolved_at TEXT,
        CONSTRAINT fk_sos_trip FOREIGN KEY (trip_id)
          REFERENCES trips (trip_id) ON DELETE CASCADE,
        CONSTRAINT fk_sos_alarm FOREIGN KEY (alarm_id)
          REFERENCES alarm_events (alarm_id) ON DELETE SET NULL
      )''');

    final now = DateTime.now().toIso8601String();
    await d.insert('app_state', {'id': 1, 'updated_at': now});
    await d.insert('user_settings', {'id': 1, 'updated_at': now});
    await d.insert('transport_preferences', {'id': 1, 'updated_at': now});
    await d.insert('fake_call_config', {'id': 1, 'updated_at': now});
    // Built-in fake-call recordings (Figure 32 — Emergency screen).
    await d.insert('recordings', {
      'recording_id': 'preset-mom',
      'title': 'Mom call recording',
      'file_path': 'assets/sounds/fake_call_voice.wav',
      'duration_seconds': 20,
      'is_preset': 1,
      'recorded_at': now,
    });
    await d.insert('recordings', {
      'recording_id': 'preset-dad',
      'title': 'Dad call recording',
      'file_path': 'assets/sounds/fake_call_voice.wav',
      'duration_seconds': 20,
      'is_preset': 1,
      'recorded_at': now,
    });
  }

  // ---------- singletons ----------
  Future<AppState> getAppState() async =>
      AppState.fromMap((await (await db).query('app_state')).first);
  Future<void> saveAppState(AppState s) async => (await db)
      .update('app_state', s.toMap(), where: 'id = 1');

  Future<UserSettings> getUserSettings() async =>
      UserSettings.fromMap((await (await db).query('user_settings')).first);
  Future<void> saveUserSettings(UserSettings s) async => (await db)
      .update('user_settings', s.toMap(), where: 'id = 1');

  Future<TransportPreferences> getTransportPreferences() async =>
      TransportPreferences.fromMap(
          (await (await db).query('transport_preferences')).first);
  Future<void> saveTransportPreferences(TransportPreferences s) async =>
      (await db)
          .update('transport_preferences', s.toMap(), where: 'id = 1');

  Future<FakeCallConfig> getFakeCallConfig() async => FakeCallConfig.fromMap(
      (await (await db).query('fake_call_config')).first);
  Future<void> saveFakeCallConfig(FakeCallConfig c) async =>
      (await db).update('fake_call_config', c.toMap(), where: 'id = 1');

  // ---------- emergency contacts ----------
  Future<List<EmergencyContact>> getContacts() async =>
      (await (await db).query('emergency_contacts', orderBy: 'contact_order'))
          .map(EmergencyContact.fromMap)
          .toList();

  Future<void> upsertContact(EmergencyContact c) async => (await db).insert(
      'emergency_contacts', c.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteContact(String id) async => (await db)
      .delete('emergency_contacts', where: 'contact_id = ?', whereArgs: [id]);

  // ---------- recordings ----------
  Future<List<Recording>> getRecordings() async =>
      (await (await db).query('recordings', orderBy: 'is_preset DESC, recorded_at'))
          .map(Recording.fromMap)
          .toList();

  Future<void> insertRecording(Recording r) async =>
      (await db).insert('recordings', r.toMap());

  Future<void> deleteRecording(String id) async => (await db)
      .delete('recordings', where: 'recording_id = ? AND is_preset = 0',
          whereArgs: [id]);

  // ---------- favorites ----------
  Future<List<Favorite>> getFavorites() async =>
      (await (await db).query('favorites', orderBy: 'created_at DESC'))
          .map(Favorite.fromMap)
          .toList();

  Future<void> insertFavorite(Favorite f) async =>
      (await db).insert('favorites', f.toMap());

  Future<void> deleteFavorite(String id) async => (await db)
      .delete('favorites', where: 'favorite_id = ?', whereArgs: [id]);

  Future<Favorite?> findFavoriteAt(double lat, double lng) async {
    final rows = await (await db).query('favorites',
        where: 'ABS(lat - ?) < 0.0005 AND ABS(lng - ?) < 0.0005',
        whereArgs: [lat, lng]);
    return rows.isEmpty ? null : Favorite.fromMap(rows.first);
  }

  // ---------- trips / suggestions / steps ----------
  Future<void> insertTrip(Trip t) async =>
      (await db).insert('trips', t.toMap());
  Future<void> updateTrip(Trip t) async => (await db)
      .update('trips', t.toMap(), where: 'trip_id = ?', whereArgs: [t.tripId]);

  Future<List<Trip>> getTripHistory() async => (await (await db).query('trips',
          where: "status != 'configured'", orderBy: 'created_at DESC'))
      .map(Trip.fromMap)
      .toList();

  Future<void> insertSuggestion(RouteSuggestion s) async {
    final d = await db;
    await d.insert('route_suggestions', s.toMap());
    for (final step in s.steps) {
      await d.insert('route_steps', step.toMap());
    }
  }

  // ---------- events ----------
  Future<void> insertAlarmEvent(AlarmEvent e) async =>
      (await db).insert('alarm_events', e.toMap());

  Future<void> markAlarmDismissed(String alarmId) async =>
      (await db).update(
          'alarm_events',
          {'dismissed': 1, 'dismissed_at': DateTime.now().toIso8601String()},
          where: 'alarm_id = ?',
          whereArgs: [alarmId]);

  Future<void> insertOvershootEvent(Map<String, Object?> row) async =>
      (await db).insert('overshoot_events', row,
          conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> insertSosEvent(Map<String, Object?> row) async =>
      (await db).insert('sos_events', row);

  /// Behavioural learning input (Requirement R4): average alarm reaction
  /// time (seconds to dismiss) over the most recent completed trips.
  Future<double?> averageAwakeSeconds({int lastN = 10}) async {
    final rows = await (await db).rawQuery(
        'SELECT awake_seconds FROM trips WHERE awake_seconds IS NOT NULL '
        'ORDER BY created_at DESC LIMIT ?',
        [lastN]);
    if (rows.isEmpty) return null;
    final vals = rows.map((r) => (r['awake_seconds'] as num).toDouble());
    return vals.reduce((a, b) => a + b) / vals.length;
  }
}
