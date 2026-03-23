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
// Star thresholds are multiples of pairCount:
//   3★ ≤ pairs × 1.5   (nearly perfect)
//   2★ ≤ pairs × 2.5   (decent)
//   1★  anything else  (just finished)
// ════════════════════════════════════════════
enum Difficulty {
  easy  (label: 'Easy',   columns: 4, rows: 3, seconds: 120, hintCount: 3, hintSeconds: 3.0),
  medium(label: 'Medium', columns: 4, rows: 4, seconds: 90,  hintCount: 2, hintSeconds: 2.0),
  hard  (label: 'Hard',   columns: 5, rows: 6, seconds: 60,  hintCount: 1, hintSeconds: 1.5);

  const Difficulty({
    required this.label,
    required this.columns,
    required this.rows,
    required this.seconds,
    required this.hintCount,
    required this.hintSeconds,
  });

  final String label;
  final int    columns;
  final int    rows;
  final int    seconds;
  final int    hintCount;
  final double hintSeconds;

  int get cardCount => columns * rows;
  int get pairCount => cardCount ~/ 2;

  // Move thresholds for star rating
  int get threeStar => (pairCount * 1.5).round(); // e.g. 12 for medium
  int get twoStar   => (pairCount * 2.5).round(); // e.g. 20 for medium

  // Calculate stars earned from a move count
  int starsFor(int moves) {
    if (moves <= threeStar) return 3;
    if (moves <= twoStar)   return 2;
    return 1;
  }

  // How close to perfect: 1.0 = at or under threeStar, 0.0 = at or beyond twoStar
  double efficiencyFor(int moves) {
    if (moves <= threeStar) return 1.0;
    if (moves >= twoStar)   return 0.0;
    return 1.0 - (moves - threeStar) / (twoStar - threeStar);
  }
}

// ════════════════════════════════════════════
// CardModel
// ════════════════════════════════════════════
class CardModel {
  final int    id;
  final String emoji;
  bool isFlipped;
  bool isMatched;
  bool isGone;

