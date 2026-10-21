import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/debug/debug_log.dart';

class DebugPage extends StatelessWidget {
  const DebugPage({super.key});

  @override
  Widget build(BuildContext context) {
    final log = DebugLog.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug log'),
        actions: [
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
        builder: (context, _) => log.lines.isEmpty
            ? const Center(child: Text('Nothing logged yet'))
            : ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: log.lines.length,
                itemBuilder: (_, i) {
                  final l = log.lines[log.lines.length - 1 - i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: SelectableText(l, style: const TextStyle(fontSize: 11)),
                  );
                },
              ),
      ),
    );
  }
}
