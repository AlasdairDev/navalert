import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/map_support.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../services/sound_service.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/home_viewmodel.dart';
import '../viewmodels/trip_viewmodel.dart';
import 'active_trip_view.dart';

/// Figures 21–23 — Route Map & Mode Priority, Suggested Routes &
/// Commute Guide, and Trip Configuration.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] FlutterMap + route polyline (home.routePath) + origin dot /
///         destination pin · star _toggleFavorite · "Mode of Transport" →
///         _openModePriority sheet (bus/UV/jeepney switches + Done) ·
///         suggestion card onTap → home.selectSuggestion · "Show Commute
///         Guide" gate on selectedSuggestion · "Start Trip" →
///         _openTripSettings (optional destination alarm + sound +
///         vibration-only + Start Trip → tripVm.startTrip → ActiveTripView).
///  [EDIT] header card layout, tag chip colors/labels (_tag), suggestion
///         card styling, "SUGGESTED ROUTES FOUND" copy, step list rows,
///         polyline colors/width, pin styles, sheet cosmetics.
///  [WANT] fit-bounds animation, per-mode colored polylines, fare breakdown UI,
///         collapse/expand the suggestions sheet.
class RouteView extends StatefulWidget {
  const RouteView({super.key});

  @override
  State<RouteView> createState() => _RouteViewState();
}

class _RouteViewState extends State<RouteView> {
  bool _showGuide = false;

  // Sentinel dropdown value distinct from any catalogue name or `custom:`
  // sound — selecting it opens the file picker instead of setting a sound.
  static const _uploadSoundValue = '__upload_sound__';

  // ╔══════════════════════════════════════════════════════════════════════╗
  // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:                     ║
  // ║ SPAM-TAP DEBOUNCER (isProcessing) for the "Start Trip" button.       ║
  // ║                                                                      ║
  // ║ UI TEAM: `_startingTrip` is the in-flight flag. In the Trip Settings ║
  // ║ sheet below, keep `onPressed: _startingTrip ? null : ...` and the    ║
  // ║ `setSheet(() => _startingTrip = true)` that disables the button.     ║
  // ║ Style the sheet and the button freely. "Start Trip" is the single    ║
  // ║ most double-tapped control in the app — without this guard two taps  ║
  // ║ corrupt the navigation stack and the rider lands on a blank screen   ║
  // ║ or ends the trip they just started.                                  ║
  // ╚══════════════════════════════════════════════════════════════════════╝
  // In-flight guard for "Start Trip". TripViewModel
  // .startTrip already tears down any live monitoring, so the GPS listener is
  // safe — but the NAVIGATION here is not. The handler pops the sheet and then
  // pushes ActiveTripView, so two taps in the same frame ran both handlers:
  // the second `Navigator.of(ctx).pop()` fired against an already-popped sheet
  // context and took RouteView down with it, then both pushReplacement calls
  // ran. The rider ends a trip they just started, or lands on a broken stack.
  // "Start Trip" is a high-anticipation button — it gets double tapped.
  bool _startingTrip = false;

  // DO NOT MODIFY LOGIC: in-flight guard, matching the one on the Add-Favorite
  // save. The star stays tappable for the whole addFavorite/removeFavorite DB
  // round trip and `isFav` only flips once the write returns, so two taps both
  // saw "not a favorite" and each wrote a row — the same place saved twice, and
  // then only one copy removed by the un-star. A wide, easily hit window.
  bool _togglingFavorite = false;

  Future<void> _toggleFavorite() async {
    if (_togglingFavorite) return;
    _togglingFavorite = true;
    try {
      await _runToggleFavorite();
    } finally {
      // Always re-armed: a transient storage failure must stay retryable.
      if (mounted) _togglingFavorite = false;
    }
  }

  Future<void> _runToggleFavorite() async {
    final app = context.read<AppViewModel>();
    final home = context.read<HomeViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    final dest = home.destination;
    if (dest == null) return;
    final existing = app.favoriteAt(dest.lat, dest.lng);
    if (existing != null) {
      // Removing is destructive — confirm before un-starring.
      final confirmed = await showNavAlertConfirmDialog(
        context,
        title: 'Remove from Favorites?',
        message: '${dest.name} will be removed from your favorites.',
        confirmLabel: 'Remove',
        destructive: true,
      );
      if (confirmed != true) return;
      // The star must report a storage failure rather than silently doing
      // nothing (the success SnackBar below would never be reached).
      try {
        await app.removeFavorite(existing.favoriteId);
        messenger.showSnackBar(
            SnackBar(content: Text('${dest.name} removed from Favorites.')));
      } catch (_) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Could not update Favorites - storage is '
                'unavailable.')));
      }
    } else {
      try {
        final f = await app.addFavorite(
            dest.name, dest.displayName, dest.lat, dest.lng);
        home.plannedTrip?.destinationFavoriteId = f.favoriteId;
        messenger.showSnackBar(
            SnackBar(content: Text('${dest.name} added to Favorites.')));
      } catch (_) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Could not update Favorites - storage is '
                'unavailable.')));
      }
    }
    if (mounted) setState(() {});
  }

  void _openModePriority() {
    final app = context.read<AppViewModel>();
    showModalBottomSheet(
      context: context,
      backgroundColor: NavAlertColors.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        final p = app.transportPrefs;
        Widget tile(String label, String asset, bool value,
                void Function(bool) set) =>
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
              decoration: BoxDecoration(
                color: NavAlertColors.card,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(children: [
                Image.asset(asset, width: 80, height: 80, fit: BoxFit.contain),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w700)),
                ),
                Transform.scale(
                  scale: 1.4,
                  child: Switch(
                    value: value,
                    onChanged: (v) => setSheet(() => set(v)),
                  ),
                ),
              ]),
            );
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const _SheetHandle(),
            const Text('Mode Priority',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              'Select your preferred modes. Modes on will increase the '
              'likelihood of appearing. Deselect all others to de-prioritize a mode.',
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: NavAlertColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            tile('Bus', 'assets/images/transport/bus.png', p.busEnabled,
                (v) => p.busEnabled = v),
            tile('UV Express', 'assets/images/transport/uv_express.png',
                p.uvExpressEnabled, (v) => p.uvExpressEnabled = v),
            tile('Jeepney', 'assets/images/transport/jeepney.png',
                p.jeepneyEnabled, (v) => p.jeepneyEnabled = v),
            const SizedBox(height: 10),
            SizedBox(
              width: 160,
              child: ElevatedButton(
                onPressed: () async {
                  final home = context.read<HomeViewModel>();
                  await app.saveTransportPrefs();
                  if (!ctx.mounted) return;
                  Navigator.of(ctx).pop();
                  await home.regenerateSuggestions(app.transportPrefs);
                },
                child: const Text('Done'),
              ),
            ),
          ]),
        );
      }),
    );
  }

  /// Figure 23 — Trip Configuration sheet, then start monitoring.
  void _openTripSettings() {
    final home = context.read<HomeViewModel>();
    final app = context.read<AppViewModel>();
    final trip = home.plannedTrip;
    if (trip == null) return;
    var sound = app.settings.alarmSound;
    var vibrationOnly = false;
    // DO NOT MODIFY LOGIC: the destination alarm is OPT-IN. This local default
    // of false is what makes it off-by-default for real riders — the Trip model
    // itself defaults alarmEnabled to TRUE so that every other caller (and the
    // alarm test-suite) is unaffected. Do not "align" the two defaults.
    var alarmEnabled = false;

    showModalBottomSheet(
      context: context,
      backgroundColor: NavAlertColors.background,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const _SheetHandle(),
            const Text('Trip Settings',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            // Say what this sheet actually starts. The rider arrived here from
            // "Start Trip" on the commute guide, so the destination and the
            // fact that the GUIDE is what runs must be the first thing read —
            // the three controls below are all alarm options, and leading with
            // them made an optional add-on look like the subject of the screen.
            const SizedBox(height: 4),
            Text(
                'Monitoring to ${trip.destinationLabel.split(',').first}. '
                'Your step-by-step guide runs for the whole trip.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: NavAlertColors.textSecondary)),
            const SizedBox(height: 14),
            // The optional add-on comes FIRST among the alarm controls, because
            // the two below it only mean anything once it is on.
            Card(
              child: SwitchListTile(
                secondary: Icon(alarmEnabled ? Icons.alarm_on : Icons.alarm_off,
                    color: NavAlertColors.accent),
                title: const Text('Destination alarm'),
                subtitle: Text(
                    alarmEnabled
                        ? 'You will be woken as you approach your stop.'
                        : 'Optional - off. You can turn it on any time '
                            'during the trip.',
                    style: const TextStyle(
                        fontSize: 11, color: NavAlertColors.textSecondary)),
                value: alarmEnabled,
                onChanged: (v) => setSheet(() => alarmEnabled = v),
              ),
            ),
            Card(
              child: ListTile(
                leading: Icon(Icons.music_note,
                    color: alarmEnabled
                        ? NavAlertColors.accent
                        : NavAlertColors.textSecondary),
                title:
                    const Text('Alarm sound', style: TextStyle(fontSize: 13)),
                // A custom sound's filename can be much longer than any
                // catalogue name. Without a width cap the dropdown demands
                // whatever space fits it unellipsized, which starves the
                // title next to it down to a sliver — "Alarm sound" wrapping
                // one letter per line.
                trailing: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      // Guard the value like Settings does: a non-catalog
                      // sound (e.g. from an imported backup) must not crash
                      // the sheet with DropdownButton's "value not in items"
                      // assertion.
                      value: SoundService.alarmCatalog.containsKey(sound) ||
                              SoundService.isCustom(sound)
                          ? sound
                          : SoundService.alarmCatalog.keys.first,
                      dropdownColor: NavAlertColors.card,
                      items: [
                        ...SoundService.alarmCatalog.keys.map(
                            (s) => DropdownMenuItem(value: s, child: Text(s))),
                        if (SoundService.isCustom(sound))
                          DropdownMenuItem(
                            value: sound,
                            child: Text(SoundService.customLabel(sound),
                                overflow: TextOverflow.ellipsis),
                          ),
                        const DropdownMenuItem(
                          value: _uploadSoundValue,
                          child: Text('Upload your own audio…'),
                        ),
                      ],
                      // Picking a sound for an alarm that is switched off does
                      // nothing, and previewing one implies the alarm is
                      // armed. Disabled until the toggle above turns it on.
                      onChanged: alarmEnabled
                          ? (v) async {
                              if (v == null) return;
                              if (v == _uploadSoundValue) {
                                final picked = await app.pickCustomAlarmSound();
                                if (picked == null) return;
                                setSheet(() => sound = picked);
                                SoundService.instance.previewAlarm(picked);
                                return;
                              }
                              setSheet(() => sound = v);
                              SoundService.instance.previewAlarm(v);
                            }
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            Card(
              child: CheckboxListTile(
                secondary: Icon(Icons.vibration,
                    color: alarmEnabled
                        ? NavAlertColors.accent
                        : NavAlertColors.textSecondary),
                title: const Text('Vibration Only Mode',
                    style: TextStyle(fontSize: 13)),
                // Meaningless while the alarm is off — disabled rather than
                // left tappable so the sheet cannot imply it does something.
                value: vibrationOnly,
                onChanged: alarmEnabled
                    ? (v) => setSheet(() => vibrationOnly = v ?? false)
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel')),
              const SizedBox(width: 12),
              ElevatedButton(
                // Disabled while the trip is being started, so the button
                // visibly reflects the in-flight guard instead of silently
                // swallowing the taps of an impatient rider.
                onPressed: _startingTrip
                    ? null
                    : () async {
                        if (_startingTrip) return;
                        setSheet(() => _startingTrip = true);
                        final tripVm = context.read<TripViewModel>();
                        final navigator = Navigator.of(context);
                        final messenger = ScaffoldMessenger.of(context);
                        // Hand the chosen suggestion's guide legs to the trip. They
                        // are memory-only (Table 24 has no coordinates), so this is
                        // the one moment they can be transferred.
                        final legs = context
                            .read<HomeViewModel>()
                            .legsFor(trip.selectedRouteSuggestionId);
                        // View sets the chosen config on the trip; TripViewModel
                        // .startTrip() persists it (keeps the DB out of the View).
                        trip
                          ..alarmSound = sound
                          ..vibrationOnlyMode = vibrationOnly
                          ..alarmEnabled = alarmEnabled;
                        Navigator.of(ctx).pop();
                        // A failure inside startTrip (the trip write, the GPS stream,
                        // the foreground service) must SAY so and re-arm the button.
                        // Unguarded, the exception escaped the handler: the sheet had
                        // already closed, so the rider saw the sheet dismiss and then
                        // nothing at all — no trip, no alarm, no error.
                        try {
                          await tripVm.startTrip(trip, guideLegs: legs);
                        } catch (_) {
                          _startingTrip = false;
                          messenger.showSnackBar(const SnackBar(
                              content:
                                  Text('Could not start the trip - please try '
                                      'again.')));
                          return;
                        }
                        if (!mounted) {
                          _startingTrip = false;
                          return;
                        }
                        navigator.pushReplacement(MaterialPageRoute(
                            builder: (_) => const ActiveTripView()));
                      },
                child: const Text('Start Trip'),
              ),
            ]),
          ]),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeViewModel>();
    final app = context.watch<AppViewModel>();
    final dest = home.destination;
    final trip = home.plannedTrip;
    if (dest == null || trip == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final origin = LatLng(trip.originLat, trip.originLng);
    final target = LatLng(dest.lat, dest.lng);
    final isFav = app.favoriteAt(dest.lat, dest.lng) != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hello, there!'),
        leading: BackButton(onPressed: () {
          home.clearPlan();
          Navigator.of(context).pop();
        }),
      ),
      body: Column(
        children: [
          // From → To header card
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  // Figures 21/22 draw the two endpoints as ONE connected stop
                  // rail — a filled origin dot joined by a short vertical line
                  // down to the destination dot — not two unrelated rows split
                  // by a divider. The two glyphs are different sizes, so each
                  // sits centred in a shared 16 dp gutter; without that they
                  // did not even line up with each other. The divider moves
                  // BELOW the destination, where the mockup rules off the whole
                  // from→to block before the Mode chip.
                  Row(children: [
                    _railGutter(const Icon(Icons.circle,
                        size: 10, color: NavAlertColors.accent)),
                    const SizedBox(width: 10),
                    Expanded(
                      // Google-Maps style: primary name only, one line.
                      child: Text(
                          trip.originLabel
                              .split(',')
                              .take(2)
                              .map((p) => p.trim())
                              .join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ]),
                  // Wrapped in a Row so the connector hugs the left gutter —
                  // the enclosing Column centres its children by default.
                  Row(children: [
                    _railGutter(Container(
                        width: 2, height: 16, color: NavAlertColors.surface)),
                  ]),
                  Row(children: [
                    _railGutter(const Icon(Icons.location_on,
                        size: 14, color: NavAlertColors.warning)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(dest.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                    IconButton(
                      icon: Icon(isFav ? Icons.star : Icons.star_border,
                          color: isFav ? Colors.amber : null),
                      onPressed: _toggleFavorite,
                    ),
                  ]),
                  const Divider(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ActionChip(
                      avatar: const Icon(Icons.directions_bus,
                          size: 16, color: Colors.white),
                      label: const Text('Mode of Transport'),
                      backgroundColor: NavAlertColors.primaryButton,
                      onPressed: _openModePriority,
                    ),
                  ),
                ]),
              ),
            ),
          ),
          // Map — route drawn along real streets with origin dot and
          // destination pin, like Google Maps (Figure 21).
          Expanded(
            child: Builder(builder: (context) {
              final path = home.routePath.isNotEmpty
                  ? home.routePath
                      .map((p) => LatLng(p[0], p[1]))
                      .toList(growable: false)
                  : [origin, target];
              return FlutterMap(
                options: MapOptions(
                  initialCameraFit: CameraFit.coordinates(
                    coordinates: [origin, target],
                    padding: const EdgeInsets.all(48),
                  ),
                ),
                children: [
                  NavAlertMap.tiles(context),
                  PolylineLayer(polylines: [
                    // White casing under the route line for contrast.
                    Polyline(points: path, strokeWidth: 9, color: Colors.white),
                    Polyline(
                        points: path,
                        strokeWidth: 5.5,
                        color: const Color(0xFF4285F4)),
                  ]),
                  MarkerLayer(markers: [
                    // Origin: blue dot with white ring (current location).
                    Marker(
                      point: origin,
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
                    // Destination: red map pin anchored at its tip.
                    Marker(
                      point: target,
                      width: 44,
                      height: 44,
                      alignment: Alignment.topCenter,
                      child: const Icon(Icons.location_pin,
                          color: NavAlertColors.danger,
                          size: 44,
                          shadows: [
                            Shadow(color: Colors.black45, blurRadius: 6),
                          ]),
                    ),
                  ]),
                  if (home.loadingPath)
                    const Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Chip(
                          label: Text('Tracing route…',
                              style: TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                ],
              );
            }),
          ),
          // Suggested routes / commute guide panel (Figure 22)
          Container(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.42),
            decoration: const BoxDecoration(
              color: NavAlertColors.background,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child:
                _showGuide ? _buildCommuteGuide(home) : _buildSuggestions(home),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestions(HomeViewModel home) {
    // Outside Metro Manila there is no honest guide to give: the fares are the
    // LTFRB NCR rates and the GTFS feed is NCR-only. Say so instead of showing
    // "0 SUGGESTED ROUTES FOUND", which reads like a failure rather than a
    // scope limit — and make clear the alarm still works.
    final reason = home.guideUnavailableReason;
    if (reason != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.map_outlined,
              color: NavAlertColors.warning, size: 30),
          const SizedBox(height: 10),
          const Text('Outside the service area',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(reason,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12, color: NavAlertColors.textSecondary)),
        ]),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // TODO (UI Team): "Suggested Routes" header + count typography.
      const Text('Suggested Routes',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      Text('${home.suggestions.length} SUGGESTED ROUTES FOUND',
          style: const TextStyle(
              color: NavAlertColors.warning,
              fontSize: 11,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      // DO NOT MODIFY LOGIC: home.suggestions is the OUTPUT of the Dijkstra
      // routing isolate (Fastest/Cheapest, real fares). Render the cards
      // however you like, but keep the .map over home.suggestions and pass
      // each `s` into the card unchanged — the card wires selection + fares.
      Flexible(
        child: SingleChildScrollView(
          child: Row(
            children: home.suggestions
                .map((s) => Expanded(child: _suggestionCard(home, s)))
                .toList(),
          ),
        ),
      ),
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: home.selectedSuggestion == null
            ? null
            : () => setState(() => _showGuide = true),
        child: const Text('Show Commute Guide'),
      ),
    ]);
  }

  Widget _suggestionCard(HomeViewModel home, RouteSuggestion s) {
    final selected = home.selectedSuggestion?.suggestionId == s.suggestionId;
    return GestureDetector(
      // DO NOT MODIFY LOGIC: selecting a card sets the chosen route on the
      // trip (its fare + guide legs feed the live commute guide). Keep the
      // onTap → home.selectSuggestion(s). The card visuals below are [EDIT].
      onTap: () => home.selectSuggestion(s),
      child: Card(
        // USE THEME: card / surface / accent already come from NavAlertColors —
        // keep pulling from tokens rather than hardcoding new hex here.
        color: selected ? NavAlertColors.card : NavAlertColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: selected
              ? const BorderSide(color: NavAlertColors.accent, width: 2)
              : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 4, children: [
              if (s.tagPrimary != null) _tag(s.tagPrimary!),
              if (s.tagSecondary != null) _tag(s.tagSecondary!),
            ]),
            const SizedBox(height: 6),
            Text(s.routeLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.schedule,
                  size: 12, color: NavAlertColors.textSecondary),
              const SizedBox(width: 4),
              Text('${_fmtDuration(s.totalDurationMinutes)} total',
                  style: const TextStyle(
                      fontSize: 12, color: NavAlertColors.textSecondary)),
            ]),
            Text('₱${s.totalFarePhp.toStringAsFixed(2)}',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            Text(s.transportSummary ?? '',
                style: const TextStyle(
                    fontSize: 11, color: NavAlertColors.textSecondary)),
          ]),
        ),
      ),
    );
  }

  Widget _tag(String text) {
    final color = switch (text) {
      'Fastest' => NavAlertColors.success,
      'Cheapest' => NavAlertColors.warning,
      'Costly' => NavAlertColors.danger,
      _ => NavAlertColors.primary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
      child: Text(text,
          style: const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
    );
  }

  Widget _buildCommuteGuide(HomeViewModel home) {
    // Defensive, not currently reachable: "Show Commute Guide" is disabled until
    // a suggestion is selected, and regenerating always re-selects one. But this
    // is a force-unwrap inside build() on state another screen can mutate, so a
    // future change to the suggestion pipeline would turn it into a hard crash
    // on the route screen rather than a graceful fallback.
    final s = home.selectedSuggestion;
    if (s == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showGuide) setState(() => _showGuide = false);
      });
      return const SizedBox.shrink();
    }
    final estimate = home.suggestionsAreEstimates;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('Step-by-Step Commute Guide',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w700)),
      // No direct GTFS route was matched — the boarding points below are
      // approximate, so label the whole guide as an estimate to avoid sending
      // the rider looking for a specific named terminal that isn't real data.
      if (estimate)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: NavAlertColors.warning.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text('ESTIMATE - approximate boarding points',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: NavAlertColors.warning)),
        ),
      Flexible(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: s.steps.length,
          itemBuilder: (_, i) {
            final step = s.steps[i];
            // Figure 22 — each ride segment lists its boarding and
            // alighting stops beneath the instruction.
            final stops = [
              if (step.fromStop != null && step.fromStop!.isNotEmpty)
                step.fromStop!,
              if (step.toStop != null && step.toStop!.isNotEmpty) step.toStop!,
            ];
            // For a RIDE leg, the boarding terminal is the thing the rider
            // most needs — show it prominently, not buried in the instruction.
            final isRide = step.transportMode != 'walk' &&
                step.fromStop != null &&
                step.fromStop!.isNotEmpty;
            // Figures 22 / Pages 15-16 lay every step out the same way: a
            // round mode badge on the left, the instruction block in the
            // middle, and the fare + travel time stacked at the TOP RIGHT —
            // fare as a pill, time behind a small clock glyph. Both used to be
            // one grey run-on line at the bottom of the subtitle, so the two
            // figures a rider actually compares routes on were the least
            // legible thing on the card. A ride leg then rules off its title
            // block and lists the boarding/alighting stops beneath it.
            return Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _modeBadge(step.transportMode),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: isRide
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          // Prominent boarding terminal.
                                          Text('Board at ${step.fromStop}',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w700)),
                                          const SizedBox(height: 2),
                                          Text(step.instruction,
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  color: NavAlertColors
                                                      .textSecondary)),
                                        ],
                                      )
                                    // A walk leg has no fare, so the mockup
                                    // gives it no right-hand pill at all —
                                    // just the instruction with its minutes
                                    // tucked underneath.
                                    : Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(step.instruction,
                                              style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600)),
                                          if (step.durationMinutes > 0)
                                            Text(
                                                '${step.durationMinutes.toStringAsFixed(0)} min',
                                                style: const TextStyle(
                                                    fontSize: 11,
                                                    color: NavAlertColors
                                                        .textSecondary)),
                                        ],
                                      ),
                              ),
                              // A ride leg always keeps its right-hand cluster,
                              // even in the defensive case of a zero fare —
                              // otherwise the leg would lose its travel time
                              // too, since the walk branch above is what
                              // normally carries it.
                              if (step.farePhp > 0 ||
                                  (isRide && step.durationMinutes > 0)) ...[
                                const SizedBox(width: 8),
                                _fareAndTime(
                                    step.farePhp, step.durationMinutes),
                              ],
                            ],
                          ),
                          if (stops.isNotEmpty) ...[
                            const Divider(height: 14),
                            _stopRail(stops),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 10),
      // ── Figure 22 footer ────────────────────────────────────────────────
      // THE COMMUTE GUIDE IS THE PRIMARY FEATURE; the alarm is an optional
      // add-on (Chapter 3, UC-4 alt-flow B "Commute Guide Only"). These two
      // buttons are therefore equal-weight siblings, not one forced action:
      //   Close      — outlined. Dismisses the sheet and lets the rider
      //                navigate on their own using the steps above.
      //   Start Trip — solid pill. Opens Trip Settings and begins MONITORING.
      // Do not collapse this back into a single button.
      //
      // This button used to read "Enable Alarm", which misnamed the whole
      // product: it made the alarm look like the thing you were starting, and
      // a rider who only wanted the step-by-step guide had to press a button
      // promising an alarm they did not want. What the tap actually begins is
      // trip MONITORING, which is what carries the live guide; the destination
      // alarm is one optional switch inside the sheet it opens, and it is off
      // by default. Name the trip, not the add-on.
      Row(children: [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: () => setState(() => _showGuide = false),
            child: const Text('Close'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: _openTripSettings,
            child: const Text('Start Trip'),
          ),
        ),
      ]),
    ]);
  }

  /// Centres a rail glyph in a fixed 16 dp gutter so the origin dot, the
  /// connector line and the destination pin all share one vertical axis
  /// despite being different sizes.
  static Widget _railGutter(Widget child) =>
      SizedBox(width: 16, child: Center(child: child));

  /// The round mode badge every step in Pages 15/16 leads with. The mockup
  /// draws a full vehicle illustration for ride legs; the app has no such
  /// artwork, so the existing Material mode glyph is used inside the same
  /// circular plate — layout from the mockup, iconography already in the app.
  static Widget _modeBadge(String mode) {
    final asset = switch (mode) {
      'bus' => 'assets/images/transport/bus_purple.png',
      'uv_express' => 'assets/images/transport/uv_express_purple.png',
      'jeepney' => 'assets/images/transport/jeepney_purple.png',
      _ => null,
    };
    if (asset != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 64,
          height: 56,
          color: NavAlertColors.surface,
          child: Image.asset(asset, fit: BoxFit.contain),
        ),
      );
    }
    return Container(
      width: 36,
      height: 36,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: NavAlertColors.surface,
      ),
      child: const Icon(Icons.directions_walk,
          size: 18, color: NavAlertColors.accent),
    );
  }

  /// Fare pill over a clock-glyph travel time — the top-right cluster on every
  /// ride card in Pages 15/16. These are the two numbers a rider compares
  /// routes on, so they are the only thing on the card set apart from the copy.
  static Widget _fareAndTime(double farePhp, double minutes) => Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (farePhp > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                // Existing brand purple at low alpha — the same tint the live
                // guide sheet already uses to mark its current leg.
                color: NavAlertColors.primary.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('₱${farePhp.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          if (minutes > 0)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.schedule,
                    size: 11, color: NavAlertColors.textSecondary),
                const SizedBox(width: 3),
                Text('${minutes.toStringAsFixed(0)} min',
                    style: const TextStyle(
                        fontSize: 11, color: NavAlertColors.textSecondary)),
              ]),
            ),
        ],
      );

  /// Board → alight rail: a filled dot for the boarding terminal, a hollow
  /// ring for the drop-off, joined by the same connector line as the from→to
  /// header above. The alight stop used to reuse the header's map pin, which
  /// read as a second destination rather than the end of this one leg.
  static Widget _stopRail(List<String> stops) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var j = 0; j < stops.length; j++) ...[
            Row(children: [
              _railGutter(Icon(
                  j == 0 ? Icons.circle : Icons.radio_button_unchecked,
                  size: 8,
                  color:
                      j == 0 ? NavAlertColors.accent : NavAlertColors.warning)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(stops[j],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: NavAlertColors.textSecondary)),
              ),
            ]),
            if (j < stops.length - 1)
              Row(children: [
                _railGutter(Container(
                    width: 1.5,
                    height: 10,
                    color:
                        NavAlertColors.textSecondary.withValues(alpha: 0.55))),
              ]),
          ],
        ],
      );

  String _fmtDuration(double minutes) {
    final m = minutes.round();
    if (m < 60) return '$m min';
    return '${m ~/ 60} hr ${m % 60} min';
  }
}

/// The grab bar every bottom sheet in the mockups is topped with (Mode
/// Priority Page 13, Trip Settings Page 13). Both sheets are draggable, and
/// without it nothing on screen said so. Same 44x4 bar the live commute-guide
/// sheet already uses, so the two read as one component.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 4,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: NavAlertColors.textSecondary,
          borderRadius: BorderRadius.circular(2),
        ),
      );
}
