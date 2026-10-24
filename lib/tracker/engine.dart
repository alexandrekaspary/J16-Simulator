import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';
import 'package:geolocator/geolocator.dart';

import '../protocol/gt06.dart';
import 'config.dart';
import 'queue_store.dart';

typedef NotifyFn = Future<void> Function(String title, String body);

/// Simula o comportamento do J16 4G: login, heartbeat, envio periódico de
/// posição, envio em curvas, memória interna quando sem rede e resposta aos
/// comandos de configuração do servidor (TIMER, HBT, SERVER, WHERE...).
///
/// Roda no serviço em segundo plano (Android) ou no isolate principal (iOS) e
/// conversa com a interface somente por eventos do [ServiceInstance].
class TrackerEngine {
  TrackerEngine(this._service, {NotifyFn? notify}) : _notify = notify;

  final ServiceInstance _service;
  final NotifyFn? _notify;

  late TrackerConfig _cfg;
  final _enc = Gt06Encoder();
  final _dec = Gt06Decoder();
  final _store = QueueStore();
  final _battery = Battery();
  final _subs = <StreamSubscription<dynamic>>[];
  final _logs = <Map<String, dynamic>>[];

  Socket? _socket;
  Future<void> _writeChain = Future.value();
  bool _connecting = false;
  bool _loggedIn = false;
  bool _stopped = false;
  bool _flushing = false;
  bool _hbPending = false;
  int _missedHb = 0;
  int _reconnectDelay = 5;
  String _conn = 'offline';
  String? _lastError;

  StreamSubscription<Position>? _gpsSub;
  Timer? _reportTimer, _hbTimer, _loginTimer, _reconnectTimer, _gpsRetryTimer;

  Position? _pos;
  DateTime? _posAt;
  GpsFix? _lastValid;
  Position? _odoRef;
  double? _lastSentCourse;
  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _gpsError;

  List<ConnectivityResult> _net = const [];
  int _batteryLevel = 100;
  bool _charging = false;

  int _queued = 0;
  int _sent = 0;
  DateTime? _lastTx;

  // ---------------------------------------------------------------- ciclo de vida

  Future<void> start() async {
    _cfg = await TrackerConfig.load();
    _cfg.enabled = true;
    await _cfg.save();
    await _store.open();
    _queued = await _store.count();

    _subs.addAll([
      _service.on('config').listen((m) => _applyConfig(m ?? const {})),
      _service.on('sendNow').listen((_) => _report(Gt06.uploadTimed)),
      _service.on('clearQueue').listen((_) => _clearQueue()),
      _service.on('getStatus').listen((_) {
        _service.invoke('logs', {'items': _logs});
        _emit();
      }),
      _service.on('stop').listen((_) => stop()),
    ]);

    try {
      _net = await Connectivity().checkConnectivity();
    } catch (_) {}
    _subs.add(Connectivity().onConnectivityChanged.listen(_onNetwork));

    try {
      _batteryLevel = await _battery.batteryLevel;
      _charging = await _battery.batteryState == BatteryState.charging;
    } catch (_) {}
    _subs.add(_battery.onBatteryStateChanged.listen((s) {
      _charging = s == BatteryState.charging || s == BatteryState.full;
    }));

    _log('Rastreador iniciado — IMEI ${_cfg.imei}, ${_cfg.host}:${_cfg.port}, '
        'intervalo ${_cfg.intervalSec}s, pacote ${_cfg.fourGPacket ? '0xA0 (4G)' : '0x22'}');
    _startGps();
    _restartTimers();
    _connect();
    _emit();
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _log('Rastreador parado');
    _cfg.enabled = false;
    await _cfg.save();
    for (final t in [_reportTimer, _hbTimer, _loginTimer, _reconnectTimer, _gpsRetryTimer]) {
      t?.cancel();
    }
    await _gpsSub?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _socket?.destroy();
    _socket = null;
    _loggedIn = false;
    _conn = 'offline';
    _emit(running: false);
    await _store.close();
    await _service.stopSelf();
  }

  // ---------------------------------------------------------------- GPS

