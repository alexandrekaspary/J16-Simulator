// Gera as capturas de tela do app (PNG na raiz do projeto) com dados de exemplo.
//
//   flutter test tool/screenshots_test.dart --dart-define=FLUTTER_ROOT=<caminho do SDK>
//
// Fica fora de test/ para não rodar no CI.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j16_tracker/protocol/gt06.dart';
import 'package:j16_tracker/tracker/config.dart';
import 'package:j16_tracker/tracker/controller.dart';
import 'package:j16_tracker/ui/home_shell.dart';
import 'package:j16_tracker/ui/theme.dart';

const _flutterRoot = String.fromEnvironment('FLUTTER_ROOT');

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File(f).readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

TrackerConfig _cfg() => TrackerConfig(
      host: 'gps.suaempresa.com.br',
      port: 5023,
      imei: '861234567890123',
      intervalSec: 10,
      enabled: true,
    );

Map<String, dynamic> _status(TrackerConfig c, {required bool online}) => {
      'running': true,
      'conn': online ? 'online' : 'waiting_network',
      'error': online ? null : 'sem rede',
      'network': online ? 'operadora' : 'sem rede',
      'gpsFresh': true,
      'lat': -23.550520,
      'lon': -46.633308,
      'speed': online ? 62.0 : 48.0,
      'course': 275.0,
      'accuracy': 4.0,
      'queued': online ? 0 : 137,
      'sent': online ? 1284 : 1146,
      'lastTx': DateTime.now().subtract(Duration(seconds: online ? 4 : 1370)).millisecondsSinceEpoch,
      'battery': 87,
      'config': c.toMap(),
    };

List<LogEntry> _logs() {
  final e = Gt06Encoder();
  final t0 = DateTime(2026, 10, 24, 14, 32, 5);
  final fix = GpsFix(
      time: t0.toUtc(), lat: -23.550520, lon: -46.633308, speedKmh: 62, course: 275, satellites: 12, valid: true);
  const cell = CellInfo(mcc: 724, mnc: 5);
  final items = <(int, String)>[
    (0, 'Rastreador iniciado — IMEI 861234567890123, gps.suaempresa.com.br:5023, intervalo 10s, pacote 0x22'),
    (0, 'Conectando em gps.suaempresa.com.br:5023...'),
    (1, 'TX LOGIN: ${hex(e.login('861234567890123'))}'),
    (1, 'RX: 78 78 05 01 00 01 D9 DC 0D 0A'),
    (1, 'Login aceito pelo servidor'),
    (1, 'TX HEARTBEAT: ${hex(e.heartbeat(const TerminalStatus(acc: true, voltageLevel: 5, gsmSignal: 4)))}'),
    (2, 'RX: 78 78 05 13 00 02 DB 6A 0D 0A'),
    (2, 'Reenviando 20 posições da memória (137 na fila)'),
    (2, 'TX REENVIO: ${hex(e.location(fix, cell, fourG: false, acc: true, reupload: true))}'),
    (12, 'TX GPS: ${hex(e.location(fix, cell, fourG: false, acc: true))}'),
    (15, 'RX: ${hex(e.frame(Gt06.serverCommand, [4 + 9, 0, 0, 0, 0, ...'TIMER,10#'.codeUnits, 0, 2]))}'),
    (15, 'Comando do servidor: TIMER,10#'),
    (15, 'TX RESPOSTA "OK!": ${hex(e.commandReply(0, 'OK!'))}'),
    (22, 'TX GPS: ${hex(e.location(fix, cell, fourG: false, acc: true))}'),
  ];
  return [for (final (s, m) in items) LogEntry(t0.add(Duration(seconds: s)), m)];
}

void main() {
  setUpAll(() async {
    final fonts = '$_flutterRoot/bin/cache/artifacts/material_fonts';
    await _loadFont('Roboto', [
      for (final w in ['Regular', 'Medium', 'Bold', 'Light']) '$fonts/Roboto-$w.ttf',
    ]);
    await _loadFont('MaterialIcons', ['$fonts/MaterialIcons-Regular.otf']);
    await _loadFont('monospace', ['/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf']);
  });

  Future<void> shot(WidgetTester tester, String file, TrackerController c,
      {int tab = 0, Brightness brightness = Brightness.light, double height = 2340}) async {
    tester.view.physicalSize = Size(1080, height);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 72, bottom: 48);
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(brightness),
        home: HomeShell(controller: c, initialTab: tab),
      ),
    ));
    await tester.runAsync(() async {
      for (final el in find.byType(Image).evaluate()) {
        await precacheImage((el.widget as Image).image, el);
      }
    });
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File(file).writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  testWidgets('capturas', (tester) async {
    final c1 = _cfg();
    await shot(tester, 'tela_1_painel.png',
        TrackerController.preview(config: c1, status: _status(c1, online: true), logs: _logs()));

    final c2 = _cfg();
    await shot(tester, 'tela_2_sem_rede.png',
        TrackerController.preview(config: c2, status: _status(c2, online: false)));

    await shot(tester, 'tela_3_configuracoes.png',
        TrackerController.preview(config: c1, status: _status(c1, online: true)),
        tab: 1);

    await shot(tester, 'tela_3b_configuracoes_completo.png',
        TrackerController.preview(config: c1, status: _status(c1, online: true)),
        tab: 1,
        height: 3480);

    await shot(tester, 'tela_4_log.png',
        TrackerController.preview(config: c1, status: _status(c1, online: true), logs: _logs()),
        tab: 2);

    await shot(tester, 'tela_5_modo_escuro.png',
        TrackerController.preview(config: c1, status: _status(c1, online: true)),
        brightness: Brightness.dark);
  });
}
