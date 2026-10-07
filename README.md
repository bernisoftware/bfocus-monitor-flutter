# bfocus_monitor

Monitoramento de erros do [bFocus](https://bfocus.com.br) para apps **Flutter**: os erros não
tratados do app chegam ao bFocus com a versão, o ambiente, o rastro e — quando houver usuário —
a identidade assinada. O mesmo erro em vários clientes vira um grupo só, e o grupo vira demanda
para a equipe (módulo Monitoramento).

Zero dependência além do Flutter SDK · Dart 3.0+ / Flutter 3.10+ · Android, iOS, macOS,
Windows e Linux · nunca derruba o app.

## Instalação

```yaml
dependencies:
  bfocus_monitor: ^0.1.0
```

ou `flutter pub add bfocus_monitor`.

## Ligar

```dart
import 'package:bfocus_monitor/bfocus_monitor.dart';

void main() => BfocusMonitor.run(
      () => runApp(const MyApp()),
      options: const MonitorOptions(
        key: 'bf_mon_…', // Monitoramento → Agentes
        release: '1.4.2', // a versão do SEU app
        environment: 'production',
      ),
    );
```

`run` liga o monitor e roda o app numa zona protegida (`runZonedGuarded`), além de instalar
`FlutterError.onError` e `PlatformDispatcher.instance.onError`. Os handlers que já existiam
continuam rodando depois do nosso (`FlutterError.presentError` segue mostrando o erro; o
`PlatformDispatcher.onError` devolve o que o anterior decidiu). Se o seu `main` chama
`WidgetsFlutterBinding.ensureInitialized()`, faça isso dentro da função passada ao `run`.

Ao ligar, o monitor manda um **sinal de vida** (o painel mostra o agente vivo mesmo sem erro):
no máximo 1 a cada 30 min por aparelho, com um `instance` aleatório guardado num arquivo do
diretório temporário do app. Sem conseguir gravar, 1 por `init`.

Já tem a sua zona? Use `BfocusMonitor.init(options)` no lugar de `run` e capture o que chegar a
ela com `BfocusMonitor.captureException(error, stack)`.

```dart
try {
  await salvarPedido();
} catch (e, s) {
  BfocusMonitor.captureException(e, s, tags: {'modulo': 'fiscal'});
}
BfocusMonitor.captureMessage('estoque negativo', level: MonitorLevel.warning);
BfocusMonitor.addBreadcrumb('navegação', '/pedidos/42');
BfocusMonitor.setTag('loja', 'sp-01');
```

## Quem foi afetado (identidade)

O bFocus só liga o erro a um cliente e a uma pessoa com assinatura válida — a mesma do widget
(`userHash` v2). **O segredo de assinatura nunca vai para o app** (qualquer um extrai do
binário), por isso este pacote não tem `signingSecret`: o seu servidor calcula o `userHash` (o
mesmo que já entrega ao widget) e o app só repassa.

```dart
// Depois do login:
BfocusMonitor.setUser('u-123', 'cliente-9', userHash: sessao.bfocusUserHash);
// No logout:
BfocusMonitor.setUser(null, null);
```

## Opções

| Opção | Padrão | |
| --- | --- | --- |
| `key` | — | Obrigatória. |
| `release` | — | Versão do seu app. |
| `environment` | `production` | |
| `baseUrl` | `https://api.bfocus.com.br` | |
| `sampleRate` | `1.0` | 0..1. |
| `ignore` | `[]` | `String` (texto contido) ou `RegExp`. |
| `beforeSend` | — | Altera o evento ou devolve `null` para descartar. |
| `autoCapture` | `true` | Instalar os ganchos globais. |
| `inAppPackages` | `[]` | Pacotes do seu app. Vazio: tudo que não é `dart:`, Flutter, este pacote nem `libraryPackages`. |
| `libraryPackages` | `[]` | Pacotes de terceiros a tratar como biblioteca. |

Fila de 100 eventos, lotes de até 20 a cada 1 s, o mesmo erro no máximo 1 vez a cada 30 s e 100
eventos por minuto. 429/5xx/rede: uma nova tentativa depois de 2 s. 401/403: para de enviar até o
próximo `init`. `BfocusMonitor.flush()` envia o que estiver na fila.

## Limites desta versão

- **Flutter Web** não envia (o pacote usa `dart:io`); no navegador use `@bfocus/monitor`.
- Build com `--obfuscate`/`--split-debug-info`: o rastro sai sem arquivo e linha, e os frames
  ficam de fora (o tipo e a mensagem vão).
- Dart não tem exceção encadeada padrão: vai a exceção como foi lançada.

## Licença

MIT — Berni Software.
