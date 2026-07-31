import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/emergency_viewmodel.dart';
import '../services/sound_service.dart';
import 'shell.dart';

// ═══════════════════════════════════════════════════════════════════════
//  ONBOARDING FLOW (Figures 15–18) — four screens in order:
//    TutorialView → PermissionsView → ContactsSetupView → FakeCallSetupView
//  UI/UX MAP (see legend in core/theme.dart):
//   [NEED] the ORDER and the _next()/pushReplacement chain · Permissions
//          toggles calling _toggle/_toggleLocation (real OS requests) ·
//          Contacts _save (validates phone, app.saveContact) · FakeCall
//          _save → app.completeOnboarding() → ShellView (this is the ONLY
//          place onboarding is marked complete) · "Skip for now" routing.
//   [EDIT] every slide's icon/title/subtitle (_pages list), page-dot style,
//          Skip/Next/Continue/Save button copy, permission tile icons/text,
//          contact field hints, fake-call setup layout. All cosmetic.
//   [WANT] replace tutorial icons with the real illustration assets in
//          "Tutorial Pages assets/", add progress bar, animate transitions.
// ═══════════════════════════════════════════════════════════════════════

// =====================================================================
// Figure 15 — Welcome / Tutorial Screen
// =====================================================================
class TutorialView extends StatefulWidget {
  const TutorialView({super.key});

  @override
  State<TutorialView> createState() => _TutorialViewState();
}

