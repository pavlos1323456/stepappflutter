// MyStep — Health (Fit/HC) bootstrap + live pedometer + profile + themes + water tab
// UI: circular gauge + area chart + clean nav w/out selection pill

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:health/health.dart';

/* ====================== THEME CONTROLLER (dynamic colors) ====================== */

class ThemeController extends ChangeNotifier {
  static final ThemeController I = ThemeController._();
  ThemeController._();

  static const _kThemeIndex = 'theme_index';

  final List<Color> seeds = const [
    Color(0xFF00B2FF), // cyan
    Color(0xFF7C4DFF), // purple
    Color(0xFFFF6D00), // orange
    Color(0xFF00C853), // green
    Color(0xFFFF1744), // red
  ];

  int _index = 0;
  int get index => _index;
  Color get seed => seeds[_index];

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _index = p.getInt(_kThemeIndex) ?? 0;
    notifyListeners();
  }

  Future<void> setIndex(int i) async {
    if (i < 0 || i >= seeds.length) return;
    _index = i;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kThemeIndex, _index);
    notifyListeners();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.I.load();
  runApp(MyStepApp(controller: ThemeController.I));
}

/* ============================ THEME ============================ */

class AppColors {
  static const bg = Color(0xFFF1F6FB);
  static const text = Color(0xFF0B1220);
}

ThemeData appTheme(Color seed) {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontWeight: FontWeight.w900, color: AppColors.text),
      headlineMedium: TextStyle(fontWeight: FontWeight.w800, color: AppColors.text),
      titleLarge: TextStyle(fontWeight: FontWeight.w800, color: AppColors.text),
      bodyMedium: TextStyle(color: Color(0xFF425466)),
    ),
  );
}

/* ============================ APP ROOT ============================ */

class MyStepApp extends StatelessWidget {
  final ThemeController controller;
  const MyStepApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'MyStep',
          debugShowCheckedModeBanner: false,
          theme: appTheme(controller.seed),
          home: Shell(themeController: controller),
        );
      },
    );
  }
}

