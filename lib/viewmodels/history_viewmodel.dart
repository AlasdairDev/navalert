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

  Future<void> load() async {
    loading = true;
    notifyListeners();
    _trips = await _db.getTripHistory();
    loading = false;
    notifyListeners();
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
