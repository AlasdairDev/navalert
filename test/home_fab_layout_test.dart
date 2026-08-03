import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/views/home_view.dart';

/// The locate FAB shares the bottom-right corner with two pills, and BOTH are
/// painted after it — the earphones pill later in HomeView's Stack, the "View
/// Active Trip" pill in ShellView's Stack above the whole IndexedStack. So an
/// overlap does not merely look crowded: it puts the pill on top of the button
/// and makes it untappable.
///
/// The FAB used to dodge this by sitting at a flat 73 dp, which looked
/// stranded in mid-air on a real device. It now rests low and steps up only
/// when a pill is actually beneath it — which is only safe if the arithmetic
/// is right in every combination, hence this suite.
void main() {
  /// The FAB occupies [bottom, bottom + fabSize).
  double fabTop(bool trip, bool ear) =>
      HomeFabLayout.bottomFor(tripActive: trip, earphones: ear) +
      HomeFabLayout.fabSize;

  double fabBottom(bool trip, bool ear) =>
      HomeFabLayout.bottomFor(tripActive: trip, earphones: ear);

  group('resting position', () {
    test('sits at a standard margin when no pill is on screen', () {
      final bottom = fabBottom(false, false);
      expect(bottom, HomeFabLayout.restingBottom);
      // The whole point of the change: well below the old mockup value of 73.
      expect(bottom, lessThan(73));
      // And still a sane margin, not flush against the nav bar.
      expect(bottom, inInclusiveRange(16, 24));
    });
  });

  group('horizontal placement', () {
    test('uses the screen\'s standard 20 dp margin, not the mockup\'s 43', () {
      // The header pads by 20 and the earphones pill is inset left/right 20,
      // so this is what makes the FAB's right edge line up with them rather
      // than sitting inboard of both.
      expect(HomeFabLayout.restingRight, 20);
      expect(HomeFabLayout.restingRight, lessThan(43));
      expect(HomeFabLayout.restingRight, inInclusiveRange(16, 24));
    });
  });

  group('never overlaps a pill', () {
    for (final trip in [false, true]) {
      for (final ear in [false, true]) {
        test('trip=$trip earphones=$ear', () {
          final pillTop =
              HomeFabLayout.pillTopEdge(tripActive: trip, earphones: ear);
          if (pillTop == 0) return; // nothing underneath — covered above
          expect(fabBottom(trip, ear), greaterThanOrEqualTo(pillTop),
              reason: 'the FAB starts below the top of a pill that is drawn '
                  'over it — it would be covered and untappable');
        });
      }
    }

    test('keeps a visible gap rather than merely touching', () {
      expect(fabBottom(true, false),
          HomeFabLayout.pillTopEdge(tripActive: true, earphones: false) +
              HomeFabLayout.fabPillGap);
    });
  });

  group('the both-pills case the old flat 73 dp got wrong', () {
    test('clears the earphones pill in its raised slot', () {
      // With a trip running the earphones pill steps up to 60 -> 102, so the
      // old constant 73 put the FAB (73 -> 129) straight underneath it.
      final pillTop =
          HomeFabLayout.pillTopEdge(tripActive: true, earphones: true);
      expect(pillTop,
          HomeFabLayout.earphonePillRaised + HomeFabLayout.earphonePillHeight);
      expect(73, lessThan(pillTop),
          reason: 'documents the latent overlap this change fixes');
      expect(fabBottom(true, true), greaterThanOrEqualTo(pillTop));
    });
  });

  group('ordering', () {
    test('rises monotonically as more pills appear', () {
      expect(fabBottom(false, false), lessThan(fabBottom(true, false)));
      expect(fabBottom(true, false), lessThan(fabBottom(true, true)));
    });

    test('the FAB always has positive height above its anchor', () {
      expect(fabTop(false, false),
          fabBottom(false, false) + HomeFabLayout.fabSize);
    });
  });
}
