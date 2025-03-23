import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF503663),
        scaffoldBackgroundColor: const Color(0xFF503663),
      ),
      home: const PlaylistScreen(),
    );
  }
}

// Song model for MongoDB integration
class Song {
  final String? id; // MongoDB _id
  final String title;
  final String artist;
  String imagePath;
  String audioPath;
  final double? duration;
  final DateTime? createdAt;

  Song({
    this.id,
    required this.title,
    required this.artist,
    required this.imagePath,
    required this.audioPath,
    this.duration,
    this.createdAt,
  });

  // Create from JSON (from MongoDB)
  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['_id'],
      title: json['title'],
      artist: json['artist'],
      imagePath: json['imagePath'],
      audioPath: json['audioPath'],
      duration: json['duration']?.toDouble(),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'])
          : null,
    );
  }

  // Convert to JSON (for MongoDB)
  Map<String, dynamic> toJson() {
    return {
      if (id != null) '_id': id,
      'title': title,
      'artist': artist,
      'imagePath': imagePath,
      'audioPath': audioPath,
      if (duration != null) 'duration': duration,
      if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    };
  }
}

// Service for interacting with MongoDB via Node.js backend
class SongService {
  // Base URL of your Node.js server - use your server's IP or domain
  final String baseUrl = 'http://192.168.1.43:3003'; // Updated port to 3002

  // Cache manager for efficient file caching
  final DefaultCacheManager _cacheManager = DefaultCacheManager();

  // Cache for song metadata to avoid repeated server calls
  final Map<String, Song> _songCache = {};

  // Create an HTTP client with a longer timeout
  final http.Client _client = http.Client();

  // Get all songs from the server
  Future<List<Song>> getAllSongs({bool forceRefresh = false}) async {
    try {
      // If we have cached songs and don't need to refresh, return them
      if (_songCache.isNotEmpty && !forceRefresh) {
        return _songCache.values.toList();
      }

      final response = await _client.get(
        Uri.parse('$baseUrl/api/songs'),
        headers: {'Connection': 'keep-alive'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        final songs = data.map((songJson) => Song.fromJson(songJson)).toList();

        // Update cache
        _songCache.clear();
        for (var song in songs) {
          if (song.id != null) {
            _songCache[song.id!] = song;
          }
        }

        return songs;
      } else {
        throw Exception('Failed to load songs: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to connect to server: $e');
    }
  }

  // Download song and image files with efficient caching
  Future<Song> downloadSongFiles(Song song) async {
    // Skip asset files
    if (song.audioPath.startsWith('assets/')) {
      return song;
    }

    try {
      // Create a copy of the song to update the paths
      Song updatedSong = Song(
        id: song.id,
        title: song.title,
        artist: song.artist,
        imagePath: song.imagePath,
        audioPath: song.audioPath,
        duration: song.duration,
        createdAt: song.createdAt,
      );

      // Use cache manager for efficient file caching
      final audioFileInfo = await _cacheManager.getFileFromCache('audio_${song.id}');
      final imageFileInfo = await _cacheManager.getFileFromCache('image_${song.id}');

      // Download audio if not cached
      if (audioFileInfo == null) {
        final audioUrl = '$baseUrl/${song.audioPath}';
        final audioFileInfo = await _cacheManager.downloadFile(
          audioUrl,
          key: 'audio_${song.id}',
        );
        updatedSong.audioPath = audioFileInfo.file.path;
      } else {
        updatedSong.audioPath = audioFileInfo.file.path;
      }

      // Download image if not cached
      if (imageFileInfo == null) {
        final imageUrl = '$baseUrl/${song.imagePath}';
        final imageFileInfo = await _cacheManager.downloadFile(
          imageUrl,
          key: 'image_${song.id}',
        );
        updatedSong.imagePath = imageFileInfo.file.path;
      } else {
        updatedSong.imagePath = imageFileInfo.file.path;
      }

      return updatedSong;
    } catch (e) {
      print('Error downloading files: $e');
      // If download fails, return original song
      return song;
    }
  }

  // Upload a song to the server
  Future<Song> uploadSong({
    required String title,
    required String artist,
    required File audioFile,
    required File imageFile,
    double? duration,
  }) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/songs'));

      // Add text fields
      request.fields['title'] = title;
      request.fields['artist'] = artist;
      if (duration != null) {
        request.fields['duration'] = duration.toString();
      }

      // Add files with optimized settings
      request.files.add(await http.MultipartFile.fromPath(
        'audio',
        audioFile.path,
      ));

      request.files.add(await http.MultipartFile.fromPath(
        'image',
        imageFile.path,
      ));

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 201) {
        final songData = json.decode(response.body);
        final newSong = Song.fromJson(songData);

        // Update cache
        if (newSong.id != null) {
          _songCache[newSong.id!] = newSong;
        }

        return newSong;
      } else {
        throw Exception('Failed to upload song: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      throw Exception('Failed to upload song: $e');
    }
  }

  // Delete a song from the server
  Future<void> deleteSong(String id) async {
    try {
      final response = await _client.delete(Uri.parse('$baseUrl/api/songs/$id'));

      if (response.statusCode == 200) {
        // Remove from cache
        _songCache.remove(id);

        // Clear cached files
        await _cacheManager.removeFile('audio_$id');
        await _cacheManager.removeFile('image_$id');
      } else {
        throw Exception('Failed to delete song: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to connect to server: $e');
    }
  }

  // Clear cache
  Future<void> clearCache() async {
    _songCache.clear();
    await _cacheManager.emptyCache();
  }

  // Close resources
  void dispose() {
    _client.close();
  }
}

// Local songs for initial setup
final List<Song> initialSongs = [
  Song(
    title: 'Dementia Track-1',
    artist: 'Dementia_Link',
    imagePath: 'assets/images/i1.png',
    audioPath: 'assets/audio/track1.mp3',
  ),
  Song(
    title: 'Dementia Track-2',
    artist: 'Dementia_Link',
    imagePath: 'assets/images/i2.png',
    audioPath: 'assets/audio/track2.mp3',
  ),
  Song(
    title: 'Dementia Track-3',
    artist: 'Dementia_Link',
    imagePath: 'assets/images/i3.png',
    audioPath: 'assets/audio/track3.mp3',
  ),
  Song(
    title: 'Dementia Track-4',
    artist: 'Dementia_Link',
    imagePath: 'assets/images/i4.png',
    audioPath: 'assets/audio/track4.mp3',
  ),
  Song(
    title: 'Dementia special Track',
    artist: 'Meditational StateHealing Music',
    imagePath: 'assets/images/i5.jpg',
    audioPath: 'assets/audio/track5.mp3',
  ),
];

// Upload Screen for direct file upload
class UploadScreen extends StatefulWidget {
  final SongService songService;
  final Function() onUploadComplete;

  const UploadScreen({
    Key? key,
    required this.songService,
    required this.onUploadComplete,
  }) : super(key: key);

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _artistController = TextEditingController();

  File? _audioFile;
  File? _imageFile;
  bool _isUploading = false;
  double _uploadProgress = 0.0;

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  Future<void> _pickAudioFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );

      if (result != null) {
        setState(() {
          _audioFile = File(result.files.single.path!);
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking audio file: $e')),
      );
    }
  }

  Future<void> _pickImageFile() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);

