import 'package:flutter/material.dart';
import 'package:sidedeck/debug/debug_log.dart';

/// Small panel over the app showing the newest trace lines as they happen.
/// Green is a step that worked, red one that failed. Touches pass through.
class LiveTrace extends StatelessWidget {
  const LiveTrace({super.key});

  @override
  Widget build(BuildContext context) {
    final log = DebugLog.instance;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        if (!log.live) return const SizedBox.shrink();
        final last = log.entries.length > 9
            ? log.entries.sublist(log.entries.length - 9)
            : log.entries;
        return Positioned(
          left: 6,
          bottom: 6,
          width: MediaQuery.of(context).size.width * 0.62,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xB8000000),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final e in last)
                    Text(
                      e.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.2,
                        color: e.level == LogLevel.ok
                            ? const Color(0xFF5CE07A)
                            : (e.level == LogLevel.fail
                                ? const Color(0xFFFF6B6B)
                                : Colors.white70),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
