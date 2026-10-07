import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../lib/src/core/core.dart';

/// Requisição que o bFocus de mentira recebeu.
class Recorded {
  Recorded(this.method, this.path, this.headers, this.raw)
      : body = _decode(raw);

  final String method;
  final String path;
  final Map<String, String> headers; // nomes em minúsculas
  final String raw;
  final Map<String, dynamic> body;

  static Map<String, dynamic> _decode(String raw) {
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  List<Map<String, dynamic>> get events => [
        for (final e in (body['events'] as List? ?? const []))
          (e as Map).cast<String, dynamic>()
      ];
}

class Reply {
  const Reply(this.status, [this.body = const {'accepted': 1}]);
  final int status;
  final Object body;
}

/// HttpServer local que grava cada requisição e responde a sequência dada (depois, 202).
class FakeServer {
  FakeServer._(this._server, this._replies);

  final HttpServer _server;
  final List<Reply> _replies;
  final List<Recorded> requests = [];
  final List<Recorded> heartbeats = [];

  /// Resposta ao sinal de vida (padrão 204).
  int heartbeatStatus = 204;

  static Future<FakeServer> start([List<Reply> replies = const []]) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeServer._(server, replies);
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      final headers = <String, String>{};
      req.headers.forEach(
          (name, values) => headers[name.toLowerCase()] = values.join(','));
      final rec = Recorded(req.method, req.uri.path, headers, raw);
      if (req.uri.path.endsWith('/heartbeat')) {
        fake.heartbeats.add(rec);
        req.response.statusCode = fake.heartbeatStatus;
        await req.response.close();
        return;
      }
      final i = fake.requests.length;
      fake.requests.add(rec);
      final reply =
          i < fake._replies.length ? fake._replies[i] : const Reply(202);
      req.response.statusCode = reply.status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(reply.body));
      await req.response.close();
    });
    return fake;
  }

  String get baseUrl => 'http://${_server.address.host}:${_server.port}';

  List<Map<String, dynamic>> get events =>
      [for (final r in requests) ...r.events];

  Future<void> close() => _server.close(force: true);
}

MonitorClient testClient(MonitorOptions options, {HeartbeatStore? store}) =>
    MonitorClient(
      options,
      heartbeatStore: store ?? MemoryHeartbeatStore(),
      flushInterval: const Duration(milliseconds: 20),
      retryDelay: const Duration(milliseconds: 50),
    );

/// Segue um caminho com ponto ("breadcrumbs.0.category").
(Object?, bool) dig(Object? value, String path) {
  Object? cur = value;
  for (final part in path.split('.')) {
    if (cur is Map) {
      if (!cur.containsKey(part)) return (null, false);
      cur = cur[part];
    } else if (cur is List) {
      final i = int.tryParse(part);
      if (i == null || i < 0 || i >= cur.length) return (null, false);
      cur = cur[i];
    } else {
      return (null, false);
    }
  }
  return (cur, true);
}

/// Caminhos com valor nulo (o contrato não aceita).
List<String> nullPaths(Object? v, [String path = '']) {
  if (v == null) return [path];
  if (v is Map)
    return [for (final e in v.entries) ...nullPaths(e.value, '$path.${e.key}')];
  if (v is List)
    return [for (var i = 0; i < v.length; i++) ...nullPaths(v[i], '$path.$i')];
  return const [];
}

Future<void> settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Future<List<Recorded>> waitHeartbeats(FakeServer srv, int n) async {
  final sw = Stopwatch()..start();
  while (srv.heartbeats.length < n && sw.elapsed < const Duration(seconds: 3)) {
    await settle(5);
  }
  return srv.heartbeats;
}
