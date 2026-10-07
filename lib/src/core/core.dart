/// O núcleo do bFocus Monitor em Dart puro (sem Flutter) — testável com `dart test`.
library;

export 'client.dart' show MonitorClient, describeError;
export 'event.dart'
    show MonitorLevel, MonitorFrame, MonitorBreadcrumb, MonitorEvent, isoUtc;
export 'options.dart' show MonitorOptions, BeforeSend;
export 'stack.dart' show FrameClassifier, parseStackTrace, sdkPackages;
export 'transport.dart'
    show MonitorTransport, HeartbeatStore, MemoryHeartbeatStore;
export 'version.dart' show sdkVersion, sdkName;
