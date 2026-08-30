import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/emergency_viewmodel.dart';
import 'fake_call_view.dart';
import '../services/notification_permission_guard.dart';

/// Figure 32 — Emergency screen: press-and-hold SOS (3 s) and the
/// fake-call recording list.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] SOS GestureDetector onTapDown/Up beginSosHold/cancelSosHold
///         (the 3-second hold = accidental-trigger guard, R8) · the ring
///         animation running for EmergencyViewModel.sosHoldDuration ·
///         "Call 911" onPressed · recording ListTile onTap → startFakeCall →
///         FakeCallView · load-warning dismiss. Keep SOS red and obviously the
///         biggest tap target.
///  [EDIT] SOS button size/glow, "Press & Hold to Activate" copy, hold-hint
///         text, "Activate Fake Call" heading, recording row styling,
///         load-warning card look, Call 911 button style.
///  [WANT] haptic on hold, contact avatars.
class EmergencyView extends StatefulWidget {
  const EmergencyView({super.key});

  @override
  State<EmergencyView> createState() => _EmergencyViewState();
}

class _EmergencyViewState extends State<EmergencyView>
    with SingleTickerProviderStateMixin {
  /// Drives the hold ring at display refresh rate.
  ///
  /// This replaced a `holdProgress` value that a 100 ms timer in the ViewModel
  /// advanced in ten discrete jumps — the ring visibly stuttered, and every
  /// step rebuilt the whole screen. Its duration is taken from
  /// [EmergencyViewModel.sosHoldDuration], the same constant the firing timer
  /// uses, so the ring cannot finish early or late relative to the real guard.
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: EmergencyViewModel.sosHoldDuration,
  );

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  /// Runs the ring forward with the hold, and stops it on release. Paired with
  /// the ViewModel calls in the gesture handlers below — the ViewModel still
  /// owns whether the SOS actually fires; this only paints the countdown.
  ///
  /// `forward(from: 0)` restarts cleanly every hold, so no separate reset is
  /// needed, and the ring is painted only while `holdingSos` is true — which is
  /// why a completed run does not leave a full ring sitting on screen.
  void _startRing() => _ring.forward(from: 0);
  void _stopRing() => _ring.stop();

  @override
  Widget build(BuildContext context) {
    final em = context.watch<EmergencyViewModel>();
    final app = context.watch<AppViewModel>();

    // ╔══════════════════════════════════════════════════════════════════════╗
    // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:                     ║
    // ║ HARDWARE BACK-BUTTON GUARD, scoped to an in-flight SOS.              ║
    // ║                                                                      ║
    // ║ UI TEAM: restyle everything inside `child:`. Do NOT unwrap this      ║
    // ║ PopScope, and do NOT "simplify" `canPop: !sosInFlight` to a plain    ║
    // ║ `canPop: false` — that looks tidier and would BREAK THE WHOLE APP.   ║
    // ║ Read the reason below before touching this line.                     ║
    // ╚══════════════════════════════════════════════════════════════════════╝
    // Why this is NOT a plain canPop: false.
    //
    // EmergencyView is a TAB inside ShellView's IndexedStack, not a pushed
    // route. IndexedStack builds and mounts all five tabs at once, so this
    // PopScope registers with the SHELL's route and stays active even while
    // Home, History, Favorites or Settings is the visible tab. An unconditional
    // canPop: false here would therefore kill the hardware Back button across
    // the ENTIRE app, permanently — the rider could never back out of NavAlert
    // from any screen. There is also no route to "kill" here: Back on a tab
    // exits the app, it does not close the Emergency screen.
    //
    // What actually needs protecting is the emergency SEQUENCE, so Back is
    // blocked precisely while an SOS is being held or sent, and is released the
    // instant it finishes.
    final sosInFlight = em.holdingSos || em.sending;
    return PopScope(
      canPop: !sosInFlight,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('SOS in progress - wait for it to finish.')));
      },
      child: Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            // The insufficient-load warning used to render here. It now lives
            // on the Home screen, where the Activity Diagram (p.92) and the
            // "SOS Warning" mockup both put it: this screen is opened when the
            // rider already needs SOS, which is too late to act on the news
            // that their prepaid load may be short. See home_view.dart.
            const SizedBox(height: 16),
            // SOS press & hold (UC-7).
            GestureDetector(
              // DO NOT MODIFY LOGIC: the 3-second press-and-hold guard against
              // accidental SOS. Keep beginSosHold/cancelSosHold on down/up/
              // cancel and the onFired → _showResult callback. `holdProgress`
              // (0→1) drives the ring below — keep reading it.
              // ╔══════════════════════════════════════════════════════════╗
              // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:         ║
              // ║ SPAM-TAP DEBOUNCER (isProcessing) on the SOS hold.       ║
              // ║                                                          ║
              // ║ UI TEAM: the SOS button's size, glow, ring and copy are  ║
              // ║ all yours. Keep `onTapDown: em.sending ? null : ...` and ║
              // ║ the 3-second press-and-hold wiring (beginSosHold /       ║
              // ║ cancelSosHold on down/up/cancel). The hold IS the        ║
              // ║ accidental-trigger guard (R8); a plain onTap would fire  ║
              // ║ real SMS to every contact on one stray touch.            ║
              // ╚══════════════════════════════════════════════════════════╝
              // While an SOS is actually being sent, a new hold must not start.
              // fireSos already refuses re-entry, so this stops the ring
              // re-arming and pretending a second send began.
              onTapDown: em.sending
                  ? null
                  : (_) {
                      _startRing();
                      context.read<EmergencyViewModel>().beginSosHold(
                          onFired: () => _showResult(context));
                    },
              onTapUp: (_) {
                _stopRing();
                context.read<EmergencyViewModel>().cancelSosHold();
              },
              onTapCancel: () {
                _stopRing();
                context.read<EmergencyViewModel>().cancelSosHold();
              },
              child: Stack(alignment: Alignment.center, children: [
                SizedBox(
                  width: 220,
                  height: 220,
                  // DO NOT MODIFY LOGIC: the ring must run for exactly
                  // EmergencyViewModel.sosHoldDuration — it is the rider's only
                  // feedback on how much longer the accidental-trigger guard
                  // needs. AnimatedBuilder rebuilds ONLY the indicator, not the
                  // screen, which is what makes 60 fps affordable here.
                  child: AnimatedBuilder(
                    animation: _ring,
                    builder: (context, _) => CircularProgressIndicator(
                      value: em.holdingSos ? _ring.value : 0,
                      strokeWidth: 10,
                      // USE THEME: white ring on danger red is deliberate; if
                      // you change it keep the SOS unmistakably red
                      // (NavAlertColors.danger carries the "emergency" meaning
                      // — don't recolor it).
                      color: Colors.white,
                      backgroundColor:
                          NavAlertColors.danger.withValues(alpha: 0.3),
                    ),
                  ),
                ),
                Container(
                  width: 195,
                  height: 195,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: NavAlertColors.danger,
                    boxShadow: [
                      BoxShadow(
                          color:
                              NavAlertColors.danger.withValues(alpha: 0.6),
                          blurRadius: 60,
                          spreadRadius: 4),
                    ],
                  ),
                  // The label block is CENTRED in the circle and never wraps.
                  // "SENDING…" is nearly three times the width of "SOS" at the
                  // same 34 px, so at a fixed size it wrapped inside the 170 px
                  // plate and dropped the ellipsis onto a line of its own.
                  // FittedBox scales that one word down to fit instead, and
                  // maxLines/softWrap make wrapping impossible rather than
                  // merely unlikely.
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(em.sending ? 'SENDING…' : 'SOS',
                                  maxLines: 1,
                                  softWrap: false,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 40,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 3,
                                      color: Colors.white)),
                            ),
                            // Only while idle. Leaving "Press & Hold to
                            // Activate" under "SENDING…" told the rider to do
                            // the thing they had just finished doing, and
                            // pushed the two-line block off-centre.
                            if (!em.sending) ...[
                              const SizedBox(height: 4),
                              const Text('Press & Hold to Activate',
                                  maxLines: 1,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.white70)),
                            ],
                          ]),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            Text(
                'Hold for 3 seconds to notify ${app.contacts.isEmpty ? 'your' : app.contacts.length} contact${app.contacts.length == 1 ? '' : 's'} via SMS',
                style: const TextStyle(
                    fontSize: 12, color: NavAlertColors.textSecondary)),
            if (em.statusMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(em.statusMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: NavAlertColors.warning, fontSize: 12)),
              ),
            // Standing warning while SMS is blocked by Android's restricted
            // settings. A banner, not a dialog: this screen is a tab inside an
            // IndexedStack and is built while other tabs are visible, so
            // anything modal raised from here would surface over them. It also
            // has to be seen BEFORE an emergency — discovering the SOS cannot
            // send at the moment it is needed is the failure this prevents.
            // Notifications off means the "safety shortcuts active" notice
            // cannot be drawn — and that notice is the only sign the volume
            // shortcuts are armed. Re-prompting is useless once permanently
            // denied, so say so plainly and offer the only route that works.
            ListenableBuilder(
              listenable: NotificationPermissionGuard.instance,
              builder: (context, _) {
                final guard = NotificationPermissionGuard.instance;
                if (guard.granted) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Card(
                    color: const Color(0xFF4A2A00),
                    child: ListTile(
                      leading: const Icon(Icons.notifications_off,
                          color: NavAlertColors.warning),
                      title: const Text('Shortcut alert is hidden',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14)),
                      subtitle: const Text(
                          'Notifications are off, so nothing shows that the '
                          'volume shortcuts are armed. They still work.',
                          style: TextStyle(fontSize: 11)),
                      trailing: ElevatedButton(
                        onPressed: () async {
                          await guard.openSettings();
                          await guard.refresh();
                        },
                        child: const Text('Fix'),
                      ),
                    ),
                  ),
                );
              },
            ),
            if (em.smsPermanentlyDenied)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Card(
                  color: const Color(0xFF4A2A00),
                  child: ListTile(
                    leading: const Icon(Icons.sms_failed,
                        color: NavAlertColors.warning),
                    title: const Text('SOS cannot send SMS',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    subtitle: const Text(
                        'Android blocked SMS access for directly-installed '
                        'apps. Tap Fix to allow it.',
                        style: TextStyle(fontSize: 11)),
                    trailing: ElevatedButton(
                      onPressed: () => _showRestrictedSmsDialog(context),
                      child: const Text('Fix'),
                    ),
                  ),
                ),
              ),
            // ╔════════════════════════════════════════════════════════════╗
            // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:           ║
            // ║ CALL 911 IS A SEPARATE, CONFIRMED TRIGGER.                 ║
            // ║                                                            ║
            // ║ UI TEAM: restyle the button, keep the confirm dialog. This ║
            // ║ used to dial 911 on a SINGLE TAP with no confirmation, on  ║
            // ║ a screen used by people in a panic, directly beneath a     ║
            // ║ 190 px SOS target — a mis-tap placed a real emergency call.║
            // ║ SOS SMS, the fake call, and 911 must each need their own   ║
            // ║ deliberate action; never collapse them into one gesture.   ║
            // ╚════════════════════════════════════════════════════════════╝
            TextButton.icon(
              onPressed: () => _confirmCall911(context),
              icon: const Icon(Icons.call, color: NavAlertColors.danger),
              label: const Text('Call 911',
                  style: TextStyle(color: NavAlertColors.danger)),
            ),
            const Divider(height: 30),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Activate Fake Call',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 8),
            ...app.recordings.map((r) => Card(
                  child: ListTile(
                    title: Text(r.title),
                    // Figure 32: presets read "Built-in recording"; a rider's
                    // own clips are dated so several "Standard recording N"
                    // entries can be told apart at a glance.
                    subtitle: Text(
                        r.isPreset
                            ? 'Built-in recording'
                            : _shortDate(r.recordedAt),
                        style: const TextStyle(
                            fontSize: 11,
                            color: NavAlertColors.textSecondary)),
                    trailing: const Icon(Icons.phone_callback,
                        color: NavAlertColors.accent),
                    // Disabled outright while a fake call is already running,
                    // so the row cannot be panic-tapped into stacking screens.
                    enabled: !em.fakeCallActive,
                    onTap: () async {
                      // Bug fix: the caller name must follow the CHOSEN
                      // recording, otherwise picking "Dad call recording" still
                      // showed "Mom". Derive the display name from the recording
                      // title ("Dad call recording" → "Dad") and persist it so
                      // the call screen and lock-screen notification agree.
                      final caller = r.title.split(' ').first;
                      app.fakeCallConfig.recordingId = r.recordingId;
                      app.fakeCallConfig.callerName = caller;
                      // DO NOT MODIFY LOGIC: persisting the choice must never
                      // gate the call itself. This write used to be awaited
                      // unguarded, so a storage failure threw here and the
                      // fake call NEVER STARTED — the escape feature dying at
                      // exactly the moment the rider needs it. Remembering the
                      // selection is a convenience; launching the call is the
                      // safety feature.
                      try {
                        await app.saveFakeCallConfig();
                      } catch (_) {/* not persisted — still place the call */}
                      if (!context.mounted) return;
                      final vm = context.read<EmergencyViewModel>();
                      // Only push when this tap actually STARTED the call.
                      // startFakeCall returns false if one is already running,
                      // so panic-tapping the row cannot stack call screens.
                      final started = await vm.startFakeCall(callerName: caller);
                      if (started && context.mounted) {
                        Navigator.of(context).push(MaterialPageRoute(
                            fullscreenDialog: true,
                            builder: (_) => const FakeCallView()));
                      }
                    },
                  ),
                )),
          ]),
        ),
      ),
      ),
    );
  }

  /// Confirm before placing a REAL emergency call.
  ///
  /// DO NOT MODIFY LOGIC: 911 is a live emergency service. The dialog is the
  /// separation between "I touched the screen" and "I called the police", and
  /// it is what keeps this trigger distinct from the SOS hold beside it.
  Future<void> _confirmCall911(BuildContext context) async {
    final vm = context.read<EmergencyViewModel>();
    final confirmed = await showNavAlertConfirmDialog(
      context,
      title: 'Call 911?',
      message: 'This places a real call to emergency services.\n\n'
          'To text your location to your saved contacts instead, press and '
          'hold the SOS button for 3 seconds.',
      confirmLabel: 'Call 911',
      destructive: true,
    );
    if (confirmed == true) await vm.call911();
  }

  void _showResult(BuildContext context) {
    // DO NOT MODIFY LOGIC: this runs from the 3-second hold timer, long after
    // the tap that armed it, so the Emergency tab may be gone by the time the
    // SOS resolves. Reading a ViewModel or a ScaffoldMessenger off a defunct
    // context throws, and that throw would surface as an unhandled async error
    // on the SOS path — the one path that must never fault.
    if (!context.mounted) return;
    final em = context.read<EmergencyViewModel>();
    final msg = em.statusMessage;
    if (msg == null) return;
    // A permission fault is the one failure a SnackBar cannot help with: there
    // is nothing to retry and nothing to wait for. Walk the rider to the fix
    // instead — see [_showRestrictedSmsDialog].
    if (em.lastFailureWasPermission) {
      _showRestrictedSmsDialog(context);
      return;
    }
    // A failure has to LOOK like one. The outcome comes from `statusIsError`
    // rather than from sniffing the copy, so rewording a message can never
    // silently turn a red failure into a neutral one.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: em.statusIsError ? NavAlertColors.danger : null,
        duration: Duration(seconds: em.statusIsError ? 8 : 4),
      ));
  }

  /// Android 13+ "restricted settings" walkthrough.
  ///
  /// A sideloaded app cannot be granted SMS from an in-app prompt at all:
  /// Android marks SEND_SMS a restricted setting for anything installed outside
  /// a store, blocks it with "App was denied access to SMS", and returns denied
  /// however many times it is asked. Re-prompting is therefore useless, and
  /// silence is worse — the rider believes SOS is armed when it cannot send.
  /// The only route is the app's own Settings page, and the menu is genuinely
  /// hard to find, so the steps are spelled out rather than hinted at.
  ///
  /// DO NOT MODIFY LOGIC: raise this from an EXPLICIT event (a failed SOS, or
  /// the banner's button) — never from build(). EmergencyView is a tab inside
  /// ShellView's IndexedStack, so it is built while other tabs are on screen; a
  /// dialog scheduled from build() would pop up over Home.
  static Future<void> _showRestrictedSmsDialog(BuildContext context) async {
    final em = context.read<EmergencyViewModel>();
    final openSettings = await showNavAlertConfirmDialog(
      context,
      title: 'SMS access is blocked',
      message: 'Because this app was downloaded directly, Android '
          'restricted its SMS access.\n\n'
          "Please tap 'Settings', then tap the three dots (⋮) in the top "
          "right corner, and select 'Allow restricted settings'.",
      icon: Icons.sms_failed,
      cancelLabel: 'Not now',
      confirmLabel: 'Settings',
    );
    if (openSettings == true) await em.openSmsSettings();
    // They may have fixed it while they were away — clear the warning if so.
    await em.refreshSmsPermission();
  }

  /// dd/MM/yy — the compact form shown under custom recordings in Figure 32.
  static String _shortDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${two(d.year % 100)}';
  }
}
