import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/map_support.dart';
import 'core/theme.dart';
import 'services/trip_notification_service.dart';
import 'viewmodels/app_viewmodel.dart';
import 'viewmodels/emergency_viewmodel.dart';
import 'viewmodels/history_viewmodel.dart';
import 'viewmodels/home_viewmodel.dart';
import 'viewmodels/trip_viewmodel.dart';
import 'views/launch_view.dart';

/// NavAlert — An Integrated Route Optimization, Fare Estimation,
/// Adaptive Destination Alarm, and Emergency Safety System for
/// Metro Manila PUV Commuters.
///
/// Capstone project — BSIT, Polytechnic University of the Philippines.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock Screen Widget channel (Figure 25). Initialized in the background —
  // the first frame must never block on a plugin handshake (a hung
  // platform channel would otherwise leave the app on a black screen).
  // TripNotificationService.init() is idempotent and is awaited again
  // inside showTrip() before any notification is posted.
  TripNotificationService.instance.init();
  // AWAITED, unlike the notification channel above: NavAlertMap.tiles() is
  // synchronous and builds its cached tile provider exactly once, so if a map
  // screen were built before the disk path resolved, the whole session would
  // silently fall back to a memory-only cache and the offline map would be
  // empty after a restart. initTileCache has its own timeout so a hung
  // platform channel still cannot hold the first frame.
  await NavAlertMap.initTileCache();
  runApp(const NavAlertApp());
}

class NavAlertApp extends StatelessWidget {
  const NavAlertApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppViewModel()..load()),
        ChangeNotifierProvider(create: (_) => HomeViewModel()),
        ChangeNotifierProvider(create: (_) => TripViewModel()),
        ChangeNotifierProvider(create: (_) => EmergencyViewModel()),
        ChangeNotifierProvider(create: (_) => HistoryViewModel()),
      ],
      child: MaterialApp(
        title: 'NavAlert',
        debugShowCheckedModeBanner: false,
        theme: buildNavAlertTheme(),
        home: const LaunchView(),
      ),
    );
  }
}
