import 'package:flutter/material.dart';

import '../tracker/controller.dart';
import 'theme.dart';

class LogPage extends StatelessWidget {
  const LogPage({super.key, required this.controller});
  final TrackerController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final t = Theme.of(context);
          final items = controller.logs.reversed.toList();
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(children: [
                Text('${items.length} eventos', style: t.textTheme.labelLarge),
                const Spacer(),
                TextButton.icon(
                  onPressed: controller.running ? () => _confirmClear(context) : null,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: Text('Apagar memória (${controller.status['queued'] ?? 0})'),
                ),
              ]),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text('Os pacotes enviados e recebidos aparecem aqui.',
                          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (_, i) => _LogTile(e: items[i]),
                    ),
            ),
          ]);
        },
      );

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apagar memória interna?'),
        content: const Text('As posições ainda não transmitidas serão perdidas.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apagar')),
        ],
      ),
    );
    if (ok == true) controller.clearQueue();
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.e});
  final LogEntry e;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = e.message;
    final (tag, color) = m.startsWith('TX')
        ? ('TX', brandBlue)
        : m.startsWith('RX')
            ? ('RX', okGreen)
            : ('••', t.colorScheme.outline);
    final isPacket = tag != '••';
    final time = '${e.time.hour.toString().padLeft(2, '0')}:${e.time.minute.toString().padLeft(2, '0')}:'
        '${e.time.second.toString().padLeft(2, '0')}';
    final split = m.lastIndexOf(': ');
    var title = isPacket && split > 0 ? m.substring(2, split).trim() : m;
    if (title.isEmpty) title = 'Servidor';
    final body = isPacket && split > 0 ? m.substring(split + 2) : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 30,
            padding: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(6)),
            child: Text(tag,
                textAlign: TextAlign.center,
                style: t.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(title,
                        style: t.textTheme.bodyMedium?.copyWith(fontWeight: isPacket ? FontWeight.w600 : null))),
                const SizedBox(width: 8),
                Text(time, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ]),
              if (body != null) ...[
                const SizedBox(height: 4),
                SelectableText(body,
                    style: TextStyle(
                        fontFamily: 'monospace', fontSize: 11.5, height: 1.35, color: t.colorScheme.onSurfaceVariant)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
