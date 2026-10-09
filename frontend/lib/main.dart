import 'package:flutter/material.dart';
import 'dart:convert';
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

class _RaphaelaHomeScreenState extends State<RaphaelaHomeScreen> {
  AIState _currentState = AIState.idle;
  String _conversationText = 'System online. Raphaela standing by.';
  final TextEditingController _inputController = TextEditingController();
  final FlutterTts _tts = FlutterTts();
  final AudioRecorder _recorder = AudioRecorder();
  static const String _backendUrl = 'http://127.0.0.1:8000';

  @override
  void initState() {
    super.initState();
    _setupTts();
  }

  Future<void> _setupTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setPitch(1.1);
    await _tts.setSpeechRate(0.5);
    await _tts.awaitSpeakCompletion(true);
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _currentState = AIState.idle);
    });
  }

  Future<void> _speak(String text) async {
    setState(() => _currentState = AIState.speaking);
    await _tts.speak(text);
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _currentState = AIState.thinking;
      _conversationText = 'You: $text\n\nRaphaela is thinking...';
    });
    _inputController.clear();

    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/chat'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'message': text}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final reply = data['response'].toString();
        setState(() {
          _conversationText = 'You: $text\n\nRaphaela: $reply';
        });
        await _speak(reply);
      } else {
        setState(() {
          _currentState = AIState.idle;
          _conversationText = 'Error: ${response.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _currentState = AIState.idle;
        _conversationText = 'Connection error: $e';
      });
    }
  }

  Future<void> _toggleRecording() async {
    if (_currentState == AIState.listening) {
      final path = await _recorder.stop();
      if (path == null) return;
      setState(() {
        _currentState = AIState.thinking;
        _conversationText = 'Transcribing...';
      });
      await _transcribeAndRespond(path);
      return;
    }

    if (!await _recorder.hasPermission()) {
      setState(() {
        _conversationText = 'Microphone permission denied.';
      });
      return;
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/raphaela_input.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: path,
    );
    setState(() {
      _currentState = AIState.listening;
      _conversationText = 'Listening... (tap mic again to stop)';
    });
  }

  Future<void> _transcribeAndRespond(String audioPath) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_backendUrl/transcribe'),
      );
      request.files.add(await http.MultipartFile.fromPath('file', audioPath));
      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode != 200) {
        setState(() {
          _currentState = AIState.idle;
          _conversationText = 'Transcription failed: ${response.statusCode}';
        });
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final userText = (data['text'] ?? '').toString().trim();

      if (userText.isEmpty) {
        setState(() {
          _currentState = AIState.idle;
          _conversationText = "I didn't catch that. Try again?";
        });
        return;
      }

      _inputController.text = userText;
      await _sendMessage();
    } catch (e) {
      setState(() {
        _currentState = AIState.idle;
        _conversationText = 'Voice error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Container(
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
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          _getStateColor().withValues(alpha: 0.4),
                          const Color(0xFF0A0E17),
                        ],
                      ),
                      border: Border.all(color: _getStateColor(), width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: _getStateColor().withValues(alpha: 0.3),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: Center(
                      child: Icon(
                        _getStateIcon(),
                        size: 48,
                        color: _getStateColor(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'STATUS: ${_currentState.name.toUpperCase()}',
                    style: TextStyle(
                      color: _getStateColor(),
                      letterSpacing: 2,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121826),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          _conversationText,
                          style: const TextStyle(
                            fontSize: 15,
                            color: Color(0xFF94A3B8),
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      FloatingActionButton(
                        heroTag: 'mic',
                        onPressed: _toggleRecording,
                        backgroundColor: _currentState == AIState.listening
                            ? const Color(0xFFE53935)
                            : const Color(0xFF7C4DFF),
                        child: Icon(
                          _currentState == AIState.listening
                              ? Icons.stop
                              : Icons.mic,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Type a message to Raphaela...',
                            hintStyle:
                                const TextStyle(color: Color(0xFF64748B)),
                            filled: true,
                            fillColor: const Color(0xFF121826),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  const BorderSide(color: Color(0xFF1E293B)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  const BorderSide(color: Color(0xFF1E293B)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  const BorderSide(color: Color(0xFF00E5FF)),
                            ),
                          ),
                          onSubmitted: (_) => _sendMessage(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FloatingActionButton(
                        heroTag: 'send',
                        onPressed: _sendMessage,
                        backgroundColor: const Color(0xFF00E5FF),
                        child:
                            const Icon(Icons.send, color: Color(0xFF0A0E17)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
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