import 'dart:async';
import 'dart:io' show Platform, exit;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';

// Global local notifications plugin instance
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Define notification channel with custom sound bubble.mp3
const AndroidNotificationChannel channel = AndroidNotificationChannel(
  'h_water_alarm_channel_v9', // unique ID to force channel recreation with custom sound
  'H Water Alarms',
  description: 'Channel for H Water reminders with custom sound',
  importance: Importance.max,
  playSound: true,
  sound: RawResourceAndroidNotificationSound('bubble'), // raw/bubble.mp3
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize timezone database for background scheduling
  tz.initializeTimeZones();
  try {
    final String timeZoneName = (await FlutterTimezone.getLocalTimezone()).identifier;
    tz.setLocalLocation(tz.getLocation(timeZoneName));
  } catch (e) {
    debugPrint("Could not set local timezone: $e");
    tz.setLocalLocation(tz.getLocation('UTC'));
  }

  if (Platform.isAndroid) {
    // Initialize notifications
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('app_icon');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    
    await flutterLocalNotificationsPlugin.initialize(
      settings: initializationSettings,
    );

    // Register notification channel explicitly (Required for custom sounds on Android 8.0+)
    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
        flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    
    if (androidImplementation != null) {
      await androidImplementation.createNotificationChannel(channel);
      await androidImplementation.requestNotificationsPermission();
    }
  }

  runApp(const WaterReminderApp());
}

