// Roda TODOS os casos de monitor/flutter/test/cases.json (cópia de
// monitor/conformance/cases.json, conferida por `generate.py --check`) contra o núcleo.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../lib/src/core/core.dart';
import 'support.dart';

const casesFormat = 1;

Map<String, dynamic> loadCases() {
  final data =
      (jsonDecode(File('../test/cases.json').readAsStringSync()) as Map)
          .cast<String, dynamic>();
  if (data['version'] != casesFormat) {
    throw StateError(
        'cases.json no formato ${data['version']}; esta suíte entende o $casesFormat');
  }
  return data;
}

void doCapture(MonitorClient client, Map capture) {
  final level = MonitorLevel.tryParse(capture['level'] as String?);
  if (capture['kind'] == 'message') {
    client.captureMessage(capture['message'] as String,
        level: level ?? MonitorLevel.info);
    return;
  }
  // O caso traz um nome de tipo neutro ("ValueError"), que não existe em Dart: entra pronto.
  final frames =
      parseStackTrace(StackTrace.current.toString(), const FrameClassifier());
  client.captureParts(
    capture['type'] as String,
    capture['message'] as String,
    frames,
    level: level ?? MonitorLevel.error,
    tags: (capture['tags'] as Map?)?.cast<String, String>(),
    fingerprint: (capture['fingerprint'] as List?)?.cast<String>(),
  );
}

