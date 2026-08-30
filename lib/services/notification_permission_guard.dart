import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Keeps POST_NOTIFICATIONS granted for the life of the install, not just at
/// onboarding.
///
/// WHY THIS EXISTS
/// The shortcut service's notification is the ONLY thing telling a commuter the
/// volume shortcuts are armed. Android will not draw it without
/// POST_NOTIFICATIONS — and the app used to ask for that exactly once, inside a
/// skippable onboarding gate. Two ordinary things then removed it for good:
///
///  * Skipping the gate. The permission is never granted, and nothing asks
///    again.
///  * Android's app-hibernation ("Pause app activity if unused", which HyperOS
///    describes as "Remove permissions ... and stop notifications"). Leave
///    NavAlert unopened for a while and the OS revokes it.
///
/// Reproduced on an emulator: revoke the permission and the notification
/// disappears while the service keeps running (isForeground=true) — so the
/// shortcuts still fire, and the commuter has no way to know. Re-opening the
/// app did NOT bring it back, because nothing re-requested it.
///
/// For a safety feature, silently losing the permission and never asking again
/// is the wrong behaviour. This re-checks on every launch and resume.
class NotificationPermissionGuard extends ChangeNotifier {
  NotificationPermissionGuard._();
  static final NotificationPermissionGuard instance =
      NotificationPermissionGuard._();

  /// True when the OS will not show the prompt again, so only a trip to system
  /// Settings can fix it. Drives the banner.
  bool permanentlyDenied = false;

  /// True once granted — the normal, quiet case.
  bool granted = true;

  /// Asks only when it can actually help. A permanently-denied permission
  /// returns denied however many times it is requested, so re-prompting is
  /// noise; the banner is the honest response instead.
  Future<void> ensure() async {
    try {
      if (await Permission.notification.isGranted) {
        _set(granted: true, blocked: false);
        return;
      }
      final status = await Permission.notification.request();
      _set(
        granted: status.isGranted,
        blocked: status.isPermanentlyDenied || status.isRestricted,
      );
    } catch (e) {
      // Never let a permission check take the app down.
      debugPrint('NavAlert: notification permission check failed — $e');
    }
  }

  /// Re-reads after the commuter has been sent to Settings, so the banner
  /// clears itself the moment they fix it.
  Future<void> refresh() async {
    try {
      final ok = await Permission.notification.isGranted;
      if (ok != granted || (ok && permanentlyDenied)) {
        _set(granted: ok, blocked: ok ? false : permanentlyDenied);
      }
    } catch (_) {}
  }

  /// Opens NavAlert's own page in system Settings.
  Future<void> openSettings() => openAppSettings();

  void _set({required bool granted, required bool blocked}) {
    if (this.granted == granted && permanentlyDenied == blocked) return;
    this.granted = granted;
    permanentlyDenied = blocked;
    notifyListeners();
  }
}