class WaterReminderApp extends StatelessWidget {
  const WaterReminderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'H Water',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF0EA5E9), // Bright Sky Blue
          secondary: Color(0xFF0284C7),
          surface: Colors.white,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.slackeyTextTheme(ThemeData.light().textTheme).copyWith(
          bodyMedium: GoogleFonts.slackey(color: const Color(0xFF0F172A)), // Dark Slate
          bodyLarge: GoogleFonts.slackey(color: const Color(0xFF0F172A)),
          titleLarge: GoogleFonts.slackey(color: const Color(0xFF0EA5E9), fontWeight: FontWeight.bold),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Method channel for updating Android Home Screen Widget
  static const _widgetChannel = MethodChannel('com.example.water_reminder/widget');
  // Method channel for controlling Windows app window
  static const _windowChannel = MethodChannel('com.example.water_reminder/window');

  // App State
  int _currentGlasses = 0;
  int _targetGlasses = 8;
  int _intervalSeconds = 60; // Now stored in total seconds
  bool _remindersEnabled = true;
  DateTime? _lastDrinkTime;
  DateTime? _nextReminderTime;

  // Audio and UI controllers
  final AudioPlayer _drinkPlayer = AudioPlayer();
  final AudioPlayer _clickPlayer = AudioPlayer();
  Timer? _countdownTimer;
  Timer? _dailyResetCheckTimer;
  late AnimationController _pulseController;
  late TextEditingController _minutesController;
  late TextEditingController _secondsController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _minutesController = TextEditingController(text: '1');
    _secondsController = TextEditingController(text: '0');
    _loadState();

    // Tap pulse scale animation
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      lowerBound: 0.94,
      upperBound: 1.06,
    );

    _startTimers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _minutesController.dispose();
    _secondsController.dispose();
    _drinkPlayer.dispose();
    _clickPlayer.dispose();
    _countdownTimer?.cancel();
    _dailyResetCheckTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadState(); // Reload the state from SharedPreferences when the app is resumed!
    }
  }

  // State Persistence
  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.reload(); // Force reload from disk to get background widget updates!
    } catch (e) {
      debugPrint("SharedPreferences reload error: $e");
    }
    final now = DateTime.now();

    // Check for daily calendar day reset or if 24 hours have passed since last drink
    final lastResetStr = prefs.getString('last_reset_date');
    final todayStr = '${now.year}-${now.month}-${now.day}';
    final lastDrinkStr = prefs.getString('last_drink_time');

    bool shouldReset = false;
    if (lastResetStr != todayStr) {
      shouldReset = true;
    } else if (lastDrinkStr != null) {
      try {
        final lastDrink = DateTime.parse(lastDrinkStr).toLocal();
        if (now.difference(lastDrink).inHours >= 24) {
          shouldReset = true;
        }
      } catch (e) {
        debugPrint("Parse last drink time error: $e");
      }
    }

    if (shouldReset) {
      await prefs.setInt('current_glasses', 0);
      await prefs.setString('last_reset_date', todayStr);
      _currentGlasses = 0;
    } else {
      _currentGlasses = prefs.getInt('current_glasses') ?? 0;
    }

    _targetGlasses = prefs.getInt('target_glasses') ?? 8;
    _intervalSeconds = prefs.getInt('interval_seconds') ?? 60;
    _remindersEnabled = prefs.getBool('reminders_enabled') ?? true;

    // Split total seconds into minutes and seconds
    final int mins = _intervalSeconds ~/ 60;
    final int secs = _intervalSeconds % 60;
    _minutesController.text = mins.toString();
    _secondsController.text = secs.toString();

    if (lastDrinkStr != null) {
      try {
        _lastDrinkTime = DateTime.parse(lastDrinkStr).toLocal();
      } catch (e) {
        debugPrint("Parse last drink time error: $e");
      }
    }

    final nextReminderStr = prefs.getString('next_reminder_time');
    if (nextReminderStr != null) {
      try {
        _nextReminderTime = DateTime.parse(nextReminderStr).toLocal();
      } catch (e) {
        debugPrint("Parse next reminder time error: $e");
      }
    } else {
      _scheduleNextReminder();
    }

    setState(() {});
  }

  Future<void> _updateAndroidWidget() async {
    if (Platform.isAndroid) {
      try {
        await _widgetChannel.invokeMethod('updateWidget');
      } catch (e) {
        debugPrint("Widget update error: $e");
      }
    }
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('current_glasses', _currentGlasses);
    await prefs.setInt('target_glasses', _targetGlasses);
    await prefs.setInt('interval_seconds', _intervalSeconds);
    await prefs.setBool('reminders_enabled', _remindersEnabled);
    if (_lastDrinkTime != null) {
      await prefs.setString('last_drink_time', _lastDrinkTime!.toIso8601String());
    }
    if (_nextReminderTime != null) {
      await prefs.setString('next_reminder_time', _nextReminderTime!.toIso8601String());
    }
    final now = DateTime.now();
    await prefs.setString('last_reset_date', '${now.year}-${now.month}-${now.day}');
    
    // Notify native Android home screen widget to reload values
    await _updateAndroidWidget();
  }

  void _startTimers() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remindersEnabled && _nextReminderTime != null) {
        final now = DateTime.now();
        if (now.isAfter(_nextReminderTime!)) {
          _triggerReminder();
        } else {
          setState(() {});
        }
      }
    });

    // Reset check every minute
    _dailyResetCheckTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      _checkDailyReset();
    });
  }

  void _checkDailyReset() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final lastResetStr = prefs.getString('last_reset_date');
    final todayStr = '${now.year}-${now.month}-${now.day}';
    final lastDrinkStr = prefs.getString('last_drink_time');

    bool shouldReset = false;
    if (lastResetStr != todayStr) {
      shouldReset = true;
    } else if (lastDrinkStr != null) {
      final lastDrink = DateTime.parse(lastDrinkStr);
      if (now.difference(lastDrink).inHours >= 24) {
        shouldReset = true;
      }
    }

    if (shouldReset) {
      setState(() {
        _currentGlasses = 0;
        _lastDrinkTime = null;
        _scheduleNextReminder();
      });
      await _saveState();
    }
  }

  void _scheduleNextReminder() {
    if (!_remindersEnabled) {
      _nextReminderTime = null;
      if (Platform.isAndroid) {
        flutterLocalNotificationsPlugin.cancel(id: 0);
      }
      _saveState();
      return;
    }
    _nextReminderTime = DateTime.now().add(Duration(seconds: _intervalSeconds));
    _saveState();

    if (Platform.isAndroid) {
      _scheduleAndroidNotification();
    }
  }

  Future<void> _scheduleAndroidNotification() async {
    try {
      await flutterLocalNotificationsPlugin.cancel(id: 0);
      
      final scheduledDate = tz.TZDateTime.now(tz.local).add(Duration(seconds: _intervalSeconds));
      
      final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        channel.id,
        channel.name,
        channelDescription: channel.description,
        importance: Importance.max,
        priority: Priority.high,
        sound: const RawResourceAndroidNotificationSound('bubble'), // raw/bubble.mp3
        playSound: true,
        vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
      );

      final NotificationDetails platformDetails = NotificationDetails(android: androidDetails);

      await flutterLocalNotificationsPlugin.zonedSchedule(
        id: 0,
        title: '💧 TIME TO DRINK WATER!',
        body: 'Drink your glass of H Water now!',
        scheduledDate: scheduledDate,
        notificationDetails: platformDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    } catch (e) {
      debugPrint("Android notification scheduling error: $e");
    }
  }

  // Core Interactions
  Future<void> _playDrinkSound() async {
    try {
      await _drinkPlayer.stop();
      await _drinkPlayer.play(AssetSource('drink.mp3'));
    } catch (e) {
      debugPrint("Drink sound play error: $e");
    }
  }

  Future<void> _playClickSound() async {
    try {
      await _clickPlayer.stop();
      await _clickPlayer.play(AssetSource('button.mp3'));
    } catch (e) {
      debugPrint("Click sound play error: $e");
    }
  }

  Future<void> _playAlarmSound() async {
    try {
      await _drinkPlayer.stop();
      await _drinkPlayer.play(AssetSource('bubble.mp3'));
    } catch (e) {
      debugPrint("Alarm sound play error: $e");
    }
  }

  void _addWater() {
    // Cap water count at the target goal amount (cannot exceed) - checked synchronously first
    if (_currentGlasses >= _targetGlasses) return;

    // Play bubble tap sound effect
    _playDrinkSound();

    _pulseController.forward(from: 0.95).then((_) => _pulseController.reverse());

    setState(() {
      _currentGlasses++;
      _lastDrinkTime = DateTime.now();
      _scheduleNextReminder();
    });

    _saveState();
  }

  void _triggerReminder() async {
    // Play foreground alarm sound so the user hears it if they are inside the app
    _playAlarmSound();

    if (Platform.isAndroid) {
      // Send System Notification Bar Alert with custom sound bubble.mp3
      final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        channel.id,
        channel.name,
        channelDescription: channel.description,
        importance: Importance.max,
        priority: Priority.high,
        sound: const RawResourceAndroidNotificationSound('bubble'), // raw/bubble.mp3
        playSound: true,
        vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
      );

      final NotificationDetails platformDetails = NotificationDetails(android: androidDetails);

      await flutterLocalNotificationsPlugin.show(
        id: 0,
        title: '💧 TIME TO DRINK WATER!',
        body: 'Drink your glass of H Water now!',
        notificationDetails: platformDetails,
      );
    }

    _scheduleNextReminder();
  }

  void _resetIntake() async {
    _playClickSound();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Color(0xFF0F172A), width: 3),
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text('RESET TODAY?', style: TextStyle(color: Color(0xFF0F172A))),
        content: const Text('Do you want to reset today\'s intake back to 0?', style: TextStyle(color: Color(0xFF475569))),
        actions: [
          TextButton(
            onPressed: () {
              _playClickSound();
              Navigator.of(context).pop();
            },
            child: const Text('CANCEL', style: TextStyle(color: Colors.grey)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0EA5E9),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Color(0xFF0F172A), width: 2),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () {
              _playClickSound();
              Navigator.of(context).pop();
              setState(() {
                _currentGlasses = 0;
                _lastDrinkTime = null;
                _scheduleNextReminder();
              });
              _saveState();
            },
            child: const Text('RESET'),
          ),
        ],
      ),
    );
  }

  void _updateIntervalFromInputs() {
    final int mins = int.tryParse(_minutesController.text) ?? 0;
    final int secs = int.tryParse(_secondsController.text) ?? 0;
    
    final int totalSeconds = (mins * 60) + secs;
    if (totalSeconds > 0 && totalSeconds <= 21600) { // Max 6 hours
      setState(() {
        _intervalSeconds = totalSeconds;
        _scheduleNextReminder();
      });
      _saveState();
    }
  }

  // Helpers
  String _getCountdownText() {
    if (!_remindersEnabled || _nextReminderTime == null) return "OFF";
    final diff = _nextReminderTime!.difference(DateTime.now());
    if (diff.isNegative) return "00:00:00";
    
    final hrs = diff.inHours.toString().padLeft(2, '0');
    final mins = (diff.inMinutes % 60).toString().padLeft(2, '0');
    final secs = (diff.inSeconds % 60).toString().padLeft(2, '0');
    
    return "$hrs:$mins:$secs";
  }

  @override
  Widget build(BuildContext context) {
    final double completionRatio = math.min(_currentGlasses / _targetGlasses, 1.0);
    final isCompleted = completionRatio >= 1.0;
    
    // Dopamine color transition: Green when completed, otherwise Sky Blue!
    final Color primaryThemeColor = isCompleted ? const Color(0xFF22C55E) : const Color(0xFF0EA5E9);

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // Header Bar
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Row(
                  children: [
                    Image.asset(
                      'assets/logo.png',
                      height: 32,
                      errorBuilder: (context, error, stackTrace) => const SizedBox(),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'H WATER',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: primaryThemeColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Main Dashboard Body
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    const SizedBox(height: 10),

                    // Interactive Circular Loader (Solid progress fill, Green on completion!)
                    ScaleTransition(
                      scale: _pulseController,
                      child: GestureDetector(
                        onTap: _addWater,
                        child: Container(
                          width: 220,
                          height: 220,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            border: Border.all(
                              color: isCompleted ? primaryThemeColor : const Color(0xFF0F172A),
                              width: 3.5,
                            ),
                          ),
                          child: Stack(
                            children: [
                              // Solid progress fill loader (No waves!)
                              ClipOval(
                                child: CustomPaint(
                                  size: const Size(220, 220),
                                  painter: WaterFillPainter(
                                    progress: completionRatio,
                                    fillColor: primaryThemeColor,
                                  ),
                                ),
                              ),

                              // Overlapping Text labels inside loader circle
                              Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.local_drink,
                                      size: 30,
                                      color: completionRatio > 0.45 ? Colors.white : primaryThemeColor,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '$_currentGlasses / $_targetGlasses',
                                      style: TextStyle(
                                        fontSize: 34,
                                        fontWeight: FontWeight.bold,
                                        color: completionRatio > 0.45 ? Colors.white : const Color(0xFF0F172A),
                                      ),
                                    ),
                                    Text(
                                      'CUPS',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: completionRatio > 0.45 ? Colors.white70 : const Color(0xFF0F172A),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: completionRatio > 0.45 ? Colors.black.withOpacity(0.12) : primaryThemeColor.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        'TAP TO DRINK',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                          color: completionRatio > 0.45 ? Colors.white : primaryThemeColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),

                    // Glasses visual checklist tracker (Turns Green when completed)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: isCompleted ? primaryThemeColor : const Color(0xFF0F172A), width: 2.5),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'TRACKER',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: isCompleted ? primaryThemeColor : const Color(0xFF0F172A),
                                ),
                              ),
                              Text(
                                'Goal: $_targetGlasses Cups',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: primaryThemeColor,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            alignment: WrapAlignment.center,
                            children: List.generate(_targetGlasses, (index) {
                              final isDrunk = index < _currentGlasses;
                              return AnimatedScale(
                                scale: isDrunk ? 1.1 : 1.0,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.elasticOut,
                                child: CustomPaint(
                                  size: const Size(26, 36),
                                  painter: CupWidgetPainter(
                                    isFilled: isDrunk,
                                    primaryColor: primaryThemeColor,
                                  ),
                                ),
                              );
                            }),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ALARM CONFIGURATION CARD (Dual Input for Minutes & Seconds)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _remindersEnabled ? (isCompleted ? primaryThemeColor : const Color(0xFF0F172A)) : Colors.grey.shade400,
                          width: 2.5,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _remindersEnabled ? Icons.notifications_active : Icons.notifications_off,
                                    color: _remindersEnabled ? primaryThemeColor : Colors.grey,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _remindersEnabled ? 'ALARM: ${_getCountdownText()}' : 'ALARM: OFF',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: _remindersEnabled ? const Color(0xFF0F172A) : Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                              Switch.adaptive(
                                value: _remindersEnabled,
                                activeColor: primaryThemeColor,
                                onChanged: (bool val) {
                                  _playClickSound();
                                  setState(() {
                                    _remindersEnabled = val;
                                    _scheduleNextReminder();
                                  });
                                  _saveState();
                                },
                              ),
                            ],
                          ),

                          if (_remindersEnabled) ...[
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'REMIND INTERVAL (MIN & SEC):',
                                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  'Current: $_intervalSeconds sec',
                                  style: TextStyle(fontSize: 9, color: primaryThemeColor, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            
                            // Dual Text Inputs for Minutes and Seconds
                            Row(
                              children: [
                                // Minutes input
                                Expanded(
                                  child: SizedBox(
                                    height: 46,
                                    child: TextField(
                                      controller: _minutesController,
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                      style: GoogleFonts.slackey(
                                        fontSize: 13,
                                        color: const Color(0xFF0F172A),
                                      ),
                                      decoration: InputDecoration(
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                                        filled: true,
                                        fillColor: Colors.grey.shade100,
                                        suffixText: 'm',
                                        suffixStyle: const TextStyle(fontSize: 10, color: Colors.grey),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(10),
                                          borderSide: const BorderSide(color: Color(0xFF0F172A), width: 2),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(10),
                                          borderSide: const BorderSide(color: Color(0xFF0F172A), width: 2),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(10),
                                          borderSide: BorderSide(color: primaryThemeColor, width: 2.5),
                                        ),
                                      ),
                                      onChanged: (_) => _updateIntervalFromInputs(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),

                                // Seconds input
                                Expanded(
                                  child: SizedBox(
                                    height: 46,
                                    child: TextField(
                                      controller: _secondsController,
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                      style: GoogleFonts.slackey(
                                        fontSize: 13,
                                        color: const Color(0xFF0F172A),
                                      ),
                                      decoration: InputDecoration(
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                                        filled: true,
                                        fillColor: Colors.grey.shade100,
                                        suffixText: 's',
                                        suffixStyle: const TextStyle(fontSize: 10, color: Colors.grey),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(10),
                                          borderSide: const BorderSide(color: Color(0xFF0F172A), width: 2),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(10),
                                          borderSide: const BorderSide(color: Color(0xFF0F172A), width: 2),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(10),
                                          borderSide: BorderSide(color: primaryThemeColor, width: 2.5),
                                        ),
                                      ),
                                      onChanged: (_) => _updateIntervalFromInputs(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                
                                // Quick increment buttons
                                IconButton(
                                  icon: Icon(Icons.add_circle, color: primaryThemeColor, size: 36),
                                  padding: EdgeInsets.zero,
                                  onPressed: () {
                                    _playClickSound();
                                    final currentMins = int.tryParse(_minutesController.text) ?? 0;
                                    final newMins = currentMins + 1;
                                    _minutesController.text = newMins.toString();
                                    _updateIntervalFromInputs();
                                  },
                                ),
                                
                                IconButton(
                                  icon: Icon(Icons.remove_circle, color: primaryThemeColor, size: 36),
                                  padding: EdgeInsets.zero,
                                  onPressed: () {
                                    _playClickSound();
                                    final currentMins = int.tryParse(_minutesController.text) ?? 0;
                                    if (currentMins > 0) {
                                      final newMins = currentMins - 1;
                                      _minutesController.text = newMins.toString();
                                      _updateIntervalFromInputs();
                                    }
                                  },
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Goal target controls
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: isCompleted ? primaryThemeColor : const Color(0xFF0F172A), width: 2.5),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'GOAL TARGET',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove, color: Color(0xFF0F172A)),
                                onPressed: _targetGlasses > 4
                                    ? () {
                                        _playClickSound();
                                        setState(() {
                                          _targetGlasses--;
                                        });
                                        _saveState();
                                      }
                                    : null,
                              ),
                              Text(
                                '$_targetGlasses',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add, color: Color(0xFF0F172A)),
                                onPressed: _targetGlasses < 15
                                    ? () {
                                        _playClickSound();
                                        setState(() {
                                          _targetGlasses++;
                                        });
                                        _saveState();
                                      }
                                    : null,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                     OutlinedButton.icon(
                       onPressed: _resetIntake,
                       icon: const Icon(Icons.refresh_rounded),
                       label: const Text('RESET TODAY'),
                       style: OutlinedButton.styleFrom(
                         foregroundColor: const Color(0xFF0F172A),
                         side: const BorderSide(color: Color(0xFF0F172A), width: 2.5),
                         padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                         shape: RoundedRectangleBorder(
                           borderRadius: BorderRadius.circular(12),
                         ),
                         textStyle: const TextStyle(fontWeight: FontWeight.bold),
                       ),
                     ),
                     const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Custom solid progress fill painter
class WaterFillPainter extends CustomPainter {
  final double progress;
  final Color fillColor;

  WaterFillPainter({
    required this.progress,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final double baseHeight = h * (1.0 - progress);

    if (progress > 0) {
      final fillPaint = Paint()..color = fillColor;
      canvas.drawRect(Rect.fromLTRB(0, baseHeight, w, h), fillPaint);
    }
  }

  @override
  bool shouldRepaint(covariant WaterFillPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.fillColor != fillColor;
}

// Custom Glass/Cup Painter
class CupWidgetPainter extends CustomPainter {
  final bool isFilled;
  final Color primaryColor;

  CupWidgetPainter({required this.isFilled, required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    final cupPath = Path()
      ..moveTo(w * 0.1, h * 0.05)
      ..lineTo(w * 0.2, h * 0.85)
      ..quadraticBezierTo(w * 0.22, h * 0.95, w * 0.35, h * 0.95)
      ..lineTo(w * 0.65, h * 0.95)
      ..quadraticBezierTo(w * 0.78, h * 0.95, w * 0.8, h * 0.85)
      ..lineTo(w * 0.9, h * 0.05)
      ..close();

    if (isFilled) {
      canvas.drawPath(cupPath, Paint()..color = primaryColor);
      canvas.drawLine(
          Offset(w * 0.14, h * 0.18), Offset(w * 0.86, h * 0.18), Paint()
            ..color = Colors.white.withOpacity(0.4)
            ..strokeWidth = 1.5);
    }

    final borderPaint = Paint()
      ..color = isFilled ? const Color(0xFF0F172A) : const Color(0xFFCBD5E1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(cupPath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CupWidgetPainter oldDelegate) =>
      oldDelegate.isFilled != isFilled || oldDelegate.primaryColor != primaryColor;
}
