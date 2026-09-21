import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() {
  runApp(const PixelTvCommanderApp());
}

class PixelTvCommanderApp extends StatelessWidget {
  const PixelTvCommanderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pixel TV Commander',
      theme: ThemeData.dark(useMaterial3: true),
      home: const DashboardScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _commandController = TextEditingController();
  
  String _statusText = "Stack Status: Ready (Tailscale 100.64.152.108)";
  final List<String> _consoleLogs = [
    "[INFO] Initialized Pixel TV Commander",
    "[INFO] Ready for D-pad navigation or Bluetooth keyboard input"
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_focusNode);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _commandController.dispose();
    super.dispose();
  }

  Future<void> _executeCommand(String command) async {
    if (command.trim().isEmpty) return;

    setState(() {
      _consoleLogs.add("root@pixel:~# $command");
    });
    _commandController.clear();

    try {
      final response = await http.post(
        Uri.parse('http://100.64.152.108:8080/v1/chat/completions'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "model": "local-model",
          "messages": [{"role": "user", "content": command}]
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final reply = data['choices']?[0]?['message']?['content'] ?? "Command executed.";
        setState(() {
          _consoleLogs.add("[LLM] $reply");
        });
      } else {
        setState(() {
          _consoleLogs.add("[ERROR] Server returned status: ${response.statusCode}");
        });
      }
    } catch (e) {
      setState(() {
        _consoleLogs.add("[LOG] Dispatched command locally / Network timeout: $e");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Focus(
        focusNode: _focusNode,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.enter) {
              _executeCommand(_commandController.text);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Pixel TV Commander',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  Text(
                    _statusText,
                    style: const TextStyle(fontSize: 14, color: Colors.greenAccent),
                  ),
                ],
              ),
              const Divider(height: 30, color: Colors.grey),

              // Main Workspace Split
              Expanded(
                child: Row(
                  children: [
                    // Left Column: Quick Actions / Cards (D-pad navigable)
                    Expanded(
                      flex: 1,
                      child: Column(
                        children: [
                          _buildActionCard("Ping Stack Status", () {
                            setState(() => _consoleLogs.add("[INFO] Pinging Tailscale services..."));
                          }),
                          const SizedBox(height: 12),
                          _buildActionCard("Restart llama-server", () {
                            _executeCommand("systemctl restart llama-server");
                          }),
                          const SizedBox(height: 12),
                          _buildActionCard("Check Matrix Bot Logs", () {
                            _executeCommand("journalctl -u matrix-bot -n 20");
                          }),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),

                    // Right Column: Terminal Console Output
                    Expanded(
                      flex: 2,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade800),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Terminal Output & Logs',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey),
                            ),
                            const Divider(color: Colors.grey),
                            Expanded(
                              child: ListView.builder(
                                itemCount: _consoleLogs.length,
                                itemBuilder: (context, index) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                                    child: Text(
                                      _consoleLogs[index],
                                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.lightGreenAccent),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 10),
                            // Command Input Row for Bluetooth Keyboard
                            Row(
                              children: [
                                const Text("root@pixel:\$ ", style: TextStyle(color: Colors.green, fontFamily: 'monospace')),
                                Expanded(
                                  child: TextField(
                                    controller: _commandController,
                                    style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
                                    decoration: const InputDecoration(
                                      hintText: "Type command or prompt...",
                                      hintStyle: TextStyle(color: Colors.grey),
                                      border: InputBorder.none,
                                    ),
                                    onSubmitted: (value) => _executeCommand(value),
                                  ),
                                ),
                              ],
                            )
                          ],
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
    );
  }

  Widget _buildActionCard(String title, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          alignment: Alignment.centerLeft,
          side: BorderSide(color: Colors.grey.shade700),
        ),
        onPressed: onTap,
        child: Text(
          title,
          style: const TextStyle(fontSize: 16, color: Colors.white),
        ),
      ),
    );
  }
}
