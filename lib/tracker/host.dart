import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';

import 'config.dart';
import 'engine.dart';

/// Entrada do serviço Android em primeiro plano. Roda num isolate próprio, que
/// continua vivo com a tela bloqueada e mesmo se o app for fechado.
@pragma('vm:entry-point')
Future<void> androidServiceMain(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
    // parado pelo usuário: não religar no boot
    service.on('stop').listen((_) => service.setAutoStartOnBootMode(false));
  }
  final engine = TrackerEngine(service, notify: (title, body) async {
    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(title: title, content: body);
    }
  });
  await engine.start();
  if (service is AndroidServiceInstance) {
    final cfg = await TrackerConfig.load();
    await service.setAutoStartOnBootMode(cfg.autoStart);
  }
}

/// Lado da interface: inicia/para o rastreador e troca eventos com ele.
abstract class TrackerHost implements Observable {
  static TrackerHost create() => Platform.isAndroid ? _AndroidHost() : _LocalHost();

  Future<void> init();
  Future<bool> isRunning();
  Future<void> start();
  Future<void> stop();
}

class _AndroidHost extends TrackerHost {
  final _svc = FlutterBackgroundServiceAndroid();

  @override
  Future<void> init() async {
    final cfg = await TrackerConfig.load();
    await _svc.configure(
      iosConfiguration: IosConfiguration(autoStart: false),
      androidConfiguration: AndroidConfiguration(
        onStart: androidServiceMain,
        autoStart: false,
        autoStartOnBoot: cfg.autoStart && cfg.enabled,
        isForegroundMode: true,
        notificationChannelId: 'j16_tracker',
        initialNotificationTitle: 'J16 Simulator',
        initialNotificationContent: 'Iniciando rastreador...',
        foregroundServiceNotificationId: 7016,
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
    );
  }

  @override
  Future<bool> isRunning() => _svc.isServiceRunning();

  @override
  Future<void> start() async {
    if (!await isRunning()) await _svc.start();
  }

  @override
  Future<void> stop() async {
    _svc.invoke('stop');
  }

  @override
  void invoke(String method, [Map<String, dynamic>? args]) => _svc.invoke(method, args);

  @override
  Stream<Map<String, dynamic>?> on(String method) => _svc.on(method);
}

/// iOS: o motor roda no próprio isolate do app. As atualizações contínuas de
/// localização em segundo plano (UIBackgroundModes=location) mantêm o app ativo
/// com a tela bloqueada.
class _LocalHost extends TrackerHost {
  final _toUi = StreamController<(String, Map<String, dynamic>?)>.broadcast(sync: true);
  final _toEngine = StreamController<(String, Map<String, dynamic>?)>.broadcast(sync: true);
  TrackerEngine? _engine;

  @override
  Future<void> init() async {}

  @override
  Future<bool> isRunning() async => _engine != null;

  @override
  Future<void> start() async {
    if (_engine != null) return;
    final engine = TrackerEngine(_LocalServiceInstance(this));
    _engine = engine;
    await engine.start();
  }

  @override
  Future<void> stop() async => invoke('stop');

  @override
  void invoke(String method, [Map<String, dynamic>? args]) => _toEngine.add((method, args));

  @override
  Stream<Map<String, dynamic>?> on(String method) =>
      _toUi.stream.where((e) => e.$1 == method).map((e) => e.$2);
}

class _LocalServiceInstance extends ServiceInstance {
  _LocalServiceInstance(this._host);
  final _LocalHost _host;

  @override
  void invoke(String method, [Map<String, dynamic>? args]) => _host._toUi.add((method, args));

  @override
  Stream<Map<String, dynamic>?> on(String method) =>
      _host._toEngine.stream.where((e) => e.$1 == method).map((e) => e.$2);

  @override
  Future<void> stopSelf() async => _host._engine = null;
}
