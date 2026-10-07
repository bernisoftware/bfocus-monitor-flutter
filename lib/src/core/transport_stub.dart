import 'transport.dart';

/// Sem `dart:io` (Flutter Web): o monitor não envia. Para web, use `@bfocus/monitor`.
MonitorTransport? defaultTransport() => null;

Map<String, Map<String, String>> platformContexts() => {
  'runtime': {'name': 'dart', 'platform': 'web'},
};

/// Sem `dart:io`: sem arquivo (1 sinal de vida por init — e no web nem isso, sem envio).
HeartbeatStore? defaultHeartbeatStore() => null;
