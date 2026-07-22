import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/services/sound_service.dart';

/// Bundled-asset integrity.
///
/// Every alarm the rider can choose has to exist as a real file AND be
/// declared in pubspec.yaml, or the alarm plays silence at the exact moment
/// it matters. This project has already shipped with an empty assets/sounds/
/// once; these tests turn that into a build failure instead of a silent one.
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();

  group('alarm sound catalogue (Figure 33)', () {
    test('offers the five documented alarm sounds', () {
      expect(
        SoundService.alarmCatalog.keys,
        containsAll(
            ['Digital Clock', 'Siren', 'Buzzer', 'Bell', 'Air Horn']),
      );
    });

    test('every selectable alarm resolves to a file that exists', () {
      for (final entry in SoundService.alarmCatalog.entries) {
        final file = File('assets/${entry.value}');
        expect(file.existsSync(), isTrue,
            reason: '"${entry.key}" points at ${file.path}, which is missing');
        expect(file.lengthSync(), greaterThan(0),
            reason: '"${entry.key}" is an empty file — it would play silence');
      }
    });

    test('the default alarm sound is a real catalogue entry', () {
      // Trips and user_settings both default to this exact string.
      expect(SoundService.alarmCatalog.containsKey('Digital Clock'), isTrue);
    });
  });

  group('emergency audio (R7)', () {
    test('the fake-call ringtone is bundled', () {
      final ringtone = File('assets/sounds/ringtone.wav');
      expect(ringtone.existsSync(), isTrue);
      expect(ringtone.lengthSync(), greaterThan(0));
    });

    test('the built-in fake-call voice recording is bundled', () {
      final voice = File('assets/sounds/fake_call_voice.wav');
      expect(voice.existsSync(), isTrue);
      expect(voice.lengthSync(), greaterThan(0));
    });
  });

  group('transit data', () {
    test('the GTFS feed is bundled and non-trivial', () {
      final feed = File('assets/gtfs/routes.json.gz');
      expect(feed.existsSync(), isTrue);
      // The Metro Manila feed is ~0.77 MB; anything tiny means a broken build.
      expect(feed.lengthSync(), greaterThan(100000));
    });

    test('the feed ships with its attribution notice', () {
      expect(File('assets/gtfs/NOTICE.md').existsSync(), isTrue,
          reason: 'DOTC/Sakay licence terms must travel with the data');
    });
  });

  group('pubspec asset declarations', () {
    test('declares the sound directory', () {
      expect(pubspec, contains('assets/sounds/'));
    });

    test('declares the GTFS feed', () {
      expect(pubspec, contains('assets/gtfs/routes.json.gz'));
    });

    test('declares each images subfolder it ships', () {
      // Flutter does not recurse into nested asset folders, so every
      // subdirectory has to be listed individually or it silently vanishes.
      for (final dir in Directory('assets/images').listSync()) {
        if (dir is! Directory) continue;
        final name = dir.path.split(RegExp(r'[\\/]')).last;
        if (name == 'reference') continue; // repo-only, deliberately unshipped
        expect(pubspec, contains('assets/images/$name/'),
            reason: 'assets/images/$name/ exists but is not in pubspec.yaml');
      }
    });

    test('is a single valid YAML document', () {
      // A stray indent on line 1 once split this into two documents and broke
      // every build, test and analyze run at once.
      final firstLine = pubspec.split('\n').first;
      expect(firstLine, startsWith('name:'),
          reason: 'line 1 must not be indented');
      expect(pubspec, isNot(contains('\n---\n')));
    });
  });
}
