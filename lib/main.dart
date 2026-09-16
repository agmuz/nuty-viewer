import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:saf/saf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'verovio_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Nuty',
      home: FileListScreen(),
    );
  }
}

class Playlist {
  final String id;
  final String name;
  final List<String> fileNames;

  Playlist({required this.id, required this.name, required this.fileNames});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'fileNames': fileNames,
      };

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
        id: json['id'] as String,
        name: json['name'] as String,
        fileNames: (json['fileNames'] as List).cast<String>(),
      );
}

class FileListScreen extends StatefulWidget {
  const FileListScreen({super.key});

  @override
  State<FileListScreen> createState() => _FileListScreenState();
}

class _FileListScreenState extends State<FileListScreen> {
  final Saf _saf = Saf();
  String? _folderUri;
  List<SafDocumentFile> _files = [];
  List<SafDocumentFile> _filteredFiles = [];
  List<Playlist> _playlists = [];
  bool _loading = true;
  String _status = 'Ładowanie...';
  final TextEditingController _searchController = TextEditingController();

  bool _buildMode = false;
  Playlist? _editingPlaylist;
  List<String> _selectedFileNames = [];
  final TextEditingController _playlistNameController = TextEditingController();

  String? _activePlaylistId;
  Map<String, List<String>> _playedByPlaylist = {};

  bool _searchOpen = false;

  static const _playedAllKey = 'all';

  @override
  void initState() {
    super.initState();
    _init();
    _searchController.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _playlistNameController.dispose();
    super.dispose();
  }

  String get _currentPlayedKey => _activePlaylistId ?? _playedAllKey;

  void _applyFilter() {
    final query = _searchController.text.toLowerCase().trim();
    setState(() {
      var base = _files;

      if (_activePlaylistId != null) {
        final pl = _playlists.firstWhere(
          (p) => p.id == _activePlaylistId,
          orElse: () => Playlist(id: '', name: '', fileNames: []),
        );
        base = _files.where((f) => pl.fileNames.contains(f.name)).toList();
        final order = {
          for (var i = 0; i < pl.fileNames.length; i++) pl.fileNames[i]: i
        };
        base.sort((a, b) =>
            (order[a.name] ?? 9999).compareTo(order[b.name] ?? 9999));
      }

      if (query.isEmpty) {
        _filteredFiles = base;
      } else {
        _filteredFiles = base
            .where((f) => f.name.toLowerCase().contains(query))
            .toList();
      }
    });
  }

  Future<void> _init() async {
    await _loadPlaylists();
    await _loadPlayed();

    final prefs = await SharedPreferences.getInstance();
    _folderUri = prefs.getString('nuty_folder_uri');

    if (_folderUri == null) {
      await _pickFolder();
    } else {
      final grants = await _saf.persistedPermissions();
      final hasGrant = grants.any((g) => g.uri == _folderUri);
      if (hasGrant) {
        await _scanFolder();
      } else {
        await _pickFolder();
      }
    }
  }