      if (image != null) {
        setState(() {
          _imageFile = File(image.path);
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking image file: $e')),
      );
    }
  }

  Future<void> _uploadSong() async {
    if (_formKey.currentState!.validate()) {
      if (_audioFile == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an audio file')),
        );
        return;
      }

      if (_imageFile == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an image file')),
        );
        return;
      }

      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
      });

      try {
        // Show a simulated progress (since we don't have actual progress from the upload)
        final progressTimer = Stream.periodic(const Duration(milliseconds: 100), (i) => i)
            .take(100)
            .listen((i) {
          setState(() {
            _uploadProgress = i / 100;
          });
        });

        // Perform the actual upload
        await widget.songService.uploadSong(
          title: _titleController.text,
          artist: _artistController.text,
          audioFile: _audioFile!,
          imageFile: _imageFile!,
        );

        // Cancel the timer when upload is complete
        progressTimer.cancel();

        setState(() {
          _isUploading = false;
          _uploadProgress = 1.0;
        });

        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Song uploaded successfully!')),
        );

        // Trigger refresh of the main playlist screen
        widget.onUploadComplete();

        // Clear form
        _titleController.clear();
        _artistController.clear();
        setState(() {
          _audioFile = null;
          _imageFile = null;
        });

        // Navigate back to playlist screen
        Navigator.pop(context);
      } catch (e) {
        setState(() {
          _isUploading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF503663),
      appBar: AppBar(
        backgroundColor: const Color(0xFF503663),
        elevation: 0,
        title: const Text('Upload Music'),
        foregroundColor: Colors.white,
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title field
              const Text(
                'Title',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _titleController,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.1),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  hintText: 'Enter song title',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                ),
                style: const TextStyle(color: Colors.white),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a title';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Artist field
              const Text(
                'Artist',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _artistController,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.1),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  hintText: 'Enter artist name',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                ),
                style: const TextStyle(color: Colors.white),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter an artist name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 30),

              // Audio file picker
              ElevatedButton.icon(
                onPressed: _isUploading ? null : _pickAudioFile,
                icon: const Icon(Icons.audio_file),
                label: const Text('Select Audio File'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purple[300],
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  minimumSize: const Size(double.infinity, 50),
                ),
              ),
              const SizedBox(height: 10),
              if (_audioFile != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.audio_file, color: Colors.white),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          path.basename(_audioFile!.path),
                          style: const TextStyle(color: Colors.white),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 20),

              // Image file picker
              ElevatedButton.icon(
                onPressed: _isUploading ? null : _pickImageFile,
                icon: const Icon(Icons.image),
                label: const Text('Select Cover Image'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purple[300],
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  minimumSize: const Size(double.infinity, 50),
                ),
              ),
              const SizedBox(height: 10),
              if (_imageFile != null)
                Container(
                  width: double.infinity,
                  height: 150,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.white.withOpacity(0.1),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(
                      _imageFile!,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              const SizedBox(height: 30),

              // Upload button or progress indicator
              if (_isUploading)
                Column(
                  children: [
                    LinearProgressIndicator(
                      value: _uploadProgress,
                      backgroundColor: Colors.white.withOpacity(0.1),
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.purple[200]!),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Uploading... ${(_uploadProgress * 100).toInt()}%',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                )
              else
                ElevatedButton(
                  onPressed: _uploadSong,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    minimumSize: const Size(double.infinity, 50),
                  ),
                  child: const Text(
                    'Upload Song',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({Key? key}) : super(key: key);

  @override
  PlaylistScreenState createState() => PlaylistScreenState();
}

class PlaylistScreenState extends State<PlaylistScreen> {
  final SongService _songService = SongService();
  List<Song> _songs = [];
  bool _isLoading = true;
  bool _isConnected = true;

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    _loadSongs();
  }

  Future<void> _checkConnectivity() async {
    var connectivityResult = await Connectivity().checkConnectivity();
    setState(() {
      _isConnected = connectivityResult != ConnectivityResult.none;
    });

    // Listen for connectivity changes
    Connectivity().onConnectivityChanged.listen((ConnectivityResult result) {
      setState(() {
        _isConnected = result != ConnectivityResult.none;
      });

      // Reload songs when connection is restored
      if (_isConnected) {
        _loadSongs(forceRefresh: true);
      }
    });
  }

  Future<void> _loadSongs({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
    });

    try {
      if (_isConnected) {
        // Try to get songs from server if connected
        final songs = await _songService.getAllSongs(forceRefresh: forceRefresh);
        setState(() {
          _songs = songs;
          _isLoading = false;
        });
      } else {
        // If offline, use local songs or cached songs
        setState(() {
          _songs = _songs.isEmpty ? initialSongs : _songs;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error loading songs: $e');

      // If server connection fails, use initial songs
      setState(() {
        _isLoading = false;
        // Use existing songs or fall back to initialSongs
        _songs = _songs.isEmpty ? initialSongs : _songs;
      });

      if (_isConnected) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading songs: $e')),
        );
      }
    }
  }

  void _navigateToUploadScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UploadScreen(
          songService: _songService,
          onUploadComplete: () => _loadSongs(forceRefresh: true),
        ),
      ),
    );
  }

  Future<void> _migrateAssetsToMongoDB() async {
    if (!_isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot migrate songs while offline')),
      );
      return;
    }

    // Show a migration dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Migrating Assets'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Uploading audio files to MongoDB...\nThis may take a while.'),
          ],
        ),
      ),
    );

    try {
      // First, extract the assets to local files
      final directory = await getApplicationDocumentsDirectory();
      int successCount = 0;
      int failCount = 0;

      for (final song in initialSongs) {
        try {
          print('Processing ${song.title}...');

          // Copy image file from assets to documents directory
          final imageData = await rootBundle.load(song.imagePath);
          final imageFile = File('${directory.path}/${path.basename(song.imagePath)}');
          await imageFile.writeAsBytes(
            imageData.buffer.asUint8List(
              imageData.offsetInBytes,
              imageData.lengthInBytes,
            ),
          );
          print('Image saved to ${imageFile.path}');

          // Copy audio file from assets to documents directory
          final audioData = await rootBundle.load(song.audioPath);
          final audioFile = File('${directory.path}/${path.basename(song.audioPath)}');
          await audioFile.writeAsBytes(
            audioData.buffer.asUint8List(
              audioData.offsetInBytes,
              audioData.lengthInBytes,
            ),
          );
          print('Audio saved to ${audioFile.path}');

          // Upload each song to MongoDB with GridFS
          await _songService.uploadSong(
            title: song.title,
            artist: song.artist,
            audioFile: audioFile,
            imageFile: imageFile,
          );

          successCount++;
          print('Successfully uploaded ${song.title} to MongoDB');
        } catch (e) {
          failCount++;
          print('Error uploading song ${song.title} to MongoDB: $e');
        }
      }

      // After migration, load the songs from the server
      await _loadSongs(forceRefresh: true);

      // Close the dialog
      Navigator.of(context, rootNavigator: true).pop();

      // Show success dialog
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Migration Complete'),
          content: Text(
              'Successfully uploaded $successCount songs to MongoDB.\n'
                  'Failed: $failCount songs.'
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      // Close the progress dialog
      Navigator.of(context, rootNavigator: true).pop();

      // Show error dialog
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Migration Failed'),
          content: Text('Error: ${e.toString()}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF503663),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            if (!_isConnected)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                color: Colors.orange,
                width: double.infinity,
                child: const Row(
                  children: [
                    Icon(Icons.wifi_off, color: Colors.white),
                    SizedBox(width: 8),
                    Text(
                      'You are offline. Some features may be limited.',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : _songs.isEmpty
                  ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.music_note, color: Colors.white, size: 64),
                    const SizedBox(height: 16),
                    const Text(
                      'No songs found',
                      style: TextStyle(color: Colors.white, fontSize: 18),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _navigateToUploadScreen,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Upload Music'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple[300],
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              )
                  : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _songs.length,
                itemBuilder: (context, index) {
                  return _buildSongTile(context, _songs[index], index);
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.white,
        child: const Icon(Icons.refresh, color: Color(0xFF503663)),
        onPressed: () => _loadSongs(forceRefresh: true),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {},
          ),
          const Expanded(
            child: Text(
              'PLAYLIST',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          // Add upload button
          IconButton(
            icon: const Icon(Icons.upload_file, color: Colors.white),
            onPressed: _navigateToUploadScreen,
            tooltip: 'Upload new song',
          ),
          IconButton(
            icon: const Icon(Icons.cloud_upload, color: Colors.white),
            onPressed: _migrateAssetsToMongoDB,
            tooltip: 'Upload songs to MongoDB',
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.2),
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/images/brain_icon.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongTile(BuildContext context, Song song, int index) {
    // This handles both assets and file paths
    Widget buildImage() {
      if (song.imagePath.startsWith('assets/')) {
        return Image.asset(
          song.imagePath,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
        );
      } else {
        return FutureBuilder<Song>(
            future: _songService.downloadSongFiles(song),
      builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done &&
      snapshot.hasData) {
      return Image.file(
      File(snapshot.data!.imagePath),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
      );
      } else {
        return const SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          ),
        );
      }
      },
        );
      }
    }

    return Dismissible(
      key: Key(song.id ?? song.title),
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      direction: DismissDirection.endToStart,
      confirmDismiss: (direction) async {
        if (song.id == null) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Cannot delete local songs'))
          );
          return false;
        }
        return await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete Song'),
            content: Text('Are you sure you want to delete "${song.title}"?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
      },
      onDismissed: (direction) async {
        if (song.id != null) {
          try {
            await _songService.deleteSong(song.id!);
            setState(() {
              _songs.removeAt(index);
            });
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${song.title} deleted'))
            );
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Error deleting song: $e'))
            );
          }
        }
      },
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: buildImage(),
        ),
        title: Text(
          song.title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          song.artist,
          style: TextStyle(
            color: Colors.white.withOpacity(0.7),
          ),
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PlayerScreen(
                initialSong: song,
                songs: _songs,
              ),
            ),
          );
        },
      ),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  final Song initialSong;
  final List<Song> songs;

  const PlayerScreen({
    Key? key,
    required this.initialSong,
    required this.songs,
  }) : super(key: key);

  @override
  PlayerScreenState createState() => PlayerScreenState();
}

