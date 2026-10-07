import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'event.dart';
import 'options.dart';
import 'stack.dart';
import 'transport.dart';
import 'transport_stub.dart'
    if (dart.library.io) 'transport_io.dart'
    as platform;
import 'version.dart';

/// O núcleo do monitor, em Dart puro (sem Flutter): fila, filtros, dedupe e envio.
///
/// Os ganchos do Flutter (`BfocusMonitor`) só chamam [captureException]. Nenhum método
/// lança: toda falha do monitor é engolida.
class MonitorClient {
  MonitorClient(
    this.options, {
    MonitorTransport? transport,
    bool useDefaultTransport = true,
    this.flushInterval = const Duration(seconds: 1),
    this.retryDelay = const Duration(seconds: 2),
    DateTime Function()? clock,
    Random? random,
    Map<String, Map<String, String>>? contexts,
    bool heartbeat = true,
    HeartbeatStore? heartbeatStore,
    bool useDefaultHeartbeatStore = true,
    this.heartbeatMinInterval = const Duration(minutes: 30),
  }) : _transport =
           transport ??
           (useDefaultTransport ? platform.defaultTransport() : null),
       _clock = clock ?? DateTime.now,
       _random = random ?? Random(),
       _contexts = contexts ?? platform.platformContexts(),
       _classifier = FrameClassifier(
         inAppPackages: options.inAppPackages,
         libraryPackages: options.libraryPackages,
       ),
       _heartbeatStore =
           heartbeatStore ??
           (useDefaultHeartbeatStore ? platform.defaultHeartbeatStore() : null),
       _endpoint = _buildEndpoint(options.baseUrl, 'events'),
       _heartbeatEndpoint = _buildEndpoint(options.baseUrl, 'heartbeat') {
    if (options.key.trim().isEmpty) {
      throw ArgumentError.value(
        options.key,
        'key',
        'a chave bf_mon_… do agente é obrigatória',
      );
    }
    // Sinal de vida: fora do construtor (nenhuma rede síncrona no init).
    if (heartbeat) {
      Timer.run(() => unawaited(sendHeartbeat()));
    }
  }

  /// Intervalo mínimo entre dois sinais de vida no MESMO aparelho (§7b: 30 min).
  final Duration heartbeatMinInterval;
  final HeartbeatStore? _heartbeatStore;
  final Uri? _heartbeatEndpoint;
  String? _instance;

  /// Manda o sinal de vida se o último deste aparelho tiver mais de
  /// [heartbeatMinInterval]. Sem armazenamento, 1 por init. Nunca lança.
  Future<void> sendHeartbeat() async {
    try {
      final transport = _transport;
      final endpoint = _heartbeatEndpoint;
      if (_closed || _disabled || transport == null || endpoint == null) return;
      final store = _heartbeatStore;
      final now = _clock();
      Map<String, Object?>? state;
      if (store != null) {
        try {
          state = await store.read();
        } catch (_) {}
      }
      final saved = state?['instance'];
      _instance ??= saved is String && saved.isNotEmpty ? saved : _randomId();
      final last = state?['lastHeartbeat'];
      if (last is int) {
        final age = now.millisecondsSinceEpoch - last;
        if (age >= 0 && age < heartbeatMinInterval.inMilliseconds) return;
      }
      if (store != null) {
        try {
          await store.write({
            'instance': _instance,
            'lastHeartbeat': now.millisecondsSinceEpoch,
          });
        } catch (_) {}
      }
      final runtime = _contexts['runtime'];
      final body = jsonEncode({
        'instance': _instance,
        if (options.release != null && options.release!.isNotEmpty)
          'release': options.release,
        if (options.environment.isNotEmpty) 'environment': options.environment,
        'runtime': runtime == null ? {'name': 'dart'} : Map.of(runtime),
        'sdk': {'name': sdkName, 'version': sdkVersion},
      });
      final status = await transport.send(endpoint, _headers(), body);
      if (status == 401 || status == 403) {
        _disabled = true;
        _queue.clear();
      }
    } catch (_) {
      // rede: o próximo init tenta de novo
    }
  }

  String _randomId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Map<String, String> _headers() {
    const ua = '$sdkName/$sdkVersion';
    return {
      'X-bFocus-Monitor-Key': options.key.trim(),
      'Content-Type': 'application/json',
      'X-bFocus-Client': ua,
      'User-Agent': ua,
    };
  }

  static const int maxQueue = 100;
  static const int batchSize = 20;
  static const Duration dedupeWindow = Duration(seconds: 30);
  static const int perMinute = 100;
  static const int maxCrumbs = 30;
  static const int maxMessage = 2000;
  static const int maxEventBytes = 64 * 1024;

  final MonitorOptions options;
  final Duration flushInterval;
  final Duration retryDelay;
  final MonitorTransport? _transport;
  final DateTime Function() _clock;
  final Random _random;
  final Map<String, Map<String, String>> _contexts;
  final FrameClassifier _classifier;
  final Uri? _endpoint;

