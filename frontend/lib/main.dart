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

  // === TUNED THRESHOLDS ===
  static const double _voiceThreshold = -28.0;  // Normal speaking level
  static const int _silenceToStopMs = 2600;     // 2.6s pause: she will NEVER cut you off mid-sentence
  static const double _bargeThreshold = -20.0;  // Sensitive enough to interrupt with normal speaking voice

  double _currentDb = -60.0;
  final List<Map<String, String>> _history = [];

  bool _autoListen = true;
  bool _isBusy = false;
  bool _bargedIn = false;
  int _emptyTries = 0;

  Timer? _ttsSafetyTimer;
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

    
  }

  @override
  void dispose() {
    _ttsSafetyTimer?.cancel();
    _pulse.dispose();
    _rotate.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _setupTts() async {
    await _tts.awaitSpeakCompletion(false);
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
    await _tts.setSpeechRate(0.50);

    _tts.setCompletionHandler(() => _handleSpeakComplete());
    _tts.setCancelHandler(() => _handleSpeakComplete());
    _tts.setErrorHandler((_) => _handleSpeakComplete());
  }


Future<void> _handleSpeakComplete() async {
    _ttsSafetyTimer?.cancel();
    await _stopBargeIn();
    if (!mounted) return;

    final wasBarge = _bargedIn;
    _bargedIn = false;

    if (wasBarge) {
      setState(() {
        _currentState = AIState.listening;
        _conversationText = 'Listening to you...';
      });
      // 400ms pause to let Windows audio release mic cleanly
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) _listenOnce();
    } else if (_autoListen) {
      setState(() => _currentState = AIState.idle);
      await Future.delayed(const Duration(milliseconds: 250));
      if (mounted) _listenOnce();
    } else {
      setState(() => _currentState = AIState.idle);
    }
  }


  String _cleanTextForTts(String raw) {
    return raw
        .replaceAll(RegExp(r'\*.*?\*'), '')
        .replaceAll(RegExp(r'[#*_~`"]'), '')
        .replaceAll(RegExp(r'\(.*?\)'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _speak(String text) async {
    _ttsSafetyTimer?.cancel();
    final cleanSpeech = _cleanTextForTts(text);

    if (cleanSpeech.isEmpty) {
      _handleSpeakComplete();
      return;
    }

    setState(() => _currentState = AIState.speaking);
    _bargedIn = false;

    await _startBargeIn();
    await _tts.speak(cleanSpeech);

    final wordCount = cleanSpeech.split(' ').length;
    final estimatedSeconds = (wordCount / 2.3).clamp(2.0, 35.0);
    _ttsSafetyTimer = Timer(Duration(milliseconds: (estimatedSeconds * 1000).toInt() + 1500), () {
      if (_currentState == AIState.speaking) {
        _handleSpeakComplete();
      }
    });
  }

Future<void> _startBargeIn() async {
    if (!await _recorder.hasPermission()) return;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
      final dir = await getTemporaryDirectory();
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav),
        path: '${dir.path}/bargein.wav',
      );
    } catch (_) {
      return;
    }

    final startedAt = DateTime.now();
    DateTime? loudStartTime;

    _bargeSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 50))
        .listen((amp) async {
      if (mounted) setState(() => _currentDb = amp.current);

      // Give her 500ms to begin speaking cleanly
      if (DateTime.now().difference(startedAt).inMilliseconds < 500) return;

      if (amp.current > _bargeThreshold) {
        loudStartTime ??= DateTime.now();
        final duration = DateTime.now().difference(loudStartTime!).inMilliseconds;
        
        // 180ms of normal speaking voice instantly halts her
        if (duration >= 180 && !_bargedIn && _currentState == AIState.speaking) {
          _bargedIn = true;
          await _tts.stop();
          await _handleSpeakComplete();
        }
      } else {
        loudStartTime = null;
      }
    });
  }

  Future<void> _stopBargeIn() async {
    await _bargeSub?.cancel();
    _bargeSub = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
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

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav),
        path: path,
      );
    } catch (e) {
      _isBusy = false;
      setState(() => _currentState = AIState.idle);
      return;
    }

    setState(() {
      _currentState = AIState.listening;
      _conversationText = 'Listening...';
    });

    final start = DateTime.now();
    DateTime? lastVoiceHeard;
    bool speechDetected = false;
    final done = Completer<void>();

    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen((amp) {
      final now = DateTime.now();
      if (mounted) setState(() => _currentDb = amp.current);

      if (amp.current > _voiceThreshold) {
        speechDetected = true;
        lastVoiceHeard = now;
      }

      final elapsed = now.difference(start).inMilliseconds;
      final silentFor =
          lastVoiceHeard == null ? 0 : now.difference(lastVoiceHeard!).inMilliseconds;

      if (elapsed > 25000) {
        if (!done.isCompleted) done.complete();
      } else if (speechDetected && silentFor > _silenceToStopMs && elapsed > 800) {
        if (!done.isCompleted) done.complete();
      } else if (!speechDetected && elapsed > 5000) {
        if (!done.isCompleted) done.complete();
      }
    });

    await done.future;
    await _ampSub?.cancel();
    _ampSub = null;

    final saved = await _recorder.stop();
    _isBusy = false;
    if (saved == null) return;

    if (!speechDetected) {
      // Never go to IDLE: immediately keep listening!
      if (mounted) _listenOnce();
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
                  GestureDetector(
                    onTap: () {
                      if (_currentState == AIState.speaking) {
                        _tts.stop();
                        _handleSpeakComplete();
                      } else if (_currentState == AIState.idle) {
                        _listenOnce();
                      }
                    },
                    child: _animatedOrb(color),
                  ),
                  const SizedBox(height: 12),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    style: TextStyle(
                      color: color,
                      letterSpacing: 2,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                    child: Text('STATUS: ${_currentState.name.toUpperCase()}'),
                  ),
                  const SizedBox(height: 4),
                  _liveAudioMeter(),
                  const SizedBox(height: 16),
                  _conversationBox(),
                  const SizedBox(height: 14),
                  _inputRow(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _liveAudioMeter() {
    final normalized = ((_currentDb + 60) / 60).clamp(0.0, 1.0);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'MIC LEVEL: ${_currentDb.toStringAsFixed(1)} dB (TRIGGER: $_voiceThreshold dB)',
              style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), letterSpacing: 1.2),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 220,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: normalized,
              backgroundColor: const Color(0xFF1E293B),
              valueColor: AlwaysStoppedAnimation<Color>(
                _currentDb > _voiceThreshold ? const Color(0xFF00E676) : const Color(0xFF00E5FF),
              ),
              minHeight: 4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _titleBar() {
    return Container(
      height: 40,
      color: const Color(0xFF070A10),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: const Row(
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
    );
  }

  Widget _animatedOrb(Color color) {
    return SizedBox(
      width: 170,
      height: 170,
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
                  size: const Size(170, 170),
                  painter: _RingPainter(color),
                ),
              ),
              Transform.scale(
                scale: scale,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  width: 120,
                  height: 120,
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
                    child: Icon(_getStateIcon(), size: 46, color: color),
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
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF1E293B)),
        ),
        child: SingleChildScrollView(
          child: Text(
            _conversationText,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF94A3B8),
              height: 1.5,
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
          mini: true,
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
            size: 18,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _inputController,
            focusNode: _inputFocus,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Type message or speak...',
              hintStyle: const TextStyle(color: Color(0xFF64748B)),
              filled: true,
              fillColor: const Color(0xFF121826),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF1E293B)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF1E293B)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF00E5FF)),
              ),
            ),
            onSubmitted: (_) => _sendMessage(),
          ),
        ),
        const SizedBox(width: 12),
        FloatingActionButton(
          mini: true,
          heroTag: 'send',
          onPressed: () => _sendMessage(),
          backgroundColor: const Color(0xFF00E5FF),
          child: const Icon(Icons.send, color: Color(0xFF0A0E17), size: 18),
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