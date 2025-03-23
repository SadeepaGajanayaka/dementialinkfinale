// File: lib/models/song.dart
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