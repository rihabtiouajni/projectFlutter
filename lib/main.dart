import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:confetti/confetti.dart';

void main() => runApp(const MemoryGameApp());

// ════════════════════════════════════════════
// App Root
// ════════════════════════════════════════════
class MemoryGameApp extends StatelessWidget {
  const MemoryGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Memory Card Flip',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0C29),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const GameScreen(),
    );
  }
}

// ════════════════════════════════════════════
// Difficulty
// Encapsulates all grid + timer config in one place.
// Adding a new level = adding one entry here.
// ════════════════════════════════════════════
enum Difficulty {
  //           label    cols rows  seconds
  easy  (label: 'Easy',   columns: 4, rows: 3, seconds: 120),
  medium(label: 'Medium', columns: 4, rows: 4, seconds: 90),
  hard  (label: 'Hard',   columns: 5, rows: 6, seconds: 60);

  const Difficulty({
    required this.label,
    required this.columns,
    required this.rows,
    required this.seconds,
  });

  final String label;
  final int columns;  // grid columns
  final int rows;     // grid rows
  final int seconds;  // countdown limit

  // Total cards on the board
  int get cardCount => columns * rows;

  // Pairs needed (half of total cards)
  int get pairCount => cardCount ~/ 2;
}

// ════════════════════════════════════════════
// CardModel
// ════════════════════════════════════════════
class CardModel {
  final int id;
  final String emoji;
  bool isFlipped;
  bool isMatched;

  CardModel({
    required this.id,
    required this.emoji,
    this.isFlipped = false,
    this.isMatched = false,
  });
}

// ════════════════════════════════════════════
// GameScreen
// ════════════════════════════════════════════
class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {

  // Full emoji pool — 15 pairs covers Hard mode (5×6 = 30 cards)
  static const _allSymbols = [
    '🐶','🐱','🐭','🐹','🦊',
    '🐻','🐼','🐨','🐯','🦁',
    '🐸','🦋','🐬','🦄','🐙',
  ];

  // ── Game state ────────────────────────────
  late List<CardModel> _cards;
  int? _firstIndex;
  int? _secondIndex;
  bool _isChecking = false;
  int _moves       = 0;
  int _matchedPairs = 0;
  bool _gameOver   = false;

  // ── Difficulty ────────────────────────────
  Difficulty _difficulty = Difficulty.medium;

  // ── Timer ─────────────────────────────────
  late int _secondsLeft;
  late int _totalSeconds;
  Timer? _timer;

  // ── Pulse animation (≤10 s warning) ───────
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulseAnim;

  // ── Confetti ──────────────────────────────
  late ConfettiController _confetti;

