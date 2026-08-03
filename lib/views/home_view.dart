import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/map_support.dart';
import '../core/theme.dart';
import '../services/sound_service.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/home_viewmodel.dart';
import '../viewmodels/trip_viewmodel.dart';
import 'onboarding_flow.dart';
import 'search_view.dart';

/// Figure 19 — Main Screen: greeting, destination search bar and an
/// interactive OpenStreetMap view with a locate button.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] FlutterMap + TileLayer (OSM tiles, paper API) · locate FAB's
///         onPressed refreshCurrentLocation() · search bar's onTap →
///         SearchView · the incomplete-setup MaterialBanner logic ·
///         vm.startLiveTracking() (R2 — what makes the current-location dot
///         follow the rider rather than sit on the boot-time fix).
///  [EDIT] greeting text/logic (_greeting), "Where are you headed?" copy,
///         search-bar pill shape/color, marker dot style/size, FAB icon,
///         header card blur/rounding, all paddings.
///  [WANT] animate the marker, add a compass/zoom control, richer greeting.
class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> with TickerProviderStateMixin {
  final _mapController = MapController();

  /// True while the locate-me FAB is acquiring a fix — see its onPressed.
  bool _locating = false;

  /// GUI Page 8 — "Earphones connected" pill. True while the device reports a
  /// wired/Bluetooth/USB headset, which is the state in which the paper's
  /// "Bluetooth / ear-phone only detection" setting routes the destination
  /// alarm quietly through the earphones instead of the loud PUV speaker.
  /// Purely informational: the pill reflects the route, it never sets it.
  bool _earphones = false;

  /// Headset plug/unplug has no Dart-side event on this app's platform channel,
  /// so the pill is refreshed on a slow poll. The underlying call is a single
  /// AudioManager query — orders of magnitude cheaper than the GPS stream this
  /// screen already runs — and setState fires only when the answer CHANGES, so
  /// a steady state costs no rebuilds.
  Timer? _earphonePoll;
  static const _earphonePollInterval = Duration(seconds: 5);

  Future<void> _refreshEarphones() async {
    final connected = await SoundService.instance.isHeadsetConnected();
    // The poll outlives no-longer-mounted states, and the value is only worth a
    // rebuild when it actually flipped.
    if (!mounted || connected == _earphones) return;
    setState(() => _earphones = connected);
  }

  // DO NOT MODIFY LOGIC: the mover is built eagerly in initState, NOT as a lazy
  // `late final` field initializer. When GPS never returns a fix the mover is
  // never read, so a lazy field would run its initializer for the FIRST time
  // inside dispose() below — constructing an AnimationController against an
  // already-deactivated element. That throws "Looking up a deactivated widget's
  // ancestor is unsafe" and kills the frame on the way out of the Home tab,
  // which is exactly the no-signal case the rider is most likely to hit.
  late final AnimatedMapMover _mover;