void main() {
  final cases = loadCases();

  group('user_hash', () {
    // O app não assina (sem segredo no app): o vetor confere que o hash dado passa intacto.
    for (final c in (cases['user_hash'] as List).cast<Map>()) {
      test('${c['user_external_id']} passa como veio', () async {
        final srv = await FakeServer.start();
        final client =
            testClient(MonitorOptions(key: 'bf_mon_x', baseUrl: srv.baseUrl));
        client.setUser(c['user_external_id'] as String,
            c['customer_external_id'] as String,
            userHash: c['expected'] as String);
        client.captureParts('E', 'hash ${c['ts']}', []);
        expect(await client.flush(const Duration(seconds: 3)), isTrue);
        final ev = srv.events.single;
        expect(dig(ev, 'user.userHash').$1, c['expected']);
        expect(dig(ev, 'customer.externalId').$1, c['customer_external_id']);
        await client.close();
        await srv.close();
      });
    }
  });

  group('send', () {
    for (final sc in (cases['send'] as List).cast<Map>()) {
      test(sc['name'] as String, () async {
        final requests = (sc['requests'] as List).cast<Map>();
        final srv = await FakeServer.start([
          for (final r in requests)
            Reply((r['respond'] as Map)['status'] as int,
                (r['respond'] as Map)['body'] as Object),
        ]);
        final init = (sc['init'] as Map).cast<String, dynamic>();
        final client = testClient(MonitorOptions(
          key: init['key'] as String,
          release: init['release'] as String?,
          environment: init['environment'] as String? ?? 'production',
          ignore: [
            for (final p in (init['ignore'] as List? ?? const [])) p as String
          ],
          baseUrl: '${srv.baseUrl}/',
        ));

        final setUser = sc['set_user'] as Map?;
        if (setUser != null) {
          // signing_secret é só de servidor: no app o hash vem pronto do servidor do
          // cliente, então o caso "assinada pelo pacote" usa o vetor de cases.json.
          var hash = setUser['user_hash'] as String?;
          if (hash == null && init['signing_secret'] != null) {
            hash = (cases['user_hash'] as List).cast<Map>().firstWhere((v) =>
                v['secret'] == init['signing_secret'] &&
                v['ts'] == setUser['ts'] &&
                v['user_external_id'] == setUser['user_external_id'] &&
                v['customer_external_id'] ==
                    setUser['customer_external_id'])['expected'] as String;
          }
          client.setUser(setUser['user_external_id'] as String,
              setUser['customer_external_id'] as String,
              userHash: hash);
        }
        for (final b in (sc['breadcrumbs'] as List? ?? const []).cast<Map>()) {
          client.addBreadcrumb(b['category'] as String, b['message'] as String,
              level: MonitorLevel.tryParse(b['level'] as String?) ??
                  MonitorLevel.info);
        }
        final repeat = sc['repeat'] as int? ?? 1;
        for (var i = 0; i < repeat; i++) {
          doCapture(client, sc['capture'] as Map);
        }
        expect(await client.flush(const Duration(seconds: 5)), isTrue,
            reason: 'flush não esvaziou');
        expect(srv.requests.length, requests.length,
            reason: 'quantidade de requisições');

        for (var i = 0; i < requests.length; i++) {
          final got = srv.requests[i];
          final want = (requests[i]['expect'] as Map).cast<String, dynamic>();
          expect(got.method, want['method']);
          expect(got.path, want['path']);
          (want['headers'] as Map).forEach((k, v) => expect(
              got.headers[(k as String).toLowerCase()], v,
              reason: 'header $k'));
          (want['header_prefix'] as Map).forEach((k, v) => expect(
              got.headers[(k as String).toLowerCase()], startsWith(v as String),
              reason: 'header $k'));
          expect(got.headers['x-bfocus-client'],
              'bfocus-monitor-flutter/$sdkVersion');
          expect(
              got.headers['user-agent'], 'bfocus-monitor-flutter/$sdkVersion');
          final ev = got.events.single;
          (want['event'] as Map).forEach((path, value) {
            final expected = value == r'$version' ? sdkVersion : value;
            final (v, ok) = dig(ev, path as String);
            expect(ok, isTrue, reason: 'campo $path ausente em ${got.raw}');
            expect(v, expected, reason: path);
          });
          expect(nullPaths(ev), isEmpty, reason: 'campos nulos');
          expect(dig(ev, 'sdk.name').$1, 'bfocus-monitor-flutter');
          expect(ev['timestamp'],
              matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$')));
          final status = (requests[i]['respond'] as Map)['status'] as int;
          if ((status == 429 || status >= 500) && i + 1 < srv.requests.length) {
            expect(srv.requests[i + 1].raw, got.raw,
                reason: 'a nova tentativa repete o mesmo corpo');
          }
        }

        final then = sc['then_capture'] as Map?;
        if (then != null) {
          doCapture(client, then);
          await client.flush(const Duration(seconds: 2));
          await settle();
        }
        expect(srv.requests.length, requests.length,
            reason: 'requisição a mais depois do caso');
        switch (sc['after']) {
          case 'disabled':
            expect(client.disabled, isTrue);
            // Novo init volta a enviar.
            final again = testClient(MonitorOptions(
                key: init['key'] as String, baseUrl: srv.baseUrl));
            expect(again.disabled, isFalse);
            await again.close();
          case 'ok':
            expect(client.disabled, isFalse);
          default:
            fail('after desconhecido: ${sc['after']}');
        }
        await client.close();
        await srv.close();
      });
    }
  });

  group('frames', () {
    // O rastro neutro vira um rastro do Dart: biblioteca é um pacote listado como
    // biblioteca, código do sistema é o pacote do app.
    String dartFile(String file, bool library) =>
        library ? 'package:starlette/$file' : 'package:app/$file';
    for (final fc in (cases['frames'] as List).cast<Map>()) {
      test(fc['name'] as String, () {
        final runtime = (fc['runtime_order'] as List).cast<Map>();
        final stack = [
          for (var i = 0; i < runtime.length; i++)
            '#$i      ${runtime[i]['function']} (${dartFile(runtime[i]['file'] as String, runtime[i]['library'] as bool)}:${runtime[i]['line']}:1)',
        ].join('\n');
        final frames = parseStackTrace(
            stack, const FrameClassifier(libraryPackages: ['starlette']));
        final expected = (fc['expected'] as List).cast<Map>();
        expect(frames.length, expected.length);
        for (var i = 0; i < expected.length; i++) {
          final want = expected[i];
          expect(frames[i].function, want['function']);
          expect(frames[i].line, want['line']);
          expect(frames[i].inApp, want['inApp']);
          expect(frames[i].file,
              dartFile(want['file'] as String, !(want['inApp'] as bool)));
        }
      });
    }
  });

  group('heartbeat', () {
    for (final hc in (cases['heartbeat'] as List).cast<Map>()) {
      test(hc['name'] as String, () async {
        final srv = await FakeServer.start();
        srv.heartbeatStatus = (hc['respond'] as Map)['status'] as int;
        final init = (hc['init'] as Map).cast<String, dynamic>();
        final client = testClient(MonitorOptions(
          key: init['key'] as String,
          release: init['release'] as String?,
          environment: init['environment'] as String? ?? 'production',
          baseUrl: srv.baseUrl,
        ));
        final beats = await waitHeartbeats(srv, 1);
        expect(beats, isNotEmpty, reason: 'init não mandou o sinal de vida');
        final got = beats.first;
        final want = (hc['expect'] as Map).cast<String, dynamic>();
        expect(got.method, want['method']);
        expect(got.path, want['path']);
        (want['headers'] as Map).forEach((k, v) => expect(
            got.headers[(k as String).toLowerCase()], v,
            reason: 'header $k'));
        (want['header_prefix'] as Map).forEach((k, v) => expect(
            got.headers[(k as String).toLowerCase()], startsWith(v as String),
            reason: 'header $k'));
        final body = jsonDecode(got.raw);
        (want['body'] as Map).forEach((path, value) {
          final expected = value == r'$version' ? sdkVersion : value;
          final (v, ok) = dig(body, path as String);
          expect(ok, isTrue, reason: '$path ausente em ${got.raw}');
          expect(v, expected, reason: path);
        });
        for (final path in (want['body_present'] as List).cast<String>()) {
          final (v, ok) = dig(body, path);
          expect(ok && v != null && v != '', isTrue, reason: '$path ausente');
        }
        expect(nullPaths(body), isEmpty);
        expect(client.disabled, isFalse);
        await client.close();
        await srv.close();
      });
    }
  });
}