  // ── Lifecycle ─────────────────────────────
  @override
  void initState() {
    super.initState();
    _confetti = ConfettiController(duration: const Duration(seconds: 3));

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed) _pulseCtrl.reverse();
        if (s == AnimationStatus.dismissed) _pulseCtrl.forward();
      });

    _pulseAnim = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _initGame();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseCtrl.dispose();
    _confetti.dispose();
    super.dispose();
  }

  // ── Initialise / restart ──────────────────
  void _initGame() {
    _timer?.cancel();
    _pulseCtrl.stop();

    final d = _difficulty;

    // Take only as many symbols as we need pairs, then duplicate & shuffle
    final pool = _allSymbols.take(d.pairCount).toList();
    final pairs = [...pool, ...pool]..shuffle(Random());

    _cards = List.generate(
      d.cardCount,
      (i) => CardModel(id: i, emoji: pairs[i]),
    );

    _firstIndex   = null;
    _secondIndex  = null;
    _isChecking   = false;
    _moves        = 0;
    _matchedPairs = 0;
    _gameOver     = false;
    _totalSeconds = d.seconds;
    _secondsLeft  = d.seconds;

    _startTimer();
  }

  // ── Timer ─────────────────────────────────
  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_secondsLeft > 0) {
          _secondsLeft--;
          if (_secondsLeft <= 10 && !_pulseCtrl.isAnimating) {
            _pulseCtrl.forward();
          }
        } else {
          _timer?.cancel();
          _gameOver = true;
          _showTimeUpDialog();
        }
      });
    });
  }

  // Colour shifts green → amber → red as time drains
  Color get _timerColor {
    final ratio = _secondsLeft / _totalSeconds;
    if (ratio > 0.5)  return const Color(0xFF4CAF50);
    if (ratio > 0.25) return const Color(0xFFFFB300);
    return const Color(0xFFEF5350);
  }

  // ── Card tap ──────────────────────────────
  Future<void> _onTap(int index) async {
    if (_gameOver) return;
    final card = _cards[index];
    if (_isChecking || card.isMatched || card.isFlipped) return;
    if (_firstIndex != null && _secondIndex != null) return;

    setState(() => card.isFlipped = true);

    if (_firstIndex == null) {
      _firstIndex = index;
    } else {
      _secondIndex = index;
      setState(() { _isChecking = true; _moves++; });
      await _checkMatch();
    }
  }

  Future<void> _checkMatch() async {
    final a = _cards[_firstIndex!];
    final b = _cards[_secondIndex!];

    if (a.emoji == b.emoji) {
      setState(() {
        a.isMatched   = true;
        b.isMatched   = true;
        _matchedPairs++;
        _firstIndex  = null;
        _secondIndex = null;
        _isChecking  = false;
      });

      if (_matchedPairs == _difficulty.pairCount) {
        _timer?.cancel();
        _pulseCtrl.stop();
        setState(() => _gameOver = true);
        _confetti.play();
        _showWinDialog();
      }
    } else {
      await Future.delayed(const Duration(milliseconds: 900));
      setState(() {
        a.isFlipped  = false;
        b.isFlipped  = false;
        _firstIndex  = null;
        _secondIndex = null;
        _isChecking  = false;
      });
    }
  }

  void _restart() => setState(_initGame);

  // ── Dialogs ───────────────────────────────
  void _showWinDialog() => showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GameDialog(
      title: '🎉 You Win!',
      body: 'Completed in $_moves moves\nwith $_secondsLeft seconds left!',
      buttonLabel: 'Play Again',
      onPressed: () { Navigator.pop(context); _restart(); },
    ),
  );

  void _showTimeUpDialog() => showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GameDialog(
      title: "⏰ Time's Up!",
      body: 'You matched $_matchedPairs of ${_difficulty.pairCount} pairs.\nTry again?',
      buttonLabel: 'Retry',
      onPressed: () { Navigator.pop(context); _restart(); },
    ),
  );

  // ════════════════════════════════════════════
  // Build
  // ════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _confetti,
              blastDirectionality: BlastDirectionality.explosive,
              numberOfParticles: 25,
              colors: const [
                Colors.purple, Colors.pink, Colors.blue,
                Colors.yellow, Colors.orange,
              ],
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 14),
                _buildTitle(),
                const SizedBox(height: 10),
                _buildDifficultySelector(),
                const SizedBox(height: 12),
                _buildStatsRow(),
                const SizedBox(height: 12),
                // Grid takes all remaining vertical space
                Expanded(child: _buildGrid()),
                const SizedBox(height: 10),
                _buildRestartButton(),
                const SizedBox(height: 14),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitle() => const Text(
    '🧠 Memory Flip',
    style: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.bold,
      color: Colors.white,
      letterSpacing: 1.4,
    ),
  );

  // ── Difficulty pill selector ──────────────
  Widget _buildDifficultySelector() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: Difficulty.values.map((d) {
        final selected = _difficulty == d;
        // Show grid dimensions as a subtitle
        final gridLabel = '${d.columns}×${d.rows}';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: GestureDetector(
            onTap: () {
              if (!selected) {
                setState(() => _difficulty = d);
                _restart();
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF6C63FF) : Colors.white10,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Text(
                    d.label,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.white54,
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  Text(
                    gridLabel,
                    style: TextStyle(
                      color: selected ? Colors.white70 : Colors.white30,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ── Stats row ─────────────────────────────
  Widget _buildStatsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _chip(Icons.touch_app, 'Moves', '$_moves'),
        _buildTimerRing(),
        _chip(Icons.favorite, 'Pairs', '$_matchedPairs/${_difficulty.pairCount}'),
      ],
    );
  }

  Widget _buildTimerRing() {
    final mins  = _secondsLeft ~/ 60;
    final secs  = _secondsLeft % 60;
    final label =
        '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    final progress = _secondsLeft / _totalSeconds;

    return ScaleTransition(
      scale: _secondsLeft <= 10
          ? _pulseAnim
          : const AlwaysStoppedAnimation(1.0),
      child: SizedBox(
        width: 68,
        height: 68,
        child: CustomPaint(
          painter: _TimerRingPainter(
            progress: progress,
            color: _timerColor,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: _timerColor,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF6C63FF), size: 14),
          const SizedBox(width: 5),
          Text('$label: ',
              style: const TextStyle(color: Colors.white60, fontSize: 12)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12)),
        ],
      ),
    );
  }

  // ── Dynamic grid ──────────────────────────
  Widget _buildGrid() {
    final d = _difficulty;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate square card size that fits the available space
        final spacing   = 8.0;
        final hPadding  = 16.0;

        // Width-based size
        final availableW = constraints.maxWidth - hPadding * 2 -
            spacing * (d.columns - 1);
        final cardW = availableW / d.columns;

        // Height-based size (so cards don't overflow vertically)
        final availableH = constraints.maxHeight - spacing * (d.rows - 1);
        final cardH = availableH / d.rows;

        // Use the smaller of the two so everything fits
        final cardSize = min(cardW, cardH);

        // Font scales with card size so emojis don't overflow
        final emojiFontSize = (cardSize * 0.42).clamp(14.0, 32.0);

        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: d.columns,
                crossAxisSpacing: spacing,
                mainAxisSpacing: spacing,
                // childAspectRatio keeps cards square
                childAspectRatio: cardSize / cardSize,
              ),
              itemCount: d.cardCount,
              itemBuilder: (_, i) => _CardTile(
                card: _cards[i],
                emojiFontSize: emojiFontSize,
                onTap: () => _onTap(i),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRestartButton() {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF6C63FF),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: _restart,
      icon: const Icon(Icons.replay, color: Colors.white),
      label: const Text('Restart',
          style: TextStyle(color: Colors.white, fontSize: 15)),
    );
  }
}

