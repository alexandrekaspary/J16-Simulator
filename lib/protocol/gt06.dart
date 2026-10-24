// Protocolo GT06 / Concox, o mesmo usado pelo rastreador J16 4G.
//
// Quadro curto:  78 78 | LEN(1) | PROTO(1) | CONTEUDO | SERIAL(2) | CRC(2) | 0D 0A
// Quadro longo:  79 79 | LEN(2) | PROTO(1) | CONTEUDO | SERIAL(2) | CRC(2) | 0D 0A
// LEN conta de PROTO até CRC; o CRC-ITU (X.25) é calculado de LEN até SERIAL.

import 'dart:convert';
import 'dart:typed_data';

class Gt06 {
  static const int login = 0x01;
  static const int heartbeat = 0x13;
  static const int commandReply = 0x15;
  static const int location = 0x22;
  static const int alarm = 0x26;
  static const int location4g = 0xA0;
  static const int serverCommand = 0x80;

  // Modo de envio (byte "Data Upload Mode" do pacote de localização).
  static const int uploadTimed = 0x00;
  static const int uploadDistance = 0x01;
  static const int uploadCorner = 0x02;
  static const int uploadAccChange = 0x03;
  static const int uploadReconnect = 0x05;

  // Códigos de alarme (byte alto de "Alarm/Language").
  static const int alarmSos = 0x01;
  static const int alarmPowerCut = 0x02;
  static const int alarmVibration = 0x03;
  static const int alarmOverspeed = 0x06;
  static const int alarmLowBattery = 0x0E;

  static const int languageEnglish = 0x02;
}

/// CRC-ITU (CRC-16/X-25) usado pelo GT06.
int crcItu(List<int> data, [int start = 0, int? end]) {
  var crc = 0xFFFF;
  for (var i = start; i < (end ?? data.length); i++) {
    crc ^= data[i] & 0xFF;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1;
    }
  }
  return (~crc) & 0xFFFF;
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ').toUpperCase();

class _W {
  final BytesBuilder _b = BytesBuilder();
  void u8(int v) => _b.addByte(v & 0xFF);
  void u16(int v) => _b
    ..addByte((v >> 8) & 0xFF)
    ..addByte(v & 0xFF);
  void u24(int v) {
    u8(v >> 16);
    u16(v);
  }

  void u32(int v) {
    u16(v >> 16);
    u16(v);
  }

  void u64(int v) {
    u32(v >> 32);
    u32(v);
  }

  void bytes(List<int> v) => _b.add(v);
  Uint8List take() => _b.takeBytes();
}

/// Uma leitura de GPS pronta para ser codificada.
class GpsFix {
  final DateTime time; // UTC
  final double lat;
  final double lon;
  final double speedKmh;
  final double course;
  final int satellites;
  final bool valid;

  const GpsFix({
    required this.time,
    required this.lat,
    required this.lon,
    required this.speedKmh,
    required this.course,
    required this.satellites,
    required this.valid,
  });

  Map<String, dynamic> toMap() => {
        'time': time.millisecondsSinceEpoch,
        'lat': lat,
        'lon': lon,
        'speed': speedKmh,
        'course': course,
        'sats': satellites,
        'valid': valid ? 1 : 0,
      };

  factory GpsFix.fromMap(Map<String, dynamic> m) => GpsFix(
        time: DateTime.fromMillisecondsSinceEpoch(m['time'] as int, isUtc: true),
        lat: (m['lat'] as num).toDouble(),
        lon: (m['lon'] as num).toDouble(),
        speedKmh: (m['speed'] as num).toDouble(),
        course: (m['course'] as num).toDouble(),
        satellites: m['sats'] as int,
        valid: m['valid'] == 1 || m['valid'] == true,
      );
}

/// Dados da célula da operadora (LBS).
class CellInfo {
  final int mcc;
  final int mnc;
  final int lac;
  final int cellId;
  const CellInfo({this.mcc = 724, this.mnc = 5, this.lac = 0, this.cellId = 0});
}

