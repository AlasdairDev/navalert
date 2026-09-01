/// Width of the Yes/No pair on the Overshoot Detected prompt (Figure 29).
///
/// The two buttons were hardcoded at 147 dp each to match the measured natural
/// size of the Alarm Stage 1/2 Snooze/Dismiss pair. That arithmetic does not
/// fit the phone the mockups are drawn against:
///
///   147 + 14 gap + 147            = 308
///   + card padding (22 x 2)       = 352
///   + screen padding (24 x 2)     = 400 dp
///
/// which overflows a 360 dp screen — "Yes" ran past the edge of the card. The
/// prompt appears when a rider has just missed their stop, so a button that is
/// clipped at the moment it is needed is the worst place in the app for this.
///
/// Lifted out of the widget for the same reason as [CommuteSheetLayout]: it is
/// pure arithmetic over a measurement, so it belongs where it can be asserted
/// across every plausible screen rather than eyeballed on one.
class OvershootButtonLayout {
  /// Matches the Snooze/Dismiss pair when there is room for it.
  static const double preferredWidth = 147;

  /// Gap between the two buttons.
  static const double gap = 14;

  static const double height = 48;

  /// Width for ONE button given the space the card actually offers.
  ///
  /// Never wider than [preferredWidth], so on a roomy screen the pair still
  /// matches Snooze/Dismiss. Never wider than half the available space either,
  /// so it cannot overflow — the two buttons plus the gap always fit.
  static double buttonWidth(double availableWidth) {
    final half = (availableWidth - gap) / 2;
    if (half <= 0) return 0;
    return half < preferredWidth ? half : preferredWidth;
  }

  /// Total width the pair occupies, for asserting it fits.
  static double pairWidth(double availableWidth) =>
      buttonWidth(availableWidth) * 2 + gap;
}
