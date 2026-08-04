import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/views/commute_sheet_layout.dart';

/// Follow-the-rider camera state for the live trip map.
///
/// Two rules fight each other and the resolution is what this class exists for:
///
///  * the camera must track the blue dot, or the map is a decoration; and
///  * the rider must be able to look ahead down the route, or the map is
///    unusable — a fix lands every 1-2 s, so an unconditional follow yanks the
///    camera back before they can read anything.
///
/// Follow is therefore ON by default and released by a MANUAL pan only. The
/// distinction matters because the follow itself moves the camera: if a
/// programmatic move counted as a gesture, the first tracked fix would disengage
/// tracking permanently and the feature would silently do nothing.
void main() {
  group('default state', () {
    test('follows the rider without being asked', () {
      // The rider opened a navigation screen. Tracking is the premise, not an
      // opt-in.
      expect(TripCameraTracker().following, isTrue);
    });
  });

  group('disengaging', () {
    test('a manual pan releases the camera', () {
      final t = TripCameraTracker();
      t.onPositionChanged(hasGesture: true);
      expect(t.following, isFalse,
          reason: 'the rider dragged the map to look ahead — snapping back on '
              'the next fix would make the map unreadable');
    });

    test('the tracker\'s own move does NOT release it', () {
      final t = TripCameraTracker();
      // flutter_map reports hasGesture == false for MapController.move, which
      // is what AnimatedMapMover drives. If this disengaged, tracking would
      // switch itself off on the very first fix it handled.
      t.onPositionChanged(hasGesture: false);
      expect(t.following, isTrue);
    });

    test('staying disengaged survives further programmatic events', () {
      final t = TripCameraTracker();
      t.onPositionChanged(hasGesture: true);
      t.onPositionChanged(hasGesture: false);
      expect(t.following, isFalse,
          reason: 'a non-gesture event must not silently re-arm follow behind '
              'the rider\'s back');
    });
  });

  group('re-engaging', () {
    test('recenter turns following back on', () {
      final t = TripCameraTracker();
      t.onPositionChanged(hasGesture: true);
      t.recenter();
      expect(t.following, isTrue);
    });

    test('recenter is idempotent', () {
      final t = TripCameraTracker();
      t.recenter();
      t.recenter();
      expect(t.following, isTrue);
    });
  });

  group('bottom-padded camera offset', () {
    test('lifts the target above the widget centre', () {
      // flutter_map documents Offset(0, y) as moving the intended centre DOWN
      // by y. The dot must sit HIGHER than the widget centre — in the middle of
      // the band left visible above the sheet — so the sign must be negative.
      expect(TripCameraTracker.cameraOffsetY(300), lessThan(0));
    });

    test('lifts it by half of what the sheet and footer hide', () {
      // Visible band is [0, H - obscured]; its centre is (H - obscured) / 2,
      // which is obscured / 2 above the widget centre H / 2.
      expect(TripCameraTracker.cameraOffsetY(300), closeTo(-150, 1e-9));
      expect(TripCameraTracker.cameraOffsetY(0), closeTo(0, 1e-9));
    });

    test('never pushes the target off-screen for absurd obscured heights', () {
      // A malformed layout must not fling the camera somewhere unrelated.
      final y = TripCameraTracker.cameraOffsetY(-500);
      expect(y, lessThanOrEqualTo(0),
          reason: 'a negative obscured height would otherwise push the dot '
              'DOWN behind the sheet');
    });
  });
}
