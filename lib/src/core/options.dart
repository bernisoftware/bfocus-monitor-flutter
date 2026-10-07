import 'event.dart';

/// Função que recebe o evento pronto e devolve o evento (alterado ou não) ou `null`
/// para descartar.
typedef BeforeSend = MonitorEvent? Function(MonitorEvent event);

/// Configuração do monitor. Só [key] é obrigatória.
///
/// Não existe `signingSecret` aqui de propósito: o segredo de assinatura NUNCA vai para o
/// app (qualquer um extrai do binário). A assinatura (`userHash`) vem do seu servidor — a
/// mesma que ele já entrega ao widget — e entra em `BfocusMonitor.setUser`.
class MonitorOptions {
  const MonitorOptions({
    required this.key,
    this.release,
    this.environment = 'production',
    this.baseUrl = 'https://api.bfocus.com.br',
    this.sampleRate = 1.0,
    this.ignore = const [],
    this.beforeSend,
    this.autoCapture = true,
    this.inAppPackages = const [],
    this.libraryPackages = const [],
  });

  /// Chave de envio do agente (`bf_mon_…`), em Monitoramento → Agentes.
  final String key;

  /// Versão do SEU app (`1.4.2`).
  final String? release;

  /// Padrão `production`.
  final String environment;

  /// Padrão `https://api.bfocus.com.br`.
  final String baseUrl;

  /// Fração dos eventos enviada, 0..1.
  final double sampleRate;

  /// Mensagens a ignorar: `String` (texto contido) ou `RegExp`.
  final List<Pattern> ignore;

  /// Última chance de mudar ou descartar o evento. Uma exceção aqui é engolida e o evento
  /// vai como estava.
  final BeforeSend? beforeSend;

  /// Instalar os ganchos globais (FlutterError.onError e PlatformDispatcher.onError).
  final bool autoCapture;

  /// Pacotes do SEU app (`['meu_app', 'meu_app_core']`). Preenchido, só eles são "do
  /// sistema" (inApp). Vazio: tudo que não é `dart:`, Flutter, este pacote nem
  /// [libraryPackages].
  final List<String> inAppPackages;

  /// Pacotes de terceiros a tratar como biblioteca quando [inAppPackages] está vazio.
  final List<String> libraryPackages;
}
