import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navalert/core/map_support.dart';

/// The live GPS stream delivers a fix every couple of seconds, so painting the
/// marker straight at each new coordinate made the blue dot jump the whole gap
/// in one frame. [LatLngGlide] interpolates between fixes so it travels the gap
/// instead of teleporting across it.
void main() {
  const a = LatLng(14.5979, 121.0108);
  const b = LatLng(14.6079, 121.0208);

  /// Pumps a glide whose current value is recorded into [seen].
  Widget harness(LatLng target, List<LatLng> seen) => MaterialApp(
        home: LatLngGlide(
          target: target,
          builder: (_, p) {
            seen.add(p);
            return const SizedBox.shrink();
          },
        ),
      );

  testWidgets('starts painted exactly at its first target', (t) async {
    final seen = <LatLng>[];
    await t.pumpWidget(harness(a, seen));
    expect(seen.last.latitude, closeTo(a.latitude, 1e-9));
    expect(seen.last.longitude, closeTo(a.longitude, 1e-9));
  });

  testWidgets('travels through the gap rather than jumping it', (t) async {
    final seen = <LatLng>[];
    await t.pumpWidget(harness(a, seen));
    await t.pumpWidget(harness(b, seen));

    // Halfway through the glide the dot must be strictly BETWEEN the two
    // fixes — that is the whole difference from a teleport.
    await t.pump(const Duration(milliseconds: 200));
    final mid = seen.last;
    expect(mid.latitude, greaterThan(a.latitude));
    expect(mid.latitude, lessThan(b.latitude));
    expect(mid.longitude, greaterThan(a.longitude));
    expect(mid.longitude, lessThan(b.longitude));

    // And it must actually arrive.
    await t.pumpAndSettle();
    expect(seen.last.latitude, closeTo(b.latitude, 1e-6));
    expect(seen.last.longitude, closeTo(b.longitude, 1e-6));
  });

  testWidgets('a fix arriving mid-glide re-aims from where the dot is now',
      (t) async {
    final seen = <LatLng>[];
    await t.pumpWidget(harness(a, seen));
    await t.pumpWidget(harness(b, seen));
    await t.pump(const Duration(milliseconds: 150));
    final interrupted = seen.last;

    // A third fix lands before the second glide finished. Restarting from `a`
    // would visibly snap the dot backwards; it must continue from where it is.
    const c = LatLng(14.6179, 121.0308);
    await t.pumpWidget(harness(c, seen));
    await t.pump(const Duration(milliseconds: 16));
    expect(seen.last.latitude, greaterThanOrEqualTo(interrupted.latitude - 1e-6),
        reason: 'the dot jumped backwards when a new fix interrupted a glide');

    await t.pumpAndSettle();
    expect(seen.last.latitude, closeTo(c.latitude, 1e-6));
  });

  testWidgets('an unchanged target does not restart the animation',
      (t) async {
    final seen = <LatLng>[];
    await t.pumpWidget(harness(a, seen));
    await t.pumpWidget(harness(b, seen));
    await t.pumpAndSettle();
    final settled = seen.last;

    // The ViewModel notifies on things other than position (address lookups,
    // banners), so the same coordinate re-arriving must be inert.
    await t.pumpWidget(harness(b, seen));
    await t.pump(const Duration(milliseconds: 16));
    expect(seen.last.latitude, closeTo(settled.latitude, 1e-9));
    expect(seen.last.longitude, closeTo(settled.longitude, 1e-9));
  });
}
