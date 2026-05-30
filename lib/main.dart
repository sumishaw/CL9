import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CaptionLensApp());
}

class CaptionLensApp extends StatelessWidget {
  const CaptionLensApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Caption Lens',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: Colors.black,
          colorScheme: const ColorScheme.dark(primary: Color(0xFFFF3B3B)),
        ),
        home: const HomePage(),
      );
}

enum ModelState { checking, notReady, ready, error }
enum CaptionMode { liveCaptions, audioCapture }

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _ch = MethodChannel('overlay_channel');

  // State
  String  originalText     = '';
  String  displayText      = '';
  bool    isRunning        = false;
  bool    hasOverlay       = false;
  bool    hasAccessibility = false;
  String  targetLang       = 'hindi';
  String  statusMsg        = '';
  int     translationCount = 0;
  bool    _pulse           = false;
  Timer?  _pulseTimer;
  Timer?  _pollTimer;
  String  _lastSeenHindi   = '';

  ModelState  modelState    = ModelState.checking;
  String      modelErrorMsg = '';

  CaptionMode captionMode = CaptionMode.liveCaptions;

  // Log tab state
  late TabController _tabController;
  String  _logText      = 'Tap Refresh to load logs.';
  bool    _logLoading   = false;
  final   ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addObserver(this);

    _ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'onTranslation':
          final a = call.arguments as Map? ?? {};
          _applyTranslation(
            a['original']?.toString() ?? '',
            a['english']?.toString()  ?? '',
            a['hindi']?.toString()    ?? '',
          );
          break;
        case 'onModelReady':
          if (mounted) setState(() => modelState = ModelState.ready);
          break;
        case 'onModelError':
          final a   = call.arguments as Map? ?? {};
          final msg = a['message']?.toString() ?? 'CT2 translation server not reachable';
          if (mounted) setState(() { modelState = ModelState.error; modelErrorMsg = msg; });
          break;
        case 'onLiveCaptionReaderConnected':
          if (mounted) setState(() => hasAccessibility = true);
          break;
      }
    });

    _checkPermissions();
    _checkModelStatus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
      _checkModelStatus();
    }
  }

  Future<void> _checkPermissions() async {
    try {
      final overlay = await _ch.invokeMethod<bool>('hasOverlayPermission') ?? false;
      if (mounted) setState(() => hasOverlay = overlay);
    } catch (_) {}
  }

  Future<void> _checkModelStatus() async {
    try {
      if (mounted) setState(() => modelState = ModelState.checking);
      final ready = await _ch.invokeMethod<bool>('isModelReady') ?? false;
      if (mounted) setState(() => modelState = ready ? ModelState.ready : ModelState.notReady);
    } catch (_) {
      if (mounted) setState(() => modelState = ModelState.notReady);
    }
  }

  void _applyTranslation(String orig, String en, String hi) {
    if (!mounted) return;
    final show = hi.isNotEmpty ? hi : en;
    if (show.isEmpty || show == _lastSeenHindi) return;
    _lastSeenHindi = show;
    setState(() {
      originalText     = orig;
      displayText      = show;
      translationCount++;
    });
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (!isRunning || !mounted) return;
      try {
        final result = await _ch.invokeMethod<Map>('getLatestTranslation');
        if (result == null || !mounted) return;
        _applyTranslation(
          result['original']?.toString() ?? '',
          result['english']?.toString()  ?? '',
          result['hindi']?.toString()    ?? '',
        );
      } catch (_) {}
    });
  }

  void _stopPolling() { _pollTimer?.cancel(); _pollTimer = null; }

  Future<void> _start() async {
    if (modelState != ModelState.ready) {
      setState(() => statusMsg = '⚠ Start whisper_server.py in Termux first, then tap CHECK');
      return;
    }
    if (!hasOverlay) {
      await _ch.invokeMethod('requestOverlayPermission');
      if (mounted) setState(() =>
          statusMsg = '⚠ Allow "Display over other apps" → come back → tap START');
      return;
    }

    if (captionMode == CaptionMode.liveCaptions && !hasAccessibility) {
      if (mounted) setState(() =>
          statusMsg = '⚠ Enable LiveCaptionReader in Settings → Accessibility → Caption Lens');
      return;
    }

    await _ch.invokeMethod('startOverlay');

    if (captionMode == CaptionMode.audioCapture) {
      // Legacy audio capture mode
      if (mounted) setState(() => statusMsg = '⏳ Approve "Start recording" dialog…');
      final ok = await _ch.invokeMethod<bool>('startSpeechCapture') ?? false;
      if (!ok) {
        if (mounted) setState(() => statusMsg = '⚠ Screen capture not approved');
        return;
      }
    }

    _pulseTimer?.cancel();
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 700),
        (_) { if (mounted) setState(() => _pulse = !_pulse); });

    _lastSeenHindi = '';
    _startPolling();

    if (mounted) setState(() {
      isRunning        = true;
      translationCount = 0;
      statusMsg        = '';
      displayText      = captionMode == CaptionMode.liveCaptions
          ? 'Reading Live Captions…'
          : 'Listening to video audio…';
      originalText     = '';
    });
  }

  Future<void> _stop() async {
    _pulseTimer?.cancel();
    _pulse = false;
    _stopPolling();
    if (captionMode == CaptionMode.audioCapture) {
      await _ch.invokeMethod('stopSpeechCapture');
    }
    await _ch.invokeMethod('stopOverlay');
    if (mounted) setState(() {
      isRunning      = false;
      statusMsg      = '';
      displayText    = '';
      originalText   = '';
      _lastSeenHindi = '';
    });
  }

  Future<void> _setLanguage(String lang) async {
    await _ch.invokeMethod('setTargetLanguage', {'language': lang});
    if (mounted) setState(() => targetLang = lang);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _logScroll.dispose();
    _pulseTimer?.cancel();
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        toolbarHeight: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFFFF3B3B),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white38,
          tabs: const [
            Tab(icon: Icon(Icons.subtitles), text: 'Caption Lens'),
            Tab(icon: Icon(Icons.article_outlined), text: 'Logs'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildMainTab(),
          _buildLogTab(),
        ],
      ),
    );
  }

  Widget _buildMainTab() {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              _buildHeader(),
              const SizedBox(height: 16),
              _buildInfoBanner(),
              const SizedBox(height: 16),
              _buildModelCard(),
              const SizedBox(height: 12),
              _buildOverlayPermRow(),
              const SizedBox(height: 12),
              _buildAccessibilityRow(),
              const SizedBox(height: 16),
              _buildModeSelector(),
              const SizedBox(height: 16),
              _buildLanguageChips(),
              const SizedBox(height: 16),
              _buildLangSelector(),
              const SizedBox(height: 16),
              if (originalText.isNotEmpty) ...[
                _buildDetectedText(),
                const SizedBox(height: 10),
              ],
              if (displayText.isNotEmpty)
                _buildTranslationOutput(),
              if (statusMsg.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildStatusBanner(),
              ],
              const SizedBox(height: 20),
              _buildStartStopButton(),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  captionMode == CaptionMode.liveCaptions
                      ? 'Using Android Live Captions — no audio captured by this app'
                      : 'Captures internal phone audio — microphone stays off',
                  style: const TextStyle(color: Colors.white24, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      );
  }

  // ── Log tab ───────────────────────────────────────────────────────────────

  Future<void> _refreshLogs() async {
    if (_logLoading) return;
    setState(() => _logLoading = true);
    try {
      final logs = await _ch.invokeMethod<String>('getLogs') ?? 'No logs yet.';
      setState(() => _logText = logs.isEmpty ? 'No logs yet.' : logs);
      // Scroll to bottom after render
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients)
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      });
    } catch (e) {
      setState(() => _logText = 'Error fetching logs: $e');
    } finally {
      setState(() => _logLoading = false);
    }
  }

  Future<void> _clearLogs() async {
    await _ch.invokeMethod('clearLogs');
    setState(() => _logText = 'Logs cleared.');
  }

  Widget _buildLogTab() {
    return SafeArea(
      child: Column(
        children: [
          // Toolbar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Text('Diagnostic Logs',
                    style: TextStyle(color: Colors.white, fontSize: 15,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_logLoading)
                  const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2,
                          color: Color(0xFFFF3B3B)))
                else
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Color(0xFFFF3B3B)),
                    tooltip: 'Refresh',
                    onPressed: _refreshLogs,
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.white38),
                  tooltip: 'Clear',
                  onPressed: _clearLogs,
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          // Log content
          Expanded(
            child: _logText.isEmpty
                ? const Center(child: Text('No logs yet — tap Refresh',
                    style: TextStyle(color: Colors.white38)))
                : Scrollbar(
                    controller: _logScroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _logScroll,
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        _logText,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFamily: 'monospace',
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
          ),
          // Bottom hint
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Long-press text to copy • Tap Refresh to update',
              style: const TextStyle(color: Colors.white24, fontSize: 10),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() => Row(children: [
    AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: 36, height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isRunning
            ? (_pulse ? Colors.red : Colors.red.withAlpha(128))
            : Colors.white12,
      ),
      child: const Icon(Icons.subtitles, color: Colors.white, size: 20),
    ),
    const SizedBox(width: 12),
    const Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Caption Lens',
            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
        Text('Real-time Hindi subtitles via Live Captions',
            style: TextStyle(color: Colors.white38, fontSize: 11)),
      ]),
    ),
    if (isRunning)
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.fiber_manual_record, color: Colors.white, size: 8),
          const SizedBox(width: 4),
          Text('$translationCount',
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
        ]),
      ),
  ]);

  Widget _buildInfoBanner() {
    final isLC = captionMode == CaptionMode.liveCaptions;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withAlpha(20),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blue.withAlpha(51)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_outline, color: Colors.blue, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            isLC
                ? 'Uses Android Live Captions for perfect speech recognition. '
                  'Enable Live Captions + this accessibility service, then tap START.'
                : 'Captures audio playing on the tablet internally — works with YouTube, VLC, '
                  'Chrome, offline videos. Approve the screen capture dialog when you tap START.',
            style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.5),
          ),
        ),
      ]),
    );
  }

  Widget _buildModelCard() {
    switch (modelState) {
      case ModelState.checking:
        return _cardShell(
          icon: Icons.hourglass_top, iconColor: Colors.white38,
          borderColor: Colors.white12, bgColor: const Color(0xFF111111),
          title: 'Checking CT2 translation server…',
          subtitle: 'Connecting to whisper_server.py on port 8765',
          trailing: const SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38)),
        );
      case ModelState.notReady:
        return _cardShell(
          icon: Icons.cloud_off, iconColor: Colors.orangeAccent,
          borderColor: Colors.orange.withAlpha(102),
          bgColor: Colors.orange.withAlpha(15),
          title: 'Translation Server Not Running',
          subtitle: 'Run in Termux:\npython3 whisper_server.py',
          trailing: ElevatedButton(
            onPressed: _checkModelStatus,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent, foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('CHECK', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        );
      case ModelState.ready:
        return _cardShell(
          icon: Icons.check_circle, iconColor: Colors.greenAccent,
          borderColor: Colors.greenAccent.withAlpha(77),
          bgColor: Colors.green.withAlpha(15),
          title: 'Translation Server Ready',
          subtitle: 'CT2 opus-mt-en-hi · Hindi output · No censoring',
          trailing: const Icon(Icons.check, color: Colors.greenAccent, size: 20),
        );
      case ModelState.error:
        return _cardShell(
          icon: Icons.error_outline, iconColor: Colors.redAccent,
          borderColor: Colors.red.withAlpha(102),
          bgColor: Colors.red.withAlpha(15),
          title: 'Translation Server Unreachable',
          subtitle: modelErrorMsg.isNotEmpty ? modelErrorMsg : 'Start whisper_server.py then tap RETRY',
          trailing: ElevatedButton(
            onPressed: _checkModelStatus,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('RETRY', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        );
    }
  }

  Widget _buildOverlayPermRow() => _permRow(
    icon: hasOverlay ? Icons.check_circle : Icons.radio_button_unchecked,
    iconColor: hasOverlay ? Colors.greenAccent : Colors.white30,
    title: 'Overlay Permission',
    subtitle: 'Required to show floating subtitles over other apps',
    granted: hasOverlay,
    onAllow: () async {
      await _ch.invokeMethod('requestOverlayPermission');
      await _checkPermissions();
    },
  );

  Widget _buildAccessibilityRow() => _permRow(
    icon: hasAccessibility ? Icons.check_circle : Icons.accessibility_new,
    iconColor: hasAccessibility ? Colors.greenAccent : Colors.white30,
    title: 'Accessibility Service',
    subtitle: hasAccessibility
        ? 'LiveCaptionReader active — reading Live Captions'
        : 'Settings → Accessibility → Caption Lens → LiveCaptionReader → ON',
    granted: hasAccessibility,
    onAllow: () async {
      await _ch.invokeMethod('openAccessibilitySettings');
    },
    allowLabel: 'Enable',
  );

  Widget _permRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool granted,
    required VoidCallback onAllow,
    String allowLabel = 'Allow',
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFF111111),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: granted ? Colors.greenAccent.withAlpha(77) : Colors.white12),
    ),
    child: Row(children: [
      Icon(icon, color: iconColor, size: 20),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
        Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 11, height: 1.4)),
      ])),
      if (!granted)
        GestureDetector(
          onTap: onAllow,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: const Color(0xFFFF3B3B), borderRadius: BorderRadius.circular(6)),
            child: Text(allowLabel,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ),
      if (granted) const Icon(Icons.check, color: Colors.greenAccent, size: 16),
    ]),
  );

  Widget _buildModeSelector() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Caption Source',
          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Row(children: [
        _modeBtn(
          icon: Icons.closed_caption,
          label: 'Live Captions',
          sublabel: 'Recommended',
          mode: CaptionMode.liveCaptions,
        ),
        const SizedBox(width: 10),
        _modeBtn(
          icon: Icons.mic_none,
          label: 'Audio Capture',
          sublabel: 'Legacy',
          mode: CaptionMode.audioCapture,
        ),
      ]),
    ],
  );

  Widget _modeBtn({
    required IconData icon,
    required String label,
    required String sublabel,
    required CaptionMode mode,
  }) {
    final sel = captionMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: isRunning ? null : () => setState(() => captionMode = mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          decoration: BoxDecoration(
            color: sel ? const Color(0x26FF3B3B) : const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sel ? const Color(0xFFFF3B3B) : Colors.white12),
          ),
          child: Column(children: [
            Icon(icon, color: sel ? const Color(0xFFFF3B3B) : Colors.white38, size: 22),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(
              color: sel ? Colors.white : Colors.white54,
              fontSize: 12, fontWeight: sel ? FontWeight.bold : FontWeight.normal,
            )),
            Text(sublabel, style: TextStyle(
              color: sel ? Colors.redAccent.withAlpha(179) : Colors.white24,
              fontSize: 10,
            )),
          ]),
        ),
      ),
    );
  }

  Widget _buildLanguageChips() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF0a1628),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.blue.withAlpha(51)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Detects & Translates',
          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _chip('🇯🇵 Japanese'), _chip('🇨🇳 Chinese'),    _chip('🇰🇷 Korean'),
        _chip('🇫🇷 French'),   _chip('🇩🇪 German'),    _chip('🇪🇸 Spanish'),
        _chip('🇹🇷 Turkish'),  _chip('🇸🇦 Arabic'),    _chip('🇧🇷 Portuguese'),
        _chip('🇷🇺 Russian'),  _chip('🇮🇩 Indonesian'), _chip('🇬🇧 English'),
      ]),
      const SizedBox(height: 10),
      const Text('Works with',
          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _chip('📺 YouTube'), _chip('🌐 Chrome'), _chip('🦊 Firefox'),
        _chip('🎬 VLC'),     _chip('📁 Offline'), _chip('+ Any app'),
      ]),
    ]),
  );

  Widget _buildLangSelector() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Translate to',
          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Row(children: [
        _langBtn('🇬🇧 English', 'english'),
        const SizedBox(width: 10),
        _langBtn('🇮🇳 Hindi', 'hindi'),
      ]),
    ],
  );

  Widget _buildDetectedText() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        captionMode == CaptionMode.liveCaptions ? 'Live Caption' : 'Detected audio',
        style: const TextStyle(color: Colors.white38, fontSize: 12),
      ),
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: Colors.white10, borderRadius: BorderRadius.circular(10)),
        child: Text(originalText,
            style: const TextStyle(color: Colors.white60, fontSize: 15, letterSpacing: 0.3)),
      ),
    ],
  );

  Widget _buildTranslationOutput() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        targetLang == 'hindi' ? '🇮🇳 Hindi Translation' : '🇬🇧 English Translation',
        style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 6),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 80),
        child: Container(
          key: ValueKey(displayText),
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.withAlpha(20),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.greenAccent.withAlpha(77)),
          ),
          child: Text(displayText,
              style: const TextStyle(
                  color: Colors.greenAccent, fontSize: 22,
                  fontWeight: FontWeight.bold, height: 1.4)),
        ),
      ),
    ],
  );

  Widget _buildStatusBanner() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.orange.withAlpha(26),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.orange.withAlpha(77)),
    ),
    child: Row(children: [
      const Icon(Icons.info_outline, color: Colors.orange, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(statusMsg,
          style: const TextStyle(color: Colors.orange, fontSize: 13))),
    ]),
  );

  Widget _buildStartStopButton() {
    final busy = modelState == ModelState.checking;
    final readyToStart = modelState == ModelState.ready && hasOverlay &&
        (captionMode == CaptionMode.audioCapture || hasAccessibility);

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: busy ? null : (isRunning ? _stop : (readyToStart ? _start : _start)),
        icon: Icon(
          isRunning ? Icons.stop_circle_outlined : Icons.play_circle_outline,
          size: 26,
        ),
        label: Text(
          isRunning ? 'STOP' : (captionMode == CaptionMode.liveCaptions
              ? 'START — LIVE CAPTIONS MODE'
              : 'START — CAPTURE VIDEO AUDIO'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 0.5),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: isRunning ? const Color(0xFF333333) : const Color(0xFFFF3B3B),
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade800,
          disabledForegroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 4,
        ),
      ),
    );
  }

  Widget _chip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.white.withAlpha(15),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white12),
    ),
    child: Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
  );

  Widget _langBtn(String label, String value) {
    final selected = targetLang == value;
    return GestureDetector(
      onTap: () => _setLanguage(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFF3B3B) : const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: selected ? const Color(0xFFFF3B3B) : Colors.white12),
        ),
        child: Text(label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white54,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
            )),
      ),
    );
  }

  Widget _cardShell({
    required IconData icon, required Color iconColor,
    required Color borderColor, required Color bgColor,
    required String title, required String subtitle, Widget? trailing,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: bgColor,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: borderColor),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Icon(icon, color: iconColor, size: 22),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11, height: 1.4)),
      ])),
      if (trailing != null) ...[const SizedBox(width: 10), trailing],
    ]),
  );
}
