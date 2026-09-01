import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/views/overshoot_button_layout.dart';

/// The Yes/No pair on Overshoot Detected (Figure 29).
///
/// The buttons were fixed at 147 dp each to match the Snooze/Dismiss pair, and
/// that arithmetic needs 400 dp of screen once the card and screen padding are
/// counted. The phone the mockups are drawn against is 360 dp, so "Yes"
/// overflowed the card — reported from a device.
///
/// This prompt appears the moment a rider has missed their stop. A button
/// clipped exactly then is the worst place in the app for it, so the widths
/// are asserted across every plausible screen instead of eyeballed on one.
void main() {
  // What the card actually offers a child, on a 360 dp phone:
  //   360 - screen padding (24 x 2) - card padding (22 x 2) = 268
  const availableOn360 = 360.0 - 48 - 44;

  test('the old fixed width did not fit the target phone', () {
    // The bug, stated as arithmetic so it cannot come back unnoticed.
    const oldPairWidth = 147.0 * 2 + OvershootButtonLayout.gap;
    expect(oldPairWidth, greaterThan(availableOn360),
        reason: 'two 147 dp buttons plus the gap cannot fit 268 dp');
  });

  test('the pair fits on a 360 dp phone', () {
    expect(OvershootButtonLayout.pairWidth(availableOn360),
        lessThanOrEqualTo(availableOn360));
  });

  test('both buttons stay equal width', () {
    final w = OvershootButtonLayout.buttonWidth(availableOn360);
    expect(OvershootButtonLayout.pairWidth(availableOn360),
        closeTo(w * 2 + OvershootButtonLayout.gap, 0.001));
  });

  test('never wider than the Snooze/Dismiss pair it matches', () {
    for (final available in [268.0, 400.0, 600.0, 1200.0]) {
      expect(OvershootButtonLayout.buttonWidth(available),
          lessThanOrEqualTo(OvershootButtonLayout.preferredWidth),
          reason: 'at ${available}dp it must not exceed 147');
    }
  });

  test('uses the full 147 once there is room', () {
    // 147*2 + 14 = 308, so anything at or above that gets the preferred size.
    expect(OvershootButtonLayout.buttonWidth(308),
        closeTo(OvershootButtonLayout.preferredWidth, 0.001));
    expect(OvershootButtonLayout.buttonWidth(900),
        closeTo(OvershootButtonLayout.preferredWidth, 0.001));
  });

  test('fits every plausible screen, not just 360', () {
    // Smallest Android phones still shipping are ~320 dp wide.
    for (final screen in [320.0, 360.0, 390.0, 412.0, 480.0, 600.0, 800.0]) {
      final available = screen - 48 - 44;
      expect(OvershootButtonLayout.pairWidth(available),
          lessThanOrEqualTo(available),
          reason: 'overflows on a ${screen}dp screen');
    }
  });

  test('degenerate width collapses instead of going negative', () {
    // A negative width throws in the render tree; zero merely draws nothing.
    expect(OvershootButtonLayout.buttonWidth(10), 0);
    expect(OvershootButtonLayout.buttonWidth(0), 0);
  });
}
