/// O evento do Monitoramento (contrato em monitor/BRIEF.md §4). Dart puro: sem Flutter.
library;

/// Gravidade do evento.
enum MonitorLevel {
  fatal,
  error,
  warning,
  info;

  /// Nível a partir do texto do contrato (`null` se não for um dos quatro).
  static MonitorLevel? tryParse(String? value) {
    for (final l in MonitorLevel.values) {
      if (l.name == value) return l;
    }
    return null;
  }
}

/// Uma linha do rastro. A lista vai de FORA para DENTRO: o último é onde estourou.
class MonitorFrame {
  MonitorFrame({
    this.file,
    this.function,
    this.line,
    this.col,
    this.inApp = false,
  });

  String? file;
  String? function;
  int? line;
  int? col;
  bool inApp;

  Map<String, Object> toJson() => {
    if (file != null) 'file': file!,
    if (function != null) 'function': function!,
    if (line != null) 'line': line!,
    if (col != null) 'col': col!,
    'inApp': inApp,
  };

  @override
  String toString() => 'MonitorFrame($function $file:$line inApp=$inApp)';
}

/// Um passo antes do erro.
class MonitorBreadcrumb {
  MonitorBreadcrumb({
    required this.timestamp,
    required this.category,
    required this.message,
    this.level = MonitorLevel.info,
  });

  final String timestamp;
  final String category;
  final String message;
  final MonitorLevel level;

  Map<String, Object> toJson() => {
    'timestamp': timestamp,
    'category': category,
    'message': message,
    'level': level.name,
  };
}

/// O evento pronto para envio. Campos nulos ou vazios não vão no JSON.
///
/// `beforeSend` recebe esta instância e pode alterá-la (ou devolver `null` para descartar).
class MonitorEvent {
  MonitorEvent({
    required this.timestamp,
    required this.level,
    required this.type,
    required this.message,
    List<MonitorFrame>? frames,
    this.release,
    this.environment,
    this.transaction,
    this.url,
    this.userExternalId,
    this.userHash,
    this.customerExternalId,
    Map<String, String>? tags,
    List<MonitorBreadcrumb>? breadcrumbs,
    this.fingerprint,
    Map<String, Map<String, String>>? contexts,
    this.sdkName = 'bfocus-monitor-flutter',
    this.sdkVersion = '0.0.0',
  }) : frames = frames ?? <MonitorFrame>[],
       tags = tags ?? <String, String>{},
       breadcrumbs = breadcrumbs ?? <MonitorBreadcrumb>[],
       contexts = contexts ?? <String, Map<String, String>>{};

  String timestamp;
  MonitorLevel level;
  String type;
  String message;
  List<MonitorFrame> frames;
  String? release;
  String? environment;
  String? transaction;
  String? url;
  String? userExternalId;
  String? userHash;
  String? customerExternalId;
  Map<String, String> tags;
  List<MonitorBreadcrumb> breadcrumbs;
  List<String>? fingerprint;
  Map<String, Map<String, String>> contexts;
  String sdkName;
  String sdkVersion;

  Map<String, Object> toJson() => {
    'timestamp': timestamp,
    'level': level.name,
    if (_has(release)) 'release': release!,
    if (_has(environment)) 'environment': environment!,
    'exception': {
      'type': type,
      'message': message,
      if (frames.isNotEmpty) 'frames': [for (final f in frames) f.toJson()],
    },
    if (_has(transaction)) 'transaction': transaction!,
    if (_has(url)) 'url': url!,
    if (_has(userExternalId))
      'user': {
        'externalId': userExternalId!,
        if (_has(userHash)) 'userHash': userHash!,
      },
    if (_has(customerExternalId))
      'customer': {'externalId': customerExternalId!},
    if (tags.isNotEmpty) 'tags': Map<String, String>.of(tags),
    if (breadcrumbs.isNotEmpty)
      'breadcrumbs': [for (final b in breadcrumbs) b.toJson()],
    if (fingerprint != null && fingerprint!.isNotEmpty)
      'fingerprint': List<String>.of(fingerprint!),
    if (contexts.isNotEmpty) 'contexts': contexts,
    'sdk': {'name': sdkName, 'version': sdkVersion},
  };

  static bool _has(String? s) => s != null && s.isNotEmpty;
}

/// ISO 8601 em UTC com milissegundos e `Z` (`2026-10-06T12:00:00.000Z`).
String isoUtc(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final ms = u.millisecond.toString().padLeft(3, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.${ms}Z';
}

/// Corta sem quebrar um par substituto (emoji) ao meio.
String truncate(String s, int max) {
  if (s.length <= max) return s;
  var end = max;
  if (end > 0) {
    final c = s.codeUnitAt(end - 1);
    if (c >= 0xD800 && c <= 0xDBFF) end--;
  }
  return s.substring(0, end);
}
