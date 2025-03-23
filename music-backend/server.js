// File: server.js
require('dotenv').config(); // Load environment variables from .env file
const express = require('express');
const mongoose = require('mongoose');
const multer = require('multer');
const cors = require('cors');
const { GridFSBucket } = require('mongodb');
const path = require('path');
const crypto = require('crypto');
const fs = require('fs');

const app = express();

// Middleware
app.use(express.json());
app.use(cors());

// Get environment variables with defaults
const mongoURI = process.env.MONGODB_URI || 'mongodb://127.0.0.1:27017/dementia_link';
const PORT = process.env.PORT || 3003;

// Connect to MongoDB
mongoose.connect(mongoURI)
  .then(() => console.log(`MongoDB Connected: ${mongoURI}`))
  .catch(err => console.log('MongoDB Connection Error:', err));

// Create GridFS bucket when connection is established
let gridFSBucket;
mongoose.connection.on('connected', () => {
  gridFSBucket = new GridFSBucket(mongoose.connection.db, {
    bucketName: 'uploads'
  });
  console.log('GridFS Bucket created');
});

// Set up disk storage for temporary file uploads
const storage = multer.diskStorage({
  destination: function (req, file, cb) {
    // Create temp directory if it doesn't exist
    const tempDir = path.join(__dirname, 'temp');
    if (!fs.existsSync(tempDir)) {
      fs.mkdirSync(tempDir, { recursive: true });
    }
    cb(null, tempDir);
  },
  filename: function (req, file, cb) {
    // Generate a random filename
    crypto.randomBytes(16, (err, buf) => {
      if (err) return cb(err);
      cb(null, buf.toString('hex') + path.extname(file.originalname));
    });
  }
});

const upload = multer({ storage });

// Song schema for MongoDB (metadata only)
const SongSchema = new mongoose.Schema({
  title: {
    type: String,
    required: true
  },
  artist: {
    type: String,
    required: true
  },
  audioFileId: {
    type: mongoose.Schema.Types.ObjectId,
    required: true
  },
  imageFileId: {
    type: mongoose.Schema.Types.ObjectId,
    required: true
  },
  duration: {
    type: Number
  },
  createdAt: {
    type: Date,
    default: Date.now
  }
});

const Song = mongoose.model('Song', SongSchema);

// Routes

// @route   GET /api/songs
// @desc    Get all songs metadata
app.get('/api/songs', async (req, res) => {
  try {
    const songs = await Song.find();
    
    // Transform the response to match your expected format
    const formattedSongs = songs.map(song => ({
      _id: song._id,
      title: song.title,
      artist: song.artist,
      imagePath: `api/files/${song.imageFileId}`,
      audioPath: `api/files/${song.audioFileId}`,
      duration: song.duration,
      createdAt: song.createdAt
    }));
    
    res.json(formattedSongs);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Server error' });
  }
});

// @route   POST /api/songs
// @desc    Upload song with audio and image files
app.post('/api/songs', upload.fields([
  { name: 'audio', maxCount: 1 },
  { name: 'image', maxCount: 1 }
]), async (req, res) => {
  try {
    if (!req.files || !req.files.audio || !req.files.image) {
      return res.status(400).json({ error: 'Please upload both audio and image files' });
    }

    const audioFile = req.files.audio[0];
    const imageFile = req.files.image[0];

    // Upload audio file to GridFS
    const audioStream = fs.createReadStream(audioFile.path);
    const audioUploadStream = gridFSBucket.openUploadStream(audioFile.originalname, {
      metadata: {
        contentType: audioFile.mimetype,
        originalName: audioFile.originalname,
        title: req.body.title,
        artist: req.body.artist
      }
    });
    
    // Use a promise to wait for the upload to complete
    const audioFileId = await new Promise((resolve, reject) => {
      audioStream.pipe(audioUploadStream)
        .on('error', reject)
        .on('finish', function() {
          resolve(this.id);
        });
    });
    
    // Upload image file to GridFS
    const imageStream = fs.createReadStream(imageFile.path);
    const imageUploadStream = gridFSBucket.openUploadStream(imageFile.originalname, {
      metadata: {
        contentType: imageFile.mimetype,
        originalName: imageFile.originalname,
        title: req.body.title,
        artist: req.body.artist
      }
    });
    
    // Use a promise to wait for the upload to complete
    const imageFileId = await new Promise((resolve, reject) => {
      imageStream.pipe(imageUploadStream)
        .on('error', reject)
        .on('finish', function() {
          resolve(this.id);
        });
    });

    // Create new song record with references to GridFS files
    const song = new Song({
      title: req.body.title,
      artist: req.body.artist,
      audioFileId: audioFileId,
      imageFileId: imageFileId,
      duration: req.body.duration ? parseFloat(req.body.duration) : null
    });

    await song.save();

    // Clean up temporary files
    fs.unlinkSync(audioFile.path);
    fs.unlinkSync(imageFile.path);

    // Return the song data in the expected format
    res.status(201).json({
      _id: song._id,
      title: song.title,
      artist: song.artist,
      imagePath: `api/files/${song.imageFileId}`,
      audioPath: `api/files/${song.audioFileId}`,
      duration: song.duration,
      createdAt: song.createdAt
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Server error: ' + err.message });
  }
});

// @route   GET /api/files/:id
// @desc    Stream files (audio or image) from GridFS
app.get('/api/files/:id', async (req, res) => {
  try {
    // First check if the ID is valid
    const fileId = new mongoose.Types.ObjectId(req.params.id);
    
    // Find the file info
    const files = await gridFSBucket.find({ _id: fileId }).toArray();
    
    if (!files || files.length === 0) {
      return res.status(404).json({ error: 'File not found' });
    }
    
    const file = files[0];
    
    // Set appropriate content type
    res.set('Content-Type', file.metadata?.contentType || 'application/octet-stream');
    
    // Stream the file to the response
    gridFSBucket.openDownloadStream(fileId).pipe(res);
  } catch (err) {
    console.error(err);
    if (err.name === 'BSONError' || err.name === 'CastError') {
      return res.status(400).json({ error: 'Invalid file ID' });
    }
    res.status(500).json({ error: 'Server error' });
  }
});

// @route   DELETE /api/songs/:id
// @desc    Delete a song and its files
app.delete('/api/songs/:id', async (req, res) => {
  try {
    // Find the song to get file IDs
    const song = await Song.findById(req.params.id);
    
    if (!song) {
      return res.status(404).json({ error: 'Song not found' });
    }

    // Delete audio and image files from GridFS
    await gridFSBucket.delete(song.audioFileId);
    await gridFSBucket.delete(song.imageFileId);
    
    // Delete song metadata
    await Song.findByIdAndDelete(req.params.id);
    
    res.json({ message: 'Song deleted successfully' });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Server error' });
  }
});

// Start server
app.listen(PORT, () => console.log(`Server running on port ${PORT}`));

module.exports = app;