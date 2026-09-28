import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf/saf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:file_picker/file_picker.dart';

class ChordsScreen extends StatefulWidget {
  final String filePath;

  const ChordsScreen({super.key, required this.filePath});

  @override
  State<ChordsScreen> createState() => _ChordsScreenState();
}

class _ChordsScreenState extends State<ChordsScreen> {
  List<List<String>> _phrases = [];
  bool _loading = true;
  String _status = 'Wczytywanie...';

  // Audio
  final Saf _saf = Saf();
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _audioFolderUri;
  String? _audioUri;
  String? _audioTempPath;
  bool _audioPlaying = false;
  bool _audioPaused = false;
  DateTime? _lastPlayPress;

  // Offset dla trąbki B → instrumenty C: −2 półtony
  static const int _semitonesDown = -2;
  static const String _prefsAudioFolder = 'audio_folder_uri';

  static const List<String> _chromatic = [
    'C', 'Des', 'D', 'Es', 'E', 'F', 'Fis', 'G', 'As', 'A', 'B', 'H'
  ];

  String get _title {
    var name = widget.filePath.split('/').last;
    name = name.replaceAll(
      RegExp(r'\.(xml|mxl|musicxml|mei)$', caseSensitive: false),
      '',
    );
    final parts = name.split('_');
    if (parts.length > 1 && int.tryParse(parts.first) != null) {
      name = parts.sublist(1).join(' ');
    }
    return name.replaceAll('_', ' ');
  }