  Future<void> _loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('playlists');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _playlists = list
            .map((j) => Playlist.fromJson(j as Map<String, dynamic>))
            .toList();
      } catch (e) {
        _playlists = [];
      }
    }
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_playlists.map((p) => p.toJson()).toList());
    await prefs.setString('playlists', raw);
  }

  Future<void> _loadPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('played');
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _playedByPlaylist = map.map(
          (k, v) => MapEntry(k, (v as List).cast<String>()),
        );
      } catch (e) {
        _playedByPlaylist = {};
      }
    }
  }

  Future<void> _savePlayed() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_playedByPlaylist);
    await prefs.setString('played', raw);
  }

  Future<void> _pickFolder() async {
    setState(() => _status = 'Wybierz folder z nutami...');
    final dir = await _saf.pickDirectory();
    if (dir == null) {
      setState(() {
        _loading = false;
        _status = 'Nie wybrano folderu. Kliknij, aby wybrać.';
      });
      return;
    }
    _folderUri = dir.uri;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nuty_folder_uri', _folderUri!);
    await _scanFolder();
  }

  Future<void> _scanFolder() async {
    setState(() {
      _loading = true;
      _status = 'Skanowanie...';
    });

    try {
      final files = await _saf.list(_folderUri!);
      final musicFiles = files.where((f) {
        final name = f.name.toLowerCase();
        return name.endsWith('.xml') ||
            name.endsWith('.mxl') ||
            name.endsWith('.musicxml') ||
            name.endsWith('.mei');
      }).toList();

      musicFiles.sort((a, b) {
        final aNum = int.tryParse(a.name.split('_').first) ?? 9999;
        final bNum = int.tryParse(b.name.split('_').first) ?? 9999;
        if (aNum != bNum) return aNum.compareTo(bNum);
        return a.name.compareTo(b.name);
      });

      setState(() {
        _files = musicFiles;
        _filteredFiles = musicFiles;
        _loading = false;
        _status = '${musicFiles.length} plików';
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _status = 'Błąd skanowania: $e';
      });
    }
  }

  /// Zapisuje plik jako "zagrany" w kontekście aktualnego widoku.
  Future<void> _markAsPlayed(String fileName) async {
    final key = _currentPlayedKey;
    final played = _playedByPlaylist[key] ?? [];
    if (!played.contains(fileName)) {
      played.add(fileName);
      _playedByPlaylist[key] = played;
      await _savePlayed();
      if (mounted) setState(() {});
    }
  }

  Future<void> _openFile(SafDocumentFile file, {int? index}) async {
    await _markAsPlayed(file.name);

    if (!mounted) return;

    final navigationList = List<SafDocumentFile>.from(_filteredFiles);
    final currentIndex =
        index ?? navigationList.indexWhere((f) => f.name == file.name);
    final safeIndex = currentIndex < 0 ? 0 : currentIndex;

    // Callback — gdy VerovioScreen zmieni utwór przez swipe/przycisk
    final onFileChanged = (SafDocumentFile newFile) async {
      await _markAsPlayed(newFile.name);
    };

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VerovioScreen(
          file: file,
          saf: _saf,
          navigationList: navigationList,
          currentIndex: safeIndex,
          onFileChanged: onFileChanged,
        ),
      ),
    );

    // Po powrocie odśwież widok — kafelki beżowe
    if (mounted) setState(() {});
  }

  void _startNewPlaylist() {
    setState(() {
      _buildMode = true;
      _editingPlaylist = null;
      _selectedFileNames = [];
      _playlistNameController.text = '';
      _activePlaylistId = null;
      _applyFilter();
    });
  }

  void _startEditPlaylist(Playlist pl) {
    setState(() {
      _buildMode = true;
      _editingPlaylist = pl;
      _selectedFileNames = List.from(pl.fileNames);
      _playlistNameController.text = pl.name;
      _activePlaylistId = null;
      _applyFilter();
    });
  }

  void _toggleSelection(SafDocumentFile file) {
    setState(() {
      if (_selectedFileNames.contains(file.name)) {
        _selectedFileNames.remove(file.name);
      } else {
        _selectedFileNames.add(file.name);
      }
    });
  }

  Future<void> _saveBuildPlaylist() async {
    final name = _playlistNameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Podaj nazwę playlisty')),
      );
      return;
    }
    if (_selectedFileNames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wybierz co najmniej jeden utwór')),
      );
      return;
    }

    setState(() {
      if (_editingPlaylist != null) {
        final idx = _playlists.indexWhere((p) => p.id == _editingPlaylist!.id);
        if (idx >= 0) {
          _playlists[idx] = Playlist(
            id: _editingPlaylist!.id,
            name: name,
            fileNames: List.from(_selectedFileNames),
          );
        }
      } else {
        _playlists.add(Playlist(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: name,
          fileNames: List.from(_selectedFileNames),
        ));
      }
    });
    await _savePlaylists();

    if (!mounted) return;
    setState(() {
      _buildMode = false;
      _editingPlaylist = null;
      _selectedFileNames = [];
      _playlistNameController.text = '';
      _applyFilter();
    });
  }

  void _cancelBuild() {
    setState(() {
      _buildMode = false;
      _editingPlaylist = null;
      _selectedFileNames = [];
      _playlistNameController.text = '';
    });
  }

  void _openPlaylist(Playlist pl) {
    setState(() {
      _activePlaylistId = pl.id;
      _searchController.clear();
      _applyFilter();
    });
  }

  void _closePlaylist() {
    setState(() {
      _activePlaylistId = null;
      _applyFilter();
    });
  }

  Future<void> _showPlaylistMenu(Playlist pl) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                pl.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('Otwórz playlistę'),
              onTap: () => Navigator.pop(ctx, 'open'),
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Edytuj playlistę'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.cleaning_services),
              title: const Text('Wyczyść oznaczenia'),
              onTap: () => Navigator.pop(ctx, 'clear'),
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text(
                'Usuń playlistę',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    if (action == 'open') {
      _openPlaylist(pl);
    } else if (action == 'edit') {
      _startEditPlaylist(pl);
    } else if (action == 'clear') {
      await _clearPlayed(pl.id);
    } else if (action == 'delete') {
      await _deletePlaylist(pl);
    }
  }

  Future<void> _clearPlayed(String key) async {
    setState(() {
      _playedByPlaylist[key] = [];
    });
    await _savePlayed();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Oznaczenia wyczyszczone')),
      );
    }
  }

  Future<void> _clearCurrentPlayed() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wyczyścić oznaczenia?'),
        content: const Text('Wszystkie beżowe kafelki wrócą do niebieskiego.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anuluj'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Wyczyść'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _clearPlayed(_currentPlayedKey);
    }
  }

  Future<void> _deletePlaylist(Playlist pl) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Usunąć playlistę?'),
        content: Text('Playlista "${pl.name}" zostanie usunięta.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anuluj'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Usuń',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      setState(() {
        _playlists.removeWhere((p) => p.id == pl.id);
        _playedByPlaylist.remove(pl.id);
        if (_activePlaylistId == pl.id) _activePlaylistId = null;
      });
      await _savePlaylists();
      await _savePlayed();
    }
  }

  int? _selectionOrder(String fileName) {
    final idx = _selectedFileNames.indexOf(fileName);
    return idx >= 0 ? idx + 1 : null;
  }

  bool _isPlayed(String fileName) {
    return (_playedByPlaylist[_currentPlayedKey] ?? []).contains(fileName);
  }

  bool get _hasPlayedInCurrent {
    return (_playedByPlaylist[_currentPlayedKey] ?? []).isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final activePlaylist = _activePlaylistId != null
        ? _playlists.firstWhere(
            (p) => p.id == _activePlaylistId,
            orElse: () => Playlist(id: '', name: '', fileNames: []),
          )
        : null;

    return Scaffold(
      body: SafeArea(
        child: _loading
            ? Center(child: Text(_status))
            : _files.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_status),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _pickFolder,
                          child: const Text('Wybierz folder'),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      _buildTopBar(activePlaylist),

                      if (_searchOpen)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                          child: TextField(
                            controller: _searchController,
                            autofocus: true,
                            decoration: InputDecoration(
                              hintText: 'Szukaj po tytule lub numerze...',
                              prefixIcon: const Icon(Icons.search, size: 20),
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.close, size: 20),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchOpen = false);
                                },
                              ),
                              border: const OutlineInputBorder(),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 8),
                            ),
                          ),
                        ),

                      Expanded(
                        child: GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 4.0,
                          ),
                          itemCount: _filteredFiles.length,
                          itemBuilder: (context, index) {
                            final file = _filteredFiles[index];
                            return _Tile(
                              file: file,
                              buildMode: _buildMode,
                              orderNumber: _selectionOrder(file.name),
                              played: _isPlayed(file.name),
                              onTap: () {
                                if (_buildMode) {
                                  _toggleSelection(file);
                                } else {
                                  _openFile(file, index: index);
                                }
                              },
                            );
                          },
                        ),
                      ),

                      if (_buildMode) _buildBuildBar(),
                    ],
                  ),
      ),
    );
  }

  Widget _buildTopBar(Playlist? activePlaylist) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: const Color(0xFF132845),
      child: Row(
        children: [
          if (_activePlaylistId != null)
            IconButton(
              icon: const Icon(Icons.arrow_back,
                  color: Colors.white, size: 22),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: 'Wróć',
              onPressed: _closePlaylist,
            ),

          if (_activePlaylistId == null && _playlists.isNotEmpty)
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _playlists.length,
                itemBuilder: (context, index) {
                  final pl = _playlists[index];
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onLongPress: () => _showPlaylistMenu(pl),
                      child: ActionChip(
                        avatar: const Icon(Icons.queue_music, size: 16),
                        label: Text('${pl.name} (${pl.fileNames.length})'),
                        onPressed: () => _openPlaylist(pl),
                      ),
                    ),
                  );
                },
              ),
            )
          else if (_activePlaylistId != null)
            Expanded(
              child: Text(
                activePlaylist?.name ?? '',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            const Expanded(
              child: Text(
                'Nuty',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '${_filteredFiles.length}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),

          IconButton(
            icon: Icon(
              _searchOpen ? Icons.search_off : Icons.search,
              color: Colors.white,
              size: 22,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            tooltip: 'Szukaj',
            onPressed: () => setState(() => _searchOpen = !_searchOpen),
          ),

          if (!_buildMode && _activePlaylistId == null)
            IconButton(
              icon: const Icon(Icons.add, color: Colors.white, size: 22),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: 'Nowa playlista',
              onPressed: _startNewPlaylist,
            ),

          if (_activePlaylistId != null && !_buildMode)
            IconButton(
              icon: const Icon(Icons.edit, color: Colors.white, size: 22),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: 'Edytuj playlistę',
              onPressed: () {
                final pl =
                    _playlists.firstWhere((p) => p.id == _activePlaylistId);
                _startEditPlaylist(pl);
              },
            ),

          if (_hasPlayedInCurrent && !_buildMode)
            IconButton(
              icon: const Icon(Icons.cleaning_services,
                  color: Colors.white, size: 22),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: 'Czyść listę',
              onPressed: _clearCurrentPlayed,
            ),

          if (_activePlaylistId == null)
            IconButton(
              icon: const Icon(Icons.folder_open,
                  color: Colors.white, size: 22),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: 'Zmień folder',
              onPressed: _pickFolder,
            ),
        ],
      ),
    );
  }

  Widget _buildBuildBar() {
    return Container(
      padding: const EdgeInsets.all(8),
      color: Colors.black87,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _playlistNameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Nazwa playlisty',
                  hintStyle: TextStyle(color: Colors.white54),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white54),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white),
                  ),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: _cancelBuild,
              tooltip: 'Anuluj',
            ),
            IconButton(
              icon: const Icon(Icons.save, color: Colors.green),
              onPressed: _saveBuildPlaylist,
              tooltip: 'Zapisz',
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final SafDocumentFile file;
  final VoidCallback onTap;
  final bool buildMode;
  final int? orderNumber;
  final bool played;

  const _Tile({
    required this.file,
    required this.onTap,
    this.buildMode = false,
    this.orderNumber,
    this.played = false,
  });

  @override
  Widget build(BuildContext context) {
    final nameWithoutExt = file.name.replaceAll(
      RegExp(r'\.(xml|mxl|musicxml|mei)$', caseSensitive: false),
      '',
    );

    final parts = nameWithoutExt.split('_');
    String number = '';
    String title = nameWithoutExt.replaceAll('_', ' ');

    if (parts.length > 1 && int.tryParse(parts.first) != null) {
      number = parts.first;
      title = parts.sublist(1).join(' ').replaceAll('_', ' ');
    }

    final selected = orderNumber != null;

    Color bgColor;
    if (selected && buildMode) {
      bgColor = const Color(0xFFD6AD23);
    } else if (played) {
      bgColor = const Color(0xFFF5E6C8);
    } else {
      bgColor = const Color(0xFF7BA7D9);
    }

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              if (buildMode && selected)
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Colors.black87,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$orderNumber',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                )
              else if (number.isNotEmpty)
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    number,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                    maxLines: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}