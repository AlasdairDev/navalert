import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../core/legal_text.dart';
import '../core/theme.dart';
import '../services/sound_service.dart';
import '../viewmodels/app_viewmodel.dart';
import 'onboarding_flow.dart';

/// Figure 33 — Settings: permissions, alarm sound, emergency contacts,
/// fake-call recordings, and legal notices.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] each SwitchListTile onChanged → app.saveSettings · alarm
///         DropdownButton onChanged (+ previewAlarm) · Update → ContactsSetup ·
///         View → FakeCallSetup · T&C/Privacy View → LegalText.show ·
///         Import/Export onPressed (confirm dialog + app.import/exportBackup).
///  [EDIT] section header labels/casing, tile copy, "Allow/Deny" wording,
///         Import/Export button icons, legal text (core/legal_text.dart —
///         shared with the onboarding tutorial's final page, edit once),
///         row spacing, whether sections use cards or dividers.
///  [WANT] group sections with icons, add an "About/version" row, a theme
///         switch, per-setting helper subtitles.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView>
    with WidgetsBindingObserver {
  // Sentinel dropdown value distinct from any catalogue name or `custom:`
  // sound — selecting it opens the file picker instead of setting a sound.
  static const _uploadSoundValue = '__upload_sound__';

  // DO NOT MODIFY LOGIC: the REAL OS permission states, re-read on every resume.
  // Location / Battery / Notifications used to render from the stored strings in
  // UserSettings, which default to 'Allow' and which NOTHING in the app ever
  // reads. So a rider who denied location during onboarding opened Settings and
  // saw "Location Access — Allow": the screen asserted a permission the app did
  // not hold, and flipping the switch only rewrote a dead string. These three
  // tiles must reflect and drive the actual OS grant, exactly like the
  // onboarding PermissionsView does. (Bluetooth stays a stored preference — it
  // is a real feature toggle for earphone-only alarm routing, not a permission.)
  bool _location = false;
  bool _battery = false;
  bool _notifications = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncStatuses();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Returning from the OS settings page must refresh the toggles, or they stay
  // stuck at their old value after the rider has just granted the permission.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncStatuses();
  }

  Future<void> _syncStatuses() async {
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    final notif = await Permission.notification.isGranted;
    final loc = await Geolocator.checkPermission();
    if (!mounted) return;
    final granted = loc == LocationPermission.always ||
        loc == LocationPermission.whileInUse;
    setState(() {
      _battery = battery;
      _notifications = notif;
      _location = granted;
    });
    // Keep the persisted strings honest so an exported backup and the DB row
    // describe what was actually granted rather than the 'Allow' default.
    final s = context.read<AppViewModel>().settings;
    final next = [
      granted ? 'Allow' : 'Deny',
      battery ? 'Allow' : 'Deny',
      notif ? 'Allow' : 'Deny',
    ];
    if (s.locationAccess != next[0] ||
        s.optimizeBatteryUsage != next[1] ||
        s.pushNotifications != next[2]) {
      s
        ..locationAccess = next[0]
        ..optimizeBatteryUsage = next[1]
        ..pushNotifications = next[2];
      context.read<AppViewModel>().saveSettings();
    }
  }

  /// A permanently denied permission can never be re-granted by asking again —
  /// Android returns "denied" with no dialog, so the switch just flicks back off
  /// forever. The OS settings page is the only remaining route. Same contract as
  /// the onboarding flow's dialog; "Not now" must stay available because every
  /// one of these is optional.
  Future<void> _offerSettings(String what, String why) async {
    if (!mounted) return;
    final open = await showNavAlertConfirmDialog(
      context,
      title: '$what is blocked',
      message: why,
      cancelLabel: 'Not now',
      confirmLabel: 'Open Settings',
    );
    if (open == true) await openAppSettings();
  }

  Future<void> _toggleLocation(bool v) async {
    if (!v) {
      // An app cannot revoke its own permission. Saying so and offering the OS
      // page is the only honest response — silently snapping the switch back
      // would look like the dead toggle this whole screen used to be.
      await _offerSettings('Location',
          'NavAlert cannot turn location off for you. Revoke it from the '
          'system app settings. Without it, trips cannot be tracked.');
      await _syncStatuses();
      return;
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    if (p == LocationPermission.deniedForever) {
      await _offerSettings('Location',
          'Android will not ask again for Location. You can turn it on from '
          'NavAlert\'s app settings.');
    }
    await _syncStatuses();
  }

  Future<void> _togglePermission(
      bool v, Permission perm, String label, String why) async {
    if (!v) {
      await _offerSettings(label, why);
      await _syncStatuses();
      return;
    }
    await perm.request();
    if (await perm.isPermanentlyDenied) {
      await _offerSettings(label,
          'Android will not ask again for $label. You can turn it on from '
          'NavAlert\'s app settings.');
    }
    await _syncStatuses();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewModel>();
    final s = app.settings;

    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 0, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(text.toUpperCase(),
                style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1,
                    color: NavAlertColors.textSecondary)),
          ),
        );

    // Reflects a REAL OS permission — the value comes from the system, never
    // from the stored string, so this row can no longer claim a grant the app
    // does not hold.
    Widget permissionTile(
            String title, bool granted, Future<void> Function(bool) onChanged) =>
        Card(
          child: SwitchListTile(
            title: Text(title),
            subtitle: Text(granted ? 'Granted' : 'Not granted',
                style: const TextStyle(
                    fontSize: 11, color: NavAlertColors.textSecondary)),
            value: granted,
            onChanged: (v) => onChanged(v),
          ),
        );

    // A stored app preference, NOT an OS permission — this one really is just a
    // saved string (it drives earphone-only alarm routing).
    Widget allowTile(String title, String value,
            void Function(String) onChanged) =>
        Card(
          child: SwitchListTile(
            title: Text(title),
            value: value == 'Allow',
            onChanged: (v) {
              onChanged(v ? 'Allow' : 'Deny');
              app.saveSettings();
            },
          ),
        );

    return Scaffold(
      appBar:
          AppBar(title: const Text('Settings'), automaticallyImplyLeading: false),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          header('Location'),
          permissionTile('Location Access', _location, _toggleLocation),
          header('Battery Optimization'),
          permissionTile(
              'Optimize battery usage',
              _battery,
              (v) => _togglePermission(
                  v,
                  Permission.ignoreBatteryOptimizations,
                  'Battery optimization',
                  'NavAlert cannot change this for you. Adjust it from the '
                      'system app settings. Without it, Android may stop the '
                      'alarm while the screen is off.')),
          header('Notifications'),
          permissionTile(
              'Push notifications',
              _notifications,
              (v) => _togglePermission(
                  v,
                  Permission.notification,
                  'Notifications',
                  'NavAlert cannot turn notifications off for you. Change it '
                      'from the system app settings.')),
          header('Bluetooth'),
          allowTile('Enable bluetooth connection', s.bluetoothEnabled,
              (v) => s.bluetoothEnabled = v),
          header('Map'),
          Card(
            child: SwitchListTile(
              title: const Text('Map dark mode'),
              subtitle: const Text('Only changes the map tiles, the rest '
                  'of the app stays the same.',
                  style: TextStyle(
                      fontSize: 11, color: NavAlertColors.textSecondary)),
              value: app.mapDarkMode,
              onChanged: (v) => app.setMapDarkMode(v),
            ),
          ),
          header('Alarm'),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: SoundService.alarmCatalog.containsKey(s.alarmSound) ||
                          SoundService.isCustom(s.alarmSound)
                      ? s.alarmSound
                      : SoundService.alarmCatalog.keys.first,
                  dropdownColor: NavAlertColors.card,
                  items: [
                    ...SoundService.alarmCatalog.keys
                        .map((n) => DropdownMenuItem(value: n, child: Text(n))),
                    // The rider's own uploaded file, if one is active — shown
                    // by its filename so it reads like a real option, not the
                    // full on-disk path.
                    if (SoundService.isCustom(s.alarmSound))
                      DropdownMenuItem(
                        value: s.alarmSound,
                        child: Text(SoundService.customLabel(s.alarmSound),
                            overflow: TextOverflow.ellipsis),
                      ),
                    const DropdownMenuItem(
                      value: _uploadSoundValue,
                      child: Text('Upload your own audio…'),
                    ),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    if (v == _uploadSoundValue) {
                      final picked = await app.pickCustomAlarmSound();
                      if (picked == null) return;
                      s.alarmSound = picked;
                      await app.saveSettings();
                      SoundService.instance.previewAlarm(picked);
                      return;
                    }
                    s.alarmSound = v;
                    app.saveSettings();
                    SoundService.instance.previewAlarm(v);
                  },
                ),
              ),
            ),
          ),
          header('Emergency Contacts'),
          Card(
            child: ListTile(
              // Figure 33 labels the row itself ("Emergency contacts"); the
              // saved names move to the subtitle so the row still says what is
              // actually stored.
              title: const Text('Emergency contacts'),
              subtitle: Text(
                  app.contacts.isEmpty
                      ? 'No contacts saved'
                      : app.contacts.map((c) => c.name).join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11, color: NavAlertColors.textSecondary)),
              trailing: ElevatedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        const ContactsSetupView(inOnboarding: false))),
                child: const Text('Update'),
              ),
            ),
          ),
          header('Fake Call'),
          Card(
            child: ListTile(
              title: const Text('All recordings'),
              subtitle: Text(
                  '${app.recordings.length} recording'
                  '${app.recordings.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontSize: 11, color: NavAlertColors.textSecondary)),
              trailing: ElevatedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        const FakeCallSetupView(inOnboarding: false))),
                child: const Text('View'),
              ),
            ),
          ),
          header('Terms & Conditions'),
          Card(
            child: ListTile(
              title: const Text('Terms & Conditions'),
              trailing: ElevatedButton(
                  onPressed: () => LegalText.show(context, LegalText.terms),
                  child: const Text('View')),
            ),
          ),
          header('Privacy Policy'),
          Card(
            child: ListTile(
              title: const Text('Privacy Policy'),
              trailing: ElevatedButton(
                  onPressed: () => LegalText.show(context, LegalText.privacy),
                  child: const Text('View')),
            ),
          ),
          header('Data Backup'),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.file_download, size: 18),
                  label: const Text('Import'),
                  onPressed: () => _importBackup(context),
                ),
                const SizedBox(width: 14),
                ElevatedButton.icon(
                  icon: const Icon(Icons.file_upload, size: 18),
                  label: const Text('Export'),
                  onPressed: () async {
                    final app = context.read<AppViewModel>();
                    final messenger = ScaffoldMessenger.of(context);
                    final path = await app.exportBackup();
                    messenger.showSnackBar(SnackBar(
                        content: Text(path == null
                            ? 'Export failed - could not write the backup '
                                'file. Check your storage space.'
                            : 'Backup exported to $path')));
                  },
                ),
              ]),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Figure 33 — Data Backup: pick one of the exported backup files.
  // DO NOT MODIFY LOGIC: Import OVERWRITES the user's current settings,
  // contacts and favorites — the confirm dialog below is required. Keep the
  // list → confirm → importBackup flow; dialog copy/look are [EDIT].
  Future<void> _importBackup(BuildContext context) async {
    final app = context.read<AppViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    final backups = await app.listBackups();
    if (!context.mounted) return;
    if (backups.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('No backups found - use Export first.')));
      return;
    }
    final chosen = await showDialog<int>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Import backup'),
        children: [
          for (var i = 0; i < backups.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(i),
              child: Text(backups[i].path.split(RegExp(r'[\\/]')).last),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    if (!context.mounted) return;
    // Importing overwrites the current data — confirm before applying.
    final confirmed = await showNavAlertConfirmDialog(
      context,
      title: 'Import this backup?',
      message: '${backups[chosen].path.split(RegExp(r'[\\/]')).last}\n\n'
          'Your current contacts, favorites, trip history and settings '
          'will be replaced by the data in this backup. This cannot be '
          'undone.',
      confirmLabel: 'Import',
      destructive: true,
    );
    if (confirmed != true) return;
    final err = await app.importBackup(backups[chosen]);
    messenger.showSnackBar(
        SnackBar(content: Text(err ?? 'Backup imported successfully.')));
  }

}
