import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../viewmodels/history_viewmodel.dart';

/// Figure 30 — Trip History with search filter, calendar date filter and
/// sort control, plus alarm-stage and awake-time (reaction) chips.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] search onChanged → vm.setFilter · calendar btn → _pickDate /
///         long-press clear · sort btn → vm.toggleSortOrder · delete icon →
///         _confirmDelete (dialog before vm.deleteTrip) · RefreshIndicator.
///  [EDIT] "Trip History" title, empty-state copy, trip-card layout, the
///         Alarm/Awake/status chip colors & labels (_chip), date format,
///         filter-button icons.
///  [WANT] group by day, monthly stats header, tap-card→detail view, export.
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
    // Cancelling the picker returns null, which used to be forwarded straight
    // through and CLEARED an active date filter — so a rider who tapped the
    // calendar, changed their mind and backed out silently lost the filter they
    // had already set. Cancel must mean "no change"; clearing has its own two
    // explicit affordances (long-press the calendar button, or the chip's ✕).
    if (picked == null) return;
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
                // Same long-form date as the cards below it — the raw ISO
                // "2026-04-20" read like debug output beside "April 20, 2026".
                label: Text('On ${_longDate(vm.dateFilter)}'),
                onDeleted: () => vm.setDateFilter(null),
              ),
            ),
          Expanded(
            child: vm.loading
                ? const Center(child: CircularProgressIndicator())
                // A read failure must not masquerade as "no trips yet" —
                // that would tell a rider their history is gone when it is
                // simply unreadable right now.
                : vm.error != null
                    ? ListView(children: [
                        const SizedBox(height: 100),
                        const Center(
                            child: Icon(Icons.error_outline,
                                color: NavAlertColors.warning, size: 30)),
                        const SizedBox(height: 10),
                        Center(
                            child: Text(vm.error!,
                                style: const TextStyle(
                                    color: NavAlertColors.textSecondary))),
                        const SizedBox(height: 10),
                        Center(
                          child: TextButton(
                              onPressed: vm.load,
                              child: const Text('Retry')),
                        ),
                      ])
                    : trips.isEmpty
                    ? LayoutBuilder(
                        builder: (context, constraints) => ListView(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                          children: [
                            SizedBox(
                              height: constraints.maxHeight - 20,
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
                                          const Icon(Icons.route,
                                              size: 68, color: Colors.white),
                                          const Positioned(
                                              top: 4,
                                              right: 4,
                                              child: Icon(Icons.star,
                                                  size: 32,
                                                  color:
                                                      NavAlertColors.accent)),
                                          const Positioned(
                                              bottom: 22,
                                              left: 2,
                                              child: Icon(Icons.star,
                                                  size: 12,
                                                  color:
                                                      NavAlertColors.accent)),
                                          const Positioned(
                                              top: 28,
                                              left: 8,
                                              child: Icon(Icons.star,
                                                  size: 10,
                                                  color:
                                                      NavAlertColors.accent)),
                                          const Positioned(
                                              bottom: 6,
                                              right: 28,
                                              child: Icon(Icons.star,
                                                  size: 14,
                                                  color:
                                                      NavAlertColors.accent)),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    const Text('No trips yet.',
                                        style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 8),
                                    const Text(
                                      'Your completed trips will show up '
                                      'here once you take a ride with the '
                                      'destination alarm on.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: NavAlertColors.textSecondary,
                                          fontStyle: FontStyle.italic,
                                          fontSize: 13,
                                          height: 1.4),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
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

  /// "April 20, 2026" — the long-form date shown beside the calendar glyph on
  /// each history card in Figure 30. The previous `toLocal().substring(0, 16)`
  /// rendered the raw ISO form ("2026-04-20 12:00"), which duplicated the
  /// departure time already printed above and read like debug output.
  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  static String _longDate(DateTime? d) {
    if (d == null) return '-';
    final l = d.toLocal();
    return '${_months[l.month - 1]} ${l.day}, ${l.year}';
  }

  /// Google-Maps-style short place name: the first two comma components of a
  /// full Nominatim address ("University Avenue (PUP), 508" instead of the
  /// five-line province-and-postcode string). Same convention as the origin
  /// row on the search screen; the stored label stays untouched in the DB.
  static String _shortPlace(String label) {
    final parts = label.split(',').map((p) => p.trim()).toList();
    return parts.take(2).join(', ');
  }

  Widget _tripCard(Trip t) {
    String time(DateTime? d) => d == null
        ? '-'
        : TimeOfDay.fromDateTime(d.toLocal()).format(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Figure 30 sets the place name in bold and drops the bracketed time
          // to a smaller muted line under it. Both used to be one 12 px block
          // split by a newline, so "PUP, Sta. Mesa" and "(Departure: 12:00 PM)"
          // carried identical weight and the card had no entry point for the
          // eye — the place is what a rider scans the list for.
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.home, size: 18, color: NavAlertColors.accent),
            const SizedBox(width: 6),
            Expanded(
                child: _endpoint(_shortPlace(t.originLabel),
                    'Departure: ${time(t.startedAt)}')),
            const Icon(Icons.location_on,
                size: 18, color: NavAlertColors.warning),
            const SizedBox(width: 6),
            Expanded(
                child: _endpoint(_shortPlace(t.destinationLabel),
                    'Arrival: ${time(t.endedAt)}')),
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
            Text(_longDate(t.startedAt),
                style: const TextStyle(
                    fontSize: 11, color: NavAlertColors.textSecondary)),
            const Spacer(),
            // Delete with confirmation — nothing is removed until the
            // user explicitly confirms in the dialog.
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline,
                  size: 20, color: NavAlertColors.textSecondary),
              tooltip: 'Delete trip',
              onPressed: () => _confirmDelete(t),
            ),
          ]),
        ]),
      ),
    );
  }

  /// Click-to-confirm deletion: shows a dialog first; the trip (and its
  /// alarm/overshoot/SOS records) is only deleted when "Delete" is tapped.
  // DO NOT MODIFY LOGIC: destructive delete — the confirm dialog is REQUIRED
  // (deleting a trip cascades to its alarm/overshoot/SOS records). Keep the
  // confirm-before-delete flow; the dialog's copy and look are [EDIT].
  Future<void> _confirmDelete(Trip t) async {
    final vm = context.read<HistoryViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // TODO (UI Team): dialog styling (title/body typography, button colors).
        title: const Text('Delete this trip?'),
        content: Text(
          '${t.originLabel.split(',').first} → '
          '${t.destinationLabel.split(',').first}\n\n'
          'This will permanently remove the trip and its alarm records '
          'from your history. This cannot be undone.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(
                    color: NavAlertColors.danger,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await vm.deleteTrip(t);
      messenger.showSnackBar(const SnackBar(content: Text('Trip deleted.')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not delete - storage is unavailable.')));
    }
  }

  /// One end of a trip: the place in bold over its bracketed time, muted.
  static Widget _endpoint(String place, String time) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(place,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, height: 1.2)),
          Text('($time)',
              style: const TextStyle(
                  fontSize: 11, color: NavAlertColors.textSecondary)),
        ],
      );

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