class _TutorialViewState extends State<TutorialView> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose(); // was leaked on every pass through onboarding
    super.dispose();
  }

  static const _pages = [
    (Icons.airline_seat_recline_extra, 'Welcome to NavAlert.',
        'Never miss your stop again.'),
    (Icons.route, 'Know your commute.',
        'Fastest routes, boarding points, fares and step-by-step guidance for jeepney, bus and UV Express.'),
    (Icons.speed, 'Adaptive smart alarm.',
        'Trigger distance adjusts to real-time vehicle speed and learns from how you wake up.'),
    (Icons.alarm, 'Three escalating stages.',
        'Gentle vibration, louder alert, then a full-screen emergency alarm you cannot sleep through.'),
    (Icons.sos, 'Emergency SOS.',
        'Hold the SOS button to text your exact GPS location to trusted contacts — even without internet.'),
    (Icons.phone_in_talk, 'Fake call escape.',
        'Simulate a realistic incoming call to discreetly exit unsafe situations.'),
  ];

  void _next() {
    if (_page == _pages.length - 1) {
      _skip();
    } else {
      _controller.nextPage(
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void _skip() => Navigator.of(context)
      .pushReplacement(MaterialPageRoute(builder: (_) => const PermissionsView()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) {
                  final (icon, title, sub) = _pages[i];
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 120, color: NavAlertColors.accent),
                        const SizedBox(height: 36),
                        Text(title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        Text(sub,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: NavAlertColors.textSecondary,
                                fontSize: 15)),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _pages.length,
                (i) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 18 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == _page
                        ? NavAlertColors.accent
                        : NavAlertColors.surface,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Expanded(
                      child: OutlinedButton(
                          onPressed: _skip, child: const Text('Skip'))),
                  const SizedBox(width: 16),
                  Expanded(
                      child: ElevatedButton(
                          onPressed: _next,
                          child: Text(_page == _pages.length - 1
                              ? 'Get Started'
                              : 'Next'))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// Figure 16 — Permissions Request Screen
// =====================================================================
class PermissionsView extends StatefulWidget {
  const PermissionsView({super.key});

  @override
  State<PermissionsView> createState() => _PermissionsViewState();
}

class _PermissionsViewState extends State<PermissionsView>
    with WidgetsBindingObserver {
  bool _notifications = false;
  bool _location = false;
  bool _bluetooth = false;
  bool _battery = false;

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

  // DO NOT MODIFY LOGIC (observer + _syncStatuses): Batch 2 fix. When the user
  // returns from a system settings page (e.g. battery optimization), re-read the
  // real permission states so the toggles reflect what was actually granted
  // instead of staying stuck off. Removing the observer or this resumed-hook
  // re-introduces the "battery toggle snaps back to off" bug.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncStatuses();
  }

  Future<void> _syncStatuses() async {
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    final bluetooth = await Permission.bluetoothConnect.isGranted;
    final notif = await Permission.notification.isGranted;
    final loc = await Geolocator.checkPermission();
    if (!mounted) return;
    setState(() {
      _battery = battery;
      _bluetooth = bluetooth;
      _notifications = notif;
      _location = loc == LocationPermission.always ||
          loc == LocationPermission.whileInUse;
    });
  }

  /// DO NOT MODIFY LOGIC: a permanently denied permission can NEVER be granted
  /// by asking again — Android returns "denied" immediately without showing any
  /// dialog, so the toggle just flicks back off forever and the rider is stuck
  /// tapping a control that will never work. The OS settings page is the only
  /// remaining route, so offer it explicitly. "Not now" must stay available:
  /// every one of these permissions is optional, and none may block onboarding.
  Future<void> _offerSettings(String what) async {
    if (!mounted) return;
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$what is blocked'),
        content: Text(
            'Android will not ask again for $what. You can turn it on from '
            'NavAlert\'s app settings. The app still works without it, with '
            'reduced functionality.',
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Not now')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Open Settings')),
        ],
      ),
    );
    if (open == true) await openAppSettings();
  }

  /// DO NOT MODIFY LOGIC: the tile promises "Location (Always)" and the
  /// manifest declares ACCESS_BACKGROUND_LOCATION, but on Android 10+ the
  /// background grant is SEPARATE and can only be requested once foreground
  /// access is already held — asking up front is auto-denied without a prompt,
  /// which is why "Always" never actually took effect. Best-effort by design:
  /// the trip alarm still runs via the foreground service without it, so a
  /// refusal here must never block onboarding.
  Future<void> _requestBackgroundLocation() async {
    try {
      if (await Permission.locationAlways.isGranted) return;
      await Permission.locationAlways.request();
    } catch (_) {/* older OS, or no background support — foreground is enough */}
  }

  Future<void> _toggleLocation(bool v) async {
    if (v) {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      _location = p == LocationPermission.always ||
          p == LocationPermission.whileInUse;
      if (p == LocationPermission.deniedForever) {
        await _offerSettings('Location');
      } else if (_location) {
        await _requestBackgroundLocation();
      }
    } else {
      _location = false;
    }
    if (mounted) setState(() {});
  }

  // DO NOT MODIFY LOGIC: these fire the REAL OS permission dialogs
  // (Figure 16). Each permission must also be declared in AndroidManifest.xml
  // or the request is auto-denied. Restyle the permission tiles; keep the
  // request calls and the granted-state wiring.
  Future<void> _toggle(
      Permission perm, void Function(bool) set, bool v, String label) async {
    if (v) {
      await perm.request();
      // Re-read the ACTUAL status rather than trusting request()'s return.
      // ignoreBatteryOptimizations opens a system settings page and the
      // immediate result is often stale — checking .isGranted after it settles
      // reflects what the user actually chose, so the toggle stops snapping back.
      set(await perm.isGranted);
      // "Deny" twice makes Android stop asking. Without this the toggle is
      // simply dead from then on, with nothing explaining why.
      if (await perm.isPermanentlyDenied) await _offerSettings(label);
    } else {
      set(false);
    }
    if (mounted) setState(() {});
  }

  void _continue() => Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ContactsSetupView()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 24),
              const Icon(Icons.verified_user,
                  size: 64, color: NavAlertColors.accent),
              const SizedBox(height: 16),
              const Text('Permissions Requests',
                  style:
                      TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                'NavAlert needs the following permissions to wake you by location.',
                textAlign: TextAlign.center,
                style: TextStyle(color: NavAlertColors.textSecondary),
              ),
              const SizedBox(height: 24),
              _permTile(Icons.notifications, 'Notifications',
                  'Show alarms and alerts.', _notifications,
                  (v) => _toggle(Permission.notification,
                      (g) => _notifications = g, v, 'Notifications')),
              _permTile(Icons.location_on, 'Location (Always)',
                  'Track your trip even when the app is closed.', _location,
                  _toggleLocation),
              _permTile(Icons.bluetooth, 'Bluetooth',
                  'Allow ear-phone only detection.', _bluetooth,
                  (v) => _toggle(Permission.bluetoothConnect,
                      (g) => _bluetooth = g, v, 'Bluetooth')),
              _permTile(Icons.battery_saver, 'Optimize Battery',
                  'Allow alarms to run reliably in the background.', _battery,
                  (v) => _toggle(Permission.ignoreBatteryOptimizations,
                      (g) => _battery = g, v, 'Battery optimization')),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                    onPressed: _continue, child: const Text('Continue')),
              ),
              TextButton(
                  onPressed: _continue,
                  child: const Text('Skip for now ›',
                      style:
                          TextStyle(color: NavAlertColors.textSecondary))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _permTile(IconData icon, String title, String sub, bool value,
      Future<void> Function(bool) onChanged) {
    return Card(
      child: SwitchListTile(
        secondary: Icon(icon, color: NavAlertColors.accent),
        title: Text(title),
        subtitle: Text(sub,
            style: const TextStyle(
                color: NavAlertColors.textSecondary, fontSize: 12)),
        value: value,
        onChanged: (v) => onChanged(v),
      ),
    );
  }
}

