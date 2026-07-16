import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../viewmodels/history_viewmodel.dart';

/// Figure 30 — Trip History with search filter, calendar date filter and
/// sort control, plus alarm-stage and awake-time (reaction) chips.
class HistoryView extends StatefulWidget {
  const HistoryView({super.key});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => context.read<HistoryViewModel>().load());
  }

  Future<void> _pickDate() async {
    final vm = context.read<HistoryViewModel>();
    final picked = await showDatePicker(
      context: context,
      initialDate: vm.dateFilter ?? DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    vm.setDateFilter(picked);
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HistoryViewModel>();
    final trips = vm.visibleTrips;
    return Scaffold(
      appBar: AppBar(
          title: const Text('Trip History'), automaticallyImplyLeading: false),
      body: RefreshIndicator(
        onRefresh: () => context.read<HistoryViewModel>().load(),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search), hintText: 'Search'),
                  onChanged: vm.setFilter,
                ),
              ),
              const SizedBox(width: 8),
              // Calendar date filter (Figure 30)
              IconButton.filledTonal(
                icon: Icon(Icons.calendar_month,
                    color: vm.dateFilter == null
                        ? null
                        : NavAlertColors.warning),
                onPressed: _pickDate,
                onLongPress: () => vm.setDateFilter(null),
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.filter_list),
                onPressed: vm.toggleSortOrder,
                tooltip: vm.newestFirst ? 'Newest first' : 'Oldest first',
              ),
            ]),
          ),
          if (vm.dateFilter != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InputChip(
                label: Text(
                    'On ${vm.dateFilter!.toLocal().toString().substring(0, 10)}'),
                onDeleted: () => vm.setDateFilter(null),
              ),
            ),
          Expanded(
            child: vm.loading
                ? const Center(child: CircularProgressIndicator())
                : trips.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 120),
                        Center(
                            child: Text('No trips yet.',
                                style: TextStyle(
                                    color: NavAlertColors.textSecondary))),
                      ])
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: trips.length,
                        itemBuilder: (_, i) => _tripCard(trips[i]),
                      ),
          ),
        ]),
      ),
    );
  }

  Widget _tripCard(Trip t) {
    String time(DateTime? d) => d == null
        ? '—'
        : TimeOfDay.fromDateTime(d.toLocal()).format(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.home, size: 18, color: NavAlertColors.accent),
            const SizedBox(width: 6),
            Expanded(
                child: Text('${t.originLabel}\n(Departure: ${time(t.startedAt)})',
                    style: const TextStyle(fontSize: 12))),
            const Icon(Icons.location_on,
                size: 18, color: NavAlertColors.warning),
            const SizedBox(width: 6),
            Expanded(
                child: Text('${t.destinationLabel}\n(Arrival: ${time(t.endedAt)})',
                    style: const TextStyle(fontSize: 12))),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            if (t.highestAlarmStage != null)
              _chip('Alarm: Stage ${t.highestAlarmStage}',
                  NavAlertColors.danger),
            if (t.awakeSeconds != null)
              _chip('Awake: ${t.awakeSeconds} s', NavAlertColors.warning),
            _chip(t.status.toUpperCase(),
                t.status == 'arrived'
                    ? NavAlertColors.success
                    : NavAlertColors.primary),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.calendar_month,
                size: 14, color: NavAlertColors.textSecondary),
            const SizedBox(width: 4),
            Text(
                t.startedAt == null
                    ? '—'
                    : '${t.startedAt!.toLocal()}'.substring(0, 16),
                style: const TextStyle(
                    fontSize: 11, color: NavAlertColors.textSecondary)),
          ]),
        ]),
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(10)),
        child: Text(text,
            style: const TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700,
                color: Colors.white)),
      );
}
