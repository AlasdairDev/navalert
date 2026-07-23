import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/map_support.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../services/geocoding_service.dart';
import '../viewmodels/home_viewmodel.dart';

/// UC-4 (Search & Set Destination) — "pins the exact drop-off point on
/// the map": lets the commuter drop a pin at the precise alighting spot
/// instead of searching by name. Returns the picked [PlaceResult].
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] FlutterMap onTap → _onTap (drop pin + reverse-geocode) ·
///         "Confirm Drop-off Point" → _confirm (returns PlaceResult) ·
///         disabled state until a pin exists.
///  [EDIT] "Pin Drop-off Point" title, the red pin + blue current-location
///         dot styles, the bottom summary card, "Tap the map…" hint copy,
///         "Locating address…" text, confirm button label.
///  [WANT] center crosshair instead of tap-to-drop, draggable pin, snap to
///         nearest GTFS stop.
class PinOnMapView extends StatefulWidget {
  const PinOnMapView({super.key});

  @override
  State<PinOnMapView> createState() => _PinOnMapViewState();
}

class _PinOnMapViewState extends State<PinOnMapView> {
  final _geocoder = GeocodingService();

  LatLng? _picked;
  String? _pickedAddress;
  bool _resolving = false;

  Future<void> _onTap(TapPosition tapPosition, LatLng point) async {
    // Reject drop-offs outside NCR: the app has no route or fare data there,
    // so a pin in a province would produce no guide (Scope and Limitations).
    // The camera constraint keeps most taps in-bounds, but the very edge of
    // the fenced view can still fall just outside.
    if (!NavAlertMap.isWithinNcr(point)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'NavAlert routing covers Metro Manila (NCR) only — pick a drop-off '
            'inside the region.'),
      ));
      return;
    }
    setState(() {
      _picked = point;
      _pickedAddress = null;
      _resolving = true;
    });
    try {
      final addr = await _geocoder.reverse(point.latitude, point.longitude);
      if (!mounted) return;
      // Ignore stale lookups if the user tapped somewhere else meanwhile.
      if (_picked == point) {
        setState(() => _pickedAddress = addr);
      }
    } catch (_) {/* offline — coordinates are still usable */} finally {
      if (mounted && _picked == point) setState(() => _resolving = false);
    }
  }

  void _confirm() {
    final p = _picked;
    if (p == null) return;
    final full = _pickedAddress ??
        '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';
    final name = full.split(',').first.trim();
    Navigator.of(context).pop(PlaceResult(
      name: name.isEmpty ? 'Pinned Location' : name,
      displayName: full,
      lat: p.latitude,
      lng: p.longitude,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final home = context.read<HomeViewModel>();
    final center = _picked ??
        LatLng(home.currentLat ?? 14.5979, home.currentLng ?? 121.0108);

    return Scaffold(
      appBar: AppBar(title: const Text('Pin Drop-off Point')),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              options: MapOptions(
                initialCenter: center,
                initialZoom: 16,
                onTap: _onTap,
                cameraConstraint: NavAlertMap.ncrConstraint,
                minZoom: 10,
                maxZoom: 20,
              ),
              children: [
                NavAlertMap.tiles(context),
                MarkerLayer(markers: [
                  if (home.currentLat != null)
                    Marker(
                      point: LatLng(home.currentLat!, home.currentLng!),
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
                  if (_picked != null)
                    Marker(
                      point: _picked!,
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
              ],
            ),
          ),
          // Picked-point summary + confirmation
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            decoration: const BoxDecoration(
              color: NavAlertColors.background,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _picked == null
                      ? 'Tap the map to drop a pin at your exact drop-off point.'
                      : _resolving
                          ? 'Locating address…'
                          : (_pickedAddress ??
                              '${_picked!.latitude.toStringAsFixed(5)}, '
                                  '${_picked!.longitude.toStringAsFixed(5)}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, color: NavAlertColors.textSecondary),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _picked == null ? null : _confirm,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Confirm Drop-off Point'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
