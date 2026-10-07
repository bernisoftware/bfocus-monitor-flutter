# Changelog

## 0.1.0

Primeira versão.

- `BfocusMonitor.run(() => runApp(...), options: ...)`: `runZonedGuarded` +
  `FlutterError.onError` + `PlatformDispatcher.instance.onError`, encadeando os handlers que
  já existiam.
- `BfocusMonitor.init`, `captureException`, `captureMessage`, `setUser` (com o `userHash` vindo
  do seu servidor), `setTag`, `addBreadcrumb`, `flush`, `close`.
- Rastro do Dart convertido para frames de fora para dentro, com `inApp` por pacote
  (`inAppPackages`/`libraryPackages`).
- Envio em lote com `dart:io` HttpClient (sem dependências), fila de 100, nova tentativa em
  429/5xx/rede, para de enviar em 401/403, o mesmo erro no máximo 1 vez a cada 30 s e 100
  eventos por minuto.
- Sinal de vida (`POST /api/v1/monitor/heartbeat`) no init, no máximo 1 a cada 30 min por
  aparelho (estado em arquivo no diretório temporário; sem ele, 1 por init).
