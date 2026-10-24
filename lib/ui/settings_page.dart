import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tracker/config.dart';
import '../tracker/controller.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});
  final TrackerController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _form = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _imei = TextEditingController();
  final _interval = TextEditingController();
  final _heartbeat = TextEditingController();
  final _corner = TextEditingController();
  final _mcc = TextEditingController();
  final _mnc = TextEditingController();
  final _lac = TextEditingController();
  final _cell = TextEditingController();
  bool _fourG = false;
  bool _mobileOnly = false;
  bool _autoStart = true;
  bool _dirty = false;
  Map<String, dynamic>? _shown;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    for (final c in [_host, _port, _imei, _interval, _heartbeat, _corner, _mcc, _mnc, _lac, _cell]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Atualiza os campos quando a configuração muda fora da tela (ex.: comando TIMER do servidor).
  void _sync() {
    final c = widget.controller.config;
    final m = c.toMap();
    if (_dirty || (_shown != null && _sameSettings(_shown!, m))) return;
    _shown = m;
    _host.text = c.host;
    _port.text = '${c.port}';
    _imei.text = c.imei;
    _interval.text = '${c.intervalSec}';
    _heartbeat.text = '${c.heartbeatSec}';
    _corner.text = '${c.cornerDeg}';
    _mcc.text = '${c.mcc}';
    _mnc.text = '${c.mnc}';
    _lac.text = '${c.lac}';
    _cell.text = '${c.cellId}';
    _fourG = c.fourGPacket;
    _mobileOnly = c.mobileOnly;
    _autoStart = c.autoStart;
    if (mounted) setState(() {});
  }

  static bool _sameSettings(Map<String, dynamic> a, Map<String, dynamic> b) {
    const keys = ['host', 'port', 'imei', 'intervalSec', 'heartbeatSec', 'cornerDeg', 'fourGPacket', 'mobileOnly',
      'autoStart', 'mcc', 'mnc', 'lac', 'cellId'];
    return keys.every((k) => a[k] == b[k]);
  }

  void _touch() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final cur = widget.controller.config;
    final c = TrackerConfig.fromMap({
      ...cur.toMap(),
      'host': _host.text.trim(),
      'port': int.parse(_port.text),
      'imei': _imei.text.trim(),
      'intervalSec': int.parse(_interval.text),
      'heartbeatSec': int.parse(_heartbeat.text),
      'cornerDeg': int.parse(_corner.text),
      'fourGPacket': _fourG,
      'mobileOnly': _mobileOnly,
      'autoStart': _autoStart,
      'mcc': int.parse(_mcc.text),
      'mnc': int.parse(_mnc.text),
      'lac': int.parse(_lac.text),
      'cellId': int.parse(_cell.text),
    });
    FocusScope.of(context).unfocus();
    _dirty = false;
    _shown = null;
    await widget.controller.saveConfig(c);
    _sync();
  }

  String? Function(String?) _int(int min, int max) => (v) {
        final n = int.tryParse(v ?? '');
        if (n == null || n < min || n > max) return 'Entre $min e $max';
        return null;
      };

  Widget _field(TextEditingController c, String label,
      {String? hint, String? suffix, String? Function(String?)? validator, bool number = true, Widget? action, IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: c,
        onChanged: (_) => _touch(),
        keyboardType: number ? TextInputType.number : TextInputType.url,
        inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixText: suffix,
          suffixIcon: action,
          prefixIcon: icon == null ? null : Icon(icon, size: 20),
        ),
        validator: validator,
      ),
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 0, 10),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _header('Servidor'),
          _field(_host, 'Servidor (IP ou domínio)',
              hint: 'ex.: rastreamento.suaempresa.com.br',
              number: false,
              icon: Icons.dns_outlined,
              validator: (v) => (v ?? '').trim().isEmpty ? 'Informe o servidor' : null),
          _field(_port, 'Porta', hint: '5023 (GT06 no Traccar)', icon: Icons.settings_ethernet, validator: _int(1, 65535)),
          _field(_imei, 'IMEI do rastreador',
              icon: Icons.memory,
              validator: (v) => TrackerConfig.isValidImei(v ?? '') ? null : 'O IMEI deve ter 15 dígitos',
              action: IconButton(
                tooltip: 'Gerar novo IMEI',
                icon: const Icon(Icons.casino_outlined),
                onPressed: () {
                  _imei.text = TrackerConfig.randomImei();
                  _touch();
                },
              )),
          _header('Leituras de GPS'),
          _field(_interval, 'Tempo entre leituras de GPS',
              suffix: 'segundos', icon: Icons.timer_outlined, validator: _int(5, 18000)),
          _field(_heartbeat, 'Heartbeat (pacote de status)',
              suffix: 'segundos', icon: Icons.favorite_outline, validator: _int(10, 18000)),
          _field(_corner, 'Envio extra em curvas',
              suffix: 'graus (0 = off)', icon: Icons.turn_right, validator: _int(0, 180)),
          _header('Pacote e rede'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Pacote de localização', style: t.textTheme.bodyLarge),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('0x22 padrão')),
                      ButtonSegment(value: true, label: Text('0xA0 4G')),
                    ],
                    selected: {_fourG},
                    onSelectionChanged: (s) => setState(() {
                      _fourG = s.first;
                      _dirty = true;
                    }),
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Transmitir só pela operadora'),
                  subtitle: const Text('No Wi-Fi as posições ficam na memória'),
                  value: _mobileOnly,
                  onChanged: (v) => setState(() {
                    _mobileOnly = v;
                    _dirty = true;
                  }),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Iniciar automaticamente'),
                  subtitle: const Text('Ao abrir o app e ao ligar o aparelho'),
                  value: _autoStart,
                  onChanged: (v) => setState(() {
                    _autoStart = v;
                    _dirty = true;
                  }),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          Theme(
            data: t.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              title: const Text('Avançado (dados LBS da célula)'),
              children: [
                Row(children: [
                  Expanded(child: _field(_mcc, 'MCC', validator: _int(0, 999))),
                  const SizedBox(width: 12),
                  Expanded(child: _field(_mnc, 'MNC', validator: _int(0, 999))),
                ]),
                Row(children: [
                  Expanded(child: _field(_lac, 'LAC', validator: _int(0, 0x7FFFFFFF))),
                  const SizedBox(width: 12),
                  Expanded(child: _field(_cell, 'Cell ID', validator: _int(0, 0x7FFFFFFF))),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_dirty ? 'Salvar alterações' : 'Salvar', style: const TextStyle(fontSize: 16)),
              style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Protocolo GT06 (Concox), o mesmo do J16 4G. Cadastre o IMEI acima na sua plataforma '
            '(no Traccar use a porta 5023).',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
