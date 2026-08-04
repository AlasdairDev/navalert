import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/views/commute_sheet_layout.dart';

/// Geometry for the commute-guide sheet once it floats OVER the live map.
///
/// The sheet shares the screen with two things it must never fight: the map
/// underneath it (which is the entire point of the overlay) and the safety
/// footer below it (Slide-to-Stop, SOS, Fake Call). Both relationships are pure
/// arithmetic over three measurements, so they are pinned down here rather than
/// discovered on a device — the same reason [HomeFabLayout] was lifted out of
/// HomeView.
///
/// The stakes are not cosmetic. `DraggableScrollableSheet` asserts
/// `min <= initial <= max`; violating it throws on the ONE screen a rider
/// cannot leave without the Slide-to-Stop control, so the ordering is asserted
/// across every plausible screen and footer rather than assumed.
void main() {
  /// A 360x800 dp phone — the device the mockups are drawn against. The header
  /// and footer figures are MEASURED off the mounted screen by
  /// commute_guide_overlay_test, not guessed: an invented footer height makes
  /// every assertion below describe a layout that does not ship.
  const screen = 800.0;
  const header = 83.0;
  const footer = 170.0;
  const region = screen - header - footer;

  CommuteSheetFractions resolve({
    double screenHeight = screen,
    double regionHeight = region,
    double footerHeight = footer,
  }) =>
      CommuteSheetLayout.resolve(
        screenHeight: screenHeight,
        regionHeight: regionHeight,
        footerHeight: footerHeight,
      );

  /// Screen pixels hidden by the sheet at [extent] plus the footer beneath it.
  double obscured(double extent,
          {double regionHeight = region, double footerHeight = footer}) =>
      extent * regionHeight + footerHeight;

  group('resting state', () {
    test('leaves the top half of the map completely visible', () {
      final f = resolve();
      // The directive's hard requirement. Everything else about the resting
      // height is a preference; this is the line that makes the overlay worth
      // building at all.
      expect(obscured(f.initial), lessThanOrEqualTo(screen * 0.5),
          reason: 'the resting sheet plus the safety footer cover more than '
              'half the screen — the map is no longer usable at a glance');
    });

    test('uses the whole height the half-screen rule leaves it', () {
      final f = resolve();
      final obs = obscured(f.initial);
      // The requirement asks for a resting sheet of "e.g. 30% to 40%". With the
      // real 170 px safety footer that is not simultaneously satisfiable: 30%
      // of the screen plus the footer is 51.3%, which breaks the half-map rule.
      // The map wins — it is stated as a requirement while the band is stated
      // as an example — so the honest property to pin down is that the sheet
      // takes every pixel the budget allows and stops there. On this device
      // that is 28.6% of the screen.
      expect(obs, lessThanOrEqualTo(screen * 0.5));
      expect(obs, greaterThan(screen * 0.5 - 4),
          reason: 'the sheet is leaving budget unspent — a guide showing one '
              'card where two would fit wastes the space the rider came for');
    });

    test('caps at the resting preference when the footer is small', () {
      const small = 60.0;
      const smallRegion = screen - header - small;
      final f = resolve(footerHeight: small, regionHeight: smallRegion);
      // Budget would allow 339 px here. The preference caps it, so a short
      // footer does not quietly let the guide creep up over the map.
      expect(f.initial * smallRegion,
          closeTo(CommuteSheetLayout.restingSheetScreenFraction * screen, 1.5));
    });

    test('shows more than the drag handle', () {
      final f = resolve();
      // A resting sheet that only shows its handle is the collapsed alarm-ON
      // sheet, not a guide the rider can read while riding.
      expect(f.initial * region,
          greaterThanOrEqualTo(CommuteSheetLayout.minSheetHeight * 2));
    });
  });

  group('full extension', () {
    test('never covers the map completely', () {
      final f = resolve();
      final mapVisible = screen - obscured(f.max);
      expect(mapVisible,
          greaterThanOrEqualTo(screen * CommuteSheetLayout.minMapVisibleFraction),
          reason: 'dragged fully up the sheet must still leave a top margin — '
              'map context is never 100% lost');
    });

    test('is taller than the resting height, or there is nothing to drag', () {
      final f = resolve();
      expect(f.max, greaterThan(f.initial));
    });
  });

  group('collapsed state', () {
    test('always leaves the handle and step counter reachable', () {
      final f = resolve();
      expect(f.min * region,
          greaterThanOrEqualTo(CommuteSheetLayout.minSheetHeight));
    });
  });

  group('min <= initial <= max holds everywhere', () {
    // DraggableScrollableSheet asserts this. A footer inflated by the Signal
    // Lost card on a short screen is a real runtime state, not a hypothetical.
    for (final s in [480.0, 640.0, 800.0, 960.0, 1200.0]) {
      for (final ftr in [100.0, 154.0, 220.0, 320.0]) {
        test('screen=$s footer=$ftr', () {
          final f = resolve(
              screenHeight: s, regionHeight: s - header - ftr, footerHeight: ftr);
          expect(f.min, greaterThan(0));
          expect(f.min, lessThanOrEqualTo(f.initial));
          expect(f.initial, lessThanOrEqualTo(f.max));
          expect(f.max, lessThanOrEqualTo(1.0));
        });
      }
    }
  });

  group('degenerate input cannot produce an invalid sheet', () {
    // These are the shapes that throw rather than merely look wrong.
    final cases = <String, CommuteSheetFractions Function()>{
      'zero region': () => resolve(regionHeight: 0),
      'negative region': () => resolve(regionHeight: -50),
      'zero screen': () => resolve(screenHeight: 0),
      'footer taller than the screen': () =>
          resolve(footerHeight: 900, regionHeight: 20),
      'footer exactly the screen height': () =>
          resolve(footerHeight: screen, regionHeight: 0),
    };
    cases.forEach((name, build) {
      test(name, () {
        final f = build();
        expect(f.min, greaterThan(0));
        expect(f.min, lessThanOrEqualTo(f.initial));
        expect(f.initial, lessThanOrEqualTo(f.max));
        expect(f.max, lessThanOrEqualTo(1.0));
      });
    });
  });

  group('snap sizes', () {
    test('are ordered and inside the min/max range', () {
      final f = resolve();
      // flutter asserts snapSizes are sorted and within [min, max].
      for (var i = 1; i < f.snapSizes.length; i++) {
        expect(f.snapSizes[i], greaterThan(f.snapSizes[i - 1]));
      }
      for (final s in f.snapSizes) {
        expect(s, inInclusiveRange(f.min, f.max));
      }
    });
  });

  group('the footer budget is honoured before the resting preference', () {
    test('a tall footer shrinks the sheet rather than covering the map', () {
      const tall = 320.0;
      const tallRegion = screen - header - tall;
      final f = resolve(footerHeight: tall, regionHeight: tallRegion);
      expect(
          obscured(f.initial, regionHeight: tallRegion, footerHeight: tall) /
              screen,
          lessThanOrEqualTo(CommuteSheetLayout.maxObscuredScreenFraction + 1e-9),
          reason: 'the Signal Lost card must not push the resting sheet down '
              'over the half of the map the rider is navigating by');
    });
  });
}
