import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/usb_output.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/debug/log_upload.dart';
import 'package:sidedeck/ui/debug_page.dart';
import 'package:sidedeck/ui/deleted_tracks_page.dart';
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/state/avoids.dart';
import 'package:sidedeck/state/dislikes.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/subsonic/subsonic_client.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.dj});

  final DjController dj;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Dislikes.instance.load().then((_) {
      if (mounted) setState(() {});
    });
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _url.text = prefs.getString('subsonic_url') ?? '';
    _user.text = prefs.getString('subsonic_user') ?? '';
    _pass.text = prefs.getString('subsonic_pass') ?? '';
    setState(() {});
  }

  Future<void> _saveAndTest() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await SubsonicClient.savePrefs(
        url: _url.text.trim(),
        user: _user.text.trim(),
        pass: _pass.text,
      );
      final client = SubsonicClient(
        baseUrl: _url.text.trim(),
        username: _user.text.trim(),
        password: _pass.text,
      );
      await client.ping();
      setState(() => _status = 'Connected OK');
    } catch (e) {
      setState(() => _status = 'Failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'External mixer',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            'Turn this on with a USB mixer plugged into the phone. Deck A and Deck B '
            'go out as separate channels so you mix and cue on the hardware — the '
            'on-screen EQ/crossfader hides. Works with devices such as the EP-136 '
            '(set USB mode to Multi).',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use external mixer'),
            subtitle: Text(
              widget.dj.externalMixer
                  ? 'ON — Deck A → channel 1, Deck B → channel 2 on the '
                      '${UsbOutput.deviceLabel(widget.dj.usbDeviceName)}'
                  : 'OFF — audio stays on the phone',
            ),
            value: widget.dj.externalMixer,
            onChanged: (v) async {
              await widget.dj.setExternalMixer(v);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text('Deleted tracks (${Dislikes.instance.count})'),
            subtitle: const Text('See what you deleted. These are never picked or searched for.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DeletedTracksPage()),
              );
              if (mounted) setState(() {});
            },
          ),
          ListTile(
            title: const Text('Clear automix play history'),
            subtitle: const Text('Tracks played in the last 24 hours are skipped. This lets them play again.'),
            onTap: () async {
              await widget.dj.clearPlayedHistory();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Play history cleared')),
              );
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Test log'),
            subtitle: const Text('Every step with OK or FAIL. Copy it to send.'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DebugPage()),
            ),
          ),
          const Text('Send logs to Claude',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            'Failures are posted to a private GitHub issue so Claude can read them '
            'and find the cause. Create a fine-grained token for the beatdeck '
            'repository only, with Issues: read and write, and paste it here.',
            style: TextStyle(fontSize: 12),
          ),
          TextField(
            controller: TextEditingController(text: LogUpload.token),
            obscureText: true,
            decoration: const InputDecoration(labelText: 'GitHub token'),
            onChanged: (v) {
              LogUpload.token = v;
              LogUpload.save();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Send failures automatically'),
            subtitle: Text(LogUpload.status.isEmpty ? 'Off until a token is set' : LogUpload.status),
            value: LogUpload.auto,
            onChanged: (v) {
              LogUpload.auto = v;
              LogUpload.save();
              setState(() {});
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Live trace on screen'),
            subtitle: const Text(
              'Shows each step as it happens: green worked, red failed.',
            ),
            value: DebugLog.instance.live,
            onChanged: (v) async {
              await DebugLog.instance.setLive(v);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show decks 3 and 4'),
            subtitle: const Text(
              'Off by default. Decks 1 and 2 are the main pair and the only ones '
              'automix uses.',
            ),
            value: widget.dj.showDecks34,
            onChanged: (v) async {
              await widget.dj.setShowDecks34(v);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          const Text(
            'Subsonic server',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            'Optional. Tracks download to a local cache, then play like local files. '
            'Use http:// for a server on your LAN. Use https:// if the server is '
            'on the internet — otherwise the login token travels in the clear.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://192.168.1.10:4533',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _user,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _saveAndTest,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save & ping'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!),
          ],
          const Divider(height: 32),
          const Text(
            'Reset',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.cleaning_services_outlined),
            label: const Text('Clear cache'),
            onPressed: _clearCache,
          ),
          const SizedBox(height: 4),
          const Text(
            'Forgets the saved track analysis and the shop / chart lists. '
            'They are read again when needed. Your music and settings stay.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset to factory settings'),
            onPressed: _factoryReset,
          ),
          const SizedBox(height: 4),
          const Text(
            'Puts every setting back to how it started (Auto DJ, looks, '
            'fetching, logins, Less-of-this list). Your music files, '
            'library folders, playlists, stars, Backup tracks and deleted-track '
            'list are kept.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12),
          ),
          const Divider(height: 32),
          const Text(
            'About',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            'SideDeck 1.1.0\n'
            'Copyright © 2026 SideDeck contributors\n\n'
            'This program is free software under the GNU GPL v3 or later. '
            'There is no warranty.\n\n'
            'Support & issues: github.com/manueljpy/SideDeck',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () {
              showLicensePage(
                context: context,
                applicationName: 'SideDeck',
                applicationVersion: '1.1.0',
                applicationLegalese:
                    'Copyright © 2026 SideDeck contributors\n\n'
                    'GNU GPL v3 or later. See LICENSE and NOTICE in the '
                    'source repository.',
              );
            },
            child: const Text('Open-source licenses'),
          ),
        ],
      ),
    );
  }

  Future<void> _clearCache() async {
    final ok = await _confirm('Clear cache?',
        'Saved track analysis and the shop / chart lists are forgotten and read again when needed.');
    if (ok != true) return;
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in p.getKeys().toList()) {
        if (_isCacheKey(k)) await p.remove(k);
      }
      await AnalysisCache.instance.clearAll();
    } catch (e) {
      DebugLog.add('settings', 'clear cache failed: $e');
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cache cleared.')));
    }
  }

  static bool _isCacheKey(String k) =>
      k == 'ra_v1' ||
      k == 'traxsource_all_v1' ||
      k == 'taste_labels_v1' ||
      k.startsWith('hardwax_') ||
      k.startsWith('disc_') ||
      k.endsWith('_try') ||
      k == 'ra_gate_v2' ||
      k == 'traxsource_gate_v2';

  // Kept on a factory reset: the user's music and what they built from it.
  static const _keep = {
    'library_folder',
    'library_paths',
    'local_playlists',
    'disliked_v1',
    'play_counts_v1',
    'track_stars_v1',
    'lib_tags_v1',
    'lib_genre_override_v1',
    'wish_lists_v1',
  };

  Future<void> _factoryReset() async {
    final ok = await _confirm('Reset to factory settings?',
        'Every setting goes back to how it started and you will be signed out of Soulseek, '
        'Subsonic and the rest. Your music, library folders, playlists, stars, Backup tracks '
        'and deleted-track list are kept. The app closes the Auto DJ and asks you to restart it.');
    if (ok != true) return;
    try {
      if (widget.dj.automixOn) widget.dj.stopAutomix();
      final p = await SharedPreferences.getInstance();
      for (final k in p.getKeys().toList()) {
        if (!_keep.contains(k)) await p.remove(k);
      }
      Avoids.instance.clear();
      await AnalysisCache.instance.clearAll();
    } catch (e) {
      DebugLog.add('settings', 'factory reset failed: $e');
    }
    if (mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          title: const Text('Reset done'),
          content: const Text('Close BeatDeck completely and open it again to start fresh.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    }
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes')),
          ],
        ),
      );
}
