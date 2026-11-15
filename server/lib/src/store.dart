import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'schema.dart';

class DatabaseStore {
  final Database db;
  DatabaseStore._(this.db);

  /// Preserve historical credit-note reductions when upgrading v13.
  /// The excess amount remains an unapplied credit note.
  static void _backfillLegacyCreditNotes(Database db) {
    final returns=db.select('''SELECT id,tenant_id,branch_id,party_id,kind,
      original_id,total_minor,created_at,created_by,snapshot_json
      FROM documents WHERE state='posted'
        AND kind IN ('sale_return','purchase_return')
      ORDER BY branch_id,party_id,original_id,created_at,id''');
    for(final row in returns) {
      final snapshot=jsonDecode(row['snapshot_json'] as String);
      if(snapshot is! Map) throw StateError('Invalid return snapshot during v14 migration');
      if(snapshot['refund_method']!='credit') continue;
      final originalId=row['original_id'] as String?;
      if(originalId==null) continue;
      final expectedKind=row['kind']=='sale_return'?'sale':'purchase';
      final originals=db.select('''SELECT id,total_minor,paid_minor
        FROM documents WHERE id=? AND tenant_id=? AND branch_id=?
          AND party_id=? AND kind=? AND state='posted' ''',
        [originalId,row['tenant_id'],row['branch_id'],row['party_id'],expectedKind]);
      if(originals.isEmpty) continue;
      final original=originals.first;
      final linked=db.select('''SELECT
        (SELECT COALESCE(SUM(amount_minor),0) FROM debt_allocations WHERE document_id=?) +
        (SELECT COALESCE(SUM(amount_minor),0) FROM debt_allocation_lines WHERE document_id=?) AS total
        ''',[originalId,originalId]).first['total'] as int;
      final previouslyApplied=db.select('''SELECT COALESCE(SUM(amount_minor),0) AS total
        FROM debt_credit_allocations WHERE document_id=?''',[originalId]).first['total'] as int;
      final due=(original['total_minor'] as int)-(original['paid_minor'] as int)-linked-previouslyApplied;
      final returnTotal=row['total_minor'] as int;
      final applied=due>0?(returnTotal<due?returnTotal:due):0;
      if(applied>0) {
        db.execute('''INSERT INTO debt_credit_allocations(
          id,credit_document_id,document_id,branch_id,party_id,party_type,
          amount_minor,reason,created_by,created_at)
          VALUES(?,?,?,?,?,?,?,'v14 migration: preserve original invoice credit',?,?)''',
          ['v14-'+(row['id'] as String),row['id'],originalId,row['branch_id'],
            row['party_id'],row['kind']=='sale_return'?'customer':'supplier',
            applied,row['created_by'],row['created_at']]);
      }
    }
  }

  factory DatabaseStore.open(String filePath) {
    final file = File(filePath);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    final db = sqlite3.open(filePath);
    try {
      db.execute('PRAGMA foreign_keys=ON');
      db.execute('PRAGMA busy_timeout=5000');
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute('CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY)');
        final ver = db.select('SELECT MAX(version) AS version FROM schema_version').first['version'] as int? ?? 0;
        // Never downgrade/migrate a database created by newer application code.
        // A silent open could corrupt future schema or financial records.
        if (ver > 15) throw StateError('Database schema $ver is newer than supported schema 15');
        if (ver < 1) {
          for (final stmt in schemaV1) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(1)');
        }
        if (ver < 2) {
          for (final stmt in schemaV2) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(2)');
        }
        if (ver < 3) {
          for (final stmt in schemaV3) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(3)');
        }
        if (ver < 4) {
          for (final stmt in schemaV4) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(4)');
        }
        if (ver < 5) {
          for (final stmt in schemaV5) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(5)');
        }
        if (ver < 6) {
          for (final stmt in schemaV6) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(6)');
        }
        if (ver < 7) {
          for (final stmt in schemaV7) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(7)');
        }
        if (ver < 8) {
          for (final stmt in schemaV8) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(8)');
        }
        if (ver < 9) {
          for (final stmt in schemaV9) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(9)');
        }
        if (ver < 10) {
          for (final stmt in schemaV10) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(10)');
        }
        if (ver < 11) {
          for (final stmt in schemaV11) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(11)');
        }
        if (ver < 12) {
          for (final stmt in schemaV12) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(12)');
        }
        if (ver < 13) {
          for (final stmt in schemaV13) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(13)');
        }
        if (ver < 14) {
          for (final stmt in schemaV14) { db.execute(stmt); }
          _backfillLegacyCreditNotes(db);
          db.execute('INSERT INTO schema_version(version) VALUES(14)');
        }
        if (ver < 15) {
          for (final stmt in schemaV15) { db.execute(stmt); }
          db.execute('INSERT INTO schema_version(version) VALUES(15)');
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
      return DatabaseStore._(db);
    } catch (_) {
      db.dispose(); // No leaked file handles / WAL locks on migration failure.
      rethrow;
    }
  }

  factory DatabaseStore.memory() {
    final db = sqlite3.openInMemory();
    db.execute('PRAGMA foreign_keys=ON');
    for (final stmt in schemaV1) { db.execute(stmt); }
    for (final stmt in schemaV2) { db.execute(stmt); }
    for (final stmt in schemaV3) { db.execute(stmt); }
    for (final stmt in schemaV4) { db.execute(stmt); }
    for (final stmt in schemaV5) { db.execute(stmt); }
    for (final stmt in schemaV6) { db.execute(stmt); }
    for (final stmt in schemaV7) { db.execute(stmt); }
    for (final stmt in schemaV8) { db.execute(stmt); }
    for (final stmt in schemaV9) { db.execute(stmt); }
    for (final stmt in schemaV10) { db.execute(stmt); }
    for (final stmt in schemaV11) { db.execute(stmt); }
    for (final stmt in schemaV12) { db.execute(stmt); }
    for (final stmt in schemaV13) { db.execute(stmt); }
    for (final stmt in schemaV14) { db.execute(stmt); }
    for (final stmt in schemaV15) { db.execute(stmt); }
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