// =====================================================================
// Figure 17 — Emergency Contacts Setup
// =====================================================================
/// DO NOT MODIFY LOGIC: shown on the setup screens when the local database
/// could not be read. Without it the rider just sees an empty contact form and
/// an untappable "Select Recording" dropdown with no explanation — the exact
/// silent failure that made "can't save contacts / recordings" so hard to
/// diagnose. Restyle it freely; keep the Retry action wired to retryLoad().
class _StorageErrorBanner extends StatelessWidget {
  const _StorageErrorBanner();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewModel>();
    if (!app.dataUnavailable) return const SizedBox.shrink();
    return Card(
      color: NavAlertColors.warning.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const Icon(Icons.warning_amber, color: NavAlertColors.warning),
          const SizedBox(width: 10),
          Expanded(
              child: Text(app.loadError!,
                  style: const TextStyle(fontSize: 12))),
          TextButton(
              onPressed: app.retryLoad, child: const Text('Retry')),
        ]),
      ),
    );
  }
}

/// One validated emergency-contact row, ready to persist.
typedef ContactEntry = ({int order, String name, String phone});

/// UC-2 Flow A — a bad number must be rejected before saving, or the SOS SMS
/// would fail silently in an emergency. Allows the common Philippine formats
/// (09171234567, +639171234567, and space/dash grouping).
final _phonePattern = RegExp(r'^\+?[0-9\- ]{7,15}$');

/// Pure validation of the three Emergency Contacts rows (Figure 17), split out
/// of the View so it is directly unit-testable (see contact_form_test.dart).
///
/// DO NOT MODIFY LOGIC: a row with only ONE of name/phone filled is an
/// explicit, named ERROR — never silently skipped. Skipping it was the cause
/// of the "can't save then continue" bug: Continue saved nothing, and outside
/// onboarding the screen then closed as if it had worked, losing the rider's
/// input with no warning. Only a completely untouched row is skipped.
({List<ContactEntry> entries, String? error}) validateContactRows(
    List<String> names, List<String> phones) {
  const none = <ContactEntry>[];
  final entries = <ContactEntry>[];
  for (var i = 0; i < 3; i++) {
    final name = (i < names.length ? names[i] : '').trim();
    final phone = (i < phones.length ? phones[i] : '').trim();
    if (name.isEmpty && phone.isEmpty) continue; // untouched row — fine
    if (name.isEmpty) {
      return (entries: none, error: 'Contact ${i + 1}: enter a name.');
    }
    if (phone.isEmpty) {
      return (entries: none, error: 'Contact ${i + 1}: enter a phone number.');
    }
    if (!_phonePattern.hasMatch(phone)) {
      return (entries: none, error: 'Contact ${i + 1}: invalid phone number.');
    }
    entries.add((order: i + 1, name: name, phone: phone));
  }
  return (entries: entries, error: null);
}

class ContactsSetupView extends StatefulWidget {
  const ContactsSetupView({super.key, this.inOnboarding = true});
  final bool inOnboarding;

  @override
  State<ContactsSetupView> createState() => _ContactsSetupViewState();
}

class _ContactsSetupViewState extends State<ContactsSetupView> {
  final _names = List.generate(3, (_) => TextEditingController());
  final _phones = List.generate(3, (_) => TextEditingController());

