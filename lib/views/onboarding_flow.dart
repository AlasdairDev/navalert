import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/emergency_viewmodel.dart';
import '../services/sound_service.dart';
import 'shell.dart';

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

class _PermissionsViewState extends State<PermissionsView> {
  bool _notifications = false;
  bool _location = false;
  bool _bluetooth = false;
  bool _battery = false;

  Future<void> _toggleLocation(bool v) async {
    if (v) {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      _location = p == LocationPermission.always ||
          p == LocationPermission.whileInUse;
    } else {
      _location = false;
    }
    setState(() {});
  }

  Future<void> _toggle(Permission perm, void Function(bool) set, bool v) async {
    if (v) {
      final st = await perm.request();
      set(st.isGranted);
    } else {
      set(false);
    }
    setState(() {});
  }

  void _continue() => Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ContactsSetupView()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
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
                      (g) => _notifications = g, v)),
              _permTile(Icons.location_on, 'Location (Always)',
                  'Track your trip even when the app is closed.', _location,
                  _toggleLocation),
              _permTile(Icons.bluetooth, 'Bluetooth',
                  'Allow ear-phone only detection.', _bluetooth,
                  (v) => _toggle(
                      Permission.bluetoothConnect, (g) => _bluetooth = g, v)),
              _permTile(Icons.battery_saver, 'Optimize Battery',
                  'Allow alarms to run reliably in the background.', _battery,
                  (v) => _toggle(Permission.ignoreBatteryOptimizations,
                      (g) => _battery = g, v)),
              const Spacer(),
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
class ContactsSetupView extends StatefulWidget {
  const ContactsSetupView({super.key, this.inOnboarding = true});
  final bool inOnboarding;

  @override
  State<ContactsSetupView> createState() => _ContactsSetupViewState();
}

class _ContactsSetupViewState extends State<ContactsSetupView> {
  final _names = List.generate(3, (_) => TextEditingController());
  final _phones = List.generate(3, (_) => TextEditingController());
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

  Future<void> _save() async {
    final app = context.read<AppViewModel>();
    var saved = 0;
    for (var i = 0; i < 3; i++) {
      final name = _names[i].text.trim();
      final phone = _phones[i].text.trim();
      if (name.isEmpty || phone.isEmpty) continue;
      if (!RegExp(r'^\+?[0-9\- ]{7,15}$').hasMatch(phone)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Contact ${i + 1}: invalid phone number.')));
        return;
      }
      final existing =
          app.contacts.where((c) => c.contactOrder == i + 1).toList();
      await app.saveContact(
          contactId: existing.isEmpty ? null : existing.first.contactId,
          name: name,
          phone: phone,
          order: i + 1);
      saved++;
    }
    if (!mounted) return;
    if (saved == 0 && widget.inOnboarding) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add at least one contact, or tap Skip for now.')));
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
              const SizedBox(height: 20),
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
  Future<void> _recordNew() async {
    final em = context.read<EmergencyViewModel>();
    final app = context.read<AppViewModel>();
    if (!em.recording) {
      final ok = await em.startRecording();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Microphone permission is required to record.')));
      }
    } else {
      final path = await em.stopRecording();
      if (path != null) {
        await app.addRecording(
            'Custom recording ${app.recordings.where((r) => !r.isPreset).length + 1}',
            path);
        app.fakeCallConfig.recordingId = app.recordings
            .lastWhere((r) => r.filePath == path)
            .recordingId;
        await app.saveFakeCallConfig();
      }
    }
    setState(() {});
  }

  Future<void> _preview() async {
    final app = context.read<AppViewModel>();
    final rec = app.selectedRecording;
    if (rec != null) await SoundService.instance.playVoice(rec.filePath);
  }

  Future<void> _save() async {
    final app = context.read<AppViewModel>();
    await SoundService.instance.stopVoice();
    await app.saveFakeCallConfig();
    if (!mounted) return;
    if (widget.inOnboarding) {
      await app.completeOnboarding();
      if (!mounted) return;
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
        child: Padding(
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
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: app.selectedRecording?.recordingId,
                      hint: const Text('Select Recording'),
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
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.badge),
                    hintText: 'Caller name (e.g. Mom)'),
                controller:
                    TextEditingController(text: app.fakeCallConfig.callerName),
                onSubmitted: (v) {
                  app.fakeCallConfig.callerName = v.isEmpty ? 'Mom' : v;
                  app.saveFakeCallConfig();
                },
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
              const Spacer(),
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