// ════════════════════════════════════════════
// _TimerRingPainter
// ════════════════════════════════════════════
class _TimerRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  const _TimerRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 8) / 2;

    canvas.drawCircle(
      center, radius,
      Paint()
        ..color = Colors.white12
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      2 * pi * progress,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_TimerRingPainter old) =>
      old.progress != progress || old.color != color;
}

// ════════════════════════════════════════════
// _CardTile
// emojiFontSize is passed in so it scales with card size
// ════════════════════════════════════════════
class _CardTile extends StatelessWidget {
  final CardModel card;
  final VoidCallback onTap;
  final double emojiFontSize;

  const _CardTile({
    required this.card,
    required this.onTap,
    required this.emojiFontSize,
  });

  @override
  Widget build(BuildContext context) {
    Color faceColor = const Color(0xFF3D3A8C);
    if (card.isMatched)       faceColor = const Color(0xFF2E7D32);
    else if (card.isFlipped)  faceColor = const Color(0xFF5C6BC0);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        transitionBuilder: (child, animation) {
          final rotate = Tween(begin: pi, end: 0.0).animate(animation);
          return AnimatedBuilder(
            animation: rotate,
            child: child,
            builder: (_, child) {
              final isFront = const ValueKey(true) == child!.key;
              final angle = isFront
                  ? min(rotate.value, pi / 2)
                  : rotate.value;
              return Transform(
                transform: Matrix4.rotationY(angle),
                alignment: Alignment.center,
                child: child,
              );
            },
          );
        },
        child: card.isFlipped || card.isMatched
            ? _face(
                key: const ValueKey(true),
                color: faceColor,
                child: Text(card.emoji,
                    style: TextStyle(fontSize: emojiFontSize)),
              )
            : _face(
                key: const ValueKey(false),
                color: const Color(0xFF3D3A8C),
                child: Text('❓',
                    style: TextStyle(fontSize: emojiFontSize * 0.85)),
              ),
      ),
    );
  }

  Widget _face({
    required Key key,
    required Color color,
    required Widget child,
  }) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(child: child),
    );
  }
}

// ════════════════════════════════════════════
// _GameDialog
// ════════════════════════════════════════════
class _GameDialog extends StatelessWidget {
  final String title;
  final String body;
  final String buttonLabel;
  final VoidCallback onPressed;

  const _GameDialog({
    required this.title,
    required this.body,
    required this.buttonLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1B4B),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20)),
      title: Text(title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, color: Colors.white)),
      content: Text(body,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white70, fontSize: 15, height: 1.6)),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6C63FF),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(
                horizontal: 28, vertical: 12),
          ),
          icon: const Icon(Icons.replay, color: Colors.white),
          label: Text(buttonLabel,
              style:
                  const TextStyle(color: Colors.white, fontSize: 15)),
          onPressed: onPressed,
        ),
      ],
    );
  }
}