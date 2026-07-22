import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

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
///         Guide" gate on selectedSuggestion · "Enable Alarm" →
///         _openTripSettings (sound + vibration-only + Start Trip →
///         tripVm.startTrip → ActiveTripView).
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

  Future<void> _toggleFavorite() async {
    final app = context.read<AppViewModel>();
    final home = context.read<HomeViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    final dest = home.destination;
    if (dest == null) return;
    final existing = app.favoriteAt(dest.lat, dest.lng);
    if (existing != null) {
      // Removing is destructive — confirm before un-starring.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove from Favorites?'),
          content: Text('${dest.name} will be removed from your favorites.',
              style: const TextStyle(fontSize: 13)),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remove',
                  style: TextStyle(
                      color: NavAlertColors.danger,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await app.removeFavorite(existing.favoriteId);
      messenger.showSnackBar(
          SnackBar(content: Text('${dest.name} removed from Favorites.')));
    } else {
      final f = await app.addFavorite(
          dest.name, dest.displayName, dest.lat, dest.lng);
      home.plannedTrip?.destinationFavoriteId = f.favoriteId;
      messenger.showSnackBar(
          SnackBar(content: Text('${dest.name} added to Favorites.')));
    }
    if (mounted) setState(() {});
  }

  void _openModePriority() {
    final app = context.read<AppViewModel>();
    showModalBottomSheet(
      context: context,
      backgroundColor: NavAlertColors.background,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        final p = app.transportPrefs;
        Widget tile(String label, IconData icon, bool value,
                void Function(bool) set) =>
            Card(
              child: SwitchListTile(
                secondary: Icon(icon, color: NavAlertColors.accent),
                title: Text(label),
                value: value,
                onChanged: (v) => setSheet(() => set(v)),
              ),
            );
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Mode Priority',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              'Select your preferred modes. Modes on will increase the '
              'likelihood of appearing. Deselect all others to de-prioritize a mode.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: NavAlertColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            tile('Bus', Icons.directions_bus, p.busEnabled,
                (v) => p.busEnabled = v),
            tile('UV Express', Icons.airport_shuttle, p.uvExpressEnabled,
                (v) => p.uvExpressEnabled = v),
            tile('Jeepney', Icons.directions_transit, p.jeepneyEnabled,
                (v) => p.jeepneyEnabled = v),
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

    showModalBottomSheet(
      context: context,
      backgroundColor: NavAlertColors.background,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Trip Settings',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: sound,
                    dropdownColor: NavAlertColors.card,
                    items: SoundService.alarmCatalog.keys
                        .map((s) =>
                            DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setSheet(() => sound = v);
                      SoundService.instance.previewAlarm(v);
                    },
                  ),
                ),
              ),
            ),
            Card(
              child: CheckboxListTile(
                title: const Text('Vibration Only Mode'),
                value: vibrationOnly,
                onChanged: (v) => setSheet(() => vibrationOnly = v ?? false),
              ),
            ),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel')),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () async {
                  final tripVm = context.read<TripViewModel>();
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
                    ..vibrationOnlyMode = vibrationOnly;
                  Navigator.of(ctx).pop();
                  await tripVm.startTrip(trip, guideLegs: legs);
                  if (!mounted) return;
                  // ignore: use_build_context_synchronously
                  Navigator.of(context).pushReplacement(MaterialPageRoute(
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
                  Row(children: [
                    const Icon(Icons.circle,
                        size: 10, color: NavAlertColors.accent),
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
                  const Divider(height: 16),
                  Row(children: [
                    const Icon(Icons.location_on,
                        size: 14, color: NavAlertColors.warning),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(dest.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                    IconButton(
                      icon: Icon(isFav ? Icons.star : Icons.star_border,
                          color: isFav ? Colors.amber : null),
                      onPressed: _toggleFavorite,
                    ),
                  ]),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ActionChip(
                      avatar: const Icon(Icons.directions_bus, size: 16),
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
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'ph.edu.pup.navalert',
                    tileProvider: CancellableNetworkTileProvider(),
                    panBuffer: 1,
                    keepBuffer: 4,
                  ),
                  PolylineLayer(polylines: [
                    // White casing under the route line for contrast.
                    Polyline(
                        points: path, strokeWidth: 9, color: Colors.white),
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
      const Text('Suggested Routes',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      Text('${home.suggestions.length} SUGGESTED ROUTES FOUND',
          style: const TextStyle(
              color: NavAlertColors.warning,
              fontSize: 11,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
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
      onTap: () => home.selectSuggestion(s),
      child: Card(
        color: selected ? NavAlertColors.card : NavAlertColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: selected
              ? const BorderSide(color: NavAlertColors.accent, width: 2)
              : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 4, children: [
              if (s.tagPrimary != null) _tag(s.tagPrimary!),
              if (s.tagSecondary != null) _tag(s.tagSecondary!),
            ]),
            const SizedBox(height: 6),
            Text(s.routeLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            Text('⏱ ${_fmtDuration(s.totalDurationMinutes)} total',
                style: const TextStyle(
                    fontSize: 12, color: NavAlertColors.textSecondary)),
            Text('₱${s.totalFarePhp.toStringAsFixed(2)}',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
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
      decoration: BoxDecoration(
          color: color, borderRadius: BorderRadius.circular(10)),
      child: Text(text,
          style: const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
    );
  }

  Widget _buildCommuteGuide(HomeViewModel home) {
    final s = home.selectedSuggestion!;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(() => _showGuide = false)),
        const Text('Step-by-Step Commute Guide',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ]),
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
              if (step.toStop != null && step.toStop!.isNotEmpty)
                step.toStop!,
            ];
            return Card(
              child: ListTile(
                dense: true,
                leading: Icon(_modeIcon(step.transportMode),
                    color: NavAlertColors.accent),
                title: Text(step.instruction,
                    style: const TextStyle(fontSize: 13)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var j = 0; j < stops.length; j++)
                      Row(children: [
                        Icon(j == 0 ? Icons.circle : Icons.location_on,
                            size: 9,
                            color: j == 0
                                ? NavAlertColors.accent
                                : NavAlertColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(stops[j],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: NavAlertColors.textSecondary)),
                        ),
                      ]),
                    Text(
                        '${step.durationMinutes.toStringAsFixed(0)} min'
                        '${step.farePhp > 0 ? '  ·  ₱${step.farePhp.toStringAsFixed(2)}' : ''}',
                        style: const TextStyle(
                            fontSize: 11,
                            color: NavAlertColors.textSecondary)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        OutlinedButton(
            onPressed: () => setState(() => _showGuide = false),
            child: const Text('Close')),
        const SizedBox(width: 12),
        ElevatedButton(
            onPressed: _openTripSettings, child: const Text('Enable Alarm')),
      ]),
    ]);
  }

  IconData _modeIcon(String mode) => switch (mode) {
        'walk' => Icons.directions_walk,
        'bus' => Icons.directions_bus,
        'uv_express' => Icons.airport_shuttle,
        _ => Icons.directions_transit,
      };

  String _fmtDuration(double minutes) {
    final m = minutes.round();
    if (m < 60) return '$m min';
    return '${m ~/ 60} hr ${m % 60} min';
  }
}
