import 'package:flutter/material.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/home_page.dart';
import 'package:sidedeck/ui/live_trace.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SideDeckApp());
}

class SideDeckApp extends StatelessWidget {
  const SideDeckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SideDeck',
      debugShowCheckedModeBanner: false,
      theme: SideDeckTheme.dark(),
      builder: (context, child) => Stack(
        children: [if (child != null) child, const LiveTrace()],
      ),
      home: const HomePage(),
    );
  }
}
