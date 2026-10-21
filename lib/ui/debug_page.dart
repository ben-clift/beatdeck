import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/debug/debug_log.dart';

class DebugPage extends StatefulWidget {
  const DebugPage({super.key});

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  bool _failsOnly = false;

  @override
  Widget build(BuildContext context) {
    final log = DebugLog.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Test log'),
        actions: [
          IconButton(
            icon: Icon(_failsOnly ? Icons.filter_alt : Icons.filter_alt_outlined),
            tooltip: 'Show only failures',
            onPressed: () => setState(() => _failsOnly = !_failsOnly),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: log.lines.join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: log.clear,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          final shown = [
            for (final e in log.entries.reversed)
              if (!_failsOnly || e.level == LogLevel.fail) e,
          ];
          if (shown.isEmpty) return const Center(child: Text('Nothing logged yet'));
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: Text(
                  'Saved to: ${log.filePath ?? 'not available'}',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final e = shown[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: SelectableText(
                        e.text,
                        style: TextStyle(
                          fontSize: 11,
                          color: e.level == LogLevel.ok
                              ? const Color(0xFF3DDC57)
                              : (e.level == LogLevel.fail ? const Color(0xFFFF6B6B) : null),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
