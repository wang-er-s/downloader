import 'package:flutter/material.dart';
import 'app/app.dart';
export 'app/app.dart' show DownloaderApp;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DownloaderApp());
}