  CardModel({
    required this.id,
    required this.emoji,
    this.isFlipped = false,
    this.isMatched = false,
    this.isGone    = false,
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

  static const _allSymbols = [
    '🐶','🐱','🐭','🐹','🦊',
    '🐻','🐼','🐨','🐯','🦁',
    '🐸','🦋','🐬','🦄','🐙',
  ];

  // ── Game state ────────────────────────────
  late List<CardModel> _cards;
  int?  _firstIndex;
  int?  _secondIndex;
  bool  _isChecking   = false;
  int   _moves        = 0;
  int   _matchedPairs = 0;
  bool  _gameOver     = false;

  // ── Ghost mode ────────────────────────────
  bool _ghostMode    = false;
  bool _ghostPeeking = false;

  // ── Difficulty ────────────────────────────
  Difficulty _difficulty = Difficulty.medium;

  // ── Best stars per difficulty (in-memory; survives restarts) ──
  // Key: Difficulty, Value: 1-3
  final Map<Difficulty, int> _bestStars = {};

  // ── Game timer ────────────────────────────
  late int   _secondsLeft;
  late int   _totalSeconds;
  Timer?     _gameTimer;

  // ── Hint system ───────────────────────────
  late int _hintsLeft;
  bool     _hintActive    = false;
  double   _hintProgress  = 0.0;
  Timer?   _hintTimer;
  int      _hintCountdown = 0;

  // ── Pulse animation ───────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulseAnim;

  // ── Confetti ──────────────────────────────
  late ConfettiController _confetti;

  // ─────────────────────────────────────────
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
    _gameTimer?.cancel();
    _hintTimer?.cancel();
    _pulseCtrl.dispose();
    _confetti.dispose();
    super.dispose();
  }

  // ── Init ──────────────────────────────────
  void _initGame() {
    _gameTimer?.cancel();
    _hintTimer?.cancel();
    _pulseCtrl.stop();

    final d     = _difficulty;
    final pool  = _allSymbols.take(d.pairCount).toList();
    final pairs = [...pool, ...pool]..shuffle(Random());

    _cards = List.generate(d.cardCount,
        (i) => CardModel(id: i, emoji: pairs[i]));

    _firstIndex    = null;
    _secondIndex   = null;
    _isChecking    = false;
    _moves         = 0;
    _matchedPairs  = 0;
    _gameOver      = false;
    _ghostPeeking  = false;
    _hintsLeft     = d.hintCount;
    _hintActive    = false;
    _hintProgress  = 0.0;
    _hintCountdown = 0;
    _totalSeconds  = d.seconds;
    _secondsLeft   = d.seconds;

    _startGameTimer();
  }

  // ── Game timer ────────────────────────────
  void _startGameTimer() {
    _gameTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_secondsLeft > 0) {
          _secondsLeft--;
          if (_secondsLeft <= 10 && !_pulseCtrl.isAnimating) {
            _pulseCtrl.forward();
          }
        } else {
          _gameTimer?.cancel();
          _gameOver = true;
          _cancelHint();
          _showTimeUpDialog();
        }
      });
    });
  }

  Color get _timerColor {
    final r = _secondsLeft / _totalSeconds;
    if (r > 0.5)  return const Color(0xFF4CAF50);
    if (r > 0.25) return const Color(0xFFFFB300);
    return const Color(0xFFEF5350);
  }

  // ── Hint system ───────────────────────────
  void _useHint() {
    if (_hintActive || _hintsLeft <= 0 || _gameOver) return;
    setState(() {
      _hintsLeft--;
      _hintActive    = true;
      _hintProgress  = 1.0;
      _hintCountdown = _difficulty.hintSeconds.ceil();
    });

    final totalMs = (_difficulty.hintSeconds * 1000).round();
    const tickMs  = 50;
    int elapsed   = 0;

    _hintTimer = Timer.periodic(
        const Duration(milliseconds: tickMs), (t) {
      elapsed += tickMs;
      setState(() {
        _hintProgress  = (1.0 - elapsed / totalMs).clamp(0.0, 1.0);
        _hintCountdown = max(0, ((totalMs - elapsed) / 1000).ceil());
      });
      if (elapsed >= totalMs) { t.cancel(); _cancelHint(); }
    });
  }

  void _cancelHint() {
    _hintTimer?.cancel();
    if (mounted) setState(() {
      _hintActive    = false;
      _hintProgress  = 0.0;
      _hintCountdown = 0;
    });
  }

  // ── Card tap ──────────────────────────────
  Future<void> _onTap(int index) async {
    if (_gameOver) return;
    final card = _cards[index];
    if (card.isGone || card.isMatched) return;
    if (_isChecking || card.isFlipped)  return;
    if (_firstIndex != null && _secondIndex != null) return;
    if (_hintActive) _cancelHint();

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

      if (_ghostMode) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) setState(() { a.isGone = true; b.isGone = true; });
      }

      if (_matchedPairs == _difficulty.pairCount) {
        _gameTimer?.cancel();
        _pulseCtrl.stop();
        _cancelHint();
        setState(() => _gameOver = true);

        // ── Calculate & persist best stars ──
        final earned = _difficulty.starsFor(_moves);
        final prev   = _bestStars[_difficulty] ?? 0;
        if (earned > prev) {
          setState(() => _bestStars[_difficulty] = earned);
        }

        _confetti.play();
        _showWinDialog(earned);
      }
    } else {
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) setState(() {
        a.isFlipped  = false;
        b.isFlipped  = false;
        _firstIndex  = null;
        _secondIndex = null;
        _isChecking  = false;
      });
    }
  }

  // ── Ghost peek ────────────────────────────
  Future<void> _triggerGhostPeek() async {
    if (_ghostPeeking || _gameOver) return;
    setState(() { _ghostPeeking = true; _moves += 5; });
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) setState(() => _ghostPeeking = false);
  }

  void _restart() => setState(_initGame);

  // ── Dialogs ───────────────────────────────
  void _showWinDialog(int stars) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WinDialog(
        stars:       stars,
        moves:       _moves,
        secondsLeft: _secondsLeft,
        difficulty:  _difficulty,
        onPressed: () { Navigator.pop(context); _restart(); },
      ),
    );
  }

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
                const SizedBox(height: 12),
                _buildTitle(),
                const SizedBox(height: 8),
                _buildDifficultySelector(),
                const SizedBox(height: 6),
                _buildGhostModeToggle(),
                const SizedBox(height: 8),
                _buildStatsRow(),
                const SizedBox(height: 6),
                // Live move-efficiency bar
                _buildEfficiencyBar(),
                const SizedBox(height: 6),
                _buildHintBar(),
                const SizedBox(height: 8),
                Expanded(child: _buildGrid()),
                const SizedBox(height: 6),
                if (_ghostMode) _buildGhostPeekButton(),
                const SizedBox(height: 6),
                _buildRestartButton(),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitle() => const Text(
    ' Memory Flip',
    style: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.bold,
      color: Colors.white,
      letterSpacing: 1.4,
    ),
  );

  // ── Difficulty pills (now show best-star badge) ──
  Widget _buildDifficultySelector() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: Difficulty.values.map((d) {
        final selected = _difficulty == d;
        final best     = _bestStars[d] ?? 0;

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
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF6C63FF)
                    : Colors.white10,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(children: [
                // Best-star badge row
                if (best > 0)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(
                      3,
                      (i) => Icon(
                        i < best ? Icons.star : Icons.star_border,
                        size: 10,
                        color: i < best
                            ? const Color(0xFFFFD54F)
                            : Colors.white24,
                      ),
                    ),
                  ),
                if (best > 0) const SizedBox(height: 2),
                Text(d.label,
                    style: TextStyle(
                      color: selected
                          ? Colors.white
                          : Colors.white54,
                      fontSize: 12,
                      fontWeight: selected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    )),
                Text('${d.columns}×${d.rows}',
                    style: TextStyle(
                      color: selected
                          ? Colors.white70
                          : Colors.white30,
                      fontSize: 10,
                    )),
              ]),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ── Ghost mode toggle ─────────────────────
  Widget _buildGhostModeToggle() {
    return GestureDetector(
      onTap: () {
        setState(() => _ghostMode = !_ghostMode);
        _restart();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: _ghostMode
              ? const Color(0xFF00BFA5).withOpacity(0.2)
              : Colors.white10,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _ghostMode
                ? const Color(0xFF00BFA5)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('',
              style: TextStyle(fontSize: _ghostMode ? 17 : 15)),
          const SizedBox(width: 8),
          Text('Ghost Mode',
              style: TextStyle(
                color: _ghostMode
                    ? const Color(0xFF00BFA5)
                    : Colors.white54,
                fontSize: 13,
                fontWeight: _ghostMode
                    ? FontWeight.bold
                    : FontWeight.normal,
              )),
          const SizedBox(width: 10),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 38,
            height: 20,
            decoration: BoxDecoration(
              color: _ghostMode
                  ? const Color(0xFF00BFA5)
                  : Colors.white24,
              borderRadius: BorderRadius.circular(10),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 200),
              alignment: _ghostMode
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  // ── Stats row ─────────────────────────────
  Widget _buildStatsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _chip(Icons.touch_app, 'Moves', '$_moves'),
        _buildTimerRing(),
        _chip(Icons.favorite, 'Pairs',
            '$_matchedPairs/${_difficulty.pairCount}'),
      ],
    );
  }

  // ── Live move-efficiency bar ──────────────
  // Green = on track for 3★, amber = 2★ zone, red = 1★
  Widget _buildEfficiencyBar() {
    final d          = _difficulty;
    final efficiency = d.efficiencyFor(_moves); // 1.0 → 0.0
    final stars      = d.starsFor(_moves);

    // Choose bar colour by current star level
    final barColor = stars == 3
        ? const Color(0xFF4CAF50)
        : stars == 2
            ? const Color(0xFFFFB300)
            : const Color(0xFFEF5350);

    // Label e.g. "★★★ 3 stars" live
    final starIcons = '★' * stars + '☆' * (3 - stars);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Efficiency',
                style: TextStyle(
                    color: Colors.white38, fontSize: 11),
              ),
              Row(children: [
                Text(
                  starIcons,
                  style: TextStyle(
                      color: barColor, fontSize: 12),
                ),
                const SizedBox(width: 4),
                Text(
                  '3★ in ≤${d.threeStar} moves',
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 10),
                ),
              ]),
            ],
          ),
          const SizedBox(height: 4),
          // The bar itself
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(children: [
              // Background track
              Container(
                  height: 6,
                  color: Colors.white10),
              // Filled portion — animates smoothly with every move
              AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOut,
                widthFactor: efficiency.clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: barColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              // Threshold tick: marks where 3★ ends and 2★ begins
              Positioned(
                // The tick is at the 3★ boundary
                left: MediaQuery.of(context).size.width *
                    0.0, // placeholder; tick is on the bar directly
                child: const SizedBox.shrink(),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _buildTimerRing() {
    final mins  = _secondsLeft ~/ 60;
    final secs  = _secondsLeft % 60;
    final label =
        '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';

    return ScaleTransition(
      scale: _secondsLeft <= 10
          ? _pulseAnim
          : const AlwaysStoppedAnimation(1.0),
      child: SizedBox(
        width: 66,
        height: 66,
        child: CustomPaint(
          painter: _TimerRingPainter(
            progress: _secondsLeft / _totalSeconds,
            color: _timerColor,
          ),
          child: Center(
            child: Text(label,
                style: TextStyle(
                  color: _timerColor,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
          ),
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, String value) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        Icon(icon, color: const Color(0xFF6C63FF), size: 14),
        const SizedBox(width: 5),
        Text('$label: ',
            style: const TextStyle(
                color: Colors.white60, fontSize: 12)),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
      ]),
    );
  }

  // ── Hint bar ──────────────────────────────
  Widget _buildHintBar() {
    final canUse = _hintsLeft > 0 && !_hintActive && !_gameOver;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: _hintActive
                  ? const Color(0xFFFFD54F).withOpacity(0.15)
                  : Colors.white10,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _hintActive
                    ? const Color(0xFFFFD54F).withOpacity(0.6)
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(children: [
              _buildTokenPips(),
              const Spacer(),
              _buildHintButton(canUse),
            ]),
          ),
          if (_hintActive)
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: LayoutBuilder(builder: (ctx, bc) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 50),
                  height: 3,
                  width: bc.maxWidth * _hintProgress,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFD54F),
                    borderRadius: BorderRadius.only(
                        bottomRight: Radius.circular(16)),
                  ),
                );
              }),
            ),
        ]),
      ),
    );
  }

  Widget _buildTokenPips() {
    final total = _difficulty.hintCount;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(total, (i) {
        final isSpent = i >= _hintsLeft;
        return Padding(
          padding: const EdgeInsets.only(right: 5),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width:  isSpent ? 18 : 22,
            height: isSpent ? 18 : 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSpent
                  ? Colors.white10
                  : const Color(0xFFFFD54F).withOpacity(0.85),
              border: Border.all(
                color: isSpent
                    ? Colors.white24
                    : const Color(0xFFFFD54F),
                width: isSpent ? 1 : 1.5,
              ),
            ),
            child: Center(
              child: Text(
                isSpent ? '✕' : '💡',
                style: TextStyle(
                    fontSize: isSpent ? 9 : 11,
                    color: isSpent
                        ? Colors.white30
                        : Colors.white),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildHintButton(bool canUse) {
    final String label;
    final Color  bgColor;
    final Color  textColor;

    if (_hintActive) {
      label     = '👁  Revealing… ${_hintCountdown}s';
      bgColor   = const Color(0xFFFFD54F).withOpacity(0.25);
      textColor = const Color(0xFFFFD54F);
    } else if (_hintsLeft <= 0) {
      label     = 'No hints left';
      bgColor   = Colors.white10;
      textColor = Colors.white30;
    } else {
      label     = '💡 Hint  ($_hintsLeft left)';
      bgColor   = const Color(0xFFFFD54F).withOpacity(0.2);
      textColor = const Color(0xFFFFD54F);
    }

    return GestureDetector(
      onTap: canUse ? _useHint : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: canUse
                ? const Color(0xFFFFD54F).withOpacity(0.5)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Text(label,
            style: TextStyle(
              color: textColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            )),
      ),
    );
  }

  // ── Ghost peek button ─────────────────────
  Widget _buildGhostPeekButton() {
    return GestureDetector(
      onTap: _ghostPeeking ? null : _triggerGhostPeek,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(
            horizontal: 20, vertical: 9),
        decoration: BoxDecoration(
          color: _ghostPeeking
              ? const Color(0xFF00BFA5).withOpacity(0.3)
              : Colors.white10,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _ghostPeeking
                ? const Color(0xFF00BFA5)
                : Colors.white24,
            width: 1,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 7),
          Text(
            _ghostPeeking ? 'Peeking…' : 'Peek (+5 moves)',
            style: TextStyle(
              color: _ghostPeeking
                  ? const Color(0xFF00BFA5)
                  : Colors.white60,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ]),
      ),
    );
  }

  // ── Dynamic grid ──────────────────────────
  Widget _buildGrid() {
    final d = _difficulty;
    return LayoutBuilder(builder: (context, constraints) {
      const spacing  = 8.0;
      const hPadding = 16.0;
      final cardSize = min(
        (constraints.maxWidth  - hPadding * 2 -
            spacing * (d.columns - 1)) / d.columns,
        (constraints.maxHeight - spacing * (d.rows    - 1)) / d.rows,
      );
      final fontSize = (cardSize * 0.42).clamp(14.0, 32.0);

      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: hPadding),
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            gridDelegate:
                SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount:   d.columns,
              crossAxisSpacing: spacing,
              mainAxisSpacing:  spacing,
            ),
            itemCount: d.cardCount,
            itemBuilder: (_, i) => _CardTile(
              card:         _cards[i],
              emojiFontSize: fontSize,
              ghostMode:    _ghostMode,
              ghostPeeking: _ghostPeeking,
              hintRevealed: _hintActive &&
                  !_cards[i].isMatched &&
                  !_cards[i].isFlipped &&
                  !_cards[i].isGone,
              onTap: () => _onTap(i),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildRestartButton() {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF6C63FF),
        padding: const EdgeInsets.symmetric(
            horizontal: 28, vertical: 12),
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
  final Color  color;
  const _TimerRingPainter(
      {required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 8) / 2;

    canvas.drawCircle(center, radius,
        Paint()
          ..color       = Colors.white12
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap   = StrokeCap.round);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      2 * pi * progress,
      false,
      Paint()
        ..color       = color
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap   = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_TimerRingPainter o) =>
      o.progress != progress || o.color != color;
}

// ════════════════════════════════════════════
// _CardTile
// ════════════════════════════════════════════
class _CardTile extends StatelessWidget {
  final CardModel    card;
  final VoidCallback onTap;
  final double       emojiFontSize;
  final bool         ghostMode;
  final bool         ghostPeeking;
  final bool         hintRevealed;

  const _CardTile({
    required this.card,
    required this.onTap,
    required this.emojiFontSize,
    required this.ghostMode,
    required this.ghostPeeking,
    required this.hintRevealed,
  });

  @override
  Widget build(BuildContext context) {
    if (card.isGone) {
      return AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: ghostPeeking ? 0.6 : 0.0,
        child: ghostPeeking
            ? _face(
                key: const ValueKey('peek'),
                color: const Color(0xFF00BFA5).withOpacity(0.35),
                child: Text(card.emoji,
                    style: TextStyle(fontSize: emojiFontSize)),
              )
            : _ghostSlot(),
      );
    }

    Color faceColor;
    if (card.isMatched && ghostMode) {
      faceColor = const Color(0xFF00BFA5);
    } else if (card.isMatched) {
      faceColor = const Color(0xFF2E7D32);
    } else if (hintRevealed) {
      faceColor = const Color(0xFFFF8F00).withOpacity(0.85);
    } else if (card.isFlipped) {
      faceColor = const Color(0xFF5C6BC0);
    } else {
      faceColor = const Color(0xFF3D3A8C);
    }

    final showFace =
        card.isFlipped || card.isMatched || hintRevealed;

    Widget tile = GestureDetector(
      onTap: onTap,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        transitionBuilder: (child, animation) {
          final rotate =
              Tween(begin: pi, end: 0.0).animate(animation);
          return AnimatedBuilder(
            animation: rotate,
            child: child,
            builder: (_, child) {
              final isFront =
                  const ValueKey(true) == child!.key;
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
        child: showFace
            ? _face(
                key: const ValueKey(true),
                color: faceColor,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Text(card.emoji,
                        style: TextStyle(
                            fontSize: emojiFontSize)),
                    if (hintRevealed)
                      Container(
                        width:  emojiFontSize * 1.8,
                        height: emojiFontSize * 1.8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFFFD54F)
                                .withOpacity(0.6),
                            width: 2,
                          ),
                        ),
                      ),
                  ],
                ),
              )
            : _face(
                key: const ValueKey(false),
                color: const Color(0xFF3D3A8C),
                child: Text('❓',
                    style: TextStyle(
                        fontSize: emojiFontSize * 0.85)),
              ),
      ),
    );

    if (ghostMode && card.isMatched) {
      tile = AnimatedOpacity(
          duration: const Duration(milliseconds: 500),
          opacity: 0.0,
          child: tile);
    }

    return tile;
  }

  Widget _ghostSlot() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: const Color(0xFF00BFA5).withOpacity(0.25),
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Text('👻',
            style: TextStyle(fontSize: emojiFontSize * 0.6)),
      ),
    );
  }

  Widget _face(
      {required Key key,
      required Color color,
      required Widget child}) {
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
// _WinDialog — animated star reveal
// Stars drop in one-by-one with a bounce.
// ════════════════════════════════════════════
class _WinDialog extends StatefulWidget {
  final int        stars;
  final int        moves;
  final int        secondsLeft;
  final Difficulty difficulty;
  final VoidCallback onPressed;

  const _WinDialog({
    required this.stars,
    required this.moves,
    required this.secondsLeft,
    required this.difficulty,
    required this.onPressed,
  });

  @override
  State<_WinDialog> createState() => _WinDialogState();
}

class _WinDialogState extends State<_WinDialog>
    with TickerProviderStateMixin {

  // One AnimationController per star slot
  late final List<AnimationController> _ctrls;
  late final List<Animation<double>>   _scales;
  late final List<Animation<double>>   _opacities;

  @override
  void initState() {
    super.initState();

    _ctrls = List.generate(
      3,
      (_) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 400),
      ),
    );

    // Bounce curve: overshoot then settle
    _scales = _ctrls.map((c) =>
      Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: c, curve: Curves.elasticOut),
      ),
    ).toList();

    _opacities = _ctrls.map((c) =>
      Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: c,
            curve: const Interval(0.0, 0.4, curve: Curves.easeIn)),
      ),
    ).toList();

    // Stagger: star 0 at 300 ms, star 1 at 600 ms, star 2 at 900 ms
    for (int i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: 300 + i * 300), () {
        if (mounted) _ctrls[i].forward();
      });
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) c.dispose();
    super.dispose();
  }

  // Star label copy
  String get _label {
    switch (widget.stars) {
      case 3: return 'Perfect! 🏆';
      case 2: return 'Well done! 👏';
      default: return 'Completed! 🎉';
    }
  }

  String get _subLabel {
    final d = widget.difficulty;
    return '${widget.moves} moves  •  '
        '${widget.secondsLeft}s left\n'
        '3★ in ≤${d.threeStar}  •  2★ in ≤${d.twoStar}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1B4B),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24)),
      contentPadding:
          const EdgeInsets.fromLTRB(24, 24, 24, 16),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Animated stars ───────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(3, (i) {
              final earned = i < widget.stars;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: FadeTransition(
                  opacity: _opacities[i],
                  child: ScaleTransition(
                    scale: _scales[i],
                    child: Icon(
                      earned ? Icons.star_rounded
                             : Icons.star_outline_rounded,
                      size:  earned ? 52 : 44,
                      color: earned
                          ? const Color(0xFFFFD54F)
                          : Colors.white24,
                    ),
                  ),
                ),
              );
            }),
          ),

          const SizedBox(height: 16),

          // ── Title ────────────────────────
          Text(
            _label,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 22,
                color: Colors.white,
                fontWeight: FontWeight.bold),
          ),

          const SizedBox(height: 10),

          // ── Stats ────────────────────────
          Text(
            _subLabel,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white54,
                fontSize: 13,
                height: 1.6),
          ),

          const SizedBox(height: 20),

          // ── Play Again button ────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(
                    vertical: 14),
              ),
              icon: const Icon(Icons.replay, color: Colors.white),
              label: const Text('Play Again',
                  style: TextStyle(
                      color: Colors.white, fontSize: 15)),
              onPressed: widget.onPressed,
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════
// _GameDialog — reusable simple dialog
// ════════════════════════════════════════════
class _GameDialog extends StatelessWidget {
  final String title, body, buttonLabel;
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
          style: const TextStyle(
              fontSize: 24, color: Colors.white)),
      content: Text(body,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white70,
              fontSize: 15,
              height: 1.6)),
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
              style: const TextStyle(
                  color: Colors.white, fontSize: 15)),
          onPressed: onPressed,
        ),
      ],
    );
  }
}