  @override
  void initState() {
    super.initState();

    _audioPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _audioPlaying = false;
        _audioPaused = false;
      });
    });

    _load();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final baseKey = widget.filePath.split('/').last;
      final baseTranspose =
          prefs.getString('viewer-transpose-$baseKey') ?? '';
      final originalKey =
          prefs.getString('viewer-original-key-$baseKey') ?? '';
      _audioFolderUri = prefs.getString(_prefsAudioFolder);

      final selectedPc = _keyToPitch(baseTranspose);
      final originalPc = _keyToPitch(originalKey);

      int offset;
      if (selectedPc >= 0 && originalPc >= 0) {
        offset = (selectedPc - originalPc + _semitonesDown) % 12;
      } else {
        offset = _semitonesDown;
      }
      if (offset < 0) offset += 12;

      debugPrint('=== Akordy: orig=$originalKey(pc=$originalPc), '
          'sel=$baseTranspose(pc=$selectedPc), offset=$offset');

      // Znajdź MP3
      _audioUri = await _findAudioFor(baseKey);

      final bytes = await File(widget.filePath).readAsBytes();
      final isMxl = widget.filePath.toLowerCase().endsWith('.mxl');

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
      final measures = doc.findAllElements('measure').toList();

      // Pomiń przedtakt — zacznij od pierwszego taktu z akordem
      final List<String> measureChords = [];
      final List<bool> measureBarlines = [];  // true = po tym takcie wymuś nowy wiersz
      String lastChord = '';
      bool firstChordFound = false;

      for (final m in measures) {
        final harmonies = m.findAllElements('harmony').toList();

        if (!firstChordFound) {
          if (harmonies.isEmpty) {
            // przedtakt — pomijamy
            continue;
          } else {
            firstChordFound = true;
          }
        }

        if (harmonies.isEmpty) {
          measureChords.add(lastChord);
        } else {
          final parts = <String>[];
          for (final h in harmonies) {
            final chord = _parseChord(h, offset);
            if (chord.isNotEmpty) parts.add(chord);
          }
          final combined = parts.join(' ');
          measureChords.add(combined);
          if (combined.isNotEmpty) lastChord = combined;
        }

        // Sprawdź czy w tym takcie jest kreska taktowa wymuszająca nowy wiersz
        measureBarlines.add(_hasForcedBreak(m));
      }

      // Buduj wiersze z podziałem na:
      // - max 8 taktów
      // - ale jeśli po 8. takcie zostają 1 lub 2 takty, PO KTÓRYCH
      //   jest kreska LUB koniec utworu → dołącz je (max 10 taktów)
      // - kreski: light-light, light-heavy, heavy-light, heavy-heavy
      // - repetycja koniec (<repeat backward>)
      // - repetycja startowa NIE dzieli (location="left" / <repeat forward>)
      final phrases = <List<String>>[];
      var currentPhrase = <String>[];
      const baseLimit = 8;
      const maxLimit = 10;

      for (var i = 0; i < measureChords.length; i++) {
        currentPhrase.add(measureChords[i]);

        final isLast = i == measureChords.length - 1;
        final forceBreak =
            i > 0 && i < measureBarlines.length && measureBarlines[i];

        // Czy po tym takcie (po 8. pozycji) następne 1-2 takty kończą się
        // kreską lub końcem utworu? Wtedy przedłużamy wiersz do max 10 taktów.
        bool canOverflow = false;
        if (currentPhrase.length >= baseLimit &&
            currentPhrase.length < maxLimit &&
            !forceBreak &&
            !isLast) {
          // Sprawdź czy takt po nas (i+1) ma kreskę lub jest ostatni
          final nextIdx = i + 1;
          final nextIsLast = nextIdx == measureChords.length - 1;
          final nextHasBreak = nextIdx < measureBarlines.length &&
              measureBarlines[nextIdx];

          // Sprawdź czy takt po nastepnym (i+2) ma kreskę lub jest ostatni
          final next2Idx = i + 2;
          final next2IsLast = next2Idx == measureChords.length - 1;
          final next2HasBreak =
              next2Idx < measureBarlines.length && measureBarlines[next2Idx];

          if (nextIsLast || nextHasBreak || next2IsLast || next2HasBreak) {
            canOverflow = true;
          }
        }

        final hitLimit = currentPhrase.length >= baseLimit && !canOverflow;

        if (hitLimit || forceBreak || isLast) {
          phrases.add(currentPhrase);
          currentPhrase = <String>[];
        }
      }

      if (!mounted) return;
      setState(() {
        _phrases = phrases;
        _loading = false;
        _status = phrases.isEmpty ? 'Brak akordów w pliku' : '';
      });
    } catch (e) {
      debugPrint('=== Błąd ChordsScreen: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = 'Błąd: $e';
      });
    }
  }

  int _keyToPitch(String key) {
    switch (key) {
      case 'c': return 0;
      case 'df': return 1;
      case 'd': return 2;
      case 'ef': return 3;
      case 'e': return 4;
      case 'f': return 5;
      case 'fs': return 6;
      case 'g': return 7;
      case 'af': return 8;
      case 'a': return 9;
      case 'bf': return 10;
      case 'b': return 11;
      default: return -1;
    }
  }

  /// Sprawdza czy w tym takcie jest kreska taktowa / repetycja wymuszająca nowy wiersz.
  /// Rozpoznaje:
  /// - <barline location="right"><bar-style>light-light</bar-style></barline> (podwójna cienka)
  /// - <barline location="right"><bar-style>light-heavy</bar-style></barline> (końcowa)
  /// - <barline location="right"><bar-style>heavy-light</bar-style></barline> (repetycja start)
  /// - <barline location="right"><repeat direction="forward"/></barline>
  /// - <barline location="right"><repeat direction="backward"/></barline>
  bool _hasForcedBreak(XmlElement measure) {
    final barlines = measure.findAllElements('barline');
    for (final bl in barlines) {
      // Bierzemy pod uwagę TYLKO kreski na KOŃCU taktu (location="right").
      // Repetycja startowa (location="left") NIE dzieli wiersza.
      final location = bl.getAttribute('location') ?? 'right';
      if (location != 'right') continue;

      // bar-style wymuszający nowy wiersz:
      // - light-light: podwójna cienka
      // - light-heavy: końcowa (cienka + gruba)
      // - heavy-light: koniec repetycji / odwrócona końcowa (gruba + cienka)
      // - heavy-heavy: podwójna gruba
      final style = bl.getElement('bar-style')?.innerText ?? '';
      if (style == 'light-light' ||
          style == 'light-heavy' ||
          style == 'heavy-light' ||
          style == 'heavy-heavy') {
        return true;
      }

      // <repeat direction="backward"> = KONIEC repetycji → dzielimy
      // <repeat direction="forward"> = POCZĄTEK repetycji → NIE dzielimy
      final repeat = bl.getElement('repeat');
      if (repeat != null) {
        final dir = repeat.getAttribute('direction') ?? '';
        if (dir == 'backward') return true;
      }
    }
    return false;
  }

  String _parseChord(XmlElement h, int offset) {
    final rootStep =
        h.getElement('root')?.getElement('root-step')?.innerText ?? '';
    final rootAlter =
        h.getElement('root')?.getElement('root-alter')?.innerText ?? '';
    final kind = h.getElement('kind')?.innerText ?? '';

    if (rootStep.isEmpty) return '';

    int pc = _pitchClassFromStep(rootStep, rootAlter);
    if (pc < 0) return '';

    pc = (pc + offset) % 12;
    if (pc < 0) pc += 12;

    return '${_chromatic[pc]}${_kindToSuffix(kind)}';
  }

  int _pitchClassFromStep(String step, String alter) {
    const map = {
      'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11,
    };
    final base = map[step.toUpperCase()];
    if (base == null) return -1;
    final a = int.tryParse(alter) ?? 0;
    return (base + a) % 12;
  }

  String _kindToSuffix(String kind) {
    switch (kind.toLowerCase()) {
      case 'major': return '';
      case 'minor': return 'm';
      case 'dominant': return '7';
      case 'major-seventh': return 'maj7';
      case 'minor-seventh': return 'm7';
      case 'diminished': return 'dim';
      case 'diminished-seventh': return 'dim7';
      case 'augmented': return 'aug';
      case 'half-diminished': return 'm7b5';
      case 'major-sixth': return '6';
      case 'minor-sixth': return 'm6';
      case 'dominant-ninth': return '9';
      case 'major-ninth': return 'maj9';
      case 'minor-ninth': return 'm9';
      case 'suspended-fourth': return 'sus4';
      case 'suspended-second': return 'sus2';
      default: return kind;
    }
  }

  // ── AUDIO (SAF) ──────────────────────────────────────────────

  Future<String?> _findAudioFor(String fileName) async {
    if (_audioFolderUri == null) return null;
    try {
      final mp3Name = fileName.replaceAll(
        RegExp(r'\.(xml|mxl|musicxml|mei)$', caseSensitive: false),
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
        final tempFile = File('${tempDir.path}/audio_chords.mp3');
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

  Future<void> _exportToPdf() async {
    try {
      final doc = pw.Document();

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          build: (pw.Context ctx) {
            final widgets = <pw.Widget>[];

            // Tytuł
            widgets.add(
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 16),
                child: pw.Text(
                  _title,
                  style: pw.TextStyle(
                    fontSize: 22,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            );

            // Wiersze akordów
            for (final phrase in _phrases) {
              final line = phrase.where((c) => c.isNotEmpty).join(' | ');
              if (line.isEmpty) continue;
              widgets.add(
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 12),
                  child: pw.Text(
                    line,
                    style: const pw.TextStyle(fontSize: 18),
                  ),
                ),
              );
            }

            return widgets;
          },
        ),
      );

      final bytes = await doc.save();
      final safeName = _title
          .replaceAll(RegExp(r'[^\w\s\-]'), '')
          .replaceAll(RegExp(r'\s+'), '_');
      final suggestedName = '${safeName.isEmpty ? "akordy" : safeName}.pdf';

      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Zapisz PDF',
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        bytes: Uint8List.fromList(bytes),
      );
      if (savePath == null) return;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Zapisano PDF: $savePath')),
      );
    } catch (e) {
      debugPrint('Błąd PDF: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd PDF: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        backgroundColor: const Color(0xFF132845),
        foregroundColor: Colors.white,
        actions: [
          Center(child: _audioBtn()),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Zapisz jako PDF',
            onPressed: _exportToPdf,
          ),
          const SizedBox(width: 8),
        ],
      ),
      backgroundColor: const Color(0xFF132845),
      body: _loading
          ? Center(child: Text(_status))
          : _phrases.isEmpty
              ? Center(child: Text(_status))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _phrases.length,
                  itemBuilder: (context, index) {
                    final phrase = _phrases[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E3A5F),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: const Color(0xFFd6ad23), width: 2),
                      ),
                      child: Row(
                        children: List.generate(8, (i) {
                          final chord = i < phrase.length ? phrase[i] : '';
                          return Expanded(
                            child: Center(
                              child: Text(
                                chord,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    );
                  },
                ),
    );
  }
}