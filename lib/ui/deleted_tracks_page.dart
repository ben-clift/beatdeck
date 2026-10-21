import 'package:flutter/material.dart';
import 'package:sidedeck/state/dislikes.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Log of tracks the DJ deleted: they are never picked by automix or searched
/// for by auto-fetch. Each can be allowed again.
class DeletedTracksPage extends StatefulWidget {
  const DeletedTracksPage({super.key});

  @override
  State<DeletedTracksPage> createState() => _DeletedTracksPageState();
}

class _DeletedTracksPageState extends State<DeletedTracksPage> {
  @override
  void initState() {
    super.initState();
    Dislikes.instance.load();
  }

  static String _when(int ms) {
    if (ms <= 0) return 'date not recorded';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Deleted tracks'),
        actions: [
          ListenableBuilder(
            listenable: Dislikes.instance,
            builder: (context, _) => TextButton(
              onPressed: Dislikes.instance.count == 0
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Forget all?'),
                          content: const Text(
                              'These tracks can be picked and searched for again. Files already deleted stay deleted.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Forget all')),
                          ],
                        ),
                      );
                      if (ok == true) await Dislikes.instance.clear();
                    },
              child: const Text('Forget all'),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Dislikes.instance,
        builder: (context, _) {
          final log = Dislikes.instance.log;
          if (log.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nothing deleted yet.\nHold a track in the Library and tap Delete. '
                  'It is removed from the phone and never picked or searched for again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: SideDeckTheme.muted),
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: log.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => ListTile(
              title: Text(log[i].name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('Deleted ${_when(log[i].at)}',
                  style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
              trailing: TextButton(
                onPressed: () => Dislikes.instance.allowAgain(i),
                child: const Text('Allow again'),
              ),
            ),
          );
        },
      ),
    );
  }
}
