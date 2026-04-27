import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';

class FurniApp extends StatelessWidget {
  const FurniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Furni3D',
      theme: AppTheme.theme,
      debugShowCheckedModeBanner: false,
      home: const HomeScreen(),
    );
  }
}
