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

/* ============================ APP ROOT (no auth, 2 tabs) ============================ */

class MyStepApp extends StatelessWidget {
  const MyStepApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyStep',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00B2FF)),
        useMaterial3: true,
      ),
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
      body: _pages[_index],
      bottomNavigationBar: NavigationBar(
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
  int _goal = 5000;
  String _status = '—';
  String? _error;
  List<int> _history = List.filled(7, 0);

  @override
  void initState() {
    super.initState();
    _loadPrefs().then((_) => _initPedometer());
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    _goal = p.getInt(_kGoal) ?? 5000;
    final list = p.getStringList(_kHistory);
    if (list != null && list.length == 7) {
      _history = list.map((e) => int.tryParse(e) ?? 0).toList();
    }
    setState(() {});
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
      if (mounted) setState(() => _todaySteps = todaySteps);
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
  double get _miles => _todaySteps / 2000.0;
  double get _kcal => _todaySteps * 0.04;

  @override
  Widget build(BuildContext context) {
    final pct = (_progress * 100).round();
    final size = MediaQuery.of(context).size;
    final ringSize = size.width - 32; // full-bleed μέσα στα 16px padding αριστερά/δεξιά

    return Scaffold(
      appBar: AppBar(
        title: const Text('Steps'),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // FULL-BLEED RING (λευκό background, γεμίζει σχεδόν όλο το πλάτος)
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 14, offset: Offset(0, 6))],
              ),
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
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
                              fgColor: const Color(0xFF00B2FF),
                              stroke: 20,
                            ),
                          ),
                        ),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('$_todaySteps',
                                style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w900)),
                            const SizedBox(height: 6),
                            Text('Today • $pct% of $_goal',
                                style: TextStyle(color: Colors.grey[600], fontSize: 14)),
                            const SizedBox(height: 6),
                            Text(_status, style: TextStyle(color: Colors.grey[700])),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // μικρά KPIs σε λευκό
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _kpi(Icons.local_fire_department, '${_kcal.toStringAsFixed(0)} kcal'),
                      _kpi(Icons.route_outlined, '${(_miles * 1.60934).toStringAsFixed(2)} km'),
                      _kpi(Icons.timer_outlined, '${(_todaySteps / 100.0).toStringAsFixed(0)} min'),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 7-day line chart (λεπτό, καθαρό)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 14, offset: Offset(0, 6))],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Last 7 days', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 160,
                    child: LineChart(LineChartData(
                      gridData: FlGridData(show: false),
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
                              return Text(labels[i], style: TextStyle(color: Colors.grey[600], fontSize: 12));
                            },
                          ),
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      minX: 0, maxX: 6,
                      minY: 0,
                      lineBarsData: [
                        LineChartBarData(
                          isCurved: true,
                          barWidth: 3,
                          color: const Color(0xFF00B2FF),
                          dotData: FlDotData(show: true),
                          spots: List.generate(7, (i) => FlSpot(i.toDouble(), _history[i].toDouble())),
                          belowBarData: BarAreaData(show: true, color: const Color(0x2200B2FF)),
                        ),
                      ],
                    )),
                  ),
                ],
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kpi(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF00B2FF)),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
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
  static const _kGoal = 'daily_goal';
  int _goal = 5000;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      setState(() => _goal = p.getInt(_kGoal) ?? 5000);
    });
  }

  Future<void> _save(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kGoal, v);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved daily goal')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Goals'), centerTitle: true, backgroundColor: Colors.white, elevation: 0),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 14, offset: Offset(0, 6))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Daily step goal', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Text('$_goal steps', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
              Slider(
                value: _goal.toDouble(),
                min: 1000, max: 30000, divisions: 58,
                onChanged: (v) => setState(() => _goal = (v / 500).round() * 500),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: () => _save(_goal), child: const Text('Save')),
            ],
          ),
        ),
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
  _RingPainter({required this.progress, required this.bgColor, required this.fgColor, required this.stroke});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide / 2) - stroke / 2;

    // BG circle
    final bgPaint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bgPaint);

    // FG arc
    final fgPaint = Paint()
      ..color = fgColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final start = -90.0 * (3.1415926535 / 180.0); // από πάνω
    final sweep = 2 * 3.1415926535 * progress;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(rect, start, sweep, false, fgPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) {
    return old.progress != progress || old.bgColor != bgColor || old.fgColor != fgColor || old.stroke != stroke;
  }
}
