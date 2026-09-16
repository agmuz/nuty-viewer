import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:saf/saf.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:verovio_flutter/verovio_flutter.dart';

class VerovioScreen extends StatefulWidget {
  final SafDocumentFile file;
  final Saf saf;
  final List<SafDocumentFile>? navigationList;
  final int currentIndex;
  final Future<void> Function(SafDocumentFile)? onFileChanged;

  const VerovioScreen({
    super.key,
    required this.file,
    required this.saf,
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

  bool _barVisible = true;
  Timer? _hideTimer;

  int _zoomValue = 70;
  int _spacingValue = 2;
  String _transposeValue = '';

  late List<SafDocumentFile> _navList;
  late int _currentIndex;
  late SafDocumentFile _currentFile;

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

  String get _fileKey => _currentFile.name;

  String _prefsKey(String setting) => 'viewer-$setting-$_fileKey';

  bool get _hasNavigation => _navList.length > 1;

  @override
  void initState() {
    super.initState();
    _currentFile = widget.file;
    _currentIndex = widget.currentIndex;
    _navList = widget.navigationList ?? [widget.file];
    _loadPrefsForCurrentFile().then((_) => _init());
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefsForCurrentFile() async {
    final prefs = await SharedPreferences.getInstance();
    _zoomValue = ((prefs.getInt(_prefsKey('zoom')) ?? 70) / 5).round() * 5;
    _zoomValue = _zoomValue.clamp(40, 140);
    _spacingValue = (prefs.getInt(_prefsKey('spacing')) ?? 2).clamp(-8, 20);
    _transposeValue = prefs.getString(_prefsKey('transpose')) ?? '';
  }

  Future<void> _savePrefsForCurrentFile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey('zoom'), _zoomValue);
    await prefs.setInt(_prefsKey('spacing'), _spacingValue);
    await prefs.setString(_prefsKey('transpose'), _transposeValue);
  }

  int _clampZoom(int v) => ((v / 5).round() * 5).clamp(40, 140);
  int _clampSpacing(int v) => v.clamp(-8, 20);

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
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
        ..enableZoom(false);

      if (!mounted) return;
      setState(() {
        _service = service;
        _webController = controller;
      });
      debugPrint('Verovio gotowe');

      await _renderCurrentFile();
    } catch (e) {
      debugPrint('Błąd inicjalizacji: $e');
    }
  }

  int _computePageWidth(double screenWidth) {
    const base = 2100;
    final scaleFactor = 70 / _zoomValue;
    return (base * scaleFactor).round().clamp(600, 6000);
  }

  Future<void> _renderCurrentFile() async {
    debugPrint('Renderowanie: ${_currentFile.name}');
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
        'spacingSystem': _spacingValue > 0 ? _spacingValue : 2,
        'transpose': _transposeValue,
      };
      await _service!.setOptionsJson(jsonEncode(options));

      final bytes = await widget.saf.readFileBytes(_currentFile.uri);
      final isMxl = _currentFile.name.toLowerCase().endsWith('.mxl');

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
      final trLabel = _keyLabels[_transposeValue] ?? 'ORG';
      debugPrint(
          'Z $_zoomValue%  W ${_spacingValue > 0 ? "+$_spacingValue" : "$_spacingValue"}  T $trLabel');
      _toggleBar();
    } catch (e) {
      debugPrint('Błąd: $e');
      _toggleBar();
    }
  }

  Future<void> _navigate(int direction) async {
    final newIndex = _currentIndex + direction;
    if (newIndex < 0 || newIndex >= _navList.length) {
      return;
    }

    await _savePrefsForCurrentFile();

    setState(() {
      _currentIndex = newIndex;
      _currentFile = _navList[newIndex];
    });

    // Poinformuj FileListScreen — oznacz jako zagrany
    await widget.onFileChanged?.call(_currentFile);

    await _loadPrefsForCurrentFile();

    await _renderCurrentFile();
  }

  String _svgHtmlWithSpacing(String svg) {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    html, body { margin: 0; padding: 12px; background: #fff; }
    svg { display: block; max-width: 100%; height: auto; }
  </style>
</head>
<body>
$svg
<script>
(function() {
  var spacingValue = $_spacingValue;
  function compactSystems() {
    var svg = document.querySelector('svg');
    if (!svg) return;
    var systems = svg.querySelectorAll('g.system, g[class~="system"]');
    if (systems.length < 2) return;
    var vb = svg.viewBox && svg.viewBox.baseVal;
    if (!vb || !vb.width) return;
    var renderedWidth = svg.getBoundingClientRect().width;
    if (!renderedWidth) return;
    var unitsPerPx = vb.width / renderedWidth;
    if (spacingValue < 0) {
      var strength = Math.min(0.78, Math.abs(spacingValue) * 0.085);
      var tops = [];
      systems.forEach(function(g) { tops.push(g.getBoundingClientRect().top); });
      var firstTop = tops[0];
      var largestShift = 0;
      systems.forEach(function(g, index) {
        if (index === 0) return;
        var shift = (tops[index] - firstTop) * strength * unitsPerPx;
        largestShift = Math.max(largestShift, shift);
        var original = g.getAttribute('transform') || '';
        g.setAttribute('transform', 'translate(0 ' + (-shift) + ') ' + original);
      });
      var newHeight = Math.max(vb.height * 0.35, vb.height - largestShift);
      svg.setAttribute('viewBox', vb.x + ' ' + vb.y + ' ' + vb.width + ' ' + newHeight);
      svg.removeAttribute('height');
    } else if (spacingValue > 2) {
      var extra = (spacingValue - 2) * 0.085;
      systems.forEach(function(g, index) {
        if (index === 0) return;
        var prev = systems[index - 1];
        var prevRect = prev.getBoundingClientRect();
        var curRect = g.getBoundingClientRect();
        var currentGap = curRect.top - prevRect.bottom;
        var extraShift = currentGap * extra * unitsPerPx;
        var original = g.getAttribute('transform') || '';
        g.setAttribute('transform', 'translate(0 ' + extraShift + ') ' + original);
      });
      var newHeight = vb.height * (1 + extra * systems.length * 0.1);
      svg.setAttribute('viewBox', vb.x + ' ' + vb.y + ' ' + vb.width + ' ' + newHeight);
      svg.removeAttribute('height');
    }
  }
  setTimeout(compactSystems, 50);
})();
</script>
</body>
</html>
''';
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
              onHorizontalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity < -300) {
                  _navigate(1);
                } else if (velocity > 300) {
                  _navigate(-1);
                }
              },
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
                      onPressed: () => Navigator.pop(context),
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
                          _currentFile.name.replaceAll(
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
}