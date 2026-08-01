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
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] search TextField onChanged → _search (own Nominatim state) ·
///         result onTap → _save (app.addFavorite + pop). Keep this state
///         SEPARATE from HomeViewModel (that separation is the whole point).
///  [EDIT] "Add Favorite" title, "Search a place to save…" hint, result row
///         star icon/styling, snackbar copy.
///  [WANT] label picker (Home/Work/School) on save, map preview of result.
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

  // DO NOT MODIFY LOGIC: persists the favorite and returns to the list. Keep
  // addFavorite + pop; the snackbar copy is [EDIT]. (This screen intentionally
  // has its OWN search state, separate from Home search — don't merge them.)
  // DO NOT MODIFY LOGIC: in-flight guard. addFavorite writes a row and only
  // then pops, so tapping a result five times before the first write returned
  // saved the same place five times over — five identical rows in Favorites.
  bool _saving = false;

  Future<void> _save(PlaceResult place) async {
    if (_saving) return;
    _saving = true;
    final app = context.read<AppViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    // Report a storage failure instead of popping as if the favourite saved.
    try {
      await app.addFavorite(
          place.name, place.displayName, place.lat, place.lng);
    } catch (_) {
      // Released so the rider can retry after a transient storage failure —
      // a latched guard would leave every result row permanently dead.
      _saving = false;
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not save — storage is unavailable.')));
      return;
    }
    messenger.showSnackBar(
        SnackBar(content: Text('${place.name} added to Favorites.')));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Figure 24.2 titles this screen "Add New Favorite".
      appBar: AppBar(title: const Text('Add New Favorite')),
      // ╔══════════════════════════════════════════════════════════════════╗
      // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:                 ║
      // ║ KEYBOARD UNFOCUS WRAPPER (soft-keyboard dismissal).              ║
      // ║                                                                  ║
      // ║ UI TEAM: same contract as search_view.dart — keep this           ║
      // ║ GestureDetector wrapping the body, with HitTestBehavior.opaque   ║
      // ║ and the unfocus() onTap. Restyle freely inside. Without it the   ║
      // ║ keyboard covers the result list and the rider cannot tap the     ║
      // ║ place they are trying to save.                                   ║
      // ╚══════════════════════════════════════════════════════════════════╝
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: SafeArea(
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
              // Figure 24.2 puts the ⊕ on the LEFT of each row — it reads as
              // "add this one" before the name, instead of a star that looked
              // like the row was already saved. Rows are cards there, and the
              // list had no empty state at all: before the first search, and
              // after a search that matched nothing, the screen was simply
              // blank with no indication which of the two had happened.
              child: _results.isEmpty && !_searching && _error == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            // Only ever the pre-search prompt. A "nothing
                            // matched" message does NOT belong here: _search
                            // already reports that through _error, and the
                            // search does not even run until 3 characters, so
                            // keying this on "results are empty" would tell a
                            // rider who has typed "SM" that their search found
                            // nothing when no search had been made.
                            Icon(Icons.search,
                                size: 48, color: NavAlertColors.textSecondary),
                            SizedBox(height: 12),
                            Text(
                              'Search for a place to save it to your '
                              'Favorites.',
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
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      itemCount: _results.length,
                      itemBuilder: (_, i) {
                        final r = _results[i];
                        return Card(
                          child: ListTile(
                            contentPadding:
                                const EdgeInsets.fromLTRB(12, 6, 16, 6),
                            leading: const Icon(Icons.add_circle_outline,
                                color: NavAlertColors.accent),
                            title: Text(r.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(r.displayName,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: NavAlertColors.textSecondary,
                                    fontSize: 12,
                                    height: 1.35)),
                            onTap: () => _save(r),
                          ),
                        );
                      },
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
