import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';

/// Whether the decks can be expected to play a Soulseek result, judged from
/// what the search shows, so a download is never wasted on a file that will
/// not load.
bool slskPlayable(SlskResult r) {
  if (!isNativeAudioExtension(r.ext)) return false;
  // Previews and broken stubs.
  if (r.size > 0 && r.size < 400000) return false;
  // Apple Lossless hides inside .m4a; the decks only read AAC there. AAC
  // never goes much above 320 kbps, lossless is far higher.
  if (r.ext == 'm4a' || r.ext == 'm4b' || r.ext == 'aac') {
    if (r.bitrate > 400) return false;
    if (r.durationSec > 0 && r.size > 0) {
      final kbps = r.size * 8 / r.durationSec / 1000;
      if (kbps > 400) return false;
    }
  }
  return true;
}
