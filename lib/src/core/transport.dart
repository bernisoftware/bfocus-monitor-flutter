/// Envio HTTP. A implementação de verdade (`dart:io` HttpClient) fica em transport_io.dart;
/// no Flutter Web (sem `dart:io`) entra transport_stub.dart, que não envia nada.
abstract class MonitorTransport {
  /// Manda o corpo e devolve o status HTTP. Exceção = falha de rede.
  Future<int> send(Uri endpoint, Map<String, String> headers, String body);

  /// Libera conexões.
  void close() {}
}

/// Onde o aparelho guarda o id da instância e a hora do último sinal de vida.
abstract class HeartbeatStore {
  Future<Map<String, Object?>?> read();
  Future<void> write(Map<String, Object?> state);
}

/// Em memória (testes; ou quando não há onde gravar).
class MemoryHeartbeatStore implements HeartbeatStore {
  Map<String, Object?>? state;

  @override
  Future<Map<String, Object?>?> read() async => state;

  @override
  Future<void> write(Map<String, Object?> value) async => state = Map.of(value);
}
