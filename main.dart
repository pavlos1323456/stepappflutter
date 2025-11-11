// MyStep — modern UI (safe ringSize + stable Goals first-load)
// lib/main.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_chart/fl_chart.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyStepApp());
}

/* ============================ THEME ============================ */

class AppColors {
  static const primary = Color(0xFF00B2FF);
  static const primaryDark = Color(0xFF0076FF);
  static const bg = Color(0xFFF7F9FC);
  static const text = Color(0xFF0B1220);
}

ThemeData appTheme() {
  final seed = AppColors.primary;
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
  const MyStepApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyStep',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  final _pages = const [StepsScreen(), GoalsScreen()];
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
              backgroundColor: Colors.white.withValues(alpha: 0.9),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* ============================ STEPS SCREEN ============================ */

class StepsScreen extends StatefulWidget {
  const StepsScreen({super.key});
  @override
  State<StepsScreen> createState() => _StepsScreenState();
}

class _StepsScreenState extends State<StepsScreen> {
  // keys
  static const _kBaseline = 'baseline_steps';
  static const _kDate = 'baseline_date';
  static const _kGoal = 'daily_goal';
  static const _kHistory = 'history_7';

  StreamSubscription<StepCount>? _stepSub;
  StreamSubscription<PedestrianStatus>? _statusSub;

  int _todaySteps = 0;
  int _goal = 8000;
  String _status = '—';
  String? _error;
  List<int> _history = List.filled(7, 0);

  bool _hitGoalPulse = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs().then((_) => _initPedometer());
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    _goal = p.getInt(_kGoal) ?? 8000;
    final list = p.getStringList(_kHistory);
    if (list != null && list.length == 7) {
      _history = list.map((e) => int.tryParse(e) ?? 0).toList();
    }
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
      final current = event.steps; // cumulative since reboot
      final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
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

      final todaySteps = (current - baseline).clamp(0, 1 << 31);
      if (!mounted) return;
      setState(() {
        _todaySteps = todaySteps;
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
  int get _streak {
    int c = 0;
    for (int i = _history.length - 1; i >= 0; i--) {
      if (_history[i] >= (_goal * 0.6)) {
        c++;
      } else {
        break;
      }
    }
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    // SAFE: never negative (offstage tabs can report 0 width)
    final ringSize = (screenW - 40).clamp(0.0, screenW);

    final date = DateFormat('d MMM, y').format(DateTime.now());

    return Stack(
      children: [
        // gradient background
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(0.8, -1),
              end: Alignment(-0.8, 1),
              colors: [Color(0xFFEAF6FF), Color(0xFFF9FBFF)],
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
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _simpleIconButton(
                  context,
                  icon: Icons.insights_outlined,
                  onTap: () => _showStatsBottomSheet(context),
                ),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Hero ring card
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Column(
                      children: [
                        // If offstage (ringSize==0), skip heavy paint
                        if (ringSize == 0)
                          const SizedBox.shrink()
                        else
                          SizedBox(
                            width: ringSize,
                            height: ringSize,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                TweenAnimationBuilder<double>(
                                  tween: Tween(begin: 0, end: _progress),
                                  duration: const Duration(milliseconds: 900),
                                  curve: Curves.easeOutCubic,
                                  builder: (_, v, __) => CustomPaint(
                                    painter: _RingPainter(
                                      progress: v,
                                      bgColor: const Color(0xFFEFF4FA),
                                      fgColor: AppColors.primary,
                                      stroke: 22,
                                    ),
                                  ),
                                ),
                                AnimatedScale(
                                  scale: _hitGoalPulse ? 1.08 : 1.0,
                                  duration: const Duration(milliseconds: 500),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      AnimatedSwitcher(
                                        duration: const Duration(milliseconds: 300),
                                        transitionBuilder: (c, a) =>
                                            FadeTransition(opacity: a, child: c),
                                        child: Text(
                                          '$_todaySteps',
                                          key: ValueKey(_todaySteps),
                                          style: const TextStyle(
                                              fontSize: 56, fontWeight: FontWeight.w900),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text('${(100 * _progress).round()}% of $_goal',
                                          style: TextStyle(
                                              color: Colors.grey[600], fontSize: 14)),
                                      const SizedBox(height: 6),
                                      _statusPill(_status),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                                child: _kpiTile(Icons.local_fire_department,
                                    '${_kcal.toStringAsFixed(0)} kcal')),
                            const SizedBox(width: 10),
                            Expanded(
                                child: _kpiTile(
                                    Icons.route_outlined, '${_km.toStringAsFixed(2)} km')),
                            const SizedBox(width: 10),
                            Expanded(
                                child: _kpiTile(Icons.timer_outlined,
                                    '${(_todaySteps / 100).toStringAsFixed(0)} min')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Weekly chart
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Last 7 days',
                                style: TextStyle(fontWeight: FontWeight.w800)),
                            Text('Best: $_bestDay',
                                style: TextStyle(color: Colors.grey[600])),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 170,
                          child: BarChart(
                            BarChartData(
                              gridData: FlGridData(show: false),
                              borderData: FlBorderData(show: false),
                              alignment: BarChartAlignment.spaceBetween,
                              maxY: _history
                                      .followedBy([_todaySteps, _goal])
                                      .reduce((a, b) => a > b ? a : b)
                                      .toDouble() *
                                  1.2,
                              titlesData: FlTitlesData(
                                leftTitles:
                                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                topTitles:
                                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                rightTitles:
                                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    getTitlesWidget: (v, _) {
                                      const labels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
                                      final i = v.toInt();
                                      if (i < 0 || i > 6) return const SizedBox();
                                      return Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: Text(labels[i],
                                            style: TextStyle(
                                                color: Colors.grey[600], fontSize: 12)),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              barGroups: List.generate(7, (i) {
                                final val = _history[i].toDouble();
                                return BarChartGroupData(
                                  x: i,
                                  barRods: [
                                    BarChartRodData(
                                      toY: val,
                                      width: 18,
                                      borderRadius: BorderRadius.circular(8),
                                      gradient: const LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [AppColors.primary, Color(0x2200B2FF)],
                                      ),
                                    ),
                                  ],
                                );
                              }),
                              extraLinesData: ExtraLinesData(horizontalLines: [
                                HorizontalLine(
                                  y: _goal.toDouble(),
                                  strokeWidth: 2,
                                  color: AppColors.primaryDark.withValues(alpha: 0.5),
                                  dashArray: const [6, 6],
                                  label: HorizontalLineLabel(
                                    show: true,
                                    alignment: Alignment.topRight,
                                    labelResolver: (_) => 'Goal',
                                    style: TextStyle(
                                      color: AppColors.primaryDark.withValues(alpha: 0.8),
                                    ),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                        ),
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

  // simple (no blur) icon button for 100% safety
  Widget _simpleIconButton(BuildContext context, {required IconData icon, VoidCallback? onTap}) {
    return Material(
      color: Colors.white.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: AppColors.primaryDark),
        ),
      ),
    );
  }

  Widget _statusPill(String text) {
    final isOk = text == 'Walking';
    final color = isOk ? Colors.green : Colors.grey;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isOk ? Icons.directions_walk : Icons.pause_circle_outline, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

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
          Icon(icon, color: AppColors.primaryDark),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  void _showStatsBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 4,
                decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(4)),
              ),
              const SizedBox(height: 14),
              const Text('Weekly highlights', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _miniStat('Streak', '$_streak days')),
                  const SizedBox(width: 10),
                  Expanded(child: _miniStat('Best day', '$_bestDay steps')),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _miniStat(
                      'Avg / day',
                      _history.isEmpty ? '0' : '${(_history.reduce((a, b) => a + b) / _history.length).round()}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniStat(String title, String value) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 10, offset: Offset(0, 4))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(color: Colors.grey[600])),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      );
}

/* ============================ GOALS SCREEN (stable init) ============================ */

class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key});
  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  static const _kGoal = 'daily_goal';
  late Future<int> _goalFuture;
  int _goalValue = 8000; // slider state

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
      extendBodyBehindAppBar: false,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('Goals'),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
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
                  const Text('Daily step goal',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
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
                  const SizedBox(height: 16),
                  _tipCard(),
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
        child: Text(
          s,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
        ),
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
            onSelected: (sel) {
              if (!sel) return;
              setState(() => _goalValue = g);
            },
          ),
      ],
    );
  }

  Widget _tipCard() => Card(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.tips_and_updates_outlined),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Tip: μικρά, συχνά περπατήματα μέσα στη μέρα βοηθούν περισσότερο από ένα μεγάλο. Στόχευσε σε 60–70% του στόχου μέχρι το μεσημέρι.',
                ),
              ),
            ],
          ),
        ),
      );
}

/* ============================ SHARED GLASS CARD (safe) ============================ */

class GlassCard extends StatelessWidget {
  final Widget child;
  const GlassCard({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(24)),
        child: child,
      ),
    );
  }
}

/* ============================ RING PAINTER ============================ */

class _RingPainter extends CustomPainter {
  final double progress; // 0..1
  final Color bgColor;
  final Color fgColor;
  final double stroke;
  _RingPainter({
    required this.progress,
    required this.bgColor,
    required this.fgColor,
    required this.stroke,
  });

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

    final start = -90.0 * (3.1415926535 / 180.0); // from top
    final sweep = 2 * 3.1415926535 * progress;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(rect, start, sweep, false, fgPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) {
    return old.progress != progress ||
        old.bgColor != bgColor ||
        old.fgColor != fgColor ||
        old.stroke != stroke;
  }
}
