package ph.edu.pup.navalert

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Home-screen App Widget (Batch 3).
 *
 * Renders the live trip state pushed from Dart via HomeWidgetService and offers
 * a one-tap SOS. Two tap targets, distinguished by URI:
 *   navalert://open — widget body → launches the app normally.
 *   navalert://sos  — SOS button → launches the app, which fires the SOS flow
 *                     (routed in ShellView through initiallyLaunchedFromHomeWidget /
 *                     widgetClicked).
 *
 * All display strings come from the widgetData SharedPreferences written by the
 * home_widget bridge; this class holds no trip logic of its own.
 */
class NavAlertWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.navalert_widget)

            val active = widgetData.getString("active", "false") == "true"
            val status = widgetData.getString("status", "No active trip") ?: "No active trip"
            val destination = widgetData.getString("destination", "Tap to plan your commute")
                ?: "Tap to plan your commute"
            val distance = widgetData.getString("distance", "") ?: ""
            val eta = widgetData.getString("eta", "") ?: ""

            views.setTextViewText(R.id.widget_status, status)
            views.setTextViewText(R.id.widget_destination, destination)
            views.setTextViewText(R.id.widget_distance, distance)
            views.setTextViewText(R.id.widget_eta, eta)

            // Hide the distance/ETA row when idle so it reads cleanly.
            val metricsVisible = if (active) View.VISIBLE else View.GONE
            views.setViewVisibility(R.id.widget_distance, metricsVisible)
            views.setViewVisibility(R.id.widget_eta, metricsVisible)

            // Tap body → open the app.
            views.setOnClickPendingIntent(
                R.id.widget_root,
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("navalert://open"),
                ),
            )

            // Tap SOS → open the app and trigger the emergency flow.
            views.setOnClickPendingIntent(
                R.id.widget_sos,
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("navalert://sos"),
                ),
            )

            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