class Shell extends StatefulWidget {
  final ThemeController themeController;
  const Shell({super.key, required this.themeController});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  late final _pages = [
    const StepsScreen(),
    const GoalsScreen(),
    WaterScreen(),
    SettingsScreen(themeController: widget.themeController),
  ];
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: _pages[_index],
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: NavigationBar(
              height: 64,
              elevation: 1,
              surfaceTintColor: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: 0.95),
              indicatorColor: Colors
                  .transparent, // ⬅️ no green selection pill; clean, presentation-style
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.directions_walk_outlined),
                  selectedIcon: Icon(Icons.directions_walk),
                  label: 'Steps',
                ),
                NavigationDestination(
                  icon: Icon(Icons.flag_outlined),
                  selectedIcon: Icon(Icons.flag),
                  label: 'Goals',
                ),
                NavigationDestination(
                  icon: Icon(Icons.water_drop_outlined),
                  selectedIcon: Icon(Icons.water_drop),
                  label: 'Water',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* ============================ KEYS (shared) ============================ */

const _kBaseline = 'baseline_steps';
const _kDate = 'baseline_date';
const _kGoal = 'daily_goal';
const _kHistory = 'history_7';

const _kWeight = 'user_weight_kg'; // kg
const _kHeight = 'user_height_cm';  // ΠΑΝΤΑ σε cm
const _kGender = 'user_gender';
const _kAge = 'user_age_years';

const _kWaterGoalCups = 'water_goal_cups';
const _kWaterCount = 'water_today_count';
const _kWaterDate = 'water_date';

/* ============================ STEPS SCREEN ============================ */

class StepsScreen extends StatefulWidget {
  const StepsScreen({super.key});
  @override
  State<StepsScreen> createState() => _StepsScreenState();
}

class _StepsScreenState extends State<StepsScreen> {
  // profile snapshot (for About you)
  double _weight = 0;
  double _heightCm = 0; // cm
  String _gender = '—';
  int _age = 0;

  // Health (Fit/HC)
  final health = Health();
  final List<HealthDataType> _hcTypes = const [HealthDataType.STEPS];
  final List<HealthDataAccess> _hcPerms = const [HealthDataAccess.READ];

  StreamSubscription<StepCount>? _stepSub;
  StreamSubscription<PedestrianStatus>? _statusSub;

  int _todaySteps = 0;
  int _goal = 8000;
  String _status = '—';
  String? _error;
  List<int> _history = List.filled(7, 0);

  bool _hitGoalPulse = false;
  bool _primedFromHealth = false;

  String get _todayStr => DateFormat('yyyy-MM-dd').format(DateTime.now());

  @override
  void initState() {
    super.initState();
    _primeFromHealth().whenComplete(() {
      _loadPrefs().then((_) => _initPedometer());
    });
  }

  Future<void> _primeFromHealth() async {
    try {
      final ar = await Permission.activityRecognition.request();
      if (!ar.isGranted) return;

      await health.configure();
      final ok = await health.requestAuthorization(_hcTypes, permissions: _hcPerms);
      if (!ok) return;

      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      final total = await health.getTotalStepsInInterval(start, now) ?? 0;

      if (!mounted) return;
      setState(() {
        _todaySteps = total;
        _primedFromHealth = true;
      });
    } catch (_) {}
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();

    _goal = p.getInt(_kGoal) ?? 8000;
    final list = p.getStringList(_kHistory);
    if (list != null && list.length == 7) {
      _history = list.map((e) => int.tryParse(e) ?? 0).toList();
    }

    _weight = p.getDouble(_kWeight) ?? 0;
    final rawHeight = p.getDouble(_kHeight) ?? 0;
    _heightCm = rawHeight; // ήδη cm
    _gender = p.getString(_kGender) ?? '—';
    _age = p.getInt(_kAge) ?? 0;

    if (mounted) setState(() {});
  }

  Future<void> _saveTodayToHistory(int todayCount) async {
    final p = await SharedPreferences.getInstance();
    _history = [..._history.skip(1), todayCount];
    await p.setStringList(_kHistory, _history.map((e) => e.toString()).toList());
  }

  Future<void> _initPedometer() async {
    final perm = await Permission.activityRecognition.request();
    if (!perm.isGranted) {
      setState(() => _error = 'Χρειάζεται άδεια ACTIVITY_RECOGNITION.');
      return;
    }
    final prefs = await SharedPreferences.getInstance();

    _stepSub = Pedometer.stepCountStream.listen((event) async {
      final current = event.steps;
      final todayStr = _todayStr;
      var savedDate = prefs.getString(_kDate);
      var baseline = prefs.getInt(_kBaseline);

      if (savedDate != todayStr || baseline == null) {
        if (baseline != null && savedDate != null) {
          final yesterdayCount = (current - baseline).clamp(0, 1 << 31);
          await _saveTodayToHistory(yesterdayCount);
        }
        await prefs.setString(_kDate, todayStr);
        await prefs.setInt(_kBaseline, current);
        baseline = current;
      }

      final todayLive = (current - baseline).clamp(0, 1 << 31);

      if (!mounted) return;
      setState(() {
        _todaySteps = _primedFromHealth
            ? (todayLive > _todaySteps ? todayLive : _todaySteps)
            : todayLive;

        if (!_hitGoalPulse && _todaySteps >= _goal) {
          _hitGoalPulse = true;
          Future.delayed(const Duration(milliseconds: 1600), () {
            if (mounted) setState(() => _hitGoalPulse = false);
          });
        }
      });
    }, onError: (e) {
      if (mounted) setState(() => _error = 'Step stream error: $e');
    });

    _statusSub = Pedometer.pedestrianStatusStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _status = switch (s.status) {
          'walking' => 'Walking',
          'stopped' => 'Stopped',
          _ => '—'
        };
      });
    }, onError: (e) {
      if (mounted) setState(() => _error = 'Status stream error: $e');
    });
  }

  @override
  void dispose() {
    _stepSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  double get _progress => (_todaySteps / _goal).clamp(0, 1).toDouble();
  double get _km => _todaySteps / 1312.0; // ~0.76m stride
  double get _kcal => _todaySteps * 0.04; // rough avg
  int get _bestDay => _history.fold<int>(0, (a, b) => b > a ? b : a);

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final screenW = MediaQuery.of(context).size.width;
    final ringSize = (screenW - 64).clamp(0.0, screenW); // λίγο μικρότερο για να 'αναπνέει'
    final date = DateFormat('d MMM, y').format(DateTime.now());

    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(0.8, -1),
              end: Alignment(-0.8, 1),
              colors: [Color(0xFFE7F1FA), Color(0xFFF7FAFF)],
            ),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            centerTitle: false,
            titleSpacing: 16,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Let’s move!', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(date, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                /* ====== GAUGE + KPIs ====== */
                Card(
                  elevation: 6,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                    child: Column(
                      children: [
                        SizedBox(
                          width: ringSize,
                          height: ringSize,
                          child: _Gauge(
                            value: _progress,           // 0..1
                            steps: _todaySteps,
                            goal: _goal,
                            arcColor: const Color(0xFFFF2E95),
                            bgArc: const Color(0xFFE6ECF5),
                            disk: const Color(0xFF1E2A39),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(child: _kpiTile(Icons.local_fire_department, '${_kcal.toStringAsFixed(0)} kcal')),
                            const SizedBox(width: 10),
                            Expanded(child: _kpiTile(Icons.route_outlined, '${_km.toStringAsFixed(2)} km')),
                            const SizedBox(width: 10),
                            Expanded(child: _kpiTile(Icons.timer_outlined, '${(_todaySteps / 100).toStringAsFixed(0)} min')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                /* ====== AREA CHART ====== */
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text('Last 7 days', style: TextStyle(fontWeight: FontWeight.w800)),
                            ),
                            _bestChip(_bestDay),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 170,
                          child: _AreaChart(
                            values: _history,
                            goal: _goal,
                            color: primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                /* ====== ABOUT YOU ====== */
                Card(
                  elevation: 3,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('About you', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 12),
                        _aboutRow('Height', _heightCm > 0 ? '${_heightCm.toStringAsFixed(0)} cm' : '—'),
                        _aboutRow('Weight', _weight > 0 ? '${_weight.toStringAsFixed(0)} kg' : '—'),
                        _aboutRow('Age', _age > 0 ? '$_age' : '—'),
                        _aboutRow('Gender', _gender),
                      ],
                    ),
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _bestChip(int best) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 8, offset: Offset(0, 4))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.emoji_events_outlined, size: 16),
            const SizedBox(width: 6),
            Text('Best: $best'),
          ],
        ),
      );

  Widget _aboutRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(width: 90, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w700))),
            const SizedBox(width: 12),
            Expanded(child: Text(v)),
          ],
        ),
      );

  Widget _kpiTile(IconData icon, String text) {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/* ============================ GOALS SCREEN ============================ */

class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key});
  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  late Future<int> _goalFuture;
  int _goalValue = 8000;

  @override
  void initState() {
    super.initState();
    _goalFuture = _loadGoal();
  }

  Future<int> _loadGoal() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kGoal) ?? 8000;
  }

  Future<void> _save(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kGoal, v);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved daily goal')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: const Text('Goals')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFFEAF6FF), Color(0xFFF9FBFF)],
          ),
        ),
        child: FutureBuilder<int>(
          future: _goalFuture,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final loadedGoal = snap.data ?? 8000;
            if (_goalValue == 8000) _goalValue = loadedGoal;

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Daily step goal', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  _valueBadge('$_goalValue steps'),
                  const SizedBox(height: 16),
                  _presetChips(),
                  const SizedBox(height: 8),
                  Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Slider(
                            value: _goalValue.toDouble(),
                            min: 1000,
                            max: 30000,
                            divisions: 58,
                            onChanged: (v) => setState(() => _goalValue = (v / 500).round() * 500),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            onPressed: () async {
                              await _save(_goalValue);
                              setState(() => _goalFuture = _loadGoal());
                            },
                            child: const Text('Save'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _valueBadge(String s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 10, offset: Offset(0, 4))],
        ),
        child: Text(s, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
      );

  Widget _presetChips() {
    final presets = [5000, 8000, 10000, 12000, 15000];
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final g in presets)
          ChoiceChip(
            label: Text('$g'),
            selected: _goalValue == g,
            onSelected: (sel) { if (sel) setState(() => _goalValue = g); },
          ),
      ],
    );
  }
}

