import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:xterm2/xterm.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';
import 'dart:io';

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
  // Professional xterm terminal instance and layout controller
  final Terminal _terminal = Terminal(maxLines: 1000);
  final TerminalController _terminalController = TerminalController();
  
  final FocusNode _commandFocusNode = FocusNode();
  final TextEditingController _commandController = TextEditingController();
  
  String _statusText = "Stack Status: Connecting...";
  String _serverIp = "100.64.152.108";
  
  bool _isKeyboardActive = false;
  String _activeInputSource = "Android TV Remote / D-Pad";

  WebSocketChannel? _channel;
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);

    // Initial terminal welcome text
    _terminal.write('\x1B[32m[INFO] Initialized Pixel TV Commander (xterm backend)\x1B[0m\r\n');
    _terminal.write('\x1B[33m[INFO] Connecting to PTY WebSocket server on port 8081...\x1B[0m\r\n');
    
    _connectWebSocket();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_commandFocusNode);
      _checkForUpdates().then((_) {
        if (_statusText.startsWith("Update Available")) {
          _downloadAndInstallUpdate();
        }
      });
    });
  }

  void _connectWebSocket() {
    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://$_serverIp:8081'));
      
      setState(() {
        _isConnected = true;
        _statusText = "Stack Status: Connected (WebSocket PTY)";
      });

      _terminal.write('\x1B[32m[SUCCESS] Connected to live PTY session!\x1B[0m\r\n');

      // Pipe xterm keyboard/input bytes straight into the WebSocket PTY stream
      _terminal.onOutput = (data) {
        if (_isConnected && _channel != null) {
          _channel!.sink.add(data);
        }
      };

      // Transmit terminal resize dimensions so nano/vim/htop render properly full screen
      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        if (_isConnected && _channel != null) {
          final resizeMessage = jsonEncode({
            "type": "resize",
            "cols": width,
            "rows": height,
          });
          _channel!.sink.add(resizeMessage);
        }
      };

      _channel!.stream.listen(
        (data) {
          if (data is List<int>) {
            _terminal.write(utf8.decode(data, allowMalformed: true));
          } else if (data is String) {
            _terminal.write(data);
          }
        },
        onError: (error) {
          _terminal.write('\x1B[31m[ERROR] WebSocket error: $error\x1B[0m\r\n');
          setState(() {
            _isConnected = false;
            _statusText = "Stack Status: Disconnected";
          });
        },
        onDone: () {
          _terminal.write('\x1B[33m[INFO] WebSocket session closed.\x1B[0m\r\n');
          setState(() {
            _isConnected = false;
            _statusText = "Stack Status: Disconnected";
          });
        },
      );
    } catch (e) {
      _terminal.write('\x1B[31m[ERROR] Connection failed: $e\x1B[0m\r\n');
      setState(() {
        _isConnected = false;
        _statusText = "Stack Status: Connection Failed";
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _commandFocusNode.dispose();
    _commandController.dispose();
    _channel?.sink.close();
    super.dispose();
  }

  bool _handleGlobalKey(KeyEvent event) {
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.goBack) {
      return false;
    }

    bool isKeyboardKey = (key.keyId >= LogicalKeyboardKey.keyA.keyId && key.keyId <= LogicalKeyboardKey.keyZ.keyId) ||
                          (key.keyId >= LogicalKeyboardKey.digit0.keyId && key.keyId <= LogicalKeyboardKey.digit9.keyId) ||
                          key.keyId == LogicalKeyboardKey.space ||
                          key.keyId == LogicalKeyboardKey.backspace;

    if (isKeyboardKey && !_isKeyboardActive) {
      setState(() {
        _isKeyboardActive = true;
        _activeInputSource = "Physical Bluetooth Keyboard";
      });
    }

    return false;
  }

  Future<void> _handleUserSubmission(String input) async {
    if (input.trim().isEmpty) return;

    if (input.startsWith("llm:")) {
      // Route to local Qwen LLM on port 8080
      final prompt = input.substring(4).trim();
      _commandController.clear();
      await _queryLocalLLM(prompt);
    } else {
      // Route terminal commands over the WebSocket PTY pipe (Port 8081)
      _terminal.write('\x1B[36m$input\x1B[0m\r\n');
      if (_isConnected && _channel != null) {
        _channel!.sink.add('$input\n');
      } else {
        _terminal.write('\x1B[31m[ERROR] Not connected to PTY server. Attempting reconnect...\x1B[0m\r\n');
        _connectWebSocket();
      }
      _commandController.clear();
    }

    // Ensure terminal input never loses focus after submission
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        FocusScope.of(context).requestFocus(_commandFocusNode);
      }
    });
  }

  Future<void> _queryLocalLLM(String prompt) async {
    if (prompt.trim().isEmpty) return;

    _terminal.write('\x1B[35m[LLM Prompt] $prompt\x1B[0m\r\n');

    try {
      final response = await http.post(
        Uri.parse('http://$_serverIp:8080/v1/chat/completions'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "model": "local-model",
          "messages": [
            {"role": "system", "content": "You are a helpful coding assistant running locally on the device host."},
            {"role": "user", "content": prompt}
          ]
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final reply = data['choices']?[0]?['message']?['content'] ?? "No response generated.";
        _terminal.write('\x1B[32m[LLM Response]:\x1B[0m\r\n$reply\r\n\r\n');
      } else {
        _terminal.write('\x1B[31m[ERROR] LLM server returned status: ${response.statusCode}\x1B[0m\r\n');
      }
    } catch (e) {
      _terminal.write('\x1B[31m[ERROR] Failed to reach llama-server on port 8080: $e\x1B[0m\r\n');
    }
  }

  Future<void> _checkForUpdates() async {
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/jch0029987-glitch/Flutter-ai-matrix-bot-terminal-Companion-app/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final latestTag = data['tag_name'] ?? 'v1.0.0';

        setState(() {
          if (latestTag != "v1.0.0+1") {
            _statusText = "Update Available: $latestTag";
          } else {
            _statusText = "App is up to date!";
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _downloadAndInstallUpdate() async {
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/jch0029987-glitch/Flutter-ai-matrix-bot-terminal-Companion-app/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final assets = data['assets'] as List?;
        final apkAsset = assets?.firstWhere(
          (asset) => asset['name'].toString().endsWith('.apk'),
          orElse: () => null,
        );

        if (apkAsset == null) return;

        final downloadUrl = apkAsset['browser_download_url'];
        final apkResponse = await http.get(Uri.parse(downloadUrl));
        
        if (apkResponse.statusCode == 200) {
          final dir = await getExternalStorageDirectory() ?? await getApplicationCacheDirectory();
          final filePath = '${dir.path}/update.apk';
          
          final file = File(filePath);
          await file.writeAsBytes(apkResponse.bodyBytes);

          _terminal.write('\x1B[32m[SUCCESS] Update downloaded. Launching installer...\x1B[0m\r\n');
          await OpenFilex.open(filePath);
        }
      }
    } catch (e) {
      _terminal.write('\x1B[31m[ERROR] Update execution failed: $e\x1B[0m\r\n');
    }
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          currentIp: _serverIp,
          onIpChanged: (newIp) {
            setState(() {
              _serverIp = newIp;
            });
            _terminal.write('\x1B[35m[INFO] Target IP updated to $newIp. Reconnecting WebSocket...\x1B[0m\r\n');
            _channel?.sink.close();
            _connectWebSocket();
          },
        ),
      ),
    );
  }

  Widget _buildControlButton(String label, String rawBytes) {
    return Builder(
      builder: (context) {
        return OutlinedButton(
          style: ButtonStyle(
            padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
            minimumSize: WidgetStateProperty.all(const Size(60, 36)),
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return const BorderSide(color: Colors.cyanAccent, width: 2.0);
              }
              return BorderSide(color: Colors.grey.shade700, width: 1.0);
            }),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return Colors.cyan.withOpacity(0.3);
              }
              return Colors.grey.shade900;
            }),
            shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
          ),
          onPressed: () {
            if (_isConnected && _channel != null) {
              _channel!.sink.add(rawBytes);
              _terminal.write('\x1B[33m[Sent $label]\x1B[0m\r\n');
            } else {
              _terminal.write('\x1B[31m[ERROR] Not connected to PTY.\x1B[0m\r\n');
            }
            FocusScope.of(context).requestFocus(_commandFocusNode);
          },
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
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
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _isKeyboardActive ? Colors.cyan.shade900 : Colors.amber.shade900,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _isKeyboardActive ? Colors.cyanAccent : Colors.amberAccent),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _isKeyboardActive ? Icons.keyboard : Icons.settings_remote,
                            size: 16,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "Active Input: $_activeInputSource",
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Text(
                      _statusText,
                      style: const TextStyle(fontSize: 14, color: Colors.greenAccent),
                    ),
                  ],
                ),
              ],
            ),
            const Divider(height: 30, color: Colors.grey),

            // Main Workspace Split
            Expanded(
              child: Row(
                children: [
                  // Left Column: Quick Actions
                  Expanded(
                    flex: 1,
                    child: FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          _buildActionCard("Reconnect Terminal", _connectWebSocket),
                          const SizedBox(height: 12),
                          _buildActionCard("Ask Local Qwen LLM", () {
                            _queryLocalLLM("Provide a brief status check of the system.");
                          }),
                          const SizedBox(height: 12),
                          _buildActionCard("Check Bot Logs", () {
                            _handleUserSubmission("tail -n 20 ~/pixelclaw/logs/bot.log");
                          }),
                          const SizedBox(height: 12),
                          _buildActionCard("Settings & Configuration", _openSettings),
                          const SizedBox(height: 12),
                          _buildActionCard("Check / Apply Updates", () {
                            _checkForUpdates().then((_) => _downloadAndInstallUpdate());
                          }),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),

                  // Right Column: xterm Terminal View Container
                  Expanded(
                    flex: 2,
                    child: Focus(
                      child: Builder(
                        builder: (context) {
                          final bool isFocused = Focus.of(context).hasFocus;
                          return Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isFocused ? Colors.cyanAccent : Colors.grey.shade800,
                                width: isFocused ? 2.0 : 1.0,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Interactive PTY Terminal (xterm) — Type `su` for root',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey),
                                ),
                                const Divider(color: Colors.grey),
                                Expanded(
                                  child: TerminalView(
                                    _terminal,
                                    controller: _terminalController,
                                    autofocus: true,
                                  ),
                                ),
                                const SizedBox(height: 10),

                                // --- TV Control Quick Bar for Nano / Shortcuts ---
                                SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      const Text("Shortcuts: ", style: TextStyle(color: Colors.grey, fontSize: 12)),
                                      const SizedBox(width: 8),
                                      _buildControlButton("Ctrl+O (Save)", "\x0f"),
                                      const SizedBox(width: 8),
                                      _buildControlButton("Ctrl+X (Exit)", "\x18"),
                                      const SizedBox(width: 8),
                                      _buildControlButton("Ctrl+C (Cancel)", "\x03"),
                                      const SizedBox(width: 8),
                                      _buildControlButton("Esc", "\x1b"),
                                      const SizedBox(width: 8),
                                      _buildControlButton("Tab", "\t"),
                                      const SizedBox(width: 8),
                                      _buildControlButton("Up", "\x1b[A"),
                                      const SizedBox(width: 8),
                                      _buildControlButton("Down", "\x1b[B"),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),

                                // Command Input Row
                                Row(
                                  children: [
                                    const Text("\$ ", style: TextStyle(color: Colors.green, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                                    Expanded(
                                      child: TextField(
                                        controller: _commandController,
                                        focusNode: _commandFocusNode,
                                        style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
                                        decoration: const InputDecoration(
                                          hintText: "Type command (or 'llm: [prompt]' for AI)...",
                                          hintStyle: TextStyle(color: Colors.grey),
                                          border: InputBorder.none,
                                        ),
                                        onSubmitted: (value) => _handleUserSubmission(value),
                                      ),
                                    ),
                                  ],
                                )
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionCard(String title, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      child: Builder(
        builder: (context) {
          return OutlinedButton(
            style: ButtonStyle(
              padding: WidgetStateProperty.all(const EdgeInsets.symmetric(vertical: 20, horizontal: 16)),
              alignment: Alignment.centerLeft,
              shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              side: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.focused)) {
                  return const BorderSide(color: Colors.cyanAccent, width: 2.5);
                }
                return BorderSide(color: Colors.grey.shade700, width: 1.0);
              }),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.focused)) {
                  return Colors.cyan.withOpacity(0.2);
                }
                return Colors.transparent;
              }),
            ),
            onPressed: onTap,
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, color: Colors.white),
            ),
          );
        },
      ),
    );
  }
}

// Dedicated Settings Screen fully navigable via TV D-Pad
class SettingsScreen extends StatefulWidget {
  final String currentIp;
  final ValueChanged<String> onIpChanged;

  const SettingsScreen({super.key, required this.currentIp, required this.onIpChanged});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _ipController;

  @override
  void initState() {
    super.initState();
    _ipController = TextEditingController(text: widget.currentIp);
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Commander Settings'),
        backgroundColor: Colors.black87,
      ),
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: ListView(
          children: [
            const Text(
              'Backend Tailscale Configuration',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.cyanAccent),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ipController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Tailscale Server IP Address',
                labelStyle: const TextStyle(color: Colors.grey),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.cyanAccent, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan.shade800,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              onPressed: () {
                widget.onIpChanged(_ipController.text.trim());
                Navigator.pop(context);
              },
              child: const Text('Save & Apply Settings', style: TextStyle(fontSize: 16, color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}