/// Estado do terminal usado no heartbeat e nos alarmes.
class TerminalStatus {
  final bool armed; // defesa ativada
  final bool acc; // ignição
  final bool charging;
  final bool gpsTracking;
  final bool relayCut; // óleo/eletricidade cortados
  final int alarmBits; // bits 3-5: 100 SOS, 011 bateria baixa, 010 corte energia, 001 vibração
  final int voltageLevel; // 0..6
  final int gsmSignal; // 0..4

  const TerminalStatus({
    this.armed = false,
    this.acc = false,
    this.charging = false,
    this.gpsTracking = true,
    this.relayCut = false,
    this.alarmBits = 0,
    this.voltageLevel = 6,
    this.gsmSignal = 4,
  });

  int get infoByte =>
      (armed ? 0x01 : 0) |
      (acc ? 0x02 : 0) |
      (charging ? 0x04 : 0) |
      ((alarmBits & 0x07) << 3) |
      (gpsTracking ? 0x40 : 0) |
      (relayCut ? 0x80 : 0);
}

class Gt06Encoder {
  int _serial = 0;

  int nextSerial() {
    _serial = (_serial % 0xFFFF) + 1;
    return _serial;
  }

  Uint8List frame(int protocol, List<int> content) {
    final serial = nextSerial();
    final long = content.length + 5 > 0xFF;
    final body = _W();
    if (long) {
      body.u16(content.length + 5);
    } else {
      body.u8(content.length + 5);
    }
    body
      ..u8(protocol)
      ..bytes(content)
      ..u16(serial);
    final b = body.take();
    final out = _W()
      ..u16(long ? 0x7979 : 0x7878)
      ..bytes(b)
      ..u16(crcItu(b))
      ..u16(0x0D0A);
    return out.take();
  }

  /// 0x01 — login com o IMEI em BCD (8 bytes, "0" + 15 dígitos).
  Uint8List login(String imei) {
    final digits = imei.padLeft(16, '0');
    final w = _W();
    for (var i = 0; i < 16; i += 2) {
      w.u8(int.parse(digits.substring(i, i + 2), radix: 16));
    }
    return frame(Gt06.login, w.take());
  }

  /// 0x13 — heartbeat / informação de status.
  Uint8List heartbeat(TerminalStatus s, {int alarmCode = 0}) {
    final w = _W()
      ..u8(s.infoByte)
      ..u8(s.voltageLevel.clamp(0, 6))
      ..u8(s.gsmSignal.clamp(0, 4))
      ..u8(alarmCode)
      ..u8(Gt06.languageEnglish);
    return frame(Gt06.heartbeat, w.take());
  }

  void _gps(_W w, GpsFix f) {
    final t = f.time.toUtc();
    w
      ..u8(t.year % 100)
      ..u8(t.month)
      ..u8(t.day)
      ..u8(t.hour)
      ..u8(t.minute)
      ..u8(t.second)
      ..u8(0xC0 | f.satellites.clamp(0, 15))
      ..u32((f.lat.abs() * 60 * 30000).round())
      ..u32((f.lon.abs() * 60 * 30000).round())
      ..u8(f.speedKmh.round().clamp(0, 255));
    var cs = f.course.round() % 360 & 0x3FF;
    if (f.valid) cs |= 1 << 12;
    if (f.lat >= 0) cs |= 1 << 10; // norte
    if (f.lon < 0) cs |= 1 << 11; // oeste
    w.u16(cs);
  }

