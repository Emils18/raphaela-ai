import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const RaphaelaApp());
}

class RaphaelaApp extends StatelessWidget {
  const RaphaelaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Raphaela',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0E17),
        primaryColor: const Color(0xFF00E5FF),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFF7C4DFF),
          surface: Color(0xFF121826),
        ),
        fontFamily: 'Segoe UI',
      ),
      home: const RaphaelaHomeScreen(),
    );
  }
}

enum AIState { idle, listening, thinking, speaking }

class RaphaelaHomeScreen extends StatefulWidget {
  const RaphaelaHomeScreen({super.key});

  @override
  State<RaphaelaHomeScreen> createState() => _RaphaelaHomeScreenState();
}

class _RaphaelaHomeScreenState extends State<RaphaelaHomeScreen>
    with TickerProviderStateMixin {
  AIState _currentState = AIState.idle;
  String _conversationText = 'System online. Raphaela standing by.';
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final FlutterTts _tts = FlutterTts();
  final AudioRecorder _recorder = AudioRecorder();
  static const String _backendUrl = 'http://127.0.0.1:8000';

  // === TUNABLES ===
  static const double _voiceThreshold = -28;   // higher = stricter (only louder voice triggers)
  static const int _minVoiceDurationMs = 400;  // sustained speech needed
  static const int _silenceToStopMs = 10000;   // 10s silence -> done talking
  static const int _bargeThreshold = -20;      // barge-in trigger level
  static const int _bargeSustainMs = 250;      // must speak this long to interrupt
  static const int _bargeIgnoreMs = 500;       // ignore first 500ms of her speaking

  // Conversation history — remembered across turns and interrupts
  final List<Map<String, String>> _history = [];

  bool _autoListen = true;
  bool _isBusy = false;
  bool _bargedIn = false;
  int _emptyTries = 0;

  StreamSubscription<Amplitude>? _ampSub;
  StreamSubscription<Amplitude>? _bargeSub;

  late AnimationController _pulse;
  late AnimationController _rotate;

  @override
  void initState() {
    super.initState();

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _rotate = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();

    _setupTts();

    _inputFocus.addListener(() {
      if (_inputFocus.hasFocus) _autoListen = false;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _rotate.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _setupTts() async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.setLanguage('en-US');

    try {
      final voices = await _tts.getVoices;
      if (voices is List) {
        for (final v in voices) {
          final name = (v['name'] ?? '').toString();
          if (name.toLowerCase().contains('zira')) {
            await _tts.setVoice({
              'name': name,
              'locale': (v['locale'] ?? 'en-US').toString(),
            });
            break;
          }
        }
      }
    } catch (_) {}

    await _tts.setPitch(1.15);
    await _tts.setSpeechRate(0.48);

    _tts.setCompletionHandler(() => _handleSpeakComplete());
  }

  Future<void> _handleSpeakComplete() async {
    await _stopBargeIn();
    if (!mounted) return;
    setState(() => _currentState = AIState.idle);

    final wasBarge = _bargedIn;
    _bargedIn = false;

    if (wasBarge) {
      // User interrupted → listen right away
      Future.delayed(const Duration(milliseconds: 150), _listenOnce);
    } else if (_autoListen) {
      Future.delayed(const Duration(milliseconds: 300), _listenOnce);
    }
  }

  Future<void> _speak(String text) async {
    setState(() => _currentState = AIState.speaking);
    _bargedIn = false;
    await _startBargeIn();
    await _tts.speak(text);
  }

  Future<void> _startBargeIn() async {
    if (!await _recorder.hasPermission()) return;
    try {
      final dir = await getTemporaryDirectory();
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav),
        path: '${dir.path}/bargein.wav',
      );
    } catch (_) {
      return;
    }

    final startedAt = DateTime.now();
    DateTime? sustained;

    _bargeSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 80))
        .listen((amp) {
      // Ignore her own TTS kickoff
      if (DateTime.now().difference(startedAt).inMilliseconds < _bargeIgnoreMs) {
        return;
      }
      if (amp.current > _bargeThreshold) {
        sustained ??= DateTime.now();
        if (!_bargedIn &&
            DateTime.now().difference(sustained!).inMilliseconds >=
                _bargeSustainMs) {
          _bargedIn = true;
          _tts.stop();
        }
      } else {
        sustained = null;
      }
    });
  }

  Future<void> _stopBargeIn() async {
    await _bargeSub?.cancel();
    _bargeSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
  }

  Future<void> _listenOnce() async {
    if (_isBusy || !mounted) return;
    if (!await _recorder.hasPermission()) {
      setState(() {
        _autoListen = false;
        _conversationText = 'Microphone permission denied.';
      });
      return;
    }
    _isBusy = true;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/raphaela_input.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: path,
    );
    setState(() {
      _currentState = AIState.listening;
      _conversationText = 'Listening...';
    });

    final start = DateTime.now();
    DateTime? lastLoud;
    DateTime? sustainedStart;
    bool voiceConfirmed = false;
    final done = Completer<void>();

    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 120))
        .listen((amp) {
      final now = DateTime.now();

      if (amp.current > _voiceThreshold) {
        sustainedStart ??= now;
        // Require minimum sustained voice to count as real speech
        if (!voiceConfirmed &&
            now.difference(sustainedStart!).inMilliseconds >=
                _minVoiceDurationMs) {
          voiceConfirmed = true;
        }
        lastLoud = now;
      } else {
        sustainedStart = null;
      }

      final elapsed = now.difference(start).inMilliseconds;
      final silentFor =
          lastLoud == null ? 0 : now.difference(lastLoud!).inMilliseconds;

      // Hard safety 60s
      if (elapsed > 60000) {
        if (!done.isCompleted) done.complete();
      }
      // Only stop early if we confirmed real speech AND user is quiet
      else if (voiceConfirmed &&
          silentFor > _silenceToStopMs &&
          elapsed > 1500) {
        if (!done.isCompleted) done.complete();
      }
    });

    await done.future;
    await _ampSub?.cancel();
    _ampSub = null;

    final saved = await _recorder.stop();
    _isBusy = false;
    if (saved == null) return;

    // Never heard real speech? Skip Whisper entirely
    if (!voiceConfirmed) {
      _emptyTries++;
      if (_autoListen && _emptyTries < 3) {
        _listenOnce();
      } else {
        setState(() {
          _currentState = AIState.idle;
          _emptyTries = 0;
        });
      }
      return;
    }

    setState(() => _currentState = AIState.thinking);
    final text = await _transcribe(saved);

    if (text == null || text.trim().isEmpty) {
      _emptyTries++;
      if (_autoListen && _emptyTries < 3) {
        _listenOnce();
      } else {
        setState(() {
          _currentState = AIState.idle;
          _emptyTries = 0;
        });
      }
      return;
    }

    _emptyTries = 0;
    _inputController.text = text;
    await _sendMessage();
  }

  Future<String?> _transcribe(String audioPath) async {
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_backendUrl/transcribe'),
      );
      req.files.add(await http.MultipartFile.fromPath('file', audioPath));
      final streamed = await req.send();
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return (data['text'] ?? '').toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    _history.add({'role': 'user', 'content': text});

    setState(() {
      _currentState = AIState.thinking;
      _conversationText = 'You: $text\n\nRaphaela is thinking...';
    });
    _inputController.clear();

    try {
      final resp = await http.post(
        Uri.parse('$_backendUrl/chat'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'messages': _history}),
      );

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final reply = data['response'].toString();
        _history.add({'role': 'assistant', 'content': reply});
        setState(() {
          _conversationText = 'You: $text\n\nRaphaela: $reply';
        });
        await _speak(reply);
      } else {
        _history.removeLast();
        setState(() {
          _currentState = AIState.idle;
          _conversationText = 'Error: ${resp.statusCode}';
        });
      }
    } catch (e) {
      _history.removeLast();
      setState(() {
        _currentState = AIState.idle;
        _conversationText = 'Connection error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _getStateColor();
    return Scaffold(
      body: Column(
        children: [
          _titleBar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  _animatedOrb(color),
                  const SizedBox(height: 16),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 400),
                    style: TextStyle(
                      color: color,
                      letterSpacing: 2,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                    child: Text('STATUS: ${_currentState.name.toUpperCase()}'),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _autoListen ? 'AUTO-LISTEN: ON' : 'AUTO-LISTEN: OFF',
                    style: TextStyle(
                      color: _autoListen
                          ? const Color(0xFF00E676)
                          : const Color(0xFF64748B),
                      fontSize: 10,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _conversationBox(),
                  const SizedBox(height: 16),
                  _inputRow(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _titleBar() {
    return Container(
      height: 40,
      color: const Color(0xFF070A10),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Row(
            children: [
              Icon(Icons.hexagon, color: Color(0xFF00E5FF), size: 18),
              SizedBox(width: 8),
              Text(
                'RAPHAELA // PERSONAL AI',
                style: TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 12,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove, size: 16),
                onPressed: () {},
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: () {},
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _animatedOrb(Color color) {
    return SizedBox(
      width: 200,
      height: 200,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulse, _rotate]),
        builder: (context, _) {
          final scale = 1.0 + (_pulse.value * 0.08);
          final glow = 20.0 + (_pulse.value * 25.0);
          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.rotate(
                angle: _rotate.value * 2 * 3.14159,
                child: CustomPaint(
                  size: const Size(200, 200),
                  painter: _RingPainter(color),
                ),
              ),
              Transform.scale(
                scale: scale,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        color.withValues(alpha: 0.55),
                        const Color(0xFF0A0E17),
                      ],
                    ),
                    border: Border.all(color: color, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.45),
                        blurRadius: glow,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Icon(_getStateIcon(), size: 52, color: color),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _conversationBox() {
    return Expanded(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF1E293B)),
        ),
        child: SingleChildScrollView(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child: Text(
              _conversationText,
              key: ValueKey(_conversationText),
              style: const TextStyle(
                fontSize: 15,
                color: Color(0xFF94A3B8),
                height: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _inputRow() {
    return Row(
      children: [
        FloatingActionButton(
          heroTag: 'mic',
          onPressed: () {
            setState(() {
              _autoListen = !_autoListen;
              _emptyTries = 0;
            });
            if (_autoListen && _currentState == AIState.idle) {
              _listenOnce();
            }
          },
          backgroundColor:
              _autoListen ? const Color(0xFF7C4DFF) : const Color(0xFF374151),
          child: Icon(
            _autoListen ? Icons.mic : Icons.mic_off,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _inputController,
            focusNode: _inputFocus,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Type to Raphaela (pauses auto-listen)...',
              hintStyle: const TextStyle(color: Color(0xFF64748B)),
              filled: true,
              fillColor: const Color(0xFF121826),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF1E293B)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF1E293B)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF00E5FF)),
              ),
            ),
            onSubmitted: (_) => _sendMessage(),
          ),
        ),
        const SizedBox(width: 12),
        FloatingActionButton(
          heroTag: 'send',
          onPressed: () => _sendMessage(),
          backgroundColor: const Color(0xFF00E5FF),
          child: const Icon(Icons.send, color: Color(0xFF0A0E17)),
        ),
      ],
    );
  }

  Color _getStateColor() {
    switch (_currentState) {
      case AIState.idle:
        return const Color(0xFF00E5FF);
      case AIState.listening:
        return const Color(0xFF00E676);
      case AIState.thinking:
        return const Color(0xFFFFEA00);
      case AIState.speaking:
        return const Color(0xFF7C4DFF);
    }
  }

  IconData _getStateIcon() {
    switch (_currentState) {
      case AIState.idle:
        return Icons.power_settings_new;
      case AIState.listening:
        return Icons.mic;
      case AIState.thinking:
        return Icons.psychology;
      case AIState.speaking:
        return Icons.volume_up;
    }
  }
}

class _RingPainter extends CustomPainter {
  final Color color;
  _RingPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final center = Offset(size.width / 2, size.height / 2);
    const segments = 24;
    const gap = 0.06;
    for (int i = 0; i < segments; i++) {
      final start = (i / segments) * 2 * 3.14159;
      final sweep = (2 * 3.14159 / segments) - gap;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: size.width / 2 - 4),
        start,
        sweep,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}