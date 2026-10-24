import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config.dart';
import 'host.dart';

class LogEntry {
  final DateTime time;
  final String message;
  LogEntry(this.time, this.message);
}

/// Estado da interface, alimentado pelos eventos do motor.
class TrackerController extends ChangeNotifier {
  TrackerController() : _host = TrackerHost.create();

  /// Usado em testes/capturas de tela, sem plataforma.
  TrackerController.preview({required this.config, required this.status, List<LogEntry>? logs})
      : _host = null,
        running = status['running'] == true {
    this.logs.addAll(logs ?? const []);
  }

  final TrackerHost? _host;
  final _subs = <StreamSubscription<dynamic>>[];

  TrackerConfig config = TrackerConfig();
  Map<String, dynamic> status = const {};
  final List<LogEntry> logs = [];
  bool running = false;
  bool busy = false;
  String? message;

  Future<void> init() async {
    final h = _host!;
    config = await TrackerConfig.load();
    await h.init();
    _subs.addAll([
      h.on('status').listen((m) {
        if (m == null) return;
        status = m;
        running = m['running'] == true;
        final c = m['config'];
        if (c is Map) config = TrackerConfig.fromMap(Map<String, dynamic>.from(c));
        notifyListeners();
      }),
      h.on('log').listen((m) {
        if (m == null) return;
        _addLog(m);
        notifyListeners();
      }),
      h.on('logs').listen((m) {
        final items = m?['items'];
        if (items is! List) return;
        logs.clear();
        for (final e in items) {
          _addLog(Map<String, dynamic>.from(e as Map));
        }
        notifyListeners();
      }),
    ]);
    running = await h.isRunning();
    notifyListeners();
    if (running) {
      h.invoke('getStatus');
    } else if (config.enabled && config.autoStart && config.isConfigured) {
      await start();
    }
  }

  void _addLog(Map<String, dynamic> m) {
    logs.add(LogEntry(DateTime.fromMillisecondsSinceEpoch(m['t'] as int), m['m'] as String));
    if (logs.length > 300) logs.removeRange(0, logs.length - 300);
  }

  Future<void> start() async {
    if (!config.isConfigured) {
      _say('Configure servidor, porta e IMEI antes de iniciar.');
      return;
    }
    busy = true;
    notifyListeners();
    try {
      final err = await _ensurePermissions();
      if (err != null) {
        _say(err);
        return;
      }
      await _host!.start();
      running = true;
      // Android: o serviço demora um instante para subir.
      Future<void>.delayed(const Duration(seconds: 2), () => _host.invoke('getStatus'));
    } catch (e) {
      _say('Não foi possível iniciar: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    await _host?.stop();
    running = false;
    config.enabled = false;
    notifyListeners();
  }

  Future<void> saveConfig(TrackerConfig c) async {
    if (running) {
      _host?.invoke('config', c.toMap());
    } else {
      c.enabled = config.enabled;
      await c.save();
    }
    config = c;
    _say('Configuração salva.');
  }

  void sendNow() => _host?.invoke('sendNow');
  void clearQueue() => _host?.invoke('clearQueue');

  void _say(String m) {
    message = m;
    notifyListeners();
  }

  String? takeMessage() {
    final m = message;
    message = null;
    return m;
  }

  Future<String?> _ensurePermissions() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Ative a localização (GPS) do aparelho.';
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      return 'Permissão de localização negada. Libere nas configurações do aparelho.';
    }
    if (Platform.isAndroid) {
      await Permission.notification.request();
      // "Permitir o tempo todo": necessário para religar sozinho após reiniciar o aparelho.
      if (!await Permission.locationAlways.isGranted) await Permission.locationAlways.request();
      if (!await Permission.ignoreBatteryOptimizations.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } else if (p == LocationPermission.whileInUse) {
      // iOS: pede a atualização para "Sempre".
      await Geolocator.requestPermission();
    }
    return null;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}
