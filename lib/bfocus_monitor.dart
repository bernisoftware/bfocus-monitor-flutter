/// Monitoramento de erros do bFocus para apps Flutter.
///
/// ```dart
/// void main() => BfocusMonitor.run(
///   () => runApp(const MyApp()),
///   options: const MonitorOptions(key: 'bf_mon_…', release: '1.4.2'),
/// );
/// ```
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'src/core/core.dart';

export 'src/core/core.dart'
    show
        MonitorOptions,
        MonitorLevel,
        MonitorEvent,
        MonitorFrame,
        MonitorBreadcrumb,
        BeforeSend,
        sdkVersion;

/// Ponto de entrada do monitor (estático, como o `runApp`).
///
/// Nunca derruba o app: toda falha do monitor é engolida, e os handlers que já existiam
/// continuam rodando depois do nosso (o app se comporta como sem o monitor).
abstract final class BfocusMonitor {
  static MonitorClient? _client;
  static Object? _lastError;

  /// O cliente ativo (para testes e integrações).
  @visibleForTesting
  static MonitorClient? get client => _client;

  /// Liga o monitor e roda o app numa zona protegida ([runZonedGuarded]): erros que
  /// escapam de Future/Timer também são capturados. Instala `FlutterError.onError` e
  /// `PlatformDispatcher.instance.onError` (encadeando os anteriores).
  ///
  /// Se o seu `main` chama `WidgetsFlutterBinding.ensureInitialized()`, faça isso DENTRO de
  /// [appRunner] (mesma zona do `runApp`).
  static void run(
    FutureOr<void> Function() appRunner, {
    required MonitorOptions options,
  }) {
    init(options);
    runZonedGuarded<Future<void>>(
      () async {
        await appRunner();
      },
      (error, stack) {
        _capture(
          error,
          stack,
          MonitorLevel.error,
          tags: const {'mechanism': 'zone'},
        );
        // Sem o monitor, o erro iria para a zona de fora (no Flutter, a raiz o entrega ao
        // PlatformDispatcher.onError e ao console): repassa, sem capturar de novo.
        _safe(() => Zone.current.handleUncaughtError(error, stack));
      },
    );
  }

  /// Liga o monitor sem a zona protegida (quando o app já tem a sua). Não faz chamada de
  /// rede. Chamar de novo troca a configuração e volta a enviar depois de um 401/403.
  /// Lança [ArgumentError] com a chave vazia.
  static void init(MonitorOptions options) {
    final next = MonitorClient(options);
    final old = _client;
    _client = next;
    if (old != null) unawaited(old.close(Duration.zero));
    if (options.autoCapture) _installHooks();
  }

  // Os nossos handlers: instalar de novo só se alguém os trocou (sem encadear duas vezes).
  static FlutterExceptionHandler? _flutterHook;
  static ui.ErrorCallback? _platformHook;

  static void _installHooks() {
    if (FlutterError.onError == null || FlutterError.onError != _flutterHook) {
      final previous = FlutterError.onError;
      _flutterHook = (FlutterErrorDetails details) {
        if (!details.silent) {
          _capture(
            details.exception,
            details.stack,
            MonitorLevel.error,
            tags: {
              'mechanism': 'FlutterError',
              if (details.library != null && details.library!.isNotEmpty)
                'flutter.library': details.library!,
            },
          );
        }
        if (previous != null) {
          previous(details);
        } else {
          FlutterError.presentError(details);
        }
      };
      FlutterError.onError = _flutterHook;
    }

    final dispatcher = ui.PlatformDispatcher.instance;
    if (dispatcher.onError == null || dispatcher.onError != _platformHook) {
      final previous = dispatcher.onError;
      _platformHook = (Object error, StackTrace stack) {
        _capture(
          error,
          stack,
          MonitorLevel.error,
          tags: const {'mechanism': 'PlatformDispatcher'},
        );
        // Devolve o que o handler anterior decidiu; sem anterior, false: o engine segue
        // com o tratamento padrão (registrar o erro), igual a sem o monitor.
        if (previous != null) return previous(error, stack);
        return false;
      };
      dispatcher.onError = _platformHook;
    }
  }

  static void _capture(
    Object error,
    StackTrace? stack,
    MonitorLevel level, {
    Map<String, String>? tags,
  }) {
    // O mesmo objeto pode passar pela zona e pelo PlatformDispatcher: só uma vez.
    if (identical(error, _lastError)) return;
    _lastError = error;
    _safe(
      () => _client?.captureException(error, stack, level: level, tags: tags),
    );
  }

  /// Manda um erro tratado.
  static void captureException(
    Object error,
    StackTrace? stackTrace, {
    MonitorLevel level = MonitorLevel.error,
    Map<String, String>? tags,
    List<String>? fingerprint,
  }) {
    _safe(
      () => _client?.captureException(
        error,
        stackTrace ?? StackTrace.current,
        level: level,
        tags: tags,
        fingerprint: fingerprint,
      ),
    );
  }

  /// Manda uma mensagem como evento (padrão: info).
  static void captureMessage(
    String message, {
    MonitorLevel level = MonitorLevel.info,
  }) {
    _safe(() => _client?.captureMessage(message, level: level));
  }

  /// Pessoa e cliente afetados. [userHash] é a assinatura v2 que o SEU servidor calcula
  /// (a mesma do widget) — o app nunca tem o segredo. Nulos limpam a identidade.
  static void setUser(
    String? userExternalId,
    String? customerExternalId, {
    String? userHash,
  }) {
    _safe(
      () => _client?.setUser(
        userExternalId,
        customerExternalId,
        userHash: userHash,
      ),
    );
  }

  /// Tag em todos os próximos eventos.
  static void setTag(String key, String value) =>
      _safe(() => _client?.setTag(key, value));

  /// Passo antes do erro (os últimos 30 vão junto).
  static void addBreadcrumb(
    String category,
    String message, {
    MonitorLevel level = MonitorLevel.info,
  }) {
    _safe(() => _client?.addBreadcrumb(category, message, level: level));
  }

  /// Envia o que está na fila (até [timeout]). `true` se esvaziou.
  static Future<bool> flush([
    Duration timeout = const Duration(seconds: 2),
  ]) async {
    final c = _client;
    if (c == null) return true;
    return c.flush(timeout);
  }

  /// Envia o que falta e desliga o monitor. Os ganchos ficam, mas não mandam mais nada.
  static Future<void> close() async {
    final c = _client;
    _client = null;
    if (c != null) await c.close();
  }

  static void _safe(void Function() f) {
    try {
      f();
    } catch (_) {
      // nunca derruba o app
    }
  }
}
