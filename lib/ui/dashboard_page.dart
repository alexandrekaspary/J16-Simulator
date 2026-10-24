import 'package:flutter/material.dart';

import '../tracker/controller.dart';
import 'theme.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.controller});
  final TrackerController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final c = controller;
          final s = c.status;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _ConnectionCard(c: c),
              const SizedBox(height: 12),
              _GpsCard(s: s),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _Counter(label: 'Enviados', value: '${s['sent'] ?? 0}', icon: Icons.cloud_done_outlined)),
                const SizedBox(width: 12),
                Expanded(
                    child: _Counter(
                        label: 'Na memória',
                        value: '${s['queued'] ?? 0}',
                        icon: Icons.sd_storage_outlined,
                        highlight: (s['queued'] ?? 0) as int > 0)),
                const SizedBox(width: 12),
                Expanded(child: _Counter(label: 'Último envio', value: _ago(s['lastTx']), icon: Icons.schedule)),
              ]),
              const SizedBox(height: 20),
              _StartButton(c: c),
              const SizedBox(height: 10),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: c.running ? c.sendNow : null,
                  icon: const Icon(Icons.my_location, size: 18),
                  label: const Text('Enviar posição agora'),
                  style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                ),
              ),
            ],
          );
        },
      );

  static String _ago(Object? ms) {
    if (ms is! int) return '—';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}min';
    return '${d.inHours}h';
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(title.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.1, fontWeight: FontWeight.w700, color: t.colorScheme.onSurfaceVariant)),
            ),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 12),
          child,
        ]),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.c});
  final TrackerController c;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = c.status;
    final conn = c.running ? (s['conn'] as String? ?? 'connecting') : 'stopped';
    final (label, color, icon) = switch (conn) {
      'online' => ('Online', okGreen, Icons.cloud_done),
      'waiting_network' => ('Sem rede • gravando na memória', errRed, Icons.signal_cellular_off),
      'not_configured' => ('Configure o servidor', warnAmber, Icons.settings),
      'stopped' => ('Parado', t.colorScheme.outline, Icons.pause_circle_outline),
      'login' => ('Fazendo login...', warnAmber, Icons.login),
      _ => ('Conectando...', warnAmber, Icons.sync),
    };
    final cfg = c.config;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: color)),
                const SizedBox(height: 2),
                Text(
                  cfg.host.isEmpty ? 'Servidor não configurado' : '${cfg.host}:${cfg.port}',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
          ]),
          const Divider(height: 28),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _Chip(icon: Icons.memory, text: 'IMEI ${cfg.imei}'),
            _Chip(icon: Icons.network_cell, text: '${s['network'] ?? '—'}'),
            _Chip(icon: Icons.inventory_2_outlined, text: cfg.fourGPacket ? 'GT06 0xA0 (4G)' : 'GT06 0x22'),
            _Chip(icon: Icons.timer_outlined, text: '${cfg.intervalSec}s'),
          ]),
          if (c.running && s['error'] != null && conn != 'online' && conn != 'waiting_network') ...[
            const SizedBox(height: 10),
            Text('${s['error']}', style: t.textTheme.bodySmall?.copyWith(color: errRed)),
          ],
        ]),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: t.colorScheme.primary),
        const SizedBox(width: 6),
        Text(text, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary)),
      ]),
    );
  }
}

class _GpsCard extends StatelessWidget {
  const _GpsCard({required this.s});
  final Map<String, dynamic> s;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fresh = s['gpsFresh'] == true;
    String n(Object? v, int d) => v is num ? v.toStringAsFixed(d) : '—';
    final course = s['course'];
    return _Section(
      title: 'GPS',
      trailing: Row(children: [
        Icon(Icons.circle, size: 9, color: fresh ? okGreen : warnAmber),
        const SizedBox(width: 6),
        Text(fresh ? 'Posição fixada' : (s['gpsError'] != null ? 'GPS indisponível' : 'Buscando sinal'),
            style: t.textTheme.labelMedium),
      ]),
      child: Column(children: [
        Row(children: [
          Expanded(child: _Value(label: 'Latitude', value: n(s['lat'], 6))),
          Expanded(child: _Value(label: 'Longitude', value: n(s['lon'], 6))),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _Value(label: 'Velocidade', value: '${n(s['speed'], 0)} km/h')),
          Expanded(
              child: _Value(label: 'Direção', value: course is num && course >= 0 ? '${course.round()}°' : '—')),
          Expanded(child: _Value(label: 'Precisão', value: '${n(s['accuracy'], 0)} m')),
        ]),
      ]),
    );
  }
}

class _Value extends StatelessWidget {
  const _Value({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 2),
      Text(value,
          style: t.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.label, required this.value, required this.icon, this.highlight = false});
  final String label;
  final String value;
  final IconData icon;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = highlight ? warnAmber : t.colorScheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 8),
          Text(value, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          Text(label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _StartButton extends StatelessWidget {
  const _StartButton({required this.c});
  final TrackerController c;

  @override
  Widget build(BuildContext context) {
    final running = c.running;
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed: c.busy ? null : (running ? c.stop : c.start),
        icon: Icon(running ? Icons.stop_circle_outlined : Icons.play_circle_outline),
        label: Text(running ? 'Parar rastreador' : 'Iniciar rastreador',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        style: FilledButton.styleFrom(
          backgroundColor: running ? errRed : brandBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }
}
