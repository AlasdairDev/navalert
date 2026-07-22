import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/database_service.dart';

/// Trip History ViewModel (Figure 30) — keyword search plus the
/// calendar date filter shown in the Trip History header.
class HistoryViewModel extends ChangeNotifier {
  final _db = DatabaseService.instance;

  List<Trip> _trips = [];
  bool loading = false;
  String filter = '';
  DateTime? dateFilter;
  bool newestFirst = true;

  /// Set when the history could not be read, so the View can say so instead
  /// of showing an empty list that looks like "you have taken no trips".
  String? error;

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      _trips = await _db.getTripHistory();
    } catch (e) {
      // A read failure must not leave the tab spinning forever, and an empty
      // list would wrongly read as "no trips yet".
      error = 'Could not load your trip history.';
      debugPrint('NavAlert: trip history load failed — $e');
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void setFilter(String value) {
    filter = value.toLowerCase();
    notifyListeners();
  }

  void setDateFilter(DateTime? date) {
    dateFilter = date;
    notifyListeners();
  }

  void toggleSortOrder() {
    newestFirst = !newestFirst;
    notifyListeners();
  }

  /// Permanently removes a trip (and, via cascade, its alarm, overshoot
  /// and SOS records). Only called after the user confirms the dialog.
  Future<void> deleteTrip(Trip trip) async {
    await _db.deleteTrip(trip.tripId);
    _trips.removeWhere((t) => t.tripId == trip.tripId);
    notifyListeners();
  }

  List<Trip> get visibleTrips {
    var list = _trips.where((t) {
      final matchesText = filter.isEmpty ||
          t.destinationLabel.toLowerCase().contains(filter) ||
          t.originLabel.toLowerCase().contains(filter);
      final d = t.startedAt ?? t.endedAt;
      final matchesDate = dateFilter == null ||
          (d != null &&
              d.year == dateFilter!.year &&
              d.month == dateFilter!.month &&
              d.day == dateFilter!.day);
      return matchesText && matchesDate;
    }).toList();
    if (!newestFirst) list = list.reversed.toList();
    return list;
  }
}
