import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Configuração do rastreador. Fica num arquivo JSON para que o serviço em
/// segundo plano (outro isolate no Android) sempre leia a versão atual.
class TrackerConfig {
  String host;
  int port;
  String imei;
  int intervalSec; // tempo entre leituras/envios de GPS
  int heartbeatSec;
  int cornerDeg; // envio extra em curvas (0 = desligado)
  bool fourGPacket; // 0xA0 em vez de 0x22
  bool mobileOnly; // transmitir só pela rede da operadora
  bool autoStart; // iniciar com o aparelho / ao abrir o app
  int mcc;
  int mnc;
  int lac;
  int cellId;

  // Estado persistente do "aparelho".
  bool enabled;
  int mileageMeters;

  TrackerConfig({
    this.host = '',
    this.port = 5023,
    String? imei,
    this.intervalSec = 10,
    this.heartbeatSec = 180,
    this.cornerDeg = 30,
    this.fourGPacket = false,
    this.mobileOnly = false,
    this.autoStart = true,
    this.mcc = 724,
    this.mnc = 5,
    this.lac = 0,
    this.cellId = 0,
    this.enabled = false,
    this.mileageMeters = 0,
  }) : imei = imei ?? randomImei();

  bool get isConfigured => host.trim().isNotEmpty && port > 0 && isValidImei(imei);

  Map<String, dynamic> toMap() => {
        'host': host,
        'port': port,
        'imei': imei,
        'intervalSec': intervalSec,
        'heartbeatSec': heartbeatSec,
        'cornerDeg': cornerDeg,
        'fourGPacket': fourGPacket,
        'mobileOnly': mobileOnly,
        'autoStart': autoStart,
        'mcc': mcc,
        'mnc': mnc,
        'lac': lac,
        'cellId': cellId,
        'enabled': enabled,
        'mileageMeters': mileageMeters,
      };

  factory TrackerConfig.fromMap(Map<String, dynamic> m) {
    final d = TrackerConfig();
    T v<T>(String k, T def) => m[k] is T ? m[k] as T : def;
    return TrackerConfig(
      host: v('host', d.host),
      port: v('port', d.port),
      imei: v('imei', d.imei),
      intervalSec: v('intervalSec', d.intervalSec),
      heartbeatSec: v('heartbeatSec', d.heartbeatSec),
      cornerDeg: v('cornerDeg', d.cornerDeg),
      fourGPacket: v('fourGPacket', d.fourGPacket),
      mobileOnly: v('mobileOnly', d.mobileOnly),
      autoStart: v('autoStart', d.autoStart),
      mcc: v('mcc', d.mcc),
      mnc: v('mnc', d.mnc),
      lac: v('lac', d.lac),
      cellId: v('cellId', d.cellId),
      enabled: v('enabled', d.enabled),
      mileageMeters: v('mileageMeters', d.mileageMeters),
    );
  }

  static Future<File> _file() async =>
      File(p.join(await getDatabasesPath(), 'tracker_config.json'));

  static Future<TrackerConfig> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        return TrackerConfig.fromMap(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      }
    } catch (_) {}
    final c = TrackerConfig();
    await c.save();
    return c;
  }

  Future<void> save() async {
    final f = await _file();
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(toMap()), flush: true);
    await tmp.rename(f.path);
  }

  static bool isValidImei(String s) => RegExp(r'^\d{15}$').hasMatch(s);

  /// IMEI aleatório com dígito verificador de Luhn válido.
  static String randomImei() {
    final r = Random();
    final d = [8, 6, ...List.generate(12, (_) => r.nextInt(10))];
    var sum = 0;
    for (var i = 0; i < d.length; i++) {
      var x = d[i];
      if (i.isOdd) {
        x *= 2;
        if (x > 9) x -= 9;
      }
      sum += x;
    }
    return d.join() + ((10 - sum % 10) % 10).toString();
  }
}