  void _startGps() {
    _gpsRetryTimer?.cancel();
    _gpsSub?.cancel();
    final LocationSettings settings;
    if (Platform.isAndroid) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: Duration(seconds: min(_cfg.intervalSec, 5)),
      );
    } else if (Platform.isIOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    } else {
      settings = const LocationSettings(accuracy: LocationAccuracy.best);
    }
    _gpsSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosition,
      onError: (Object e) {
        _gpsError = '$e';
        _log('GPS indisponível: $e');
        _emit();
        _gpsRetryTimer = Timer(const Duration(seconds: 15), _startGps);
      },
      cancelOnError: true,
    );
  }

  void _onPosition(Position p) {
    _gpsError = null;
    final kmh = max(0.0, p.speed) * 3.6;

    // Hodômetro: soma o deslocamento só quando o veículo está andando.
    final ref = _odoRef;
    if (ref == null || p.accuracy > 50) {
      _odoRef ??= p;
    } else {
      final d = Geolocator.distanceBetween(ref.latitude, ref.longitude, p.latitude, p.longitude);
      if (kmh >= 3 && d >= max(10, p.accuracy)) {
        _cfg.mileageMeters += d.round();
        _odoRef = p;
      } else if (kmh < 3) {
        _odoRef = p;
      }
    }

    _pos = p;
    _posAt = DateTime.now();

    // Envio extra em curvas (compensação de ângulo do J16).
    final last = _lastSentCourse;
    if (_cfg.cornerDeg > 0 &&
        last != null &&
        kmh >= 5 &&
        p.heading >= 0 &&
        _angleDiff(p.heading, last) >= _cfg.cornerDeg &&
        DateTime.now().difference(_lastSentAt).inSeconds >= 3) {
      _report(Gt06.uploadCorner);
    }
    _emit();
  }

  static double _angleDiff(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  static int _satsFromAccuracy(double acc) => acc <= 5
      ? 12
      : acc <= 10
          ? 10
          : acc <= 20
              ? 8
              : acc <= 50
                  ? 6
                  : 4;

  bool get _gpsFresh {
    final at = _posAt;
    return at != null &&
        DateTime.now().difference(at) < Duration(seconds: max(_cfg.intervalSec * 2, 30));
  }

  /// Posição atual; sem sinal de GPS, repete a última válida marcada como inválida.
  GpsFix? _currentFix() {
    final p = _pos;
    if (p != null && _gpsFresh) {
      return _lastValid = GpsFix(
        time: p.timestamp.toUtc(),
        lat: p.latitude,
        lon: p.longitude,
        speedKmh: max(0.0, p.speed) * 3.6,
        course: p.heading < 0 ? (_lastSentCourse ?? 0) : p.heading,
        satellites: _satsFromAccuracy(p.accuracy),
        valid: true,
      );
    }
    final v = _lastValid ??
        (p == null
            ? null
            : GpsFix(
                time: p.timestamp.toUtc(),
                lat: p.latitude,
                lon: p.longitude,
                speedKmh: 0,
                course: 0,
                satellites: 0,
                valid: false));
    if (v == null) return null;
    return GpsFix(
      time: DateTime.now().toUtc(),
      lat: v.lat,
      lon: v.lon,
      speedKmh: 0,
      course: v.course,
      satellites: 0,
      valid: false,
    );
  }

  // ---------------------------------------------------------------- timers

  void _restartTimers() {
    _reportTimer?.cancel();
    _hbTimer?.cancel();
    _reportTimer = Timer.periodic(
        Duration(seconds: max(_cfg.intervalSec, 1)), (_) => _report(Gt06.uploadTimed));
    _hbTimer = Timer.periodic(Duration(seconds: max(_cfg.heartbeatSec, 10)), (_) => _heartbeatTick());
  }

  Future<void> _heartbeatTick() async {
    try {
      _batteryLevel = await _battery.batteryLevel;
    } catch (_) {}
    await _cfg.save(); // guarda o hodômetro
    if (!_loggedIn) return;
    if (_hbPending) {
      _missedHb++;
      if (_missedHb >= 3) {
        _disconnect('3 heartbeats sem resposta');
        return;
      }
    }
    _hbPending = true;
    await _send(_enc.heartbeat(_status()), 'HEARTBEAT');
  }

  // ---------------------------------------------------------------- conexão

  bool get _networkOk {
    if (_cfg.mobileOnly) return _net.contains(ConnectivityResult.mobile);
    return _net.any((r) => r != ConnectivityResult.none);
  }

  String get _netName {
    if (_net.contains(ConnectivityResult.mobile)) return 'operadora';
    if (_net.contains(ConnectivityResult.wifi)) return 'wi-fi';
    if (_net.contains(ConnectivityResult.ethernet)) return 'ethernet';
    if (_net.contains(ConnectivityResult.vpn)) return 'vpn';
    return _networkOk ? 'outra' : 'sem rede';
  }

  void _onNetwork(List<ConnectivityResult> r) {
    _net = r;
    _log('Rede: $_netName');
    if (_networkOk) {
      if (_socket == null && !_connecting) {
        _reconnectDelay = 5;
        _reconnectTimer?.cancel();
        _connect();
      }
    } else if (_socket != null) {
      _disconnect(_cfg.mobileOnly ? 'sem rede da operadora' : 'sem rede');
    } else {
      _setConn('waiting_network');
    }
    _emit();
  }

  Future<void> _connect() async {
    if (_stopped || _socket != null || _connecting) return;
    if (!_cfg.isConfigured) {
      _setConn('not_configured');
      return;
    }
    if (!_networkOk) {
      _setConn('waiting_network');
      return;
    }
    _connecting = true;
    _setConn('connecting');
    _log('Conectando em ${_cfg.host}:${_cfg.port}...');
    try {
      final s = await Socket.connect(_cfg.host.trim(), _cfg.port, timeout: const Duration(seconds: 20));
      if (_stopped) {
        s.destroy();
        return;
      }
      s.setOption(SocketOption.tcpNoDelay, true);
      _socket = s;
      _writeChain = Future.value();
      _hbPending = false;
      _missedHb = 0;
      s.listen(
        _onData,
        onError: (Object e) => _disconnect('erro de conexão: $e'),
        onDone: () => _disconnect('servidor encerrou a conexão'),
        cancelOnError: true,
      );
      _setConn('login');
      await _send(_enc.login(_cfg.imei), 'LOGIN');
      _loginTimer?.cancel();
      _loginTimer = Timer(const Duration(seconds: 20), () {
        if (!_loggedIn) _disconnect('servidor não respondeu ao login');
      });
    } catch (e) {
      _lastError = '$e';
      _log('Falha ao conectar: $e');
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _disconnect(String reason) {
    final s = _socket;
    if (s == null) return;
    _socket = null;
    _loggedIn = false;
    _loginTimer?.cancel();
    _lastError = reason;
    _log('Desconectado: $reason');
    s.destroy();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    _reconnectTimer?.cancel();
    if (!_networkOk) {
      _setConn('waiting_network');
      return;
    }
    _setConn('reconnecting');
    _reconnectTimer = Timer(Duration(seconds: _reconnectDelay), _connect);
    _reconnectDelay = min(_reconnectDelay * 2, 60);
  }

  void _reconnectNow() {
    _reconnectDelay = 1;
    if (_socket != null) {
      _disconnect('reconectando');
    } else {
      _reconnectTimer?.cancel();
      _connect();
    }
  }

  void _setConn(String c) {
    if (_conn == c) return;
    _conn = c;
    _emit();
    _updateNotification();
  }

  /// As escritas no socket são enfileiradas: o IOSink não aceita add() durante flush().
  Future<bool> _send(Uint8List data, String label) {
    final f = _writeChain.then((_) async {
      final s = _socket;
      if (s == null) return false;
      try {
        s.add(data);
        await s.flush();
        _lastTx = DateTime.now();
        _log('TX $label: ${hex(data)}');
        return true;
      } catch (e) {
        _disconnect('falha no envio: $e');
        return false;
      }
    });
    _writeChain = f.then((_) {}, onError: (_) {});
    return f;
  }

  void _onData(Uint8List data) {
    for (final p in _dec.feed(data)) {
      _log('RX: ${hex(p.raw)}');
      switch (p.protocol) {
        case Gt06.login:
          _onLoginAck();
        case Gt06.heartbeat:
          _hbPending = false;
          _missedHb = 0;
        case Gt06.serverCommand:
          final c = p.command;
          if (c != null) _handleCommand(c.$1, c.$2);
      }
    }
  }

  Future<void> _onLoginAck() async {
    if (_loggedIn) return;
    _loginTimer?.cancel();
    _loggedIn = true;
    _reconnectDelay = 5;
    _lastError = null;
    _setConn('online');
    _log('Login aceito pelo servidor');
    _hbPending = true;
    await _send(_enc.heartbeat(_status()), 'HEARTBEAT');
    _flushQueue();
  }

  // ---------------------------------------------------------------- envio

  // Sem fio de ignição no celular: ACC vai sempre como ligado.
  TerminalStatus _status() => TerminalStatus(
        acc: true,
        charging: _charging,
        gpsTracking: _gpsFresh,
        voltageLevel: _batteryLevel >= 90
            ? 6
            : _batteryLevel >= 70
                ? 5
                : _batteryLevel >= 50
                    ? 4
                    : _batteryLevel >= 30
                        ? 3
                        : _batteryLevel >= 15
                            ? 2
                            : 1,
        gsmSignal: _net.contains(ConnectivityResult.mobile)
            ? 4
            : _networkOk
                ? 3
                : 0,
      );

  CellInfo get _cell => CellInfo(mcc: _cfg.mcc, mnc: _cfg.mnc, lac: _cfg.lac, cellId: _cfg.cellId);

  Uint8List _locationPacket(GpsFix f, int mode, {bool reupload = false, int? mileage}) =>
      _enc.location(f, _cell,
          fourG: _cfg.fourGPacket,
          acc: true,
          uploadMode: mode,
          reupload: reupload,
          mileageMeters: mileage ?? _cfg.mileageMeters);

  Future<void> _report(int mode) async {
    if (_stopped) return;
    final f = _currentFix();
    if (f == null) {
      _log('Aguardando primeira posição do GPS${_gpsError != null ? ' ($_gpsError)' : ''}');
      return;
    }
    _lastSentAt = DateTime.now();
    if (f.valid) _lastSentCourse = f.course;

    if (_loggedIn && await _send(_locationPacket(f, mode), _modeName(mode))) {
      _sent++;
    } else {
      await _store.add(f, uploadMode: mode, mileageMeters: _cfg.mileageMeters);
      _queued++;
      _log('Sem conexão — posição guardada na memória ($_queued na fila)');
    }
    _emit();
    _updateNotification();
  }

  static String _modeName(int mode) => switch (mode) {
        Gt06.uploadCorner => 'GPS (curva)',
        _ => 'GPS',
      };

  Future<void> _flushQueue() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_loggedIn && !_stopped) {
        final batch = await _store.oldest(20);
        if (batch.isEmpty) break;
        _log('Reenviando ${batch.length} posições da memória ($_queued na fila)');
        final done = <int>[];
        for (final r in batch) {
          final pkt = _locationPacket(r.fix, r.uploadMode, reupload: true, mileage: r.mileageMeters);
          if (!await _send(pkt, 'REENVIO')) break;
          done.add(r.id);
        }
        await _store.remove(done);
        _queued = await _store.count();
        _sent += done.length;
        _emit();
        if (done.length < batch.length) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      _log('Erro ao reenviar memória: $e');
    } finally {
      _flushing = false;
    }
  }

  Future<void> _clearQueue() async {
    await _store.clear();
    _queued = 0;
    _log('Memória interna apagada');
    _emit();
  }

  Future<void> _applyConfig(Map<String, dynamic> m) async {
    final old = _cfg;
    final n = TrackerConfig.fromMap({...old.toMap(), ...m});
    // estado do aparelho continua sendo do serviço
    n
      ..enabled = true
      ..mileageMeters = old.mileageMeters;
    _cfg = n;
    await _cfg.save();
    _log('Configuração atualizada');
    final serverChanged =
        n.host != old.host || n.port != old.port || n.imei != old.imei || n.mobileOnly != old.mobileOnly;
    if (n.intervalSec != old.intervalSec || n.heartbeatSec != old.heartbeatSec) _restartTimers();
    if (n.intervalSec != old.intervalSec) _startGps();
    if (serverChanged) _reconnectNow();
    _emit();
  }

  // ---------------------------------------------------------------- comandos do servidor

  Future<void> _handleCommand(int flag, String raw) async {
    final cmd = raw.trim();
    _log('Comando do servidor: $cmd');
    final parts = cmd.replaceAll('#', '').split(',').map((s) => s.trim()).toList();
    final name = parts.first.toUpperCase();
    String reply;
    var reconnect = false;

    switch (name) {
      case 'TIMER':
        final t = parts.length > 1 ? int.tryParse(parts[1]) : null;
        if (t != null && t >= 5 && t <= 18000) {
          _cfg.intervalSec = t;
          await _cfg.save();
          _restartTimers();
          _startGps();
          reply = 'OK!';
        } else {
          reply = 'TIMER:${_cfg.intervalSec}';
        }
      case 'HBT':
        final t = parts.length > 1 ? int.tryParse(parts[1]) : null;
        if (t != null && t >= 1 && t <= 300) {
          _cfg.heartbeatSec = t * 60;
          await _cfg.save();
          _restartTimers();
          reply = 'OK!';
        } else {
          reply = 'HBT:${(_cfg.heartbeatSec / 60).round()}';
        }
      case 'SERVER':
        // SERVER,modo,endereço,porta,0#
        if (parts.length >= 4 && int.tryParse(parts[3]) != null) {
          _cfg.host = parts[2];
          _cfg.port = int.parse(parts[3]);
          await _cfg.save();
          reconnect = true;
          reply = 'OK!';
        } else {
          reply = 'SERVER,${_cfg.host},${_cfg.port}';
        }
      case 'WHERE' || 'DWXX' || 'POSITION' || 'URL':
        reply = _whereText();
        _report(Gt06.uploadTimed);
      case 'STATUS':
        reply = _statusText();
      case 'PARAM':
        reply = 'IMEI:${_cfg.imei};TIMER:${_cfg.intervalSec};HBT:${(_cfg.heartbeatSec / 60).round()};'
            'SENDS:1;SERVER:${_cfg.host},${_cfg.port};ANGLEREP:${_cfg.cornerDeg};';
      case 'VERSION':
        reply = '[VERSION]J16_4G_SIM_V1.0.0 [BUILD]2026/10/24';
      case 'IMEI':
        reply = 'IMEI:${_cfg.imei}';
      case 'GPRSON' || 'GPRSSET':
        reply = 'GPRS:ON;SERVER:${_cfg.host},${_cfg.port};';
      case 'RESET':
        reply = 'OK!';
        reconnect = true;
      case 'MILEAGE':
        if (parts.length > 2 && parts[1].toUpperCase() == 'ON') {
          final km = int.tryParse(parts[2]);
          if (km != null) _cfg.mileageMeters = km * 1000;
        }
        reply = 'MILEAGE:${(_cfg.mileageMeters / 1000).toStringAsFixed(1)}km';
      default:
        reply = 'Command error!';
    }

    await _send(_enc.commandReply(flag, reply), 'RESPOSTA "$reply"');
    _emit();
    if (reconnect) {
      await Future<void>.delayed(const Duration(seconds: 1));
      _reconnectNow();
    }
  }

  String _whereText() {
    final f = _currentFix();
    if (f == null) return 'No GPS data!';
    final t = f.time;
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Lat:${f.lat >= 0 ? 'N' : 'S'}${f.lat.abs().toStringAsFixed(6)},'
        'Lon:${f.lon >= 0 ? 'E' : 'W'}${f.lon.abs().toStringAsFixed(6)},'
        'Course:${f.course.round()},Speed:${f.speedKmh.round()}km/h,'
        'DateTime:${two(t.year % 100)}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String _statusText() {
    final s = _status();
    const gsm = ['No signal', 'Extremely weak', 'Weak', 'Good', 'Strong'];
    return 'Battery:$_batteryLevel%;GPRS:${_loggedIn ? 'Link Up' : 'Link Down'};'
        'GSM Signal Level:${gsm[s.gsmSignal]};'
        'GPS:${_gpsFresh ? 'Successful positioning' : 'Positioning'};'
        'ACC:ON';
  }

  // ---------------------------------------------------------------- interface

  void _log(String m) {
    final e = {'t': DateTime.now().millisecondsSinceEpoch, 'm': m};
    _logs.add(e);
    if (_logs.length > 300) _logs.removeRange(0, _logs.length - 300);
    _service.invoke('log', e);
  }

  void _emit({bool running = true}) {
    final p = _pos;
    _service.invoke('status', {
      'running': running && !_stopped,
      'conn': _conn,
      'error': _lastError,
      'gpsError': _gpsError,
      'network': _netName,
      'gpsFresh': _gpsFresh,
      'lat': p?.latitude,
      'lon': p?.longitude,
      'speed': p == null ? null : max(0.0, p.speed) * 3.6,
      'course': p?.heading,
      'accuracy': p?.accuracy,
      'fixTime': _posAt?.millisecondsSinceEpoch,
      'queued': _queued,
      'sent': _sent,
      'lastTx': _lastTx?.millisecondsSinceEpoch,
      'battery': _batteryLevel,
      'config': _cfg.toMap(),
    });
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  void _updateNotification() {
    final n = _notify;
    if (n == null) return;
    final now = DateTime.now();
    if (now.difference(_lastNotify).inSeconds < 5 && _conn == 'online') return;
    _lastNotify = now;
    final state = switch (_conn) {
      'online' => 'Online',
      'waiting_network' => 'Sem rede — gravando na memória',
      'not_configured' => 'Configure o servidor',
      _ => 'Conectando...',
    };
    n('J16 4G • $state', 'Enviados: $_sent • Memória: $_queued');
  }
}
