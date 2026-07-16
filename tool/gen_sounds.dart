// Generates the bundled NavAlert alarm/ringtone WAV assets.
// Run once:  dart run tool/gen_sounds.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const sampleRate = 22050;

void main() {
  final outDir = Directory('assets/sounds')..createSync(recursive: true);

  write('${outDir.path}/digital_clock.wav', digitalClock());
  write('${outDir.path}/siren.wav', siren());
  write('${outDir.path}/buzzer.wav', buzzer());
  write('${outDir.path}/bell.wav', bell());
  write('${outDir.path}/air_horn.wav', airHorn());
  write('${outDir.path}/ringtone.wav', ringtone());
  write('${outDir.path}/fake_call_voice.wav', fakeVoice());
  stdout.writeln('Sound assets generated in ${outDir.path}');
}

List<double> digitalClock() {
  // beep-beep-beep-beep pause, 880 Hz square
  final s = <double>[];
  for (var cycle = 0; cycle < 2; cycle++) {
    for (var b = 0; b < 4; b++) {
      s.addAll(tone(880, 0.12, square: true));
      s.addAll(silence(0.08));
    }
    s.addAll(silence(0.45));
  }
  return s;
}

List<double> siren() {
  // 600 → 1200 Hz sweep up and down
  final s = <double>[];
  const dur = 2.4;
  final n = (dur * sampleRate).round();
  var phase = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / n;
    final f = 600 + 600 * (0.5 - 0.5 * math.cos(2 * math.pi * t * 2));
    phase += 2 * math.pi * f / sampleRate;
    s.add(0.85 * math.sin(phase));
  }
  return s;
}

List<double> buzzer() {
  final s = <double>[];
  for (var b = 0; b < 3; b++) {
    s.addAll(tone(150, 0.5, square: true, harmonics: 3));
    s.addAll(silence(0.18));
  }
  return s;
}

List<double> bell() {
  final s = <double>[];
  for (var strike = 0; strike < 3; strike++) {
    final n = (0.7 * sampleRate).round();
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final env = math.exp(-4 * t);
      s.add(0.8 *
          env *
          (math.sin(2 * math.pi * 1500 * t) +
              0.5 * math.sin(2 * math.pi * 2250 * t)));
    }
  }
  return s;
}

List<double> airHorn() {
  final s = <double>[];
  const dur = 1.6;
  final n = (dur * sampleRate).round();
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final env = t < 0.05 ? t / 0.05 : (t > dur - 0.15 ? (dur - t) / 0.15 : 1.0);
    s.add(0.55 *
        env *
        (saw(440, t) + saw(554, t) + 0.5 * saw(880, t)));
  }
  return s;
}

List<double> ringtone() {
  // classic ring-ring cadence, dual tone 440+480 Hz
  final s = <double>[];
  for (var r = 0; r < 2; r++) {
    final n = (0.9 * sampleRate).round();
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      s.add(0.6 *
          (math.sin(2 * math.pi * 440 * t) +
              math.sin(2 * math.pi * 480 * t)) /
          2);
    }
    s.addAll(silence(0.35));
  }
  s.addAll(silence(1.2));
  return s;
}

List<double> fakeVoice() {
  // gentle murmur-like modulated tone as a placeholder "voice"
  final s = <double>[];
  const dur = 6.0;
  final n = (dur * sampleRate).round();
  final rng = math.Random(7);
  var f = 180.0;
  var target = 200.0;
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    if (i % (sampleRate ~/ 4) == 0) target = 140 + rng.nextDouble() * 140;
    f += (target - f) * 0.0005;
    final talking = (math.sin(2 * math.pi * 2.6 * t) > -0.4) ? 1.0 : 0.0;
    s.add(0.35 *
        talking *
        math.sin(2 * math.pi * f * t) *
        (0.7 + 0.3 * math.sin(2 * math.pi * 5 * t)));
  }
  return s;
}

double saw(double freq, double t) {
  final x = t * freq;
  return 2 * (x - x.floorToDouble()) - 1;
}

List<double> tone(double freq, double seconds,
    {bool square = false, int harmonics = 1}) {
  final n = (seconds * sampleRate).round();
  return List.generate(n, (i) {
    final t = i / sampleRate;
    var v = 0.0;
    for (var h = 1; h <= harmonics; h++) {
      v += math.sin(2 * math.pi * freq * h * t) / h;
    }
    if (square) v = v.sign * 0.8;
    return v * 0.85;
  });
}

List<double> silence(double seconds) =>
    List.filled((seconds * sampleRate).round(), 0.0);

void write(String path, List<double> samples) {
  final data = Int16List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    data[i] = (samples[i].clamp(-1.0, 1.0) * 32767 * 0.9).round();
  }
  final byteData = data.buffer.asUint8List();
  final header = BytesBuilder();
  void str(String s) => header.add(s.codeUnits);
  void u32(int v) => header.add(
      [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void u16(int v) => header.add([v & 0xff, (v >> 8) & 0xff]);

  str('RIFF');
  u32(36 + byteData.length);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  str('data');
  u32(byteData.length);
  header.add(byteData);
  File(path).writeAsBytesSync(header.toBytes());
}
