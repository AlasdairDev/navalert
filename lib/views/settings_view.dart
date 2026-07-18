import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
///         View → FakeCallSetup · T&C/Privacy View → _showLegal · Import/Export
///         onPressed (confirm dialog + app.import/exportBackup).
///  [EDIT] section header labels/casing, tile copy, "Allow/Deny" wording,
///         Import/Export button icons, legal dialog text (_terms/_privacy),
///         row spacing, whether sections use cards or dividers.
///  [WANT] group sections with icons, add an "About/version" row, a theme
///         switch, per-setting helper subtitles.
class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

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
          allowTile('Location Access', s.locationAccess,
              (v) => s.locationAccess = v),
          header('Battery Optimization'),
          allowTile('Optimize battery usage', s.optimizeBatteryUsage,
              (v) => s.optimizeBatteryUsage = v),
          header('Notifications'),
          allowTile('Push notifications', s.pushNotifications,
              (v) => s.pushNotifications = v),
          header('Bluetooth'),
          allowTile('Enable bluetooth connection', s.bluetoothEnabled,
              (v) => s.bluetoothEnabled = v),
          header('Alarm'),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: SoundService.alarmCatalog.containsKey(s.alarmSound)
                      ? s.alarmSound
                      : SoundService.alarmCatalog.keys.first,
                  dropdownColor: NavAlertColors.card,
                  items: SoundService.alarmCatalog.keys
                      .map((n) => DropdownMenuItem(value: n, child: Text(n)))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
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
              title: Text(app.contacts.isEmpty
                  ? 'No contacts saved'
                  : app.contacts.map((c) => c.name).join(', ')),
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
              title: Text('${app.recordings.length} recording(s)'),
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
                  onPressed: () => _showLegal(context, _terms),
                  child: const Text('View')),
            ),
          ),
          header('Privacy Policy'),
          Card(
            child: ListTile(
              title: const Text('Privacy Policy'),
              trailing: ElevatedButton(
                  onPressed: () => _showLegal(context, _privacy),
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
                            ? 'Export cancelled.'
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
  Future<void> _importBackup(BuildContext context) async {
    final app = context.read<AppViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    final backups = await app.listBackups();
    if (!context.mounted) return;
    if (backups.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('No backups found — use Export first.')));
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import this backup?'),
        content: Text(
          '${backups[chosen].path.split(RegExp(r'[\\/]')).last}\n\n'
          'Your current contacts, favorites, trip history and settings '
          'will be replaced by the data in this backup. This cannot be '
          'undone.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Import',
                style: TextStyle(
                    color: NavAlertColors.danger,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final err = await app.importBackup(backups[chosen]);
    messenger.showSnackBar(
        SnackBar(content: Text(err ?? 'Backup imported successfully.')));
  }

  void _showLegal(BuildContext context, String text) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('NavAlert'),
        content: SingleChildScrollView(
            child: Text(text, style: const TextStyle(fontSize: 13))),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close')),
        ],
      ),
    );
  }

  static const _terms =
      'NavAlert is a capstone research prototype of the Polytechnic University '
      'of the Philippines. Route, fare and travel-time figures are estimates '
      'and may not reflect real-time changes such as route suspensions or '
      'fare adjustments. Alarms are designed to be loud and strong, but the '
      'system cannot guarantee that every user will wake up. The emergency '
      'SMS feature requires sufficient prepaid load.';

  static const _privacy =
      'In compliance with the Data Privacy Act of 2012 (RA 10173), all '
      'personal data — trip history, saved routes, emergency contacts and '
      'behavioural data — is stored only on this device in a local SQLite '
      'database. NavAlert has no backend server and transmits no personal '
      'data to any first party. Location is used solely for on-device alarm '
      'computation and, when you trigger SOS, inside the SMS sent to your '
      'chosen contacts.';
}