  @override
  void initState() {
    super.initState();
    _mover = AnimatedMapMover(_mapController, this);
    // Show the headset state immediately rather than after the first poll tick,
    // so plugging in before opening the app still lights the pill at once.
    _refreshEarphones();
    _earphonePoll =
        Timer.periodic(_earphonePollInterval, (_) => _refreshEarphones());
    // DO NOT MODIFY LOGIC: first-frame GPS acquisition + animated recenter.
    // This is the R2/UC-4 location bootstrap; the map has nothing to show
    // until refreshCurrentLocation() returns. Restyle the map/markers freely,
    // but leave this callback and the animateTo call intact.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final vm = context.read<HomeViewModel>();
      // promptIfDisabled: false — nothing the rider did triggered this, so it
      // must never eject them into the system location settings page. With GPS
      // off it falls through to the fallback banner below, which offers Retry
      // and Settings as an explicit choice. See refreshCurrentLocation's note.
      await vm.refreshCurrentLocation(promptIfDisabled: false);
      if (mounted && vm.currentLat != null) {
        _mover.animateTo(LatLng(vm.currentLat!, vm.currentLng!), 16);
      }
      // R2 — from here the dot FOLLOWS the rider instead of staying pinned to
      // the boot-time snapshot. Started after the bootstrap above so the first
      // paint still comes from the fast two-stage fix.
      //
      // Deliberately does NOT recentre the map: only the marker moves. The
      // camera is the rider's to control — panning away to look at a street and
      // being yanked back on the next GPS tick would make the map unusable, and
      // the locate button already exists for "take me back to me". Started even
      // if the bootstrap fix failed, because the stream can deliver one later.
      if (mounted) vm.startLiveTracking();
    });
  }

  @override
  void dispose() {
    // Without this the timer keeps firing against a dead State and every tick
    // calls setState on it.
    _earphonePoll?.cancel();
    _mover.dispose();
    super.dispose();
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good Morning,';
    if (h < 18) return 'Good Afternoon,';
    return 'Good Evening,';
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HomeViewModel>();
    final center = LatLng(vm.currentLat ?? 14.5979, vm.currentLng ?? 121.0108);
    // `select`, NOT `watch`: TripViewModel notifies on every GPS tick during a
    // trip, and watching it here would rebuild this screen — map included —
    // several times a second. Only the on/off transition matters.
    final tripActive = context.select<TripViewModel, bool>((t) => t.isActive);

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 14,
              // Panning is fenced to NCR — the app has no route or fare data
              // for anywhere else, so scrolling into a province is a dead end.
              cameraConstraint: NavAlertMap.ncrConstraint,
              minZoom: 10,
              maxZoom: 20,
            ),
            children: [
              // DO NOT MODIFY LOGIC: NavAlertMap.tiles / ncrConstraint come
              // from core/map_support.dart (retina tiles, NCR geofence, tile
              // buffering). Restyle markers/overlays, but don't inline-replace
              // these — they keep the map crisp and inside the service area.
              NavAlertMap.tiles(context),
              // DO NOT MODIFY LOGIC: the "you are here" dot renders ONLY for a
              // real GPS fix. `center` falls back to PUP Sta. Mesa when there
              // is no fix, and drawing the blue dot there presented a hardcoded
              // location as the rider's own — visually identical to a working
              // fix, on the very screen where they choose where they are going.
              // A missing pin is honest; a confident wrong pin is not. The
              // fallback banner below already explains the situation, and the
              // map still CENTRES on `center` because it needs somewhere to
              // look — only the "this is you" claim is withheld.
              // Glides between fixes instead of teleporting. The live stream
              // only emits once the rider has passed the 5 m distance filter,
              // roughly every 2 s, so painting straight at each new coordinate
              // moved the dot the whole gap in one frame. Only the MARKER is
              // rebuilt per animation frame — the tile layer and the camera are
              // untouched.
              if (!vm.locationIsFallback && vm.currentLat != null)
                LatLngGlide(
                  target: center,
                  builder: (context, position) => MarkerLayer(markers: [
                    // TODO (UI Team): the current-location dot style.
                    // Google-Maps-style blue is intentional and widely
                    // recognised; 0xFF4285F4 is a deliberate keep, not theme
                    // purple.
                    Marker(
                      point: position,
                      width: 22,
                      height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF4285F4),
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [
                            BoxShadow(color: Colors.black38, blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  ]),
                ),
            ],
          ),
          // Greeting + search header.
          //
          // GUI Page 10 geometry (the mockups are 360x780 dp, this device is
          // 360x800 dp, so mockup pixels are read as dp 1:1):
          //   greeting top y=38 · search bar y=146-192 (h=46) · panel ends
          //   y=210 · side margins 20.
          //
          // The SafeArea used to wrap this Container from the OUTSIDE, which
          // pushed the whole panel BELOW the status bar and left a strip of
          // bare map above it — the dead space at the top of the screen. In the
          // mockup the dark header runs edge to edge from y=0. The inset now
          // lives INSIDE the panel, so the background reaches the top of the
          // screen while the text still clears the status bar.
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: NavAlertColors.background.withValues(alpha: 0.94),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(24)),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                // 6 dp over the status-bar inset puts the greeting at roughly
                // the mockup's y=38; 18 dp below matches its 192->210 gap.
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  // TODO (UI Team): greeting + heading typography. Consider a
                  // theme text style instead of inline fontSize/weight.
                  Text(_greeting,
                      style: const TextStyle(
                          color: NavAlertColors.textSecondary, fontSize: 14)),
                  const Text('Where are you headed?',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700)),
                  // Mockup gap between the heading (ends y=130) and the search
                  // bar (starts y=146).
                  const SizedBox(height: 16),
                  GestureDetector(
                    // DO NOT MODIFY LOGIC: opens the destination search (UC-4).
                    // Restyle the pill below, but keep this onTap → SearchView.
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SearchView())),
                    child: Container(
                      // TODO (UI Team): the search pill's shape/padding/color.
                      // USE THEME: this white-on-map pill is deliberate for
                      // contrast over the map — if you restyle, keep it legible
                      // against OSM tiles (a theme token is fine if you add one).
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 13),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Row(children: [
                        Icon(Icons.search, color: Colors.black54, size: 20),
                        SizedBox(width: 8),
                        Text('Search',
                            style: TextStyle(color: Colors.black54)),
                      ]),
                    ),
                  ),
                  // UC-4 Exception 2 — the map is showing a fallback position,
                  // not the rider's own. This MUST be visible here: Home is
                  // where the map is, and silently centring on PUP Sta. Mesa
                  // looks exactly like a working GPS fix.
                  if (vm.locationIsFallback && vm.locationError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: MaterialBanner(
                        padding: const EdgeInsets.all(10),
                        backgroundColor: NavAlertColors.surface,
                        content: Text(vm.locationError!,
                            style: const TextStyle(fontSize: 12)),
                        leading: const Icon(Icons.location_off,
                            color: NavAlertColors.warning),
                        actions: [
                          TextButton(
                            onPressed: () => vm.refreshCurrentLocation(),
                            child: const Text('Retry'),
                          ),
                          TextButton(
                            onPressed: () => Geolocator.openAppSettings(),
                            child: const Text('Settings'),
                          ),
                        ],
                      ),
                    ),
                  // Incomplete-setup prompt (app_state, Table 15): onboarding
                  // was skipped without emergency contacts.
                  if (context.watch<AppViewModel>().showIncompleteSetupPrompt)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      // GUI Page 7 leads with a bold "Incomplete Setup" heading
                      // and then NAMES what is unfinished, rather than opening
                      // mid-sentence. The old single line mentioned only
                      // contacts, so a rider who had also skipped permissions
                      // and the fake-call clip was told about one third of the
                      // problem. Copy only — the prompt's own show/dismiss
                      // wiring is unchanged.
                      child: MaterialBanner(
                        padding: const EdgeInsets.all(10),
                        backgroundColor: NavAlertColors.surface,
                        content: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Incomplete Setup',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700)),
                            SizedBox(height: 4),
                            Text(
                              'Some features are not ready: permissions, SOS '
                              'contacts, and fake call simulation.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                        leading: const Icon(Icons.warning_amber,
                            color: NavAlertColors.warning),
                        actions: [
                          TextButton(
                            onPressed: () => context
                                .read<AppViewModel>()
                                .dismissIncompleteSetupPrompt(),
                            child: const Text('Dismiss'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const ContactsSetupView(
                                        inOnboarding: false))),
                            child: const Text('Setup'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Locate me button
          // TODO (UI Team): FAB position/size/icon/color are free to restyle.
          Positioned(
            // Mockup: FAB spans x=265-317 of 360 dp, so 43 dp from the right.
            right: 43,
            // Mockup: FAB occupies y=605-657 with the bottom nav starting at
            // y=730 — a constant 73 dp above the nav, whether or not a pill is
            // on screen. The pills live at 14-52, so they never collide and the
            // button no longer needs to hop when one appears.
            bottom: 73,
            child: FloatingActionButton(
              backgroundColor: Colors.white,
              // DO NOT MODIFY LOGIC: re-fetches GPS and re-centres the map
              // (UC-4). Keep refreshCurrentLocation() + animateTo; the snackbar
              // copy is [EDIT].
              // DO NOT MODIFY LOGIC: in-flight guard + mounted check.
              // refreshCurrentLocation can spend ~22 s in GPS timeouts, and the
              // FAB stayed live throughout: spam-tapping it queued that many
              // overlapping acquisitions, each ending in its own animateTo, so
              // the map yanked around for half a minute after the taps stopped.
              // The mounted check matters because animateTo drives an
              // AnimationController that dispose() has already torn down — an
              // in-flight fix returning after the tab is destroyed threw
              // "AnimationController used after being disposed".
              onPressed: _locating
                  ? null
                  : () async {
                      setState(() => _locating = true);
                      final messenger = ScaffoldMessenger.of(context);
                      messenger.showSnackBar(const SnackBar(
                          content: Text('Getting your GPS location…'),
                          duration: Duration(seconds: 2)));
                      try {
                        await vm.refreshCurrentLocation();
                      } catch (_) {
                        // refreshCurrentLocation reports through vm.locationError.
                      }
                      if (!mounted) return;
                      if (vm.currentLat != null) {
                        _mover.animateTo(
                            LatLng(vm.currentLat!, vm.currentLng!), 16.5);
                        messenger.hideCurrentSnackBar();
                      }
                      setState(() => _locating = false);
                    },
              child: const Icon(Icons.my_location, color: Colors.black87),
            ),
          ),
          // GUI Page 8 — "Earphones connected" pill, pinned just above the
          // shell's bottom navigation. It appears only while a headset is
          // actually attached, so it reports a real device state rather than
          // decorating the screen.
          //
          // [EDIT] pill shape, icon and copy. Colours are the existing
          // primaryButton / textPrimary tokens — no new palette.
          if (_earphones)
            Positioned(
              left: 20,
              right: 20,
              // Mockup: the pill sits 14 dp above the bottom nav (y=678-716,
              // nav at y=730) with the same 20 dp side margins as the search
              // bar. Page 8 and Page 13.5 draw their pills in the SAME slot, so
              // when a trip is running this one steps up over the shell's
              // "View Active Trip" pill (38 high + 8 gap) instead of colliding.
              bottom: tripActive ? 60 : 14,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 11),
                  decoration: BoxDecoration(
                    color: NavAlertColors.primaryButton,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(color: Colors.black38, blurRadius: 8),
                    ],
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.headset,
                          size: 18, color: NavAlertColors.textPrimary),
                      SizedBox(width: 10),
                      Text('Earphones connected',
                          style: TextStyle(
                              fontSize: 13,
                              fontStyle: FontStyle.italic,
                              color: NavAlertColors.textPrimary)),
                    ],
                  ),
                ),
              ),
            ),
          // ── SOS Warning (GUI "SOS Warning", Activity Diagram p.92) ─────────
          // The Activity Diagram fires this straight off "Launch App", and the
          // mockup draws it on the main screen — not on the Emergency tab,
          // where it used to live. That placement was the problem: the warning
          // says the SOS SMS may not send, and a rider only opens Emergency
          // when they ALREADY need it. Telling them their lifeline might be out
          // of load at that moment is too late to act on. On Home it lands
          // before the trip, while there is still time to top up.
          //
          // Last in the Stack so it draws over the map and the pill. Dismissal
          // is persisted (app_state.sos_low_load_warning_dismissed), so this is
          // a once-ever card, not a nag on every launch.
          if (context.watch<AppViewModel>().showSosLowLoadWarning)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Container(
                  decoration: BoxDecoration(
                    color: NavAlertColors.card,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 18),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sim_card_alert,
                          size: 34, color: NavAlertColors.warning),
                      const SizedBox(height: 10),
                      const Text('SOS Warning',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      const Text(
                        'Make sure your SIM card has sufficient prepaid load '
                        'before your trip to ensure your SOS message can be '
                        'sent.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: NavAlertColors.textSecondary),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        // DO NOT MODIFY LOGIC: this is the only way to clear the
                        // card. dismissSosLowLoadWarning persists the flag; drop
                        // the call and the warning returns on every launch with
                        // no way to silence it.
                        child: ElevatedButton(
                          onPressed: () => context
                              .read<AppViewModel>()
                              .dismissSosLowLoadWarning(),
                          child: const Text('Close'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