/* ============================ WATER SCREEN (tab) ============================ */

class WaterScreen extends StatefulWidget {
  @override
  State<WaterScreen> createState() => _WaterScreenState();
}

class _WaterScreenState extends State<WaterScreen> {
  int _goalCups = 8;
  int _count = 0;
  String get _todayStr => DateFormat('yyyy-MM-dd').format(DateTime.now());

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _goalCups = p.getInt(_kWaterGoalCups) ?? 8;
    final savedDate = p.getString(_kWaterDate);
    if (savedDate != _todayStr) {
      _count = 0;
      await p.setString(_kWaterDate, _todayStr);
      await p.setInt(_kWaterCount, 0);
    } else {
      _count = p.getInt(_kWaterCount) ?? 0;
    }
    if (mounted) setState(() {});
  }

  double get _progress => _goalCups == 0 ? 0 : _count / _goalCups;

  Future<void> _toggleCup(int index) async {
    final p = await SharedPreferences.getInstance();
    if (index < _count) {
      _count = index;
    } else {
      _count = (index + 1).clamp(0, _goalCups);
    }
    await p.setInt(_kWaterCount, _count);
    await p.setString(_kWaterDate, _todayStr);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: const Text('Water')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text('$_count / $_goalCups cups', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: List.generate(_goalCups, (i) {
                        final filled = i < _count;
                        return GestureDetector(
                          onTap: () => _toggleCup(i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: filled ? primary : Colors.white,
                              border: Border.all(
                                color: filled ? primary.withValues(alpha: 0.7) : Colors.grey.withValues(alpha: 0.4),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.06),
                                  blurRadius: 6,
                                  offset: const Offset(0, 3),
                                )
                              ],
                            ),
                            child: Icon(filled ? Icons.water_drop : Icons.water_drop_outlined,
                                size: 24, color: filled ? Colors.white : Colors.grey[700]),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Tip: stay hydrated throughout the day.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[700])),
          ],
        ),
      ),
    );
  }
}

