// Add this new screen to your app
import 'dart:io';
import 'package:firebase/services/song_service.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;

class UploadScreen extends StatefulWidget {
  final SongService songService;
  final Function() onUploadComplete;

  const UploadScreen({
    Key? key,
    required this.songService,
    required this.onUploadComplete,
  }) : super(key: key);

  @override
  _UploadScreenState createState() => _UploadScreenState();
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