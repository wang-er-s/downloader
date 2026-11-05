import 'package:flutter/material.dart';
import 'app/app.dart';
export 'app/app.dart' show MyApp;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}
