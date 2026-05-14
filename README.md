# Realtime Attendance Mobile

A Flutter mobile application for real-time face recognition-based attendance tracking.

## Features

- Face registration and storage
- Real-time face detection and recognition
- Local database for storing registered faces
- Camera integration for live recognition
- View and manage registered faces

## Technology Stack

- Flutter SDK 3.7.0+
- FaceNet TFLite model for face embeddings
- Google ML Kit for face detection
- SQLite for local data persistence
- Camera integration

## Setup

1. Clone the repository
2. Install dependencies:
   ```bash
   flutter pub get
   ```
3. Run the application:
   ```bash
   flutter run
   ```

## Project Structure

- `lib/screens` - UI screens (Home, Registration, Recognition, Registered Faces)
- `lib/machinelearning` - Machine learning components (Recognizer, Recognition models)
- `lib/database` - Database helper for SQLite operations
- `assets` - FaceNet TFLite model

## Requirements

- Flutter 3.7.0 or higher
- Android SDK (for Android deployment)
- iOS development environment (for iOS deployment)
- Device with camera support
