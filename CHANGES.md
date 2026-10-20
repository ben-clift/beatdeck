# Changes from SideDeck

Forked from SideDeck 1.1.1 (https://github.com/manueljpy/SideDeck), 20 Oct 2026.

- Removed the original signed-release workflow (needs the author's keys).
- Added .github/workflows/build.yml: analyze, test and build a debug APK on every push.
- Planned: key lock button and pitch controls, local playlists, automix, Soulseek search.

## Soulseek step A (20 Oct 2026)
- Library header: rescan button, and an "Open Seeker" button (finds the app by its launcher name).
- The library rescans its folder whenever BeatDeck comes back to the foreground, so files Seeker just downloaded appear without a manual refresh.
- Step B (Soulseek search built into BeatDeck) is a later project.
