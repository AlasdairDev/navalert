import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../services/geocoding_service.dart';
import '../viewmodels/app_viewmodel.dart';

/// Figure 31 — Favorites ⊕: a dedicated page for saving a place as a
/// favorite. Separate from the Home destination search (Figure 20) and
/// with its own search state, so results never leak between the two.
class AddFavoriteView extends StatefulWidget {
  const AddFavoriteView({super.key});

  @override
  State<AddFavoriteView> createState() => _AddFavoriteViewState();
}

class _AddFavoriteViewState extends State<AddFavoriteView> {
  final _controller = TextEditingController();
  final _geocoder = GeocodingService();
  Timer? _debounce;

  bool _searching = false;
  String? _error;
  List<PlaceResult> _results = [];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (q.trim().length >= 3) _search(q);
    });
  }

  Future<void> _search(String query) async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final r = await _geocoder.search(query);
      if (!mounted) return;
      setState(() {
        _results = r;
        if (r.isEmpty) _error = 'No results — try refining your search.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = [];
        _error = 'Network error — adding favorites needs internet.';
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _save(PlaceResult place) async {
    final app = context.read<AppViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    await app.addFavorite(place.name, place.displayName, place.lat, place.lng);
    messenger.showSnackBar(
        SnackBar(content: Text('${place.name} added to Favorites.')));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Favorite')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: TextField(
                controller: _controller,
                autofocus: true,
                style: const TextStyle(color: Colors.black87),
                decoration: const InputDecoration(
                  hintText: 'Search a place to save…',
                  fillColor: Colors.white,
                  prefixIcon: Icon(Icons.search, color: Colors.black54),
                ),
                onChanged: _onChanged,
                onSubmitted: _search,
              ),
            ),
            if (_searching) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!,
                    style: const TextStyle(color: NavAlertColors.warning)),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (_, i) {
                  final r = _results[i];
                  return ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: NavAlertColors.surface,
                      child: Icon(Icons.star_border,
                          color: Colors.amber, size: 20),
                    ),
                    title: Text(r.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(r.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: NavAlertColors.textSecondary,
                            fontSize: 12)),
                    trailing: const Icon(Icons.add_circle_outline,
                        color: NavAlertColors.accent),
                    onTap: () => _save(r),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
