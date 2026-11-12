import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'schema.dart';

class DatabaseStore {
  final Database db;
  DatabaseStore._(this.db);

  factory DatabaseStore.open(String filePath) {
    final file = File(filePath);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    final db = sqlite3.open(filePath);
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA busy_timeout=5000');
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY)');
      final ver = db.select('SELECT MAX(version) AS version FROM schema_version').first['version'] as int? ?? 0;
      if (ver < 1) {
        for (final stmt in schemaV1) { db.execute(stmt); }
        db.execute('INSERT INTO schema_version(version) VALUES(1)');
      }
      db.execute('COMMIT');
    } catch (_) { db.execute('ROLLBACK'); rethrow; }
    return DatabaseStore._(db);
  }

  factory DatabaseStore.memory() {
    final db = sqlite3.openInMemory();
    db.execute('PRAGMA foreign_keys=ON');
    for (final stmt in schemaV1) { db.execute(stmt); }
    return DatabaseStore._(db);
  }

  T transaction<T>(T Function() callback) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = callback();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Map<String, Object?>? first(String sql, [List<Object?> args = const []]) {
    final rows = db.select(sql, args);
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  List<Map<String, Object?>> rows(String sql, [List<Object?> args = const []]) =>
    db.select(sql, args).map((r) => Map<String, Object?>.from(r)).toList();

  void exec(String sql, [List<Object?> args = const []]) => db.execute(sql, args);
  void dispose() => db.dispose();
}
