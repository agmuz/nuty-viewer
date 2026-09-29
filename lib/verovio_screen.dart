import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf/saf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:xml/xml.dart';
import 'package:verovio_flutter/verovio_flutter.dart';

import 'chords_screen.dart';
import 'singletons.dart';

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

  final Saf _saf = Saf();
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _audioFolderUri;
  String? _audioUri;
  String? _audioTempPath;
  bool _audioPlaying = false;
  bool _audioPaused = false;
  DateTime? _lastPlayPress;

  bool _barVisible = true;
  Timer? _hideTimer;
  Timer? _immersiveTimer;

  int _zoomValue = 70;
  int _spacingValue = 0;
  String _transposeValue = '';
  int _octaveShift = 0;
  String _viewMode = 'notes';
  String _selectedFont = 'Leipzig';

  late List<String> _navList;
  final FocusNode _keyboardFocus = FocusNode();
  late int _currentIndex;
  late String _currentPath;

  static const String _prefsAudioFolder = 'audio_folder_uri';

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

  static const Map<String, String> _fontLabels = {
    'Leipzig': 'Leipzig',
    'Bravura': 'Bravura',
    'Leland': 'Leland',
    'Petaluma': 'Petaluma',
  };

  String get _fileKey => _currentPath.split('/').last;

  String _prefsKey(String setting) => 'viewer-$setting-$_fileKey';

  bool get _hasNavigation => _navList.length > 1;

  /// Czy bieżący plik to obraz (PNG/JPG/WEBP)?
  bool get _isImage {
    final p = _currentPath.toLowerCase();
    return p.endsWith('.png') ||
        p.endsWith('.jpg') ||
        p.endsWith('.jpeg') ||
        p.endsWith('.webp');
  }

  String get _cleanTitle {
    var name = _fileKey.replaceAll(
      RegExp(r'\.(xml|mxl|musicxml|mei|png|jpg|jpeg|webp)$', caseSensitive: false),
      '',
    );
    final parts = name.split('_');
    if (parts.length > 1 && int.tryParse(parts.first) != null) {
      name = parts.sublist(1).join(' ');
    }
    return name.replaceAll('_', ' ');
  }

  String get _effectiveTranspose {
    if (_transposeValue.isEmpty) {
      if (_octaveShift == 0) return '';
      return _octaveShift > 0 ? 'P8' : '-P8';
    }
    if (_octaveShift == 0) return _transposeValue;
    if (_octaveShift > 0) {
      return '+$_transposeValue';
    } else {
      return '-$_transposeValue';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardFocus.requestFocus();
    });
    _currentPath = widget.filePath;
    _currentIndex = widget.currentIndex;
    _navList = widget.navigationList ?? [widget.filePath];

    _audioPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _audioPlaying = false;
        _audioPaused = false;
      });
    });

    _loadPrefsForCurrentFile().then((_) => _init());
    _scheduleHide();

    // Po 3 sekundach przejdź w tryb pełnoekranowy (ukryj paski systemowe)
    _immersiveTimer = Timer(const Duration(seconds: 3), () {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    });
  }

  @override
  void dispose() {
    _keyboardFocus.dispose();
    _hideTimer?.cancel();
    _immersiveTimer?.cancel();
    // Przywróć paski systemowe przy wyjściu z ekranu
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadPrefsForCurrentFile() async {
    final prefs = await SharedPreferences.getInstance();
    _zoomValue = ((prefs.getInt(_prefsKey('zoom')) ?? 70) / 5).round() * 5;
    _zoomValue = _zoomValue.clamp(40, 140);
    _spacingValue = (prefs.getInt(_prefsKey('spacing')) ?? 0).clamp(0, 20);
    _transposeValue = prefs.getString(_prefsKey('transpose')) ?? '';
    _octaveShift = (prefs.getInt(_prefsKey('octave')) ?? 0).clamp(-1, 1);
    _viewMode = prefs.getString(_prefsKey('viewMode')) ?? 'notes';
    if (!_viewLabels.containsKey(_viewMode)) _viewMode = 'notes';
    _selectedFont = prefs.getString(_prefsKey('font')) ?? 'Leipzig';
    if (!_fontLabels.containsKey(_selectedFont)) _selectedFont = 'Leipzig';

    _audioFolderUri = prefs.getString(_prefsAudioFolder);
  }

  Future<void> _savePrefsForCurrentFile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey('zoom'), _zoomValue);
    await prefs.setInt(_prefsKey('spacing'), _spacingValue);
    await prefs.setString(_prefsKey('transpose'), _transposeValue);
    await prefs.setInt(_prefsKey('octave'), _octaveShift);
    await prefs.setString(_prefsKey('viewMode'), _viewMode);
    await prefs.setString(_prefsKey('font'), _selectedFont);
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
      final service = await VerovioSingleton.get();

      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.white)
        ..enableZoom(true);

      if (!mounted) return;
      setState(() {
        _service = service;
        _webController = controller;
      });

      if (_audioFolderUri == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showPickAudioFolderDialog();
        });
      }

      await _renderCurrentFile();
    } catch (e) {
      debugPrint('Błąd inicjalizacji: $e');
    }
  }

  Future<void> _pickAudioFolder() async {
    try {
      final dir = await _saf.pickDirectory();
      if (dir == null) return;
      _audioFolderUri = dir.uri;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsAudioFolder, _audioFolderUri!);
      debugPrint('Audio folder: $_audioFolderUri');
      if (!mounted) return;
      setState(() {});
      await _renderCurrentFile();
    } catch (e) {
      debugPrint('Błąd wyboru folderu audio: $e');
    }
  }

  Future<void> _showPickAudioFolderDialog() async {
    if (!mounted) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Folder z plikami MP3'),
        content: const Text(
          'Wybierz folder, w którym trzymasz pliki MP3 do odtwarzania.\n\n'
          'Pliki MP3 muszą mieć taką samą nazwę jak pliki XML/MXL '
          '(np. 01_Cicha_noc.mxl → 01_Cicha_noc.mp3).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Później'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Wybierz folder'),
          ),
        ],
      ),
    );
    if (result == true) {
      await _pickAudioFolder();
    }
  }

  Future<String?> _findAudioFor(String fileName) async {
    if (_audioFolderUri == null) return null;
    try {
      final mp3Name = fileName.replaceAll(
        RegExp(r'\.(xml|mxl|musicxml|mei|png|jpg|jpeg|webp)$', caseSensitive: false),
        '.mp3',
      );
      final files = await _saf.list(_audioFolderUri!);
      for (final f in files) {
        if (f.name.toLowerCase() == mp3Name.toLowerCase()) {
          debugPrint('Znaleziono MP3: ${f.name}');
          return f.uri;
        }
      }
      debugPrint('Brak MP3 dla $mp3Name');
      return null;
    } catch (e) {
      debugPrint('Błąd szukania MP3: $e');
      return null;
    }
  }

  Future<void> _onAudioPressed() async {
    if (_audioUri == null) return;

    final now = DateTime.now();

    if (_lastPlayPress != null &&
        now.difference(_lastPlayPress!).inMilliseconds < 400) {
      _lastPlayPress = null;
      try {
        if (_audioPlaying) {
          await _audioPlayer.pause();
          if (mounted) {
            setState(() {
              _audioPaused = true;
              _audioPlaying = false;
            });
          }
        }
      } catch (e) {
        debugPrint('Błąd pauzy: $e');
      }
      return;
    }
    _lastPlayPress = now;

    Future.delayed(const Duration(milliseconds: 400), () async {
      if (_lastPlayPress != now) return;
      _lastPlayPress = null;

      try {
        if (_audioPaused) {
          await _audioPlayer.resume();
          if (mounted) {
            setState(() {
              _audioPaused = false;
              _audioPlaying = true;
            });
          }
          return;
        }

        if (_audioPlaying) {
          await _audioPlayer.stop();
          await _audioPlayer.seek(Duration.zero);
          if (mounted) {
            setState(() {
              _audioPlaying = false;
              _audioPaused = false;
            });
          }
          return;
        }

        final bytes = await _saf.readFileBytes(_audioUri!);
        final tempDir = await getTemporaryDirectory();
        final tempFile = File('${tempDir.path}/audio_current.mp3');
        await tempFile.writeAsBytes(Uint8List.fromList(bytes));
        _audioTempPath = tempFile.path;

        await _audioPlayer.stop();
        await _audioPlayer.play(DeviceFileSource(_audioTempPath!));
        if (mounted) {
          setState(() {
            _audioPlaying = true;
            _audioPaused = false;
          });
        }
      } catch (e) {
        debugPrint('Błąd audio: $e');
      }
    });
  }

  Future<void> _stopAudio() async {
    try {
      await _audioPlayer.stop();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _audioPlaying = false;
        _audioPaused = false;
      });
    }
  }

  int _computePageWidth(double screenWidth) {
    const base = 2100;
    final scaleFactor = 70 / _zoomValue;
    return (base * scaleFactor).round().clamp(600, 6000);
  }

  /// Wyciąga oryginalną tonikę z XML (fifths → nazwa dur).
  Future<String> _extractOriginalKey(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final isMxl = path.toLowerCase().endsWith('.mxl');

      String xmlContent;
      if (isMxl) {
        final archive = ZipDecoder().decodeBytes(bytes);
        final xmlFile = archive.files.firstWhere(
          (f) =>
              !f.name.toUpperCase().startsWith('META-INF/') &&
              (f.name.toLowerCase().endsWith('.xml') ||
                  f.name.toLowerCase().endsWith('.musicxml')),
          orElse: () => throw Exception('Brak XML w MXL'),
        );
        xmlContent = utf8.decode(xmlFile.content);
      } else {
        xmlContent = utf8.decode(bytes);
      }

      final doc = XmlDocument.parse(xmlContent);
      final keyEl = doc.findAllElements('key').firstOrNull;
      if (keyEl == null) return '';

      final fifths =
          int.tryParse(keyEl.getElement('fifths')?.innerText ?? '0') ?? 0;

      const map = {
        -7: 'c',
        -6: 'fs',
        -5: 'df',
        -4: 'af',
        -3: 'ef',
        -2: 'bf',
        -1: 'f',
        0: 'c',
        1: 'g',
        2: 'd',
        3: 'a',
        4: 'e',
        5: 'b',
        6: 'fs',
        7: 'df',
      };
      return map[fifths] ?? '';
    } catch (e) {
      debugPrint('Błąd ekstrakcji tonacji: $e');
      return '';
    }
  }

  Future<void> _renderCurrentFile() async {
    _toggleBar();

    try {
      final screenWidth = MediaQuery.of(context).size.width;

      // Zapisz oryginalną tonikę (raz — tylko jeśli nie zapisana)
      final prefs = await SharedPreferences.getInstance();
      final origKey = 'viewer-original-key-$_fileKey';
      if (prefs.getString(origKey) == null) {
        final extracted = await _extractOriginalKey(_currentPath);
        if (extracted.isNotEmpty) {
          await prefs.setString(origKey, extracted);
          debugPrint('=== Zapisano oryginalną tonikę: $extracted');
        }
      }

      final options = <String, Object?>{
        'scale': _zoomValue,
        'pageWidth': _computePageWidth(screenWidth),
        'adjustPageHeight': true,
        'breaks': 'auto',
        'footer': 'none',
        'header': 'none',
        'mnumInterval': 0,
        'spacingSystem': _spacingValue > 0 ? _spacingValue : 2,
        'transpose': _effectiveTranspose,
        'font': _selectedFont,
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

      final audioUri = await _findAudioFor(_fileKey);
      if (!mounted) return;
      setState(() {
        _audioUri = audioUri;
        if (audioUri == null) {
          _audioPlaying = false;
          _audioPaused = false;
        }
      });

      _toggleBar();
    } catch (e) {
      debugPrint('Błąd: $e');
      _toggleBar();
    }
  }

  Future<void> _navigate(int direction) async {
    final newIndex = _currentIndex + direction;
    if (newIndex < 0 || newIndex >= _navList.length) return;

    await _stopAudio();
    await _savePrefsForCurrentFile();

    setState(() {
      _currentIndex = newIndex;
      _currentPath = _navList[newIndex];
      _audioUri = null;
      _audioPlaying = false;
      _audioPaused = false;
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
    sb.writeln(
        '    var systems = svg.querySelectorAll("g.system, g[class~=\\"system\\"]");');
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
    sb.writeln('        var original = g.getAttribute("transform") || "";');
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

  Future<void> _changeOctave(int direction) async {
    setState(() {
      if (_octaveShift == direction) {
        _octaveShift = 0;
      } else {
        _octaveShift = direction;
      }
    });
    await _savePrefsForCurrentFile();
    _toggleBar();
    await _renderCurrentFile();
  }

  Future<void> _changeFont(String font) async {
    if (font == _selectedFont) return;
    setState(() => _selectedFont = font);
    await _savePrefsForCurrentFile();
    _toggleBar();
    await _renderCurrentFile();
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

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent) {
          final k = event.logicalKey;
          if (k == LogicalKeyboardKey.arrowLeft ||
              k == LogicalKeyboardKey.pageUp) {
            _navigate(-1);
          } else if (k == LogicalKeyboardKey.arrowRight ||
              k == LogicalKeyboardKey.pageDown) {
            _navigate(1);
          } else if (k == LogicalKeyboardKey.escape) {
            Navigator.pop(context);
          }
        }
      },
      child: Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _isImage
                ? PhotoView(
                    key: ValueKey('img_$_currentPath'),
                    imageProvider: FileImage(File(_currentPath)),
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 3.0,
                    initialScale: PhotoViewComputedScale.contained,
                    backgroundDecoration:
                        const BoxDecoration(color: Colors.black),
                  )
                : _webController == null
                    ? const Center(child: CircularProgressIndicator())
                    : WebViewWidget(controller: _webController!),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _toggleBar,
              onDoubleTap: () async {
                await _stopAudio();
                _hideTimer?.cancel();
                if (!mounted) return;
                Navigator.pop(context);
              },
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            top: _barVisible ? 0 : -100,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                color: Colors.black.withValues(alpha: 0.72),
                child: Row(
                  children: [
                    if (_hasNavigation)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '${_currentIndex + 1}/${_navList.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(width: 4),
                    _miniLabel('Z'),
                    _tinyBtn(
                      icon: Icons.remove,
                      onPressed: () => _changeZoom(-5),
                    ),
                    _tinyBox('$_zoomValue'),
                    _tinyBtn(
                      icon: Icons.add,
                      onPressed: () => _changeZoom(5),
                    ),
                    const SizedBox(width: 6),
                    _miniLabel('W'),
                    _tinyBtn(
                      icon: Icons.remove,
                      onPressed: () => _changeSpacing(-1),
                    ),
                    _tinyBox(_spacingValue > 0
                        ? '+$_spacingValue'
                        : '$_spacingValue'),
                    _tinyBtn(
                      icon: Icons.add,
                      onPressed: () => _changeSpacing(1),
                    ),
                    const SizedBox(width: 6),
                    _compactToggle(
                      label: _viewLabels[_viewMode] ?? 'N',
                      active: _viewMode == 'both',
                      onPressed: _cycleViewMode,
                    ),
                    const SizedBox(width: 6),
                    _compactDropdown<String>(
                      value: _transposeValue,
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
                    const SizedBox(width: 6),
                    _miniLabel('Okt'),
                    _octaveBtn(
                      icon: Icons.keyboard_arrow_down,
                      active: _octaveShift == -1,
                      onPressed: () => _changeOctave(-1),
                      tooltip: 'Oktawa w dół',
                    ),
                    _octaveBox(),
                    _octaveBtn(
                      icon: Icons.keyboard_arrow_up,
                      active: _octaveShift == 1,
                      onPressed: () => _changeOctave(1),
                      tooltip: 'Oktawa w górę',
                    ),
                    const SizedBox(width: 6),
                    _compactDropdown<String>(
                      value: _selectedFont,
                      items: _fontLabels.entries
                          .map((e) => DropdownMenuItem<String>(
                                value: e.key,
                                child: Text(e.value),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) _changeFont(v);
                      },
                    ),
                    const SizedBox(width: 6),
                    _audioBtn(),
                    const SizedBox(width: 6),
                   IconButton(
  icon: const Text(
    'A',
    style: TextStyle(
      color: Colors.white,
      fontSize: 22,
      fontWeight: FontWeight.bold,
    ),
  ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 40, minHeight: 34),
                      onPressed: () {
                        _hideTimer?.cancel();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                ChordsScreen(filePath: _currentPath),
                          ),
                        );
                      },
                      tooltip: 'Akordy',
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(
                        Icons.more_vert,
                        color: Colors.white,
                        size: 28,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 52, minHeight: 52),
                      onPressed: _showMainMenu,
                      tooltip: 'Menu',
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back,
                        color: Colors.white,
                        size: 44,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 72, minHeight: 72),
                      onPressed: () async {
                        await _stopAudio();
                        _hideTimer?.cancel();
                        if (!mounted) return;
                        Navigator.pop(context);
                      },
                      tooltip: 'Wróć do listy',
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
              bottom: _barVisible ? 0 : -100,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  color: Colors.black.withValues(alpha: 0.72),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios,
                          color: _currentIndex > 0
                              ? Colors.white
                              : Colors.white30,
                          size: 28,
                        ),
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 52, minHeight: 52),
                        onPressed:
                            _currentIndex > 0 ? () => _navigate(-1) : null,
                        tooltip: 'Poprzedni',
                      ),
                      Expanded(
                        child: Text(
                          _cleanTitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
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
                          size: 28,
                        ),
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 52, minHeight: 52),
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
      ),
    );
  }

  Future<void> _showMainMenu() async {
    _hideTimer?.cancel();
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Wybierz folder audio (MP3)'),
              subtitle: Text(
                _audioFolderUri == null
                    ? 'Nie wybrano folderu'
                    : 'Folder ustawiony',
                style: const TextStyle(fontSize: 12),
              ),
              onTap: () => Navigator.pop(ctx, 'audio_folder'),
            ),
            if (_audioFolderUri != null)
              ListTile(
                leading: const Icon(Icons.cleaning_services),
                title: const Text('Wyczyść folder audio'),
                onTap: () => Navigator.pop(ctx, 'clear_audio_folder'),
              ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    if (action == 'audio_folder') {
      await _pickAudioFolder();
    } else if (action == 'clear_audio_folder') {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsAudioFolder);
      if (!mounted) return;
      setState(() {
        _audioFolderUri = null;
        _audioUri = null;
        _audioPlaying = false;
        _audioPaused = false;
      });
      await _renderCurrentFile();
    }
  }

  Widget _miniLabel(String text) => Padding(
        padding: const EdgeInsets.only(right: 3, left: 3),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      );

  Widget _tinyBox(String text) => Container(
        constraints: const BoxConstraints(minWidth: 34),
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      );

  Widget _tinyBtn({required IconData icon, VoidCallback? onPressed}) =>
      SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          icon: Icon(icon, color: Colors.white, size: 20),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: onPressed,
        ),
      );

  Widget _octaveBtn({
    required IconData icon,
    required bool active,
    required VoidCallback onPressed,
    required String tooltip,
  }) =>
      SizedBox(
        width: 32,
        height: 32,
        child: Container(
          decoration: BoxDecoration(
            color: active ? const Color(0xFFd6ad23) : Colors.white12,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: active ? const Color(0xFFffe889) : Colors.white24,
            ),
          ),
          child: IconButton(
            icon: Icon(
              icon,
              color: active ? Colors.black : Colors.white,
              size: 20,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onPressed,
            tooltip: tooltip,
          ),
        ),
      );

  Widget _octaveBox() {
    final label = _octaveShift == 0
        ? '0'
        : (_octaveShift > 0 ? '+8' : '−8');
    final active = _octaveShift != 0;

    return Container(
      constraints: const BoxConstraints(minWidth: 34),
      alignment: Alignment.center,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFffe889) : Colors.white12,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.black : Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _audioBtn() {
    final hasAudio = _audioUri != null;
    final playing = _audioPlaying;
    final paused = _audioPaused;

    if (!hasAudio) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white24),
          ),
          child: const Text(
            'BRAK MP3',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    IconData icon;
    String tooltip;

    if (playing) {
      icon = Icons.stop;
      tooltip = 'Stop i na początek (2× klik → pauza)';
    } else if (paused) {
      icon = Icons.play_circle_filled;
      tooltip = 'Wznów od miejsca pauzy';
    } else {
      icon = Icons.play_arrow;
      tooltip = 'Graj MP3';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        width: 40,
        height: 34,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFd6ad23),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFFFFE889)),
          ),
          child: IconButton(
            icon: Icon(icon, color: Colors.black, size: 22),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 34),
            onPressed: _onAudioPressed,
            tooltip: tooltip,
          ),
        ),
      ),
    );
  }

  Widget _compactToggle({
    required String label,
    required bool active,
    required VoidCallback onPressed,
  }) =>
      GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 42,
          height: 34,
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
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );

  Widget _compactDropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required void Function(T?) onChanged,
  }) =>
      Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white24),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            dropdownColor: Colors.black87,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            icon: const Icon(Icons.arrow_drop_down,
                color: Colors.white, size: 18),
            isDense: true,
            items: items,
            onChanged: onChanged,
          ),
        ),
      );
}