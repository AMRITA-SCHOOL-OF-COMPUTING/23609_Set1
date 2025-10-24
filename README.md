# Flutter Event Manager with Firebase Integration

A simple event management application built with Flutter. It demonstrates CRUD (Create, Read, Update, Delete) operations, state management with Provider, and real-time data synchronization using Firebase Realtime Database.

## Features

- View a list of events.
- Add, edit, and delete events.
- Search for events by name, venue, or date.
- Real-time updates across clients.

## Getting Started

### 1. Install Dependencies

```sh
flutter pub get
```

### 2. Configure Firebase

This project uses Firebase. Before running, you must set up a Firebase project and add your configuration:

- **For Android**: Place your `google-services.json` file in `android/app/`.
- **For iOS**: Add your `GoogleService-Info.plist` file to the `ios/Runner` directory via Xcode.
- **For Web/Windows**: Update `lib/firebase_options.dart` with your Firebase project's configuration details. You can generate this file automatically by running `flutterfire configure`.

### 3. Run the App

```sh
flutter run
```