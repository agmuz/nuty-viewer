import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_midi_pro/dart_midi_pro.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rush_synth/rush_synth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:verovio_flutter/verovio_flutter.dart';

class VerovioScreen extends StatefulWidget {
  final String filePath;
  final List<String>? navigationList;
  final int currentIndex;
  final Future<void> Function(String)? onFileChanged;

  const VerovioScreen({
    super.key,
    required this.filePath,
    this.navigationList,
    this.currentIndex = 0,
    this.onFileChanged,
  });

  @override
  State<VerovioScreen> createState() => _VerovioScreenState();
}

class _VerovioScreenState extends State<VerovioScreen> {
  VerovioAsyncService? _service;
  WebViewController? _webController;
  RushSequencer? _sequencer;

  bool _barVisible = true;
  Timer? _hideTimer;

  int _zoomValue = 70;
  int _spacingValue = 0;
  String _transposeValue = '';
  String _viewMode = 'notes';

  bool _audioReady = false;
  bool _isPlaying = false;
  Timer? _playbackMonitor;

  int _selectedInstrument = 11;
  int _tempoBpm = 120;

  late List<String> _navList;
  late int _currentIndex;
  late String _currentPath;

  static const Map<String, String> _keyLabels = {
    '': 'ORG',
    'c': 'C',
    'df': 'Des/Cis',
    'd': 'D',
    'ef': 'Es',
    'e': 'E',
    'f': 'F',
    'fs': 'Fis/Ges',
    'g': 'G',
    'af': 'As/Gis',
    'a': 'A',
    'bf': 'B',
    'b': 'H',
  };

  static const Map<String, String> _viewLabels = {
    'notes': 'N',
    'both': 'NA',
  };

  static const Map<int, String> _instruments = {
    0: 'Fortepian',
    11: 'Wibrafon',
    56: 'Trąbka',
    65: 'Saksofon altowy',
    71: 'Klarnet',
    73: 'Flet',
  };

  String get _fileKey => _currentPath.split('/').last;

  String _prefsKey(String setting) => 'viewer-$setting-$_fileKey';

