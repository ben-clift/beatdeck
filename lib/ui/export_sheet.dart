import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Pick tracks from what the library is showing now (so a genre filter or
/// "Most played" sort narrows the list) and send them to Google Drive.
Future<void> showExportSheet(BuildContext context, List<LibraryTrack> shown) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ExportSheet(shown: shown),
  );
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.shown});
  final List<LibraryTrack> shown;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  late final Set<String> _sel = {for (final t in widget.shown) t.path};
  bool _busy = false;

  Future<void> _send() async {
    final files = [
      for (final t in widget.shown)
        if (_sel.contains(t.path) && File(t.path).existsSync()) XFile(t.path),
    ];
    if (files.isEmpty) return;
    setState(() => _busy = true);
    try {
      // Opens the phone's share sheet: choose Drive (Save to Drive) there.
      await SharePlus.instance.share(ShareParams(files: files, subject: 'BeatDeck tracks'));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share: $e')));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.8;
    return SizedBox(
      height: h,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Send to Google Drive',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () => setState(() => _sel
                    ..clear()
                    ..addAll(widget.shown.map((t) => t.path))),
                  child: const Text('All'),
                ),
                TextButton(onPressed: () => setState(_sel.clear), child: const Text('None')),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Shows what the library list is showing now. Set a genre filter or '
                'sort by Most played first to narrow it down.',
                style: TextStyle(fontSize: 12, color: SideDeckTheme.muted),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.shown.length,
              itemBuilder: (_, i) {
                final t = widget.shown[i];
                return CheckboxListTile(
                  dense: true,
                  value: _sel.contains(t.path),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _sel.add(t.path);
                    } else {
                      _sel.remove(t.path);
                    }
                  }),
                  title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_sel.isEmpty || _busy) ? null : _send,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text(_busy ? 'Opening…' : 'Send ${_sel.length} to Google Drive'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
