package com.example.water_reminder

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class WaterWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_ADD_WATER = "com.example.water_reminder.ACTION_ADD_WATER"
    }

    // Safely reads a Preference value as Long, with fallback to Int
    private fun getSafeLong(prefs: android.content.SharedPreferences, key: String, defaultValue: Long): Long {
        return try {
            prefs.getLong(key, defaultValue)
        } catch (e: ClassCastException) {
            try {
                prefs.getInt(key, defaultValue.toInt()).toLong()
            } catch (e2: ClassCastException) {
                defaultValue
            }
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_ADD_WATER) {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            
            val target = getSafeLong(prefs, "flutter.target_glasses", 8L)
            var current = getSafeLong(prefs, "flutter.current_glasses", 0L)
            
            if (current < target) {
                current++
                
                // Play drink sound effect natively from widget receiver
                try {
                    val mediaPlayer = android.media.MediaPlayer.create(context, R.raw.drink)
                    mediaPlayer?.setOnCompletionListener { mp ->
                        mp.release()
                    }
                    mediaPlayer?.start()
                } catch (e: Exception) {
                    e.printStackTrace()
                }
                
                prefs.edit().apply {
                    putLong("flutter.current_glasses", current)
                    
                    // Update last drink time in local ISO8601 format (no 'Z')
                    val df = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)
                    putString("flutter.last_drink_time", df.format(Date()))
                    
                    // Also update reset date
                    val dateDf = SimpleDateFormat("yyyy-M-d", Locale.US)
                    putString("flutter.last_reset_date", dateDf.format(Date()))
                    
                    apply()
                }
                
                // Update all widgets
                val appWidgetManager = AppWidgetManager.getInstance(context)
                val thisWidget = ComponentName(context, WaterWidgetProvider::class.java)
                val allWidgetIds = appWidgetManager.getAppWidgetIds(thisWidget)
                for (widgetId in allWidgetIds) {
                    updateAppWidget(context, appWidgetManager, widgetId)
                }
            }
        }
    }

    private fun updateAppWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
        val views = RemoteViews(context.packageName, R.layout.water_widget)
        
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val target = getSafeLong(prefs, "flutter.target_glasses", 8L)
        val current = getSafeLong(prefs, "flutter.current_glasses", 0L)
        
        views.setTextViewText(R.id.widget_glasses_count, "$current / $target")
        
        if (current >= target) {
            views.setTextColor(R.id.widget_title, 0xFF22C55E.toInt()) // Green
            views.setInt(R.id.widget_btn_add, "setBackgroundResource", R.drawable.widget_btn_shape_green)
        } else {
            views.setTextColor(R.id.widget_title, 0xFF0EA5E9.toInt()) // Sky Blue
            views.setInt(R.id.widget_btn_add, "setBackgroundResource", R.drawable.widget_btn_shape)
        }

        // Tap on widget background -> opens Flutter App
        val appIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val appPendingIntent = PendingIntent.getActivity(
            context, 0, appIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(R.id.widget_background, appPendingIntent)

        // Tap on "+ DRINK" button -> triggers ACTION_ADD_WATER action receiver
        val addIntent = Intent(context, WaterWidgetProvider::class.java).apply {
            action = ACTION_ADD_WATER
        }
        val addPendingIntent = PendingIntent.getBroadcast(
            context, 1, addIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(R.id.widget_btn_add, addPendingIntent)

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}
