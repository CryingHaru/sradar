import 'package:flutter/material.dart';
import 'radar_screen.dart';

void main() {
  runApp(const RadarApp());
}

class RadarApp extends StatelessWidget {
  const RadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radar Meteorológico SV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF60A5FA),
          surface: Color(0xFF121621),
          onSurface: Color(0xFFF3F4F6),
        ),
        fontFamily: 'Inter',
        useMaterial3: true,
        dividerTheme: const DividerThemeData(
          color: Colors.white10,
          thickness: 1.0,
        ),
      ),
      home: const RadarScreen(),
    );
  }
}