class PlayerScreenState extends State<PlayerScreen> {
  late AudioPlayer _audioPlayer;
  late Song _currentSong;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _isPlaying = false;
  bool _isLoading = true;
  final SongService _songService = SongService();

  @override
  void initState() {
    super.initState();
    _currentSong = widget.initialSong;
    _audioPlayer = AudioPlayer();
    _setupAudioPlayer();
  }

  void _setupAudioPlayer() async {
    // Duration state
    _audioPlayer.positionStream.listen((pos) {
      setState(() => _position = pos);
    });
    _audioPlayer.durationStream.listen((dur) {
      setState(() => _duration = dur ?? Duration.zero);
    });
    // Playing state
    _audioPlayer.playerStateStream.listen((state) {
      setState(() => _isPlaying = state.playing);
    });
    // Load the initial song
    await _loadCurrentSong();
  }

  Future<void> _loadCurrentSong() async {
    setState(() => _isLoading = true);

    try {
      // Check if song is local asset or needs to be downloaded
      if (_currentSong.audioPath.startsWith('assets/')) {
        await _audioPlayer.setAsset(_currentSong.audioPath);
      } else {
        // Download if it's a remote file
        final updatedSong = await _songService.downloadSongFiles(_currentSong);
        _currentSong = updatedSong;

        // Use the local file
        await _audioPlayer.setFilePath(_currentSong.audioPath);
      }

      await _audioPlayer.play();
      setState(() => _isLoading = false);
    } catch (e) {
      print("Error loading audio source: $e");
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading audio: $e')),
      );
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  void _playPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  void _playNext() async {
    final currentIndex = widget.songs.indexWhere(
            (song) => song.title == _currentSong.title && song.artist == _currentSong.artist
    );

    if (currentIndex < widget.songs.length - 1) {
      setState(() => _currentSong = widget.songs[currentIndex + 1]);
      await _loadCurrentSong();
    }
  }

  void _playPrevious() async {
    final currentIndex = widget.songs.indexWhere(
            (song) => song.title == _currentSong.title && song.artist == _currentSong.artist
    );

    if (currentIndex > 0) {
      setState(() => _currentSong = widget.songs[currentIndex - 1]);
      await _loadCurrentSong();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF4A2B5C),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildAlbumArt(),
            const Spacer(),
            _buildSongInfo(),
            _buildProgressBar(),
            _buildControls(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          const Expanded(
            child: Text(
              'Now Playing...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.2),
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/images/brain_icon.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlbumArt() {
    Widget buildImage() {
      if (_isLoading) {
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      } else if (_currentSong.imagePath.startsWith('assets/')) {
        return Image.asset(
          _currentSong.imagePath,
          fit: BoxFit.cover,
        );
      } else {
        return Image.file(
          File(_currentSong.imagePath),
          fit: BoxFit.cover,
        );
      }
    }

    return Container(
      margin: const EdgeInsets.only(
        top: 65,
        left: 24,
        right: 24,
        bottom: 24,
      ),
      width: double.infinity,
      height: 300,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: buildImage(),
      ),
    );
  }

  Widget _buildSongInfo() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            _currentSong.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _currentSong.artist,
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    return Column(
      children: [
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: Colors.green,
            inactiveTrackColor: Colors.white.withOpacity(0.2),
            thumbColor: Colors.white,
            overlayColor: Colors.white.withOpacity(0.2),
          ),
          child: Slider(
            value: _position.inSeconds.toDouble(),
            max: _duration.inSeconds.toDouble() == 0
                ? 1.0 // Avoid division by zero
                : _duration.inSeconds.toDouble(),
            onChanged: (value) {
              _audioPlayer.seek(Duration(seconds: value.toInt()));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(_position),
                style: TextStyle(color: Colors.white.withOpacity(0.7)),
              ),
              Text(
                _formatDuration(_duration),
                style: TextStyle(color: Colors.white.withOpacity(0.7)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Previous button
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: IconButton(
              iconSize: 35,
              padding: const EdgeInsets.all(12),
              icon: const Icon(Icons.skip_previous, color: Colors.white),
              onPressed: _playPrevious,
            ),
          ),
          // Play/Pause button
          Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Colors.white,
                  Colors.white,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.white.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: IconButton(
              iconSize: 50,
              padding: const EdgeInsets.all(16),
              icon: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.purple,
              ),
              onPressed: _playPause,
            ),
          ),
          // Next button
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: IconButton(
              iconSize: 35,
              padding: const EdgeInsets.all(12),
              icon: const Icon(Icons.skip_next, color: Colors.white),
              onPressed: _playNext,
            ),
          ),
        ],
      ),
    );
  }
}