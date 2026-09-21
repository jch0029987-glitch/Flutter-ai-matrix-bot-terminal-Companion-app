import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
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
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _commandController = TextEditingController();
  
  String _statusText = "Stack Status: Ready (Tailscale 100.64.152.108)";
  
  // Dead-ass defaults to Remote mode
  bool _isKeyboardActive = false;
  String _activeInputSource = "Android TV Remote / D-Pad";
  
  final List<String> _consoleLogs = [
    "[INFO] Initialized Pixel TV Commander",
    "[INFO] Input system defaulted to Remote mode."
  ];

  @override
  void initState() {
    super.initState();
    
    // Attach global hardware key listener
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_focusNode);
      
      // Auto-check updates on boot
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
    _focusNode.dispose();
    _commandController.dispose();
    super.dispose();
  }

  // Explicitly filters out remote D-pad / navigation keys, only switches on physical keys
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

    return false; // Pass event downstream normally
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

          setState(() {
            _consoleLogs.add("[SUCCESS] Update downloaded. Launching installer...");
          });

          await OpenFilex.open(filePath);
        }
      }
    } catch (e) {
      setState(() {
        _consoleLogs.add("[ERROR] Update execution failed: $e");
      });
    }
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
                  // Left Column: Quick Actions with D-Pad focus traversal
                  Expanded(
                    flex: 1,
                    child: FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.start,
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
                          const SizedBox(height: 12),
                          _buildActionCard("Check for Updates", () {
                            _checkForUpdates();
                          }),
                          const SizedBox(height: 12),
                          _buildActionCard("Download & Apply Update", () {
                            _downloadAndInstallUpdate();
                          }),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),

                  // Right Column: Terminal Console Output & Log Stream
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

                          // Command Input Row
                          Row(
                            children: [
                              const Text("root@pixel:\$ ", style: TextStyle(color: Colors.green, fontFamily: 'monospace')),
                              Expanded(
                                child: TextField(
                                  controller: _commandController,
                                  focusNode: _focusNode,
                                  autofocus: true,
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
    );
  }

  // Action card styled with visual focus response for Android TV remotes
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
                  return Colors.cyan.withValues(alpha: 0.2);
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