  bool get _hasNavigation => _navList.length > 1;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.filePath;
    _currentIndex = widget.currentIndex;
    _navList = widget.navigationList ?? [widget.filePath];
    _loadPrefsForCurrentFile().then((_) => _init());
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _playbackMonitor?.cancel();
    _sequencer?.stop();
    super.dispose();
  }

  Future<void> _loadPrefsForCurrentFile() async {
    final prefs = await SharedPreferences.getInstance();
    _zoomValue = ((prefs.getInt(_prefsKey('zoom')) ?? 70) / 5).round() * 5;
    _zoomValue = _zoomValue.clamp(40, 140);
    _spacingValue = (prefs.getInt(_prefsKey('spacing')) ?? 0).clamp(0, 20);
    _transposeValue = prefs.getString(_prefsKey('transpose')) ?? '';
    _viewMode = prefs.getString(_prefsKey('viewMode')) ?? 'notes';
    if (!_viewLabels.containsKey(_viewMode)) _viewMode = 'notes';
    _selectedInstrument = prefs.getInt(_prefsKey('instrument')) ?? 11;
    if (!_instruments.containsKey(_selectedInstrument)) {
      _selectedInstrument = 11;
    }
    _tempoBpm = (prefs.getInt(_prefsKey('tempo')) ?? 120).clamp(40, 240);
  }

  Future<void> _savePrefsForCurrentFile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey('zoom'), _zoomValue);
    await prefs.setInt(_prefsKey('spacing'), _spacingValue);
    await prefs.setString(_prefsKey('transpose'), _transposeValue);
    await prefs.setString(_prefsKey('viewMode'), _viewMode);
    await prefs.setInt(_prefsKey('instrument'), _selectedInstrument);
    await prefs.setInt(_prefsKey('tempo'), _tempoBpm);
  }

  int _clampZoom(int v) => ((v / 5).round() * 5).clamp(40, 140);
  int _clampSpacing(int v) => v.clamp(0, 20);

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _barVisible = false);
    });
  }

  void _toggleBar() {
    setState(() => _barVisible = true);
    _scheduleHide();
  }

  Future<void> _init() async {
    try {
      final resourcePath =
          await VerovioResourceManager.ensureVerovioAssetsReady();
      final service =
          await VerovioAsyncService.spawn(resourcePath: resourcePath);

      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.white)
        ..enableZoom(true);

      if (!mounted) return;
      setState(() {
        _service = service;
        _webController = controller;
      });

      await _initAudio();
      await _renderCurrentFile();
    } catch (e) {
      debugPrint('Błąd inicjalizacji: $e');
    }
  }

  Future<void> _initAudio() async {
    try {
      final seq = await RushSequencer.fromAsset(
        'assets/soundfonts/FluidR3_GM.sf2',
      );
      if (!mounted) return;
      setState(() {
        _sequencer = seq;
        _audioReady = true;
      });
      debugPrint('Audio gotowe (rush_synth + FluidR3_GM.sf2)');
    } catch (e) {
      debugPrint('Błąd audio: $e');
    }
  }

  int _computePageWidth(double screenWidth) {
    const base = 2100;
    final scaleFactor = 70 / _zoomValue;
    return (base * scaleFactor).round().clamp(600, 6000);
  }

  Future<void> _renderCurrentFile() async {
    _toggleBar();

    try {
      final screenWidth = MediaQuery.of(context).size.width;

      final options = <String, Object?>{
        'scale': _zoomValue,
        'pageWidth': _computePageWidth(screenWidth),
        'adjustPageHeight': true,
        'breaks': 'auto',
        'footer': 'none',
        'header': 'none',
        'mnumInterval': 0,
        'mnumHome': false,
        'mnumAll': false,
        'spacingSystem': _spacingValue > 0 ? _spacingValue : 2,
        'transpose': _transposeValue,
      };
      await _service!.setOptionsJson(jsonEncode(options));

      final bytes = await File(_currentPath).readAsBytes();
      final isMxl = _currentPath.toLowerCase().endsWith('.mxl');

      if (isMxl) {
        await _service!.loadZipDataBuffer(bytes);
      } else {
        final xml = utf8.decode(bytes);
        await _service!.loadData(xml);
      }

      final svg = await _service!.renderToSvg(1, xmlDeclaration: true);
      if (svg.isEmpty) {
        debugPrint('Verovio zwróciło pusty SVG.');
        _toggleBar();
        return;
      }

      await _webController!.loadHtmlString(_svgHtmlWithSpacing(svg));
      if (!mounted) return;
      _toggleBar();
    } catch (e) {
      debugPrint('Błąd: $e');
      _toggleBar();
    }
  }

  Future<void> _navigate(int direction) async {
    final newIndex = _currentIndex + direction;
    if (newIndex < 0 || newIndex >= _navList.length) return;

    await _stopPlayback();
    await _savePrefsForCurrentFile();

    setState(() {
      _currentIndex = newIndex;
      _currentPath = _navList[newIndex];
    });

    await widget.onFileChanged?.call(_currentPath);

    await _loadPrefsForCurrentFile();
    await _renderCurrentFile();
  }

  String _svgHtmlWithSpacing(String svg) {
    final sb = StringBuffer();
    sb.writeln('<!DOCTYPE html>');
    sb.writeln('<html>');
    sb.writeln('<head>');
    sb.writeln('  <meta charset="utf-8">');
    sb.writeln(
        '  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">');
    sb.writeln('  <style>');
    sb.writeln('    html, body {');
    sb.writeln('      margin: 0;');
    sb.writeln('      padding: 12px;');
    sb.writeln('      background: #fff;');
    sb.writeln('      -webkit-overflow-scrolling: touch;');
    sb.writeln('    }');
    sb.writeln('    svg { display: block; max-width: 100%; height: auto; }');
    sb.writeln(
        '    svg .mNum, svg [class~="mNum"], svg g.mNum, svg text.mNum {');
    sb.writeln('      display: none !important;');
    sb.writeln('    }');
    sb.writeln('    .notes-only-active g.harm,');
    sb.writeln('    .notes-only-active g[class~="harm"] {');
    sb.writeln('      display: none !important;');
    sb.writeln('    }');
    sb.writeln('  </style>');
    sb.writeln('</head>');
    sb.writeln('<body>');
    sb.writeln(svg);
    sb.writeln('<script>');
    sb.writeln('(function() {');
    sb.writeln('  var spacingValue = $_spacingValue;');
    sb.writeln('  var viewMode = "$_viewMode";');
    sb.writeln('  function applySettings() {');
    sb.writeln('    var svg = document.querySelector("svg");');
    sb.writeln('    if (!svg) return;');
    sb.writeln(
        '    svg.querySelectorAll("text.mNum, g.mNum, [class~=\\"mNum\\"]").forEach(function(el) {');
    sb.writeln('      el.remove();');
    sb.writeln('    });');
    sb.writeln('    document.body.classList.remove("notes-only-active");');
    sb.writeln('    if (viewMode === "notes") {');
    sb.writeln('      document.body.classList.add("notes-only-active");');
    sb.writeln('    }');
    sb.writeln('    var systems = svg.querySelectorAll("g.system, g[class~=\\"system\\"]");');
    sb.writeln('    if (systems.length < 2) return;');
    sb.writeln('    var vb = svg.viewBox && svg.viewBox.baseVal;');
    sb.writeln('    if (!vb || !vb.width) return;');
    sb.writeln('    var renderedWidth = svg.getBoundingClientRect().width;');
    sb.writeln('    if (!renderedWidth) return;');
    sb.writeln('    var unitsPerPx = vb.width / renderedWidth;');
    sb.writeln('    if (spacingValue > 2) {');
    sb.writeln('      var extra = (spacingValue - 2) * 0.085;');
    sb.writeln('      systems.forEach(function(g, index) {');
    sb.writeln('        if (index === 0) return;');
    sb.writeln('        var prev = systems[index - 1];');
    sb.writeln('        var prevRect = prev.getBoundingClientRect();');
    sb.writeln('        var curRect = g.getBoundingClientRect();');
    sb.writeln('        var currentGap = curRect.top - prevRect.bottom;');
    sb.writeln('        var extraShift = currentGap * extra * unitsPerPx;');
    sb.writeln(
        '        var original = g.getAttribute("transform") || "";');
    sb.writeln(
        '        g.setAttribute("transform", "translate(0 " + extraShift + ") " + original);');
    sb.writeln('      });');
    sb.writeln(
        '      var newHeight = vb.height * (1 + extra * systems.length * 0.1);');
    sb.writeln(
        '      svg.setAttribute("viewBox", vb.x + " " + vb.y + " " + vb.width + " " + newHeight);');
    sb.writeln('      svg.removeAttribute("height");');
    sb.writeln('    }');
    sb.writeln('  }');
    sb.writeln('  window.__applySettings = applySettings;');
    sb.writeln('  setTimeout(applySettings, 50);');
    sb.writeln('})();');
    sb.writeln('</script>');
    sb.writeln('</body>');
    sb.writeln('</html>');
    return sb.toString();
  }

  Future<void> _changeZoom(int step) async {
    final next = _clampZoom(_zoomValue + step);
    if (next == _zoomValue) return;
    setState(() => _zoomValue = next);
    await _savePrefsForCurrentFile();
    _toggleBar();
    await _renderCurrentFile();
  }

  Future<void> _changeSpacing(int step) async {
    final next = _clampSpacing(_spacingValue + step);
    if (next == _spacingValue) return;
    setState(() => _spacingValue = next);
    await _savePrefsForCurrentFile();
    _toggleBar();
    await _renderCurrentFile();
  }

  Future<void> _changeTranspose(String value) async {
    if (value == _transposeValue) return;
    setState(() => _transposeValue = value);
    await _savePrefsForCurrentFile();
    _toggleBar();
    await _renderCurrentFile();
  }

  Future<void> _changeInstrument(int program) async {
    if (program == _selectedInstrument) return;
    setState(() => _selectedInstrument = program);
    await _savePrefsForCurrentFile();
    _toggleBar();
    if (_isPlaying) {
      await _stopPlayback();
    }
  }

  Future<void> _changeTempo(int delta) async {
    final next = (_tempoBpm + delta).clamp(40, 240);
    if (next == _tempoBpm) return;
    setState(() => _tempoBpm = next);
    await _savePrefsForCurrentFile();
    if (_sequencer != null && _audioReady) {
      try {
        await _sequencer!.setSpeed(next / 120.0);
      } catch (e) {
        debugPrint('Błąd zmiany tempa: $e');
      }
    }
  }

  Future<void> _cycleViewMode() async {
    final modes = ['notes', 'both'];
    final idx = modes.indexOf(_viewMode);
    final next = modes[(idx + 1) % modes.length];
    setState(() => _viewMode = next);
    await _savePrefsForCurrentFile();
    _toggleBar();
    await _renderCurrentFile();
  }

  List<int> _applyInstrumentToMidi(List<int> midiBytes, int program) {
    try {
      final parser = MidiParser();
      final file = parser.parseMidiFromBuffer(midiBytes);
      for (final track in file.tracks) {
        final programEvents = track.whereType<ProgramChangeMidiEvent>();
        if (programEvents.isNotEmpty) {
          for (final ev in programEvents) {
            ev.programNumber = program;
          }
        } else {
          final pc = ProgramChangeMidiEvent()
            ..channel = 0
            ..programNumber = program
            ..deltaTime = 0;
          track.insert(0, pc);
        }
      }
      final writer = MidiWriter();
      return writer.writeMidiToBuffer(file);
    } catch (e) {
      debugPrint('Błąd modyfikacji MIDI: $e');
      return midiBytes;
    }
  }

  Future<void> _stopPlayback() async {
    if (!_isPlaying) return;
    try {
      await _sequencer?.stop();
    } catch (_) {}
    _playbackMonitor?.cancel();
    if (!mounted) return;
    setState(() => _isPlaying = false);
  }

  Future<void> _togglePlayback() async {
    if (!_audioReady || _sequencer == null || _service == null) {
      debugPrint('Audio jeszcze nie gotowe');
      return;
    }
    if (_isPlaying) {
      await _stopPlayback();
      return;
    }

    try {
      final midiBytes = await _service!.renderToMidiBytes();
      if (midiBytes.isEmpty) {
        debugPrint('Verovio nie zwróciło MIDI');
        return;
      }

      final modified = _applyInstrumentToMidi(midiBytes, _selectedInstrument);

      final tempDir = await getTemporaryDirectory();
      final midiFile = File('${tempDir.path}/current.mid');
      await midiFile.writeAsBytes(modified);

      if (!mounted) return;
      setState(() => _isPlaying = true);
      _toggleBar();

      await _sequencer!.setSpeed(_tempoBpm / 120.0);
      await _sequencer!.play(midiPath: midiFile.path);

      _playbackMonitor?.cancel();
      _playbackMonitor = Timer.periodic(
        const Duration(milliseconds: 500),
        (timer) async {
          if (!mounted) {
            timer.cancel();
            return;
          }
          final done = _sequencer!.endOfSequence;
          if (done) {
            timer.cancel();
            setState(() => _isPlaying = false);
          }
        },
      );
    } catch (e) {
      debugPrint('Błąd odtwarzania: $e');
      if (mounted) setState(() => _isPlaying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _webController == null
                ? const Center(child: CircularProgressIndicator())
                : WebViewWidget(controller: _webController!),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _toggleBar,
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            top: _barVisible ? 0 : -80,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                color: Colors.black.withValues(alpha: 0.78),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: Colors.white, size: 20),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () async {
                        await _stopPlayback();
                        if (!mounted) return;
                        Navigator.pop(context);
                      },
                      tooltip: 'Wróć',
                    ),
                    if (_hasNavigation)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '${_currentIndex + 1}/${_navList.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    _miniLabel('Z'),
                    _stepBtn(
                      icon: Icons.remove,
                      onPressed: () => _changeZoom(-5),
                    ),
                    _valueBox('$_zoomValue'),
                    _stepBtn(
                      icon: Icons.add,
                      onPressed: () => _changeZoom(5),
                    ),
                    const SizedBox(width: 6),
                    _miniLabel('W'),
                    _stepBtn(
                      icon: Icons.remove,
                      onPressed: () => _changeSpacing(-1),
                    ),
                    _valueBox(_spacingValue > 0
                        ? '+$_spacingValue'
                        : '$_spacingValue'),
                    _stepBtn(
                      icon: Icons.add,
                      onPressed: () => _changeSpacing(1),
                    ),
                    const SizedBox(width: 6),
                    _toggleBtn(
                      label: _viewLabels[_viewMode] ?? 'N',
                      active: _viewMode == 'both',
                      onPressed: _cycleViewMode,
                    ),
                    const SizedBox(width: 6),
                    Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _transposeValue,
                          dropdownColor: Colors.black87,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                          icon: const Icon(Icons.arrow_drop_down,
                              color: Colors.white, size: 16),
                          items: _keyLabels.entries
                              .map((e) => DropdownMenuItem<String>(
                                    value: e.key,
                                    child: Text(e.value),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) _changeTranspose(v);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _selectedInstrument,
                          dropdownColor: Colors.black87,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                          icon: const Icon(Icons.arrow_drop_down,
                              color: Colors.white, size: 16),
                          items: _instruments.entries
                              .map((e) => DropdownMenuItem<int>(
                                    value: e.key,
                                    child: Text(e.value),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) _changeInstrument(v);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () => _showTempoDialog(),
                      child: Container(
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white12,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Text(
                          'T ${_tempoBpm}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      icon: Icon(
                        _isPlaying ? Icons.pause : Icons.play_arrow,
                        color: _audioReady ? Colors.white : Colors.white38,
                        size: 24,
                      ),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: _audioReady ? _togglePlayback : null,
                      tooltip: _isPlaying ? 'Pauza' : 'Odtwórz',
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_hasNavigation)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              bottom: _barVisible ? 0 : -80,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  color: Colors.black.withValues(alpha: 0.78),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios,
                          color: _currentIndex > 0
                              ? Colors.white
                              : Colors.white30,
                          size: 24,
                        ),
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 44, minHeight: 44),
                        onPressed:
                            _currentIndex > 0 ? () => _navigate(-1) : null,
                        tooltip: 'Poprzedni',
                      ),
                      Expanded(
                        child: Text(
                          _fileKey.replaceAll(
                            RegExp(r'\.(xml|mxl|musicxml|mei)$',
                                caseSensitive: false),
                            '',
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.arrow_forward_ios,
                          color: _currentIndex < _navList.length - 1
                              ? Colors.white
                              : Colors.white30,
                          size: 24,
                        ),
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 44, minHeight: 44),
                        onPressed: _currentIndex < _navList.length - 1
                            ? () => _navigate(1)
                            : null,
                        tooltip: 'Następny',
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showTempoDialog() async {
    _hideTimer?.cancel();
    int localTempo = _tempoBpm;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF132845),
          title: const Text(
            'Tempo',
            style: TextStyle(color: Colors.white),
          ),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.remove, color: Colors.white),
                onPressed: () {
                  setDialogState(() {
                    localTempo = (localTempo - 5).clamp(40, 240);
                  });
                },
              ),
              Container(
                width: 80,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '$localTempo',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, color: Colors.white),
                onPressed: () {
                  setDialogState(() {
                    localTempo = (localTempo + 5).clamp(40, 240);
                  });
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Anuluj',
                  style: TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final delta = localTempo - _tempoBpm;
                await _changeTempo(delta);
              },
              child: const Text('OK',
                  style: TextStyle(color: Color(0xFFd6ad23))),
            ),
          ],
        ),
      ),
    );
    _scheduleHide();
  }

  Widget _miniLabel(String text) => Padding(
        padding: const EdgeInsets.only(right: 3),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      );

  Widget _valueBox(String text) => Container(
        constraints: const BoxConstraints(minWidth: 32),
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      );

  Widget _stepBtn({required IconData icon, VoidCallback? onPressed}) =>
      SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          icon: Icon(icon, color: Colors.white, size: 16),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          onPressed: onPressed,
        ),
      );

  Widget _toggleBtn({
    required String label,
    required bool active,
    required VoidCallback onPressed,
  }) =>
      GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 40,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? const Color(0xFFd6ad23) : Colors.white12,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: active ? const Color(0xFFffe889) : Colors.white24,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.black : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
}