  final List<String> _queue = [];
  final Map<String, DateTime> _seen = {};
  final Map<String, String> _tags = {};
  final List<MonitorBreadcrumb> _crumbs = [];
  String? _userId;
  String? _customerId;
  String? _userHash;
  DateTime? _minuteStart;
  int _inMinute = 0;
  Timer? _timer;
  bool _sending = false;
  bool _disabled = false;
  bool _closed = false;

  /// Desligado depois de um 401/403 (até um novo init).
  bool get disabled => _disabled;

  /// Eventos na fila (sem contar o lote em envio).
  int get pendingCount => _queue.length;

  /// Nada na fila e nada em envio.
  bool get idle => _queue.isEmpty && !_sending;

  static Uri? _buildEndpoint(String base, String path) {
    try {
      var b = base.trim();
      while (b.endsWith('/')) {
        b = b.substring(0, b.length - 1);
      }
      return Uri.parse('$b/api/v1/monitor/$path');
    } catch (_) {
      return null;
    }
  }

  /// Captura um erro (o que o Dart lançar). [stackTrace] nulo: usa o rastro atual.
  void captureException(
    Object error,
    StackTrace? stackTrace, {
    MonitorLevel level = MonitorLevel.error,
    Map<String, String>? tags,
    List<String>? fingerprint,
  }) {
    try {
      final d = describeError(error);
      final frames = parseStackTrace(
        (stackTrace ?? StackTrace.current).toString(),
        _classifier,
      );
      captureParts(
        d.$1,
        d.$2,
        frames,
        level: level,
        tags: tags,
        fingerprint: fingerprint,
      );
    } catch (_) {
      /* nunca derruba o app */
    }
  }

  /// Manda uma mensagem como evento (padrão: info).
  void captureMessage(
    String message, {
    MonitorLevel level = MonitorLevel.info,
  }) {
    try {
      final frames = parseStackTrace(
        StackTrace.current.toString(),
        _classifier,
      );
      captureParts(
        'Message',
        message,
        frames,
        level: level,
        fingerprint: [message],
      );
    } catch (_) {}
  }

  /// Captura com tipo, mensagem e frames já prontos.
  void captureParts(
    String type,
    String message,
    List<MonitorFrame> frames, {
    MonitorLevel level = MonitorLevel.error,
    Map<String, String>? tags,
    List<String>? fingerprint,
  }) {
    try {
      _capture(type, message, frames, level, tags, fingerprint);
    } catch (_) {}
  }

  void _capture(
    String type,
    String message,
    List<MonitorFrame> frames,
    MonitorLevel level,
    Map<String, String>? tags,
    List<String>? fingerprint,
  ) {
    if (_closed || _disabled || _transport == null || _endpoint == null) return;
    message = truncate(message, maxMessage);
    for (final p in options.ignore) {
      if (p is String
          ? (p.isNotEmpty && message.contains(p))
          : p.allMatches(message).isNotEmpty)
        return;
    }
    if (options.sampleRate < 1 && _random.nextDouble() >= options.sampleRate)
      return;

    final now = _clock();
    final key = '$type|$message|${_dedupeFrame(frames)}';
    final last = _seen[key];
    if (last != null && now.difference(last) < dedupeWindow) return;
    if (_minuteStart == null ||
        now.difference(_minuteStart!) >= const Duration(minutes: 1)) {
      _minuteStart = now;
      _inMinute = 0;
    }
    if (_inMinute >= perMinute) return;
    _inMinute++;
    _seen[key] = now;
    if (_seen.length > 1000) {
      _seen.removeWhere((_, t) => now.difference(t) >= dedupeWindow);
    }

    MonitorEvent? event = MonitorEvent(
      timestamp: isoUtc(now),
      level: level,
      type: type,
      message: message,
      frames: frames,
      release: options.release,
      environment: options.environment,
      userExternalId: _userId,
      userHash: _userHash,
      customerExternalId: _customerId,
      tags: {
        ..._tags,
        if (tags != null)
          for (final e in tags.entries)
            truncate(e.key, 64): truncate(e.value, 200),
      },
      breadcrumbs: List.of(_crumbs),
      fingerprint: fingerprint,
      contexts: {for (final e in _contexts.entries) e.key: Map.of(e.value)},
      sdkName: sdkName,
      sdkVersion: sdkVersion,
    );
    final before = options.beforeSend;
    if (before != null) {
      try {
        event = before(event);
      } catch (_) {
        /* beforeSend com erro: vai como estava */
      }
      if (event == null) return;
    }
    final body = _encode(event);
    if (body == null) return;
    if (_queue.length >= maxQueue) return; // fila cheia: descarta o mais novo
    _queue.add(body);
    if (_queue.length >= batchSize) {
      _schedule(Duration.zero);
    } else {
      _timer ??= Timer(flushInterval, _drain);
    }
  }

  String _dedupeFrame(List<MonitorFrame> frames) {
    for (final f in frames.reversed) {
      if (f.inApp) return '${f.file}:${f.line}';
    }
    return frames.isEmpty ? '' : '${frames.last.file}:${frames.last.line}';
  }

  /// Serializa cortando breadcrumbs, frames e mensagem até caber em 64 KB.
  String? _encode(MonitorEvent e) {
    for (var attempt = 0; attempt < 5; attempt++) {
      final String s;
      try {
        s = jsonEncode(e.toJson());
      } catch (_) {
        return null;
      }
      if (utf8.encode(s).length <= maxEventBytes) return s;
      switch (attempt) {
        case 0:
          e.breadcrumbs = [];
        case 1:
          if (e.frames.length > 20)
            e.frames = e.frames.sublist(e.frames.length - 20);
        case 2:
          e.message = truncate(e.message, 500);
          e.tags = {};
          e.contexts = {};
        case 3:
          for (final f in e.frames) {
            if (f.file != null) f.file = truncate(f.file!, 300);
            if (f.function != null) f.function = truncate(f.function!, 200);
          }
          e.fingerprint = null;
      }
    }
    return null;
  }

  /// Pessoa e cliente afetados. [userHash] é a assinatura v2 que o SEU servidor calculou
  /// (a mesma do widget). Nulos limpam a identidade.
  void setUser(
    String? userExternalId,
    String? customerExternalId, {
    String? userHash,
  }) {
    _userId = (userExternalId?.isEmpty ?? true) ? null : userExternalId;
    _customerId = (customerExternalId?.isEmpty ?? true)
        ? null
        : customerExternalId;
    _userHash = (userHash?.isEmpty ?? true) ? null : userHash;
  }

  void setTag(String key, String value) {
    if (key.isEmpty) return;
    _tags[truncate(key, 64)] = truncate(value, 200);
  }

  void addBreadcrumb(
    String category,
    String message, {
    MonitorLevel level = MonitorLevel.info,
  }) {
    try {
      _crumbs.add(
        MonitorBreadcrumb(
          timestamp: isoUtc(_clock()),
          category: truncate(category, 40),
          message: truncate(message, 300),
          level: level,
        ),
      );
      if (_crumbs.length > maxCrumbs) _crumbs.removeAt(0);
    } catch (_) {}
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, _drain);
  }

  Future<void> _drain() async {
    _timer?.cancel();
    _timer = null;
    if (_sending) return;
    _sending = true;
    try {
      while (_queue.isNotEmpty) {
        final n = min(batchSize, _queue.length);
        final batch = _queue.sublist(0, n);
        _queue.removeRange(0, n);
        if (_disabled) continue;
        await _sendBatch(batch);
      }
    } catch (_) {
      // nunca derruba o app
    } finally {
      _sending = false;
    }
  }

  Future<void> _sendBatch(List<String> batch) async {
    final transport = _transport;
    final endpoint = _endpoint;
    if (transport == null || endpoint == null) return;
    final body = '{"events":[${batch.join(',')}]}';
    final headers = _headers();
    for (var attempt = 0; attempt < 2; attempt++) {
      int? status;
      try {
        status = await transport.send(endpoint, headers, body);
      } catch (_) {
        status = null; // rede
      }
      if (status != null && status >= 200 && status < 300) return;
      if (status == 401 || status == 403) {
        _disabled =
            true; // chave errada/revogada: não martelar até o próximo init
        _queue.clear();
        return;
      }
      if (status == null || status == 429 || status >= 500) {
        if (attempt == 0 && !_closed) {
          await Future<void>.delayed(retryDelay);
          continue;
        }
        return;
      }
      return; // 400, 413…: descarta o lote
    }
  }

  /// Envia o que está na fila e espera até [timeout]. `true` se esvaziou.
  Future<bool> flush([Duration timeout = const Duration(seconds: 2)]) async {
    try {
      final sw = Stopwatch()..start();
      if (_queue.isNotEmpty && !_sending) unawaited(_drain());
      while (!idle) {
        if (sw.elapsed >= timeout) return false;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (_queue.isNotEmpty && !_sending) unawaited(_drain());
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Envia o que falta (até 2 s) e desliga. Capturas depois disso são ignoradas.
  Future<void> close([Duration timeout = const Duration(seconds: 2)]) async {
    if (_closed) return;
    try {
      await flush(timeout);
    } finally {
      _closed = true;
      _timer?.cancel();
      _timer = null;
      _queue.clear();
      try {
        _transport?.close();
      } catch (_) {}
    }
  }
}

/// Tipo e mensagem do erro. A mensagem perde o prefixo "Tipo: " e "Exception: ".
(String, String) describeError(Object error) {
  String type;
  try {
    type = error.runtimeType.toString();
  } catch (_) {
    type = 'Object';
  }
  String message;
  try {
    message = error.toString();
  } catch (_) {
    message = type;
  }
  for (final prefix in ['$type: ', 'Exception: ']) {
    if (message.startsWith(prefix)) {
      message = message.substring(prefix.length);
      break;
    }
  }
  return (type, message);
}