/* ============================ SETTINGS SCREEN ============================ */

class SettingsScreen extends StatefulWidget {
  final ThemeController themeController;
  const SettingsScreen({super.key, required this.themeController});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  double _weight = 70;   // kg
  double _heightCm = 175; // cm ΠΑΝΤΑ
  String _gender = '—';
  int _age = 25;
  int _waterGoal = 8;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _weight = p.getDouble(_kWeight) ?? 70;

    // normalize height to cm (fix old meters values)
    final savedH = p.getDouble(_kHeight);
    if (savedH == null) {
      _heightCm = 175;
    } else if (savedH >= 1 && savedH <= 3) {
      _heightCm = (savedH * 100).roundToDouble();
      await p.setDouble(_kHeight, _heightCm);
    } else {
      _heightCm = savedH;
    }
    if (_heightCm < 120 || _heightCm > 240) {
      _heightCm = 175;
    }

    _gender = p.getString(_kGender) ?? '—';
    _age = p.getInt(_kAge) ?? 25;
    _waterGoal = p.getInt(_kWaterGoalCups) ?? 8;
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveProfile() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kWeight, _weight);
    await p.setDouble(_kHeight, _heightCm);
    await p.setString(_kGender, _gender);
    await p.setInt(_kAge, _age);
    await p.setInt(_kWaterGoalCups, _waterGoal);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved profile')));
  }

  Future<void> _openSliderSheet({
    required String title,
    required double min,
    required double max,
    required int divisions,
    required double initial,
    required String unit,
    required ValueChanged<double> onChanged,
  }) async {
    double init = initial.clamp(min, max);
    double temp = init;

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                left: 16, right: 16, top: 12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text('${temp.toStringAsFixed(0)} $unit'),
                  Slider(
                    value: temp,
                    min: min,
                    max: max,
                    divisions: divisions,
                    onChanged: (v) => setSheet(() => temp = v),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () { onChanged(temp); Navigator.pop(ctx); },
                    child: const Text('Select'),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
    setState(() {}); // refresh
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.themeController.seeds;
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), centerTitle: true),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFFEAF6FF), Color(0xFFF9FBFF)],
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionTitle('Profile'),
              const SizedBox(height: 8),
              _card(
                child: Column(
                  children: [
                    _pickerTile(
                      label: 'Weight',
                      value: '${_weight.toStringAsFixed(0)} kg',
                      icon: Icons.monitor_weight_outlined,
                      onTap: () => _openSliderSheet(
                        title: 'Select Weight',
                        min: 30, max: 200, divisions: 170,
                        initial: _weight, unit: 'kg',
                        onChanged: (v) => _weight = v.roundToDouble(),
                      ),
                    ),
                    const Divider(height: 1),
                    _pickerTile(
                      label: 'Height',
                      value: '${_heightCm.toStringAsFixed(0)} cm',
                      icon: Icons.height,
                      onTap: () => _openSliderSheet(
                        title: 'Select Height',
                        min: 120, max: 220, divisions: 100,
                        initial: _heightCm, unit: 'cm',
                        onChanged: (v) => _heightCm = v.roundToDouble(),
                      ),
                    ),
                    const Divider(height: 1),
                    _pickerTile(
                      label: 'Age',
                      value: '$_age',
                      icon: Icons.cake_outlined,
                      onTap: () => _openSliderSheet(
                        title: 'Select Age',
                        min: 10, max: 100, divisions: 90,
                        initial: _age.toDouble(), unit: 'years',
                        onChanged: (v) => _age = v.round(),
                      ),
                    ),
                    const Divider(height: 1),
                    _genderPicker(),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(onPressed: _saveProfile, child: const Text('Save profile')),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              _sectionTitle('Theme color'),
              const SizedBox(height: 8),
              _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: List.generate(colors.length, (i) {
                        final selected = i == widget.themeController.index;
                        return GestureDetector(
                          onTap: () => widget.themeController.setIndex(i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 42, height: 42,
                            decoration: BoxDecoration(
                              color: colors[i],
                              shape: BoxShape.circle,
                              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 4))],
                              border: Border.all(
                                color: selected ? Colors.black.withValues(alpha: 0.35) : Colors.white,
                                width: selected ? 2.2 : 1.0,
                              ),
                            ),
                            child: selected ? const Icon(Icons.check, color: Colors.white) : null,
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 12),
                    Text('Pick one of 5 colors to personalize the app.', style: TextStyle(color: Colors.grey[700])),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              _sectionTitle('Water goal'),
              const SizedBox(height: 8),
              _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.water_drop_outlined),
                      title: const Text('Daily water goal'),
                      subtitle: Text('$_waterGoal cups'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openSliderSheet(
                        title: 'Water goal (cups)',
                        min: 4, max: 16, divisions: 12,
                        initial: _waterGoal.toDouble(), unit: 'cups',
                        onChanged: (v) => _waterGoal = v.round(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(onPressed: _saveProfile, child: const Text('Save water goal')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pickerTile({required String label, required String value, required IconData icon, required VoidCallback onTap}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(value),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  Widget _sectionTitle(String s) => Text(s, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800));
  Widget _card({required Widget child}) => Card(elevation: 4, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)), child: Padding(padding: const EdgeInsets.all(16), child: child));

  Widget _genderPicker() {
    final items = const ['—', 'Male', 'Female', 'Other'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(padding: EdgeInsets.only(left: 16, top: 8, bottom: 6), child: Text('Gender', style: TextStyle(fontWeight: FontWeight.w700))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<String>(
            value: _gender,
            items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
            onChanged: (v) => setState(() => _gender = v ?? '—'),
            decoration: InputDecoration(
              filled: true, fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }
}

/* ============================ CUSTOM WIDGETS ============================ */

class _Gauge extends StatelessWidget {
  final double value; // 0..1
  final int steps;
  final int goal;
  final Color arcColor;
  final Color bgArc;
  final Color disk;
  const _Gauge({
    required this.value,
    required this.steps,
    required this.goal,
    required this.arcColor,
    required this.bgArc,
    required this.disk,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GaugePainter(value: value, arcColor: arcColor, bgArc: bgArc, disk: disk),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$steps', style: const TextStyle(color: Colors.white, fontSize: 56, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text('${(value * 100).round()}% of $goal',
                style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double value;
  final Color arcColor;
  final Color bgArc;
  final Color disk;
  _GaugePainter({required this.value, required this.arcColor, required this.bgArc, required this.disk});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 8;

    // inner dark disk
    final diskR = radius * 0.78;
    final diskPaint = Paint()..color = disk..style = PaintingStyle.fill;
    canvas.drawCircle(center, diskR, diskPaint);

    // background arc
    final stroke = radius * 0.18;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final start = -math.pi * 0.5; // from top
    final bg = Paint()
      ..color = bgArc
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, math.pi * 2, false, bg);

    // foreground arc
    final fg = Paint()
      ..color = arcColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, (math.pi * 2) * value, false, fg);

    // slight light ring on disk
    final rim = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, diskR, rim);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.value != value || old.arcColor != arcColor || old.bgArc != bgArc || old.disk != disk;
}

class _AreaChart extends StatelessWidget {
  final List<int> values; // 7 values
  final int goal;
  final Color color;
  const _AreaChart({required this.values, required this.goal, required this.color});

  @override
  Widget build(BuildContext context) {
    final maxVal = ([
      ...values,
      goal,
    ]..sort())
        .last
        .toDouble();
    final maxY = (maxVal == 0 ? 1000 : maxVal) * 1.3;

    final spots = List.generate(7, (i) => FlSpot(i.toDouble(), values[i].toDouble()));
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: 6,
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) {
                const labels = ['S','M','T','W','T','F','S'];
                final i = v.toInt();
                if (i < 0 || i > 6) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(labels[i], style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(enabled: false),
        extraLinesData: ExtraLinesData(horizontalLines: [
          HorizontalLine(
            y: goal.toDouble(),
            strokeWidth: 2,
            color: Colors.amber[700]!.withOpacity(0.9),
            dashArray: const [6, 6],
            label: HorizontalLineLabel(
              show: true,
              alignment: Alignment.topRight,
              labelResolver: (_) => 'Goal',
              style: TextStyle(color: Colors.amber[800]),
            ),
          ),
        ]),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            barWidth: 3,
            color: color,
            isStrokeCapRound: true,
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [color.withOpacity(0.35), color.withOpacity(0.08)],
              ),
            ),
            dotData: FlDotData(
              show: true,
              getDotPainter: (s, _, __, ___) => FlDotCirclePainter(
                radius: 4,
                color: Colors.white,
                strokeWidth: 3,
                strokeColor: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ============================ RING PAINTER (legacy, unused by gauge) ============================ */
// (διατηρώ αν το θέλεις αλλού)
class _RingPainter extends CustomPainter {
  final double progress; // 0..1
  final Color bgColor;
  final Color fgColor;
  final double stroke;
  _RingPainter({required this.progress, required this.bgColor, required this.fgColor, required this.stroke});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide / 2) - stroke / 2;

    final bgPaint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bgPaint);

    final fgPaint = Paint()
      ..color = fgColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final start = -math.pi / 2; // from top
    final sweep = 2 * math.pi * progress;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(rect, start, sweep, false, fgPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) {
    return old.progress != progress || old.bgColor != bgColor || old.fgColor != fgColor || old.stroke != stroke;
  }
}
