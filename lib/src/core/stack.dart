import 'event.dart';

/// Pacotes do Flutter/Dart SDK: nunca são "do sistema".
const Set<String> sdkPackages = {
  'flutter',
  'flutter_test',
  'flutter_web_plugins',
  'flutter_localizations',
  'flutter_driver',
  'integration_test',
  'sky_engine',
  'bfocus_monitor',
};

/// Decide o `inApp` de cada arquivo do rastro.
class FrameClassifier {
  const FrameClassifier({
    this.inAppPackages = const [],
    this.libraryPackages = const [],
  });

  final List<String> inAppPackages;
  final List<String> libraryPackages;

  bool inApp(String file) {
    if (file.startsWith('dart:') || file.startsWith('org-dartlang-sdk:'))
      return false;
    if (file.startsWith('package:')) {
      final slash = file.indexOf('/');
      final pkg = file.substring(
        'package:'.length,
        slash < 0 ? file.length : slash,
      );
      if (sdkPackages.contains(pkg)) return false;
      if (inAppPackages.isNotEmpty) return inAppPackages.contains(pkg);
      return !libraryPackages.contains(pkg);
    }
    final lower = file.toLowerCase();
    if (lower.contains('/.pub-cache/') ||
        lower.contains('/flutter/packages/') ||
        lower.contains('/flutter/bin/cache/')) {
      return false;
    }
    return inAppPackages.isEmpty;
  }
}

// VM: "#0      Foo.bar (package:app/x.dart:10:5)" (linha/coluna opcionais).
final RegExp _vmLine = RegExp(r'^#\d+\s+(.+?)\s+\((.+)\)\s*$');
final RegExp _location = RegExp(r'^(.*?):(\d+)(?::(\d+))?$');
// package:stack_trace (terse/Chain): "package:app/x.dart 10:5  Foo.bar".
final RegExp _terseLine = RegExp(r'^(\S+)\s+(\d+)(?::(\d+))?\s+(.+)$');

/// Rastro do Dart (de DENTRO para fora) → frames do contrato (de FORA para dentro).
/// Ficam no máximo [max] frames (os mais internos).
List<MonitorFrame> parseStackTrace(
  String? stack,
  FrameClassifier classifier, {
  int max = 60,
}) {
  if (stack == null || stack.isEmpty) return <MonitorFrame>[];
  final frames = <MonitorFrame>[];
  for (final raw in stack.split('\n')) {
    if (frames.length >= max) break;
    final line = raw.trim();
    if (line.isEmpty ||
        line.startsWith('<asynchronous suspension>') ||
        line == '===== asynchronous gap ===========================') {
      continue;
    }
    String? fn;
    String file;
    int? ln;
    int? col;
    final vm = _vmLine.firstMatch(line);
    if (vm != null) {
      fn = vm.group(1);
      final loc = vm.group(2)!;
      final m = _location.firstMatch(loc);
      if (m != null && m.group(1)!.isNotEmpty) {
        file = m.group(1)!;
        ln = int.tryParse(m.group(2)!);
        col = m.group(3) == null ? null : int.tryParse(m.group(3)!);
      } else {
        file = loc;
      }
    } else {
      final t = _terseLine.firstMatch(line);
      if (t == null) continue;
      file = t.group(1)!;
      ln = int.tryParse(t.group(2)!);
      col = t.group(3) == null ? null : int.tryParse(t.group(3)!);
      fn = t.group(4);
    }
    frames.add(
      MonitorFrame(
        file: file,
        function: fn,
        line: ln,
        col: col,
        inApp: classifier.inApp(file),
      ),
    );
  }
  // Os frames do próprio monitor (quem capturou) não são o erro.
  while (frames.isNotEmpty && isOwnFile(frames.first.file ?? '')) {
    frames.removeAt(0);
  }
  return frames.reversed.toList();
}

/// Arquivo do próprio pacote (instalado ou, nos testes, pelo caminho).
bool isOwnFile(String file) =>
    file.startsWith('package:bfocus_monitor/') ||
    file.endsWith('/lib/src/core/client.dart') ||
    file.endsWith('/lib/bfocus_monitor.dart');
