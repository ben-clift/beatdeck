import 'package:flutter/material.dart';
import 'package:sidedeck/midi/midi_controller.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Connect a MIDI controller and teach the app what each control does.
class MidiPage extends StatelessWidget {
  const MidiPage({super.key, required this.dj});

  final DjController dj;

  @override
  Widget build(BuildContext context) {
    final midi = midiFor(dj);
    return Scaffold(
      appBar: AppBar(
        title: const Text('MIDI controller'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: midi.refresh),
        ],
      ),
      body: ListenableBuilder(
        listenable: midi,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const Text(
              'Plug a controller into the USB port (or pair a Bluetooth one), '
              'connect it below, then pick a control in the list and move the '
              'knob or press the button on your controller to link them.',
              style: TextStyle(color: SideDeckTheme.muted),
            ),
            const SizedBox(height: 10),
            if (midi.error != null)
              Text(midi.error!, style: const TextStyle(color: Colors.redAccent)),
            if (midi.devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No MIDI devices found.'),
              ),
            for (final d in midi.devices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.piano),
                title: Text(d.name),
                trailing: midi.connected.contains(d.id)
                    ? TextButton(
                        onPressed: () => midi.disconnect(d),
                        child: const Text('Disconnect'),
                      )
                    : FilledButton(
                        onPressed: () => midi.connect(d),
                        child: const Text('Connect'),
                      ),
              ),
            if (midi.lastSeen.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('Last message: ${midi.lastSeen}',
                    style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
              ),
            const Divider(),
            for (final a in midi.actions)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(a.label),
                subtitle: Text(
                  midi.learning == a.id
                      ? (a.continuous ? 'Move a knob or fader now…' : 'Press a button now…')
                      : (midi.keyFor(a.id) == null ? 'Not linked' : _pretty(midi.keyFor(a.id)!)),
                  style: TextStyle(
                    color: midi.learning == a.id ? const Color(0xFFFF9F1C) : null,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (midi.keyFor(a.id) != null)
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => midi.clear(a.id),
                      ),
                    TextButton(
                      onPressed: () => midi.learning == a.id
                          ? midi.cancelLearn()
                          : midi.startLearn(a.id),
                      child: Text(midi.learning == a.id ? 'Cancel' : 'Learn'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _pretty(String key) {
    final p = key.split(':');
    return '${p[0] == 'c' ? 'CC' : 'Note'} ${p[2]}  ·  channel ${int.parse(p[1]) + 1}';
  }
}
