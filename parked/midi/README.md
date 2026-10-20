MIDI controller support, parked. Moved out of lib/ so it is not built.
To bring it back: move both .dart files into lib/, add flutter_midi_command ^1.4.0 to pubspec.yaml
with a win32 ^6.3.0 dependency_override (file_picker 8 clashes with it), and restore the
MIDI icon in library_drawer.dart and midiFor(_dj) in home_page.dart.
