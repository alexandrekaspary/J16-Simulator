import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:j16_tracker/protocol/gt06.dart';

List<int> bytes(String hexStr) =>
    hexStr.split(' ').where((s) => s.isNotEmpty).map((s) => int.parse(s, radix: 16)).toList();

void main() {
  test('login igual ao exemplo da documentação GT06', () {
    final pkt = Gt06Encoder().login('123456789012345');
    expect(hex(pkt), '78 78 0D 01 01 23 45 67 89 01 23 45 00 01 8C DD 0D 0A');
  });

  test('localização 0x22 decodificada como no Traccar', () {
    final fix = GpsFix(
      time: DateTime.utc(2026, 10, 24, 13, 45, 7),
      lat: -23.550520,
      lon: -46.633308,
      speedKmh: 62,
      course: 275,
      satellites: 9,
      valid: true,
    );
    final pkt = Gt06Encoder().location(fix, const CellInfo(mcc: 724, mnc: 5, lac: 0x1234, cellId: 0xABCDE),
        fourG: false, acc: true, reupload: true);
    expect(pkt.length, 0x22 + 5); // tamanho padrão do 0x22
    expect(pkt[2], 0x22);
    expect(pkt[3], 0x22);
    final b = ByteData.sublistView(pkt);
    expect(pkt.sublist(4, 10), [26, 10, 24, 13, 45, 7]);
    expect(pkt[10] & 0x0F, 9);
    final flags = b.getUint16(20);
    var lat = b.getUint32(11) / 60.0 / 30000.0;
    var lon = b.getUint32(15) / 60.0 / 30000.0;
    if (flags & (1 << 10) == 0) lat = -lat;
    if (flags & (1 << 11) != 0) lon = -lon;
    expect(lat, closeTo(-23.550520, 1e-5));
    expect(lon, closeTo(-46.633308, 1e-5));
    expect(pkt[19], 62);
    expect(flags & 0x3FF, 275);
    expect(flags & (1 << 12) != 0, isTrue); // GPS válido
    expect(b.getUint16(22), 724);
    expect(pkt[24], 5);
    expect(b.getUint16(25), 0x1234);
    expect(pkt.sublist(27, 30), [0x0A, 0xBC, 0xDE]);
    expect(pkt[30], 1); // ACC
    expect(pkt[32], 1); // reenvio da memória
    expect(crcItu(pkt, 2, pkt.length - 4), b.getUint16(pkt.length - 4));
    expect(pkt.sublist(pkt.length - 2), [0x0D, 0x0A]);
  });

  test('localização 4G 0xA0 tem LAC 4 bytes, Cell ID 8 bytes e hodômetro', () {
    final fix = GpsFix(
        time: DateTime.utc(2026), lat: 1, lon: 1, speedKmh: 0, course: 0, satellites: 5, valid: true);
    final pkt = Gt06Encoder().location(fix, const CellInfo(lac: 0x01020304, cellId: 0x0102030405),
        fourG: true, acc: false, mileageMeters: 123456);
    expect(pkt[2], 0x2D);
    expect(pkt[3], 0xA0);
    final b = ByteData.sublistView(pkt);
    expect(b.getUint32(25), 0x01020304);
    expect(b.getUint32(29), 0x01);
    expect(b.getUint32(33), 0x02030405);
    expect(b.getUint32(40), 123456);
  });

  test('heartbeat e alarme têm os tamanhos do protocolo', () {
    final e = Gt06Encoder();
    final hb = e.heartbeat(const TerminalStatus(acc: true, relayCut: true, voltageLevel: 4, gsmSignal: 3));
    expect(hb[2], 0x0A);
    expect(hb[4], 0x80 | 0x40 | 0x02);
    final fix = GpsFix(
        time: DateTime.utc(2026), lat: 1, lon: 1, speedKmh: 0, course: 0, satellites: 5, valid: true);
    final al = e.alarm(fix, const CellInfo(), const TerminalStatus(alarmBits: 4), Gt06.alarmSos);
    expect(al[2], 0x25);
    expect(al[3], 0x26);
    expect(al[al.length - 8], Gt06.alarmSos);
  });

  test('decodifica comando 0x80 mesmo partido em dois pedaços TCP', () {
    // Formato enviado pelo Traccar para "Relay,1#"
    final cmd = ascii.encode('Relay,1#');
    final body = [1 + 1 + 4 + cmd.length + 2 + 2, 0x80, 4 + cmd.length, 0, 0, 0, 7, ...cmd, 0, 9];
    final crc = crcItu(body);
    final frame = [0x78, 0x78, ...body, crc >> 8, crc & 0xFF, 0x0D, 0x0A];
    final d = Gt06Decoder();
    expect(d.feed([0x00, ...frame.sublist(0, 7)]), isEmpty);
    final out = d.feed([...frame.sublist(7), ...bytes('78 78 05 01 00 01 D9 DC 0D 0A')]);
    expect(out.length, 2);
    expect(out[0].command, (7, 'Relay,1#'));
    expect(out[0].serial, 9);
    expect(out[1].protocol, Gt06.login);

    final reply = Gt06Encoder().commandReply(7, 'Cut off the fuel supply: Success!');
    expect(reply[3], 0x15);
    expect(reply[4], 4 + 33);
    expect(ascii.decode(reply.sublist(9, 9 + 33)), 'Cut off the fuel supply: Success!');
  });
}
