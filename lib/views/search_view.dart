import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/home_viewmodel.dart';
import 'pin_on_map_view.dart';
import 'route_view.dart';

/// Figure 20 — Destination Search Screen ("Where to?") using the
/// Nominatim API over OpenStreetMap.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] search TextField's onChanged/_onChanged (debounced Nominatim) ·
///         result ListTile onTap → _select · "Pin on the map" onTap →
///         PinOnMapView · the currentAddressShort origin display.
///  [EDIT] "Where to?" title, origin→destination dot/line indicator style,
///         "Your location" caption, hint text, result row icons/spacing,
///         the pin-on-map card look, progress/error styles.
///  [WANT] recent-searches list, result category icons, map preview per result.
class SearchView extends StatefulWidget {
  const SearchView({super.key});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    // Rebuild so the local "Current Location" match below re-evaluates on every
    // keystroke. It costs no network call, so unlike the Nominatim search it
    // does not wait for the debounce or the 3-character minimum.
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (q.trim().length >= 3) context.read<HomeViewModel>().search(q);
    });
  }

  /// The commuter's own position, offered as a pickable search result.
  ///
  /// Where they are standing is a place like any other, but it was the one
  /// place the search could not reach: the position sat in a read-only caption
  /// above the field, so a commuter at PUP could search for every landmark
  /// EXCEPT the one under their feet.
  ///
  /// Offered with an empty query as a shortcut, and matched locally against the
  /// reverse-geocoded address plus the words people actually type when they
  /// mean themselves. Local matching also means it appears instantly, before
  /// Nominatim has answered.
  PlaceResult? _currentLocationMatch(HomeViewModel vm) {
    final lat = vm.currentLat;
    final lng = vm.currentLng;
    // A fallback position is a guess, not a fix (UC-4 Exception 2). Offering it
    // as somewhere to travel to would hand back a place they never were.
    if (lat == null || lng == null || vm.locationIsFallback) return null;

    final label = vm.currentAddressShort ?? 'Current Location';
    final q = _controller.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      const aliases = ['current location', 'my location', 'here', 'me'];
      final haystack = '$label ${vm.currentAddress ?? ''}'.toLowerCase();
      final matches = haystack.contains(q) ||
          aliases.any((a) => a.startsWith(q) || a.contains(q));
      if (!matches) return null;
    }
    return PlaceResult(
      name: label,
      displayName: vm.currentAddress ?? 'Where you are right now',
      lat: lat,
      lng: lng,
    );
  }

  // DO NOT MODIFY LOGIC: in-flight guard, matching the one on the Favorites
  // one-tap start and the Add-Favorite save. The modal loader below only blocks
  // taps once its barrier is painted on the NEXT frame, so two taps landing in
  // the same frame BOTH got through. That corrupted the navigation stack rather
  // than merely doing the work twice: two loaders were pushed, then each run's
  // `finally` popped one and called pushReplacement — so the second pop ate a
  // real route and the rider could land on a blank stack or back on Search with
  // the route already planned. This is the app's primary path (Home → Search →
  // Route), and picking a destination is exactly where an impatient double tap
  // happens.
  bool _selecting = false;

  Future<void> _select(PlaceResult place) async {
    if (_selecting) return;
    _selecting = true;
    final home = context.read<HomeViewModel>();
    final app = context.read<AppViewModel>();
    final messenger = ScaffoldMessenger.of(context);

    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    // DO NOT MODIFY LOGIC: a failure inside setDestination (the trip write, or
    // the routing isolate) must SAY so. It used to propagate straight out of
    // this method: the loader closed and nothing else happened, so the rider
    // tapped a destination and the app just sat on the search screen with no
    // error and no route — indistinguishable from a dead results list.
    var planned = true;
    try {
      await home.setDestination(place, app.transportPrefs);
    } catch (_) {
      planned = false;
    } finally {
      if (mounted) Navigator.of(context).pop(); // close loader
      // Released unconditionally so a transient routing/storage failure cannot
      // leave every result row permanently dead — the rider must be able to
      // retry. On the success path this screen is replaced anyway.
      _selecting = false;
    }
    if (!mounted) return;
    if (!planned) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not plan a route to that destination - '
              'please try again.')));
      return;
    }
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => const RouteView()));
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HomeViewModel>();
    return Scaffold(
      appBar: AppBar(title: const Text('Where to?')),
      // ╔══════════════════════════════════════════════════════════════════╗
      // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:                 ║
      // ║ KEYBOARD UNFOCUS WRAPPER (soft-keyboard dismissal).              ║
      // ║                                                                  ║
      // ║ UI TEAM: this GestureDetector must stay wrapped around the body, ║
      // ║ with `behavior: HitTestBehavior.opaque` and the `unfocus()`      ║
      // ║ onTap. Restyle everything inside it. Removing it (or dropping    ║
      // ║ `opaque`) traps the soft keyboard open over the results list —   ║
      // ║ the rider cannot see or reach the destination they searched for, ║
      // ║ on the app's primary Home → Search → Route path. Do not add a    ║
      // ║ competing onTap here; the result rows keep their own.            ║
      // ╚══════════════════════════════════════════════════════════════════╝
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: SafeArea(
          child: Column(
            children: [
              // Figure 20 — origin → destination header: current-location
              // dot connected by a line to the search field. The address is
              // shown Google-Maps style: primary name only, single line.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Column(children: [
                        const SizedBox(height: 5),
                        const Icon(Icons.circle,
                            size: 12, color: NavAlertColors.accent),
                        Expanded(
                          child: Container(
                            width: 2,
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            color: NavAlertColors.surface,
                          ),
                        ),
                        const Icon(Icons.location_on,
                            size: 14, color: NavAlertColors.warning),
                        const SizedBox(height: 18),
                      ]),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(vm.currentAddressShort ?? 'Current Location',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                            // UC-4 Exception 2 — never let a fallback position
                            // masquerade as the rider's real starting point.
                            Text(vm.locationError ?? 'Your location',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: vm.locationIsFallback
                                        ? NavAlertColors.warning
                                        : NavAlertColors.textSecondary)),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _controller,
                              autofocus: true,
                              style: const TextStyle(color: Colors.black87),
                              decoration: const InputDecoration(
                                hintText: 'Search destination…',
                                fillColor: Colors.white,
                                prefixIcon:
                                    Icon(Icons.search, color: Colors.black54),
                              ),
                              onChanged: _onChanged,
                              onSubmitted: (q) =>
                                  context.read<HomeViewModel>().search(q),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // UC-4 step 2 — the commuter may pin the exact drop-off
              // point on the map instead of searching by name.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Card(
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.pin_drop,
                        color: NavAlertColors.accent),
                    title: const Text('Pin on the map',
                        style: TextStyle(fontSize: 14)),
                    subtitle: const Text(
                        'Drop a pin at your exact drop-off point.',
                        style: TextStyle(
                            fontSize: 11, color: NavAlertColors.textSecondary)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () async {
                      final picked = await Navigator.of(context)
                          .push<PlaceResult>(MaterialPageRoute(
                              builder: (_) => const PinOnMapView()));
                      if (picked != null && context.mounted) {
                        await _select(picked);
                      }
                    },
                  ),
                ),
              ),
              if (vm.searching) const LinearProgressIndicator(),
              if (vm.searchError != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(vm.searchError!,
                      style: const TextStyle(color: NavAlertColors.warning)),
                ),
              Expanded(
                // DO NOT MODIFY LOGIC: vm.results is the Nominatim geocoding
                // output (NCR-bounded). Restyle each ListTile freely, but keep
                // the builder over vm.results and the onTap → _select(r), which
                // sets the destination and kicks off route planning.
                // The results area had no empty state at all: before the first
                // search — which is how this screen always opens — it was simply
                // a blank slab under the search field, with nothing to say the
                // app was waiting on input rather than having failed. Same
                // pre-search prompt the Add-Favorite search already carries, so
                // the two search screens behave alike.
                //
                // Deliberately NOT a "nothing matched" message: the query is not
                // even sent until 3 characters, and a real no-match is reported
                // through vm.searchError above — keying off an empty list would
                // tell a rider who has typed "SM" that their search found
                // nothing when no search had run yet.
                child: vm.results.isEmpty &&
                        _currentLocationMatch(vm) == null &&
                        !vm.searching &&
                        vm.searchError == null
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: NavAlertColors.card,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // Same gradient-circle + scattered-star treatment
                              // as the Favorites/History empty states, so all
                              // three "nothing here yet" screens read as one
                              // family instead of three different looks.
                              SizedBox(
                                height: 160,
                                width: 160,
                                child: Stack(
                                  alignment: Alignment.center,
                                  clipBehavior: Clip.none,
                                  children: [
                                    Container(
                                      height: 140,
                                      width: 140,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: RadialGradient(
                                          center: Alignment(-0.3, -0.3),
                                          colors: [
                                            NavAlertColors.accent,
                                            NavAlertColors.primary,
                                          ],
                                        ),
                                      ),
                                    ),
                                    const Icon(Icons.search,
                                        size: 68, color: Colors.white),
                                    const Positioned(
                                        top: 4,
                                        right: 4,
                                        child: Icon(Icons.star,
                                            size: 32,
                                            color: NavAlertColors.accent)),
                                    const Positioned(
                                        bottom: 22,
                                        left: 2,
                                        child: Icon(Icons.star,
                                            size: 12,
                                            color: NavAlertColors.accent)),
                                    const Positioned(
                                        top: 28,
                                        left: 8,
                                        child: Icon(Icons.star,
                                            size: 10,
                                            color: NavAlertColors.accent)),
                                    const Positioned(
                                        bottom: 6,
                                        right: 28,
                                        child: Icon(Icons.star,
                                            size: 14,
                                            color: NavAlertColors.accent)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),
                              const Text(
                                'Search for where you are headed, or drop a pin '
                                'on the map above.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: NavAlertColors.textSecondary,
                                    fontSize: 13,
                                    height: 1.4),
                              ),
                            ],
                          ),
                        ),
                      )
                    : Builder(builder: (_) {
                        final here = _currentLocationMatch(vm);
                        final rows = <PlaceResult>[
                          if (here != null) here,
                          ...vm.results,
                        ];
                        return ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (_, i) {
                          final r = rows[i];
                          final isHere = here != null && i == 0;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: NavAlertColors.surface,
                              child: Icon(
                                  isHere
                                      ? Icons.my_location
                                      : Icons.navigation,
                                  color: NavAlertColors.accent,
                                  size: 20),
                            ),
                            title: Text(r.name),
                            subtitle: Text(r.displayName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: NavAlertColors.textSecondary,
                                    fontSize: 12)),
                            onTap: () => _select(r),
                          );
                        },
                        );
                      }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