  @override
  void dispose() {
    // Six controllers leaked on EVERY visit, and this screen is reopened
    // from Settings > Emergency Contacts > Update, so it accumulated.
    for (final c in [..._names, ..._phones]) {
      c.dispose();
    }
    super.dispose();
  }
  // Figure 17 shows two views: an intro card first, then the input form.
  late bool _showIntro = widget.inOnboarding;

  @override
  void initState() {
    super.initState();
    final contacts = context.read<AppViewModel>().contacts;
    for (var i = 0; i < contacts.length && i < 3; i++) {
      _names[i].text = contacts[i].name;
      _phones[i].text = contacts[i].phoneNumber;
    }
  }

  // DO NOT MODIFY LOGIC: saves up to 3 emergency contacts with phone-number
  // validation (UC-2 Flow A — an invalid number must be rejected before save,
  // or SOS SMS would fail). Keep the validation + saveContact; the error
  // SnackBar copy is [EDIT].
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // DO NOT MODIFY LOGIC: in-flight guard. Continue writes to the database and
  // then navigates; a second tap while the first is still saving duplicates
  // the writes and pushes the next screen twice.
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    _saving = true;
    try {
      await _runSave();
    } finally {
      if (mounted) _saving = false;
    }
  }

  Future<void> _runSave() async {
    final app = context.read<AppViewModel>();

    // DO NOT MODIFY LOGIC: validate FIRST and surface the exact problem. A
    // half-filled row used to be skipped in silence, which is what made
    // Continue appear to do nothing (in onboarding) or close the screen
    // without saving (from Settings / the Home banner).
    final result = validateContactRows(
        [for (final c in _names) c.text], [for (final c in _phones) c.text]);
    if (result.error != null) {
      _toast(result.error!);
      return;
    }

    if (result.entries.isEmpty) {
      // Nothing was typed at all.
      if (widget.inOnboarding) {
        _toast('Add at least one contact, or tap Skip for now.');
        return;
      }
      _next(); // opened from Settings and left untouched — just close.
      return;
    }

    var saved = 0;
    for (final e in result.entries) {
      final existing =
          app.contacts.where((c) => c.contactOrder == e.order).toList();
      // A failed write must surface an error, never silently swallow the tap.
      try {
        await app.saveContact(
            contactId: existing.isEmpty ? null : existing.first.contactId,
            name: e.name,
            phone: e.phone,
            order: e.order);
        saved++;
      } catch (_) {
        _toast('Could not save contact ${e.order} — please try again.');
        return;
      }
    }

    // Grant SEND_SMS now, while we're in the foreground with a dialog we can
    // show. A background SOS (screen off, volume shortcut) cannot request a
    // permission headlessly — so if it isn't granted here, the automatic SMS
    // would silently fail later. Requesting at contact-setup is the right time.
    // Time-boxed so a stuck permission dialog can never block Continue.
    if (saved > 0 && !await Permission.sms.isGranted) {
      try {
        await Permission.sms.request().timeout(const Duration(seconds: 20));
      } catch (_) {/* denied, or dialog stalled — proceed regardless */}
    }
    if (!mounted) return;

    // DO NOT MODIFY LOGIC: never navigate away as if the save succeeded when
    // nothing was written — that is silent data loss. This check is NOT gated
    // on inOnboarding: the Settings and Home-banner entry points need it most.
    if (saved == 0) {
      _toast('Nothing was saved — please check the details and try again.');
      return;
    }
    _next();
  }

  void _next() {
    if (widget.inOnboarding) {
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const FakeCallSetupView()));
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showIntro) return _buildIntro();
    return Scaffold(
      appBar: widget.inOnboarding
          ? null
          : AppBar(title: const Text('Emergency Contacts')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(Icons.contacts, size: 56, color: NavAlertColors.accent),
              const SizedBox(height: 12),
              const Text('Add Emergency Contacts',
                  style:
                      TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                'Your emergency contacts will be notified with your location '
                'via SMS when you activate SOS — even without internet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: NavAlertColors.textSecondary),
              ),
              const SizedBox(height: 12),
              const _StorageErrorBanner(),
              const SizedBox(height: 8),
              for (var i = 0; i < 3; i++) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      TextField(
                        controller: _names[i],
                        decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.person),
                            hintText: 'Enter name ${i + 1}'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _phones[i],
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.phone),
                            hintText: 'Enter phone number'),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                    onPressed: _save, child: const Text('Continue')),
              ),
              if (widget.inOnboarding)
                TextButton(
                    onPressed: _next,
                    child: const Text('Skip for now ›',
                        style:
                            TextStyle(color: NavAlertColors.textSecondary))),
            ],
          ),
        ),
      ),
    );
  }

  /// Figure 17 (first view) — intro card before the input form.
  Widget _buildIntro() {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              const Icon(Icons.contacts, size: 56, color: NavAlertColors.accent),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Add 3 Emergency Contacts',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    const Text(
                      'Your emergency contacts will be notified with your '
                      'location via SMS when you activate SOS — even '
                      'without internet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: NavAlertColors.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                        onPressed: () => setState(() => _showIntro = false),
                        child: const Text('Continue')),
                  ]),
                ),
              ),
              const Spacer(),
              Align(
                alignment: Alignment.bottomRight,
                child: TextButton(
                    onPressed: _next,
                    child: const Text('Skip for now ›',
                        style:
                            TextStyle(color: NavAlertColors.textSecondary))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// Figure 18 — Fake Call Setup Screen
// =====================================================================
class FakeCallSetupView extends StatefulWidget {
  const FakeCallSetupView({super.key, this.inOnboarding = true});
  final bool inOnboarding;

  @override
  State<FakeCallSetupView> createState() => _FakeCallSetupViewState();
}

class _FakeCallSetupViewState extends State<FakeCallSetupView> {
  late final TextEditingController _callerCtrl;

  @override
  void initState() {
    super.initState();
    _callerCtrl = TextEditingController(
        text: context.read<AppViewModel>().fakeCallConfig.callerName);
  }

  @override
  void dispose() {
    _callerCtrl.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // DO NOT MODIFY LOGIC: every branch must give feedback. A recording that
  // silently fails to save leaves the rider with a "Record New" button that
  // appears to do nothing.
  Future<void> _recordNew() async {
    final em = context.read<EmergencyViewModel>();
    final app = context.read<AppViewModel>();
    if (!em.recording) {
      final ok = await em.startRecording();
      if (!ok) {
        _toast('Microphone permission is required to record.');
      }
    } else {
      final path = await em.stopRecording();
      if (path == null) {
        _toast('Recording failed — nothing was captured.');
      } else {
        try {
          final title =
              'Custom recording ${app.recordings.where((r) => !r.isPreset).length + 1}';
          await app.addRecording(title, path);
          // firstWhereOrNull-style lookup: lastWhere THROWS when the new row
          // cannot be found, which would lose the recording behind an
          // unhandled error.
          final saved =
              app.recordings.where((r) => r.filePath == path).toList();
          if (saved.isNotEmpty) {
            app.fakeCallConfig.recordingId = saved.last.recordingId;
            await app.saveFakeCallConfig();
          }
          _toast('Recording saved.');
        } catch (_) {
          _toast('Could not save the recording — storage is unavailable.');
        }
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _preview() async {
    final rec = context.read<AppViewModel>().selectedRecording;
    if (rec == null) {
      _toast('No recording selected yet.');
      return;
    }
    await SoundService.instance.playVoice(rec.filePath);
  }

  /// Click-to-confirm deletion, matching the trip/favorite pattern: nothing is
  /// removed until the rider explicitly confirms in the dialog.
  ///
  /// DO NOT MODIFY LOGIC: stop the audio first. Deleting the .m4a while
  /// SoundService still holds it open leaves the player pointing at a file that
  /// no longer exists, and on Android the delete can fail outright because the
  /// handle is locked — so the row would vanish while the file stayed behind.
  Future<void> _deleteSelectedRecording() async {
    final app = context.read<AppViewModel>();
    final rec = app.selectedRecording;
    if (rec == null || rec.isPreset) return;
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this recording?'),
        content: Text(
          '${rec.title}\n\nThis permanently removes the recording from your '
          'device. This cannot be undone.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(
                    color: NavAlertColors.danger,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await SoundService.instance.stopVoice();
    } catch (_) {/* nothing was playing — proceed with the delete */}

    try {
      await app.removeRecording(rec.recordingId);
      messenger.showSnackBar(SnackBar(content: Text('${rec.title} deleted.')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not delete — storage is unavailable.')));
    }
    if (mounted) setState(() {});
  }

  // In-flight guard: Save/Skip completes onboarding and then replaces the whole
  // navigation stack, so a double tap could run completeOnboarding twice and
  // push two shells.
  bool _saving = false;

  // DO NOT MODIFY LOGIC: a storage failure must NEVER trap the rider on this
  // screen. Save/Skip is the last step of onboarding — if the write throws and
  // we do not navigate, the app can never be reached at all. Persist
  // best-effort, warn, then continue regardless.
  Future<void> _save() async {
    if (_saving) return;
    _saving = true;
    try {
      await _runSave();
    } finally {
      // DO NOT MODIFY LOGIC: the guard MUST be released. Without this the flag
      // latched on the first tap and never cleared, so anything that threw on
      // the way out (the audio stop, the navigation) left Save AND "Skip for
      // now" permanently dead — and both are the only exits from the last step
      // of onboarding, so the rider could never reach the app.
      if (mounted) _saving = false;
    }
  }

  Future<void> _runSave() async {
    final app = context.read<AppViewModel>();
    try {
      await SoundService.instance.stopVoice();
    } catch (_) {/* audio teardown must never block finishing setup */}
    // Persist the caller name exactly as typed (Save must not require
    // pressing Enter on the keyboard first).
    final name = _callerCtrl.text.trim();
    app.fakeCallConfig.callerName = name.isEmpty ? 'Mom' : name;
    var stored = true;
    try {
      await app.saveFakeCallConfig();
      if (widget.inOnboarding) await app.completeOnboarding();
    } catch (_) {
      stored = false;
    }
    if (!mounted) return;
    if (!stored) {
      _toast('Saved locally only — storage is unavailable.');
    }
    if (widget.inOnboarding) {
      Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ShellView()), (_) => false);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewModel>();
    final em = context.watch<EmergencyViewModel>();
    return Scaffold(
      appBar: widget.inOnboarding
          ? null
          : AppBar(title: const Text('Fake Call Setup')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 24),
              const Icon(Icons.phone_in_talk,
                  size: 56, color: NavAlertColors.accent),
              const SizedBox(height: 12),
              const Text('Fake Call Setup',
                  style:
                      TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                'Choose or record the audio that plays during a fake call so '
                'you can believably exit unsafe situations.',
                textAlign: TextAlign.center,
                style: TextStyle(color: NavAlertColors.textSecondary),
              ),
              const SizedBox(height: 12),
              const _StorageErrorBanner(),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: app.selectedRecording?.recordingId,
                      hint: const Text('Select Recording'),
                      // Shown only if the recordings list is somehow empty, so
                      // the control never looks like a silently-dead button.
                      disabledHint: const Text('No recordings available'),
                      dropdownColor: NavAlertColors.card,
                      items: app.recordings
                          .map((r) => DropdownMenuItem(
                              value: r.recordingId, child: Text(r.title)))
                          .toList(),
                      onChanged: (v) {
                        app.fakeCallConfig.recordingId = v;
                        app.saveFakeCallConfig();
                      },
                    ),
                  ),
                ),
              ),
              // Delete the selected CUSTOM recording. The row does not render
              // at all for built-in presets — they are bundled assets and
              // deleting one would leave the fake call with no fallback clip.
              if (app.selectedRecording != null &&
                  !app.selectedRecording!.isPreset)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _deleteSelectedRecording,
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: NavAlertColors.danger),
                    label: const Text('Delete this recording',
                        style: TextStyle(color: NavAlertColors.danger)),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.badge),
                    hintText: 'Caller name (e.g. Mom)'),
                controller: _callerCtrl,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _recordNew,
                    icon: Icon(em.recording ? Icons.stop : Icons.fiber_manual_record,
                        color: em.recording ? NavAlertColors.danger : null),
                    label: Text(em.recording ? 'Stop Recording' : 'Record New'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                      onPressed: _preview,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play')),
                ],
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child:
                    ElevatedButton(onPressed: _save, child: const Text('Save')),
              ),
              if (widget.inOnboarding)
                TextButton(
                    onPressed: _save,
                    child: const Text('Skip for now ›',
                        style:
                            TextStyle(color: NavAlertColors.textSecondary))),
            ],
          ),
        ),
      ),
    );
  }
}