  /// 0x22 (GPS+LBS padrão) ou 0xA0 (GPS+LBS 4G).
  Uint8List location(
    GpsFix f,
    CellInfo cell, {
    required bool fourG,
    required bool acc,
    int uploadMode = Gt06.uploadTimed,
    bool reupload = false,
    int mileageMeters = 0,
  }) {
    final w = _W();
    _gps(w, f);
    final mnc2 = cell.mnc > 0xFF;
    w.u16(cell.mcc | (mnc2 ? 0x8000 : 0));
    mnc2 ? w.u16(cell.mnc) : w.u8(cell.mnc);
    if (fourG) {
      w
        ..u32(cell.lac)
        ..u64(cell.cellId);
    } else {
      w
        ..u16(cell.lac)
        ..u24(cell.cellId);
    }
    w
      ..u8(acc ? 1 : 0)
      ..u8(uploadMode)
      ..u8(reupload ? 1 : 0);
    if (fourG) w.u32(mileageMeters);
    return frame(fourG ? Gt06.location4g : Gt06.location, w.take());
  }

  /// 0x26 — alarme (GPS + LBS + status).
  Uint8List alarm(GpsFix f, CellInfo cell, TerminalStatus s, int alarmCode) {
    final w = _W();
    _gps(w, f);
    w
      ..u8(9) // tamanho do bloco LBS
      ..u16(cell.mcc)
      ..u8(cell.mnc & 0xFF)
      ..u16(cell.lac & 0xFFFF)
      ..u24(cell.cellId & 0xFFFFFF)
      ..u8(s.infoByte)
      ..u8(s.voltageLevel.clamp(0, 6))
      ..u8(s.gsmSignal.clamp(0, 4))
      ..u8(alarmCode)
      ..u8(Gt06.languageEnglish);
    return frame(Gt06.alarm, w.take());
  }

  /// 0x15 — resposta de texto a um comando 0x80 do servidor.
  Uint8List commandReply(int serverFlag, String text) {
    final data = ascii.encode(text);
    final w = _W()
      ..u8(4 + data.length)
      ..u32(serverFlag)
      ..bytes(data)
      ..u16(Gt06.languageEnglish);
    return frame(Gt06.commandReply, w.take());
  }
}

class Gt06Packet {
  final int protocol;
  final Uint8List content;
  final int serial;
  final Uint8List raw;
  Gt06Packet(this.protocol, this.content, this.serial, this.raw);

  /// Para 0x80: (flag do servidor, texto do comando).
  (int, String)? get command {
    if (protocol != Gt06.serverCommand || content.length < 5) return null;
    final len = content[0];
    final flag = ByteData.sublistView(content, 1, 5).getUint32(0);
    final end = (1 + len).clamp(5, content.length);
    return (flag, ascii.decode(content.sublist(5, end), allowInvalid: true));
  }
}

/// Separa os quadros recebidos do servidor (TCP pode juntar ou partir pacotes).
class Gt06Decoder {
  final List<int> _buf = [];

  List<Gt06Packet> feed(List<int> data) {
    _buf.addAll(data);
    final out = <Gt06Packet>[];
    while (_buf.length >= 2) {
      final start = _findHeader();
      if (start < 0) {
        _buf.removeRange(0, _buf.length - 1);
        break;
      }
      if (start > 0) _buf.removeRange(0, start);
      final long = _buf[0] == 0x79;
      final hdr = long ? 4 : 3;
      if (_buf.length < hdr) break;
      final len = long ? (_buf[2] << 8) | _buf[3] : _buf[2];
      final total = hdr + len + 2;
      if (len < 5) {
        _buf.removeRange(0, 2);
        continue;
      }
      if (_buf.length < total) break;
      final raw = Uint8List.fromList(_buf.sublist(0, total));
      _buf.removeRange(0, total);
      final protocol = raw[hdr];
      final content = raw.sublist(hdr + 1, hdr + len - 4);
      final serial = (raw[hdr + len - 4] << 8) | raw[hdr + len - 3];
      out.add(Gt06Packet(protocol, content, serial, raw));
    }
    return out;
  }

  int _findHeader() {
    for (var i = 0; i < _buf.length - 1; i++) {
      final b = _buf[i];
      if ((b == 0x78 || b == 0x79) && _buf[i + 1] == b) return i;
    }
    return -1;
  }
}
