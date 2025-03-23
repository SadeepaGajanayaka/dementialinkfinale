// File: lib/services/song_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../models/song.dart';

class SongService {
  // Base URL of your Node.js server - update this to your actual server IP
  // For emulator, use 10.0.2.2
  // For physical device, use your computer's IP address or your server's domain
  final String baseUrl;

  // Cache manager for efficient file caching
  final DefaultCacheManager _cacheManager = DefaultCacheManager();

  // Cache for song metadata to avoid repeated server calls
  final Map<String, Song> _songCache = {};

  // Create an HTTP client with a longer timeout
  final http.Client _client = http.Client();

  SongService({required this.baseUrl});

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

  // Efficiently get a song with its files
  Future<Song> getSongWithFiles(Song song) async {
    // First check if we need to download files
    final updatedSong = await _downloadSongFiles(song);
    return updatedSong;
  }

  // Download song and image files if they're not already cached
  Future<Song> _downloadSongFiles(Song song) async {
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

      // Skip asset files
      if (song.audioPath.startsWith('assets/')) {
        return song;
      }

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