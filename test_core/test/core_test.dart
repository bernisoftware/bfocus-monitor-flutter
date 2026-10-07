import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../lib/src/core/core.dart';
import '../../lib/src/core/transport_io.dart' show FileHeartbeatStore;
import 'support.dart';

class PedidoException implements Exception {
  PedidoException(this.id);
  final int id;
  @override
  String toString() => 'PedidoException: pedido $id não encontrado';
}

void lancar() => throw PedidoException(42);

void main() {
  group('versão', () {
    test('constante = pubspec.yaml = monitor/release.json', () {
      final pubspec = File('../pubspec.yaml').readAsStringSync();
      final m =
          RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
      expect(m?.group(1), sdkVersion);
      final release = File('../../release.json');
      if (release.existsSync()) {
        expect((jsonDecode(release.readAsStringSync()) as Map)['version'],
            sdkVersion);
      }
      expect(File('../README.md').readAsStringSync(),
          contains('bfocus_monitor: ^$sdkVersion'));
    });
  });

  group('parseStackTrace', () {
    test('formato da VM: de fora para dentro, inApp por pacote', () {
      const stack =
          '#0      Pedido.total (package:loja/pedidos/total.dart:50:7)\n'
          '#1      _HomeState.build.<anonymous closure> (package:loja/main.dart:10:5)\n'
          '<asynchronous suspension>\n'
          '#2      GestureRecognizer.invokeCallback (package:flutter/src/gestures/recognizer.dart:345:24)\n'
          '#3      _rootRun (dart:async/zone.dart:1399:13)\n'
          '#4      Dio.fetch (package:dio/src/dio_mixin.dart:300:3)\n';
      final frames = parseStackTrace(
          stack, const FrameClassifier(libraryPackages: ['dio']));
      expect(frames.map((f) => f.function), [
        'Dio.fetch',
        '_rootRun',
        'GestureRecognizer.invokeCallback',
        '_HomeState.build.<anonymous closure>',
        'Pedido.total',
      ]);
      expect(frames.map((f) => f.inApp), [false, false, false, true, true]);
      expect(frames.last.file, 'package:loja/pedidos/total.dart');
      expect(frames.last.line, 50);
      expect(frames.last.col, 7);
    });

    test('inAppPackages restringe ao app', () {
      const stack =
          '#0      a (package:loja/a.dart:1:1)\n#1      b (package:outro/b.dart:2:1)\n';
      final frames = parseStackTrace(
          stack, const FrameClassifier(inAppPackages: ['loja']));
      expect(frames.map((f) => f.inApp), [false, true]);
    });

    test('formato terse do package:stack_trace e sem coluna', () {
      const stack = 'package:loja/a.dart 10:5  Foo.bar\n'
          'dart:async  _rootRun\n'
          '#0      main (file:///app/bin/main.dart:3)\n';
      final frames = parseStackTrace(stack, const FrameClassifier());
      expect(frames.first.function, 'main');
      expect(frames.first.line, 3);
      expect(frames.first.col, isNull);
      expect(frames.last.function, 'Foo.bar');
      expect(frames.last.inApp, isTrue);
    });

    test('rastro vazio ou ilegível não quebra', () {
      expect(parseStackTrace(null, const FrameClassifier()), isEmpty);
      expect(parseStackTrace('lixo\n\n', const FrameClassifier()), isEmpty);
    });

    test('pacotes do Flutter, este pacote e pub-cache são biblioteca', () {
      const c = FrameClassifier();
      expect(c.inApp('package:flutter/src/widgets/framework.dart'), isFalse);
      expect(c.inApp('package:bfocus_monitor/bfocus_monitor.dart'), isFalse);
      expect(c.inApp('dart:ui/hooks.dart'), isFalse);
      expect(
          c.inApp(
              'file:///Users/x/.pub-cache/hosted/pub.dev/dio-5.0.0/lib/a.dart'),
          isFalse);
      expect(c.inApp('package:loja/main.dart'), isTrue);
    });
  });

  group('captura', () {
    late FakeServer srv;
    late MonitorClient client;

    Future<Map<String, dynamic>> only() async {
      expect(await client.flush(const Duration(seconds: 3)), isTrue);
      return srv.events.single;
    }

    setUp(() async => srv = await FakeServer.start());
    tearDown(() async {
      await client.close();
      await srv.close();
    });

    test('exceção real: tipo, mensagem, frames e contextos', () async {
      client = testClient(MonitorOptions(
          key: 'bf_mon_x', baseUrl: srv.baseUrl, release: '2.0.0'));
      try {
        lancar();
      } catch (e, s) {
        client.captureException(e, s);
      }
      final ev = await only();
      expect(dig(ev, 'exception.type').$1, 'PedidoException');
      expect(dig(ev, 'exception.message').$1, 'pedido 42 não encontrado');
      expect(ev['environment'], 'production');
      final frames = (dig(ev, 'exception.frames').$1 as List).cast<Map>();
      expect(frames.last['function'], 'lancar');
      expect(frames.last['inApp'], isTrue);
      expect((ev['contexts'] as Map)['os'], isNotNull);
      expect(dig(ev, 'contexts.runtime.name').$1, 'dart');
    });

    test(
        'captureMessage: nível info, fingerprint = mensagem, sem frames do monitor',
        () async {
      client =
          testClient(MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl));
      client.captureMessage('estoque negativo');
      final ev = await only();
      expect(ev['level'], 'info');
      expect(ev['fingerprint'], ['estoque negativo']);
      final frames = (dig(ev, 'exception.frames').$1 as List).cast<Map>();
      expect(
          frames.where((f) =>
              (f['file'] as String).endsWith('/lib/src/core/client.dart')),
          isEmpty);
    });

    test('tags do processo + do evento; ignore com RegExp; beforeSend',
        () async {
      client = testClient(MonitorOptions(
        key: 'bf_mon_x',
        baseUrl: srv.baseUrl,
        ignore: [RegExp(r'^Network')],
        beforeSend: (e) {
          if (e.message.contains('descartar')) return null;
          if (e.message.contains('quebrar')) throw StateError('bug');
          e.tags['alterado'] = 'sim';
          return e;
        },
      ));
      client.setTag('modulo', 'fiscal');
      client.captureParts('E', 'NetworkError x', []);
      client.captureParts('E', 'descartar', []);
      client.captureParts('E', 'quebrar', []);
      client.captureParts('E', 'ok', [], tags: {'etapa': 'nfe'});
      await client.flush(const Duration(seconds: 3));
      final evs = srv.events;
      expect(evs.map((e) => dig(e, 'exception.message').$1), ['quebrar', 'ok']);
      expect(evs.last['tags'],
          {'modulo': 'fiscal', 'etapa': 'nfe', 'alterado': 'sim'});
      expect(evs.first['tags'], {'modulo': 'fiscal'});
    });

    test('100 por minuto e lotes de no máximo 20', () async {
      client =
          testClient(MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl));
      for (var i = 0; i < 150; i++) {
        client.captureParts('E', 'erro $i', []);
        if (i % 20 == 0) await settle(5);
      }
      await client.flush(const Duration(seconds: 5));
      expect(srv.events.length, 100);
      expect(srv.requests.every((r) => r.events.length <= 20), isTrue);
    });

    test('fila limitada a 100 (cheia: descarta o mais novo)', () async {
      client = MonitorClient(
          MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl),
          heartbeatStore: MemoryHeartbeatStore(),
          flushInterval: const Duration(seconds: 30),
          retryDelay: const Duration(milliseconds: 10));
      // Sem dar a vez ao event loop, nada sai: a fila enche.
      for (var i = 0; i < 100; i++) {
        client.captureParts('E', 'f $i', []);
      }
      await client.flush(const Duration(seconds: 5));
      expect(srv.events.length, 100);
    });

    test('5xx: 1 nova tentativa e segue enviando', () async {
      await srv.close();
      srv = await FakeServer.start(const [Reply(503), Reply(500)]);
      client =
          testClient(MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl));
      client.captureParts('E', 'a', []);
      await client.flush(const Duration(seconds: 3));
      expect(srv.requests.length, 2);
      client.captureParts('E', 'b', []);
      await client.flush(const Duration(seconds: 3));
      expect(srv.requests.length, 3);
    });

    test('403 desliga; 413 descarta sem nova tentativa', () async {
      await srv.close();
      srv = await FakeServer.start(const [Reply(413), Reply(403)]);
      client =
          testClient(MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl));
      client.captureParts('E', 'grande', []);
      await client.flush(const Duration(seconds: 3));
      expect(srv.requests.length, 1);
      expect(client.disabled, isFalse);
      client.captureParts('E', 'proibido', []);
      await client.flush(const Duration(seconds: 3));
      client.captureParts('E', 'depois', []);
      await client.flush(const Duration(seconds: 1));
      expect(srv.requests.length, 2);
      expect(client.disabled, isTrue);
    });

    test('sem rede: engole e não trava', () async {
      client = testClient(
          const MonitorOptions(key: 'bf_mon_x', baseUrl: 'http://127.0.0.1:1'));
      client.captureParts('E', 'offline', []);
      expect(await client.flush(const Duration(seconds: 3)), isTrue);
    });

    test('evento gigante cabe em 64 KB', () async {
      client =
          testClient(MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl));
      for (var i = 0; i < 30; i++) {
        client.addBreadcrumb('c', 'b' * 300);
      }
      client.captureParts('E', 'm' * 5000, [
        for (var i = 0; i < 60; i++)
          MonitorFrame(file: 'f' * 2000, function: 'fn', line: i)
      ]);
      await client.flush(const Duration(seconds: 3));
      expect(utf8.encode(srv.requests.single.raw).length,
          lessThanOrEqualTo(64 * 1024 + 20));
      expect(dig(srv.events.single, 'exception.message').$1,
          hasLength(lessThanOrEqualTo(2000)));
    });

    test('chave vazia: ArgumentError', () {
      client =
          testClient(MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl));
      expect(() => MonitorClient(const MonitorOptions(key: ' ')),
          throwsArgumentError);
    });
  });

  test('describeError tira o prefixo', () {
    expect(describeError(Exception('falhou')), (r'_Exception', 'falhou'));
    expect(describeError(StateError('x')).$1, 'StateError');
    expect(describeError('texto').$2, 'texto');
  });

  test('isoUtc', () {
    expect(isoUtc(DateTime.utc(2026, 10, 6, 12, 0, 0, 7)),
        '2026-10-06T12:00:00.007Z');
  });

  group('sinal de vida', () {
    late FakeServer srv;
    setUp(() async => srv = await FakeServer.start());
    tearDown(() async => srv.close());

    test('1 no init com instance, runtime e sdk; sem host', () async {
      final store = MemoryHeartbeatStore();
      final c = testClient(
        MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl, release: '3.0.0'),
        store: store,
      );
      final beats = await waitHeartbeats(srv, 1);
      final body = jsonDecode(beats.single.raw) as Map;
      expect(body['instance'], store.state!['instance']);
      expect(body['release'], '3.0.0');
      expect(body['runtime'], containsPair('name', 'dart'));
      expect(body.containsKey('host'), isFalse);
      expect(srv.requests, isEmpty, reason: 'sinal de vida não é evento');
      await c.flush();
      await c.close();
      await settle();
      expect(srv.heartbeats.length, 1, reason: 'flush/close não mandam');
    });

    test('no máximo 1 a cada 30 min por aparelho; instance persistido',
        () async {
      final store = MemoryHeartbeatStore();
      var now = DateTime.utc(2026, 10, 6, 12);
      MonitorClient make() => MonitorClient(
            MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl),
            heartbeatStore: store,
            clock: () => now,
          );
      final a = make();
      await waitHeartbeats(srv, 1);
      final b = make(); // novo init 10 min depois: não manda
      now = now.add(const Duration(minutes: 10));
      await b.sendHeartbeat();
      await settle();
      expect(srv.heartbeats.length, 1);
      now = now.add(const Duration(minutes: 25)); // 35 min do primeiro
      final c = make();
      await waitHeartbeats(srv, 2);
      expect(srv.heartbeats.length, 2);
      final ids = srv.heartbeats
          .map((r) => (jsonDecode(r.raw) as Map)['instance'])
          .toSet();
      expect(ids, hasLength(1), reason: 'o mesmo aparelho, o mesmo instance');
      for (final x in [a, b, c]) {
        await x.close();
      }
    });

    test('arquivo no diretório temporário guarda o estado entre inits',
        () async {
      final dir = await Directory.systemTemp.createTemp('bfmon');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/estado.json');
      // O FileHeartbeatStore de verdade (o padrão do pacote fora do web).
      final a = testClient(
          MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl),
          store: FileHeartbeatStore(file));
      await waitHeartbeats(srv, 1);
      final b = testClient(
          MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl),
          store: FileHeartbeatStore(file));
      await settle(100);
      expect(srv.heartbeats.length, 1);
      expect((jsonDecode(file.readAsStringSync()) as Map)['instance'],
          isA<String>());
      await a.close();
      await b.close();
    });

    test('sem armazenamento: 1 por init', () async {
      final a = MonitorClient(
          MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl),
          useDefaultHeartbeatStore: false);
      final b = MonitorClient(
          MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl),
          useDefaultHeartbeatStore: false);
      expect(await waitHeartbeats(srv, 2), hasLength(2));
      await a.close();
      await b.close();
    });

    test('401 no sinal de vida desliga o envio', () async {
      srv.heartbeatStatus = 401;
      final c =
          testClient(MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl));
      await waitHeartbeats(srv, 1);
      await settle();
      expect(c.disabled, isTrue);
      c.captureParts('E', 'x', []);
      await c.flush(const Duration(milliseconds: 200));
      expect(srv.requests, isEmpty);
      await c.close();
    });
  });
}
