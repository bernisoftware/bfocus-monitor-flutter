import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'transport.dart';

/// Envio com `dart:io` HttpClient — sem pacote `http`.
class IoTransport extends MonitorTransport {
  IoTransport({Duration timeout = const Duration(seconds: 10)})
    : _timeout = timeout;

  final Duration _timeout;
  HttpClient? _client;

  @override
  Future<int> send(
    Uri endpoint,
    Map<String, String> headers,
    String body,
  ) async {
    final client = _client ??= HttpClient()..connectionTimeout = _timeout;
    final req = await client.postUrl(endpoint).timeout(_timeout);
    headers.forEach((k, v) {
      req.headers.set(k, v, preserveHeaderCase: true);
    });
    final bytes = utf8.encode(body);
    req.contentLength = bytes.length;
    req.add(bytes);
    final resp = await req.close().timeout(_timeout);
    await resp.drain<void>().timeout(_timeout, onTimeout: () {});
    return resp.statusCode;
  }

  @override
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}

MonitorTransport? defaultTransport() => IoTransport();

/// Sistema e runtime do aparelho (sem dado pessoal).
Map<String, Map<String, String>> platformContexts() {
  final contexts = <String, Map<String, String>>{};
  try {
    contexts['os'] = {
      'name': Platform.operatingSystem,
      'version': Platform.operatingSystemVersion,
    };
    contexts['runtime'] = {
      'name': 'dart',
      'version': Platform.version.split(' ').first,
    };
    contexts['device'] = {
      'locale': Platform.localeName,
      'processors': '${Platform.numberOfProcessors}',
    };
  } catch (_) {
    // Plataforma sem essas informações: segue sem elas.
  }
  return contexts;
}

/// Arquivo JSON no diretório temporário do app (no Flutter: cache do app no Android,
/// tmp no iOS). Falhou ler ou gravar: o cliente segue com 1 sinal de vida por init.
class FileHeartbeatStore implements HeartbeatStore {
  FileHeartbeatStore(this.file);

  final File file;

  @override
  Future<Map<String, Object?>?> read() async {
    try {
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      return data is Map ? data.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(Map<String, Object?> state) async {
    try {
      await file.writeAsString(jsonEncode(state), flush: true);
    } catch (_) {}
  }
}

HeartbeatStore? defaultHeartbeatStore() {
  try {
    return FileHeartbeatStore(
      File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}bfocus_monitor_heartbeat.json',
      ),
    );
  } catch (_) {
    return null;
  }
}
