// Ganchos do Flutter (precisa do Flutter SDK: `flutter test`). O núcleo — fila, envio,
// conformidade com cases.json — é testado sem Flutter em test_core/ (`dart test`).
import 'dart:ui' as ui;

import 'package:bfocus_monitor/bfocus_monitor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Porta fechada: nada sai da máquina; o teste olha a fila.
  const options = MonitorOptions(
    key: 'bf_mon_teste',
    baseUrl: 'http://127.0.0.1:1',
  );

  tearDown(() async => BfocusMonitor.close());

  test('chave vazia: ArgumentError', () {
    expect(
      () => BfocusMonitor.init(const MonitorOptions(key: '')),
      throwsArgumentError,
    );
  });

  test('FlutterError.onError captura e chama o handler anterior', () {
    final previous = FlutterError.onError;
    final seen = <FlutterErrorDetails>[];
    FlutterError.onError = seen.add;
    addTearDown(() => FlutterError.onError = previous);

    BfocusMonitor.init(options);
    final details = FlutterErrorDetails(
      exception: StateError('quebrou'),
      stack: StackTrace.current,
      library: 'widgets',
    );
    FlutterError.onError!(details);

    expect(seen, [details], reason: 'o handler anterior continua rodando');
    expect(BfocusMonitor.client!.pendingCount, 1);
  });

  test('erro silencioso do Flutter não vai', () {
    BfocusMonitor.init(options);
    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('imagem'), silent: true),
    );
    expect(BfocusMonitor.client!.pendingCount, 0);
  });

  test('PlatformDispatcher.onError devolve o que o anterior decidiu', () {
    final dispatcher = ui.PlatformDispatcher.instance;
    final previous = dispatcher.onError;
    dispatcher.onError = (e, s) => true;
    addTearDown(() => dispatcher.onError = previous);

    BfocusMonitor.init(options);
    expect(
      dispatcher.onError!(StateError('async'), StackTrace.current),
      isTrue,
    );
    expect(BfocusMonitor.client!.pendingCount, 1);
  });

  test(
    'captureException, captureMessage, setUser, setTag e addBreadcrumb não lançam',
    () async {
      BfocusMonitor.init(options);
      BfocusMonitor.setUser('u-1', 'c-1', userHash: 'v2.1.abc');
      BfocusMonitor.setTag('loja', 'sp');
      BfocusMonitor.addBreadcrumb('nav', '/x');
      BfocusMonitor.captureException(Exception('x'), null);
      BfocusMonitor.captureMessage('m', level: MonitorLevel.warning);
      expect(BfocusMonitor.client!.pendingCount, 2);
      await BfocusMonitor.flush(const Duration(milliseconds: 100));
    },
  );

  test('versão do pacote', () {
    expect(sdkVersion, '0.1.0');
  });
}
