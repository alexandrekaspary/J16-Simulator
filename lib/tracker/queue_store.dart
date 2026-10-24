import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../protocol/gt06.dart';

/// Registro guardado enquanto não há conexão com o servidor.
class QueuedRecord {
  final int id;
  final GpsFix fix;
  final int uploadMode;
  final int mileageMeters;

  QueuedRecord(this.id, this.fix, this.uploadMode, this.mileageMeters);
}

/// Memória interna (SQLite) para posições não transmitidas.
class QueueStore {
  static const _maxRows = 200000; // ~ 23 dias a cada 10 s
  Database? _db;

  Future<void> open() async {
    _db ??= await openDatabase(
      p.join(await getDatabasesPath(), 'j16_queue.db'),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          time INTEGER NOT NULL,
          lat REAL NOT NULL,
          lon REAL NOT NULL,
          speed REAL NOT NULL,
          course REAL NOT NULL,
          sats INTEGER NOT NULL,
          valid INTEGER NOT NULL,
          mode INTEGER NOT NULL DEFAULT 0,
          mileage INTEGER NOT NULL DEFAULT 0
        )'''),
    );
  }

  Database get _d => _db!;

  Future<void> add(GpsFix fix,
      {int uploadMode = 0, int mileageMeters = 0}) async {
    await _d.insert('queue', {
      ...fix.toMap(),
      'mode': uploadMode,
      'mileage': mileageMeters,
    });
    // Como no aparelho, quando a memória enche os registros mais antigos saem.
    final n = await count();
    if (n > _maxRows) {
      await _d.rawDelete(
          'DELETE FROM queue WHERE id IN (SELECT id FROM queue ORDER BY id LIMIT ?)', [n - _maxRows]);
    }
  }

  Future<List<QueuedRecord>> oldest(int limit) async {
    final rows = await _d.query('queue', orderBy: 'id', limit: limit);
    return rows
        .map((r) => QueuedRecord(
              r['id'] as int,
              GpsFix.fromMap(r),
              r['mode'] as int,
              r['mileage'] as int,
            ))
        .toList();
  }

  Future<void> remove(List<int> ids) async {
    if (ids.isEmpty) return;
    await _d.delete('queue', where: 'id IN (${List.filled(ids.length, '?').join(',')})', whereArgs: ids);
  }

  Future<int> count() async =>
      Sqflite.firstIntValue(await _d.rawQuery('SELECT COUNT(*) FROM queue')) ?? 0;

  Future<void> clear() => _d.delete('queue');

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
