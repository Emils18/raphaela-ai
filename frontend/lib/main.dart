import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

void main() { runApp(const RaphaelaApp()); }

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
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF00E5FF),
          secondary: const Color(0xFF7C4DFF),
          surface: const Color(0xFF121826),
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
  final String _backendUrl = 'http://127.0.0.1:8000';

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _currentState = AIState.thinking;
      _conversationText = 'You: ' + text + '\n\nRaphaela is thinking...';
    });
    _inputController.clear();
    try {
      final response = await http.post(
        Uri.parse(_backendUrl + '/chat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'message': text}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _currentState = AIState.speaking;
          _conversationText = 'You: ' + text + '\n\nRaphaela: ' + data['response'].toString();
        });
      } else {
        setState(() {
          _currentState = AIState.idle;
          _conversationText = 'Error: ' + response.statusCode.toString();
        });
      }
    } catch (e) {
      setState(() {
        _currentState = AIState.idle;
        _conversationText = 'Connection error: ' + e.toString();
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
                const Row(children: [
                  Icon(Icons.hexagon, color: Color(0xFF00E5FF), size: 18),
                  SizedBox(width: 8),
                  Text('RAPHAELA // PERSONAL AI', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
                ]),
                Row(children: [
                  IconButton(icon: const Icon(Icons.remove, size: 16), onPressed: () {}),
                  IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () {}),
                ]),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  Container(
                    width: 120, height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [_getStateColor().withOpacity(0.4), const Color(0xFF0A0E17)]),
                      border: Border.all(color: _getStateColor(), width: 2),
                      boxShadow: [BoxShadow(color: _getStateColor().withOpacity(0.3), blurRadius: 20, spreadRadius: 5)],
                    ),
                    child: Center(child: Icon(_getStateIcon(), size: 48, color: _getStateColor())),
                  ),
                  const SizedBox(height: 12),
                  Text('STATUS: ' + _currentState.name.toUpperCase(), style: TextStyle(color: _getStateColor(), letterSpacing: 2, fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 24),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(color: const Color(0xFF121826), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF1E293B))),
                      child: SingleChildScrollView(
                        child: Text(_conversationText, style: const TextStyle(fontSize: 15, color: Color(0xFF94A3B8), height: 1.5)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Type a message to Raphaela...',
                            hintStyle: const TextStyle(color: Color(0xFF64748B)),
                            filled: true,
                            fillColor: const Color(0xFF121826),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF1E293B))),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF1E293B))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00E5FF))),
                          ),
                          onSubmitted: (_) => _sendMessage(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FloatingActionButton(
                        onPressed: _sendMessage,
                        backgroundColor: const Color(0xFF00E5FF),
                        child: const Icon(Icons.send, color: Color(0xFF0A0E17)),
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
      case AIState.idle: return const Color(0xFF00E5FF);
      case AIState.listening: return const Color(0xFF00E676);
      case AIState.thinking: return const Color(0xFFFFEA00);
      case AIState.speaking: return const Color(0xFF7C4DFF);
    }
  }

  IconData _getStateIcon() {
    switch (_currentState) {
      case AIState.idle: return Icons.power_settings_new;
      case AIState.listening: return Icons.mic;
      case AIState.thinking: return Icons.psychology;
      case AIState.speaking: return Icons.volume_up;
    }
  }
}
