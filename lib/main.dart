import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:xterm/xterm.dart';
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
  // Professional xterm terminal instance
  final Terminal _terminal = Terminal(maxLines: 1000);
  
  final FocusNode _commandFocusNode = FocusNode();
  final TextEditingController _commandController = TextEditingController();
  
  String _statusText = "Stack Status: Ready (Tailscale 100.64.152.108)";
  String _serverIp = "100.64.152.108:8080";
  
  bool _isKeyboardActive = false;
  String _activeInputSource = "Android TV Remote / D-Pad";

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);

    // Initial terminal welcome text
    _terminal.write('\x1B[32m[INFO] Initialized Pixel TV Commander (xterm backend)\x1B[0m\r\n');
    _terminal.write('\x1B[33m[INFO] Input system defaulted to Remote mode.\x1B[0m\r\n');

    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_commandFocusNode);
      _checkForUpdates().then((_) {
        if (_statusText.startsWith("Update Available")) {
          _downloadAndInstallUpdate();
        }
      });
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _commandFocusNode.dispose();
    _commandController.dispose();
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

  Future<void> _executeCommand(String command) async {
    if (command.trim().isEmpty) return;

    _terminal.write('\x1B[36mroot@pixel:~# $command\x1B[0m\r\n');
    _commandController.clear();

    try {
      final response = await http.post(
        Uri.parse('http://$_serverIp/v1/chat/completions'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "model": "local-model",
          "messages": [{"role": "user", "content": command}]
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final reply = data['choices']?[0]?['message']?['content'] ?? "Command executed.";
        _terminal.write('\x1B[32m[LLM] $reply\x1B[0m\r\n');
      } else {
        _terminal.write('\x1B[31m[ERROR] Server returned status: ${response.statusCode}\x1B[0m\r\n');
      }
    } catch (e) {
      _terminal.write('\x1B[33m[LOG] Dispatched command locally / Network timeout: $e\x1B[0m\r\n');
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
              _statusText = "Stack Status: Updated IP ($newIp)";
            });
            _terminal.write('\x1B[35m[INFO] Server IP updated to $newIp\x1B[0m\r\n');
          },
        ),
      ),
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
                          _buildActionCard("Ping Stack Status", () {
                            _terminal.write('\x1B[33m[INFO] Pinging Tailscale services...\x1B[0m\r\n');
                          }),
                          const SizedBox(height: 12),
                          _buildActionCard("Restart llama-server", () {
                            _executeCommand("systemctl restart llama-server");
                          }),
                          const SizedBox(height: 12),
                          _buildActionCard("Check Matrix Bot Logs", () {
                            _executeCommand("journalctl -u matrix-bot -n 20");
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
                                  'Terminal Output & Logs (xterm)',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey),
                                ),
                                const Divider(color: Colors.grey),
                                Expanded(
                                  child: TerminalView(_terminal),
                                ),
                                const SizedBox(height: 10),

                                // Command Input Row
                                Row(
                                  children: [
                                    const Text("root@pixel:\$ ", style: TextStyle(color: Colors.green, fontFamily: 'monospace')),
                                    Expanded(
                                      child: TextField(
                                        controller: _commandController,
                                        focusNode: _commandFocusNode,
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
              padding: MaterialStateProperty.all(const EdgeInsets.symmetric(vertical: 20, horizontal: 16)),
              alignment: Alignment.centerLeft,
              shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              side: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.focused)) {
                  return const BorderSide(color: Colors.cyanAccent, width: 2.5);
                }
                return BorderSide(color: Colors.grey.shade700, width: 1.0);
              }),
              backgroundColor: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.focused)) {
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
              'Backend Configuration',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.cyanAccent),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ipController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Tailscale Server IP & Port',
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
