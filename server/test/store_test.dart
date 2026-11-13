import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:kasher_server/src/store.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String path;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('kasher-schema-');
    path = temp.path + Platform.pathSeparator + 'branch.sqlite3';
  });
  tearDown(() {
    if(temp.existsSync()) temp.deleteSync(recursive:true);
  });

  test('initial migration and reopen are idempotent', () {
    final first=DatabaseStore.open(path);
    expect(first.first('SELECT MAX(version) AS v FROM schema_version')?['v'], 1);
    expect(first.first("SELECT name FROM sqlite_master WHERE name='products'")?['name'], 'products');
    first.dispose();
    final second=DatabaseStore.open(path);
    expect(second.first('SELECT COUNT(*) AS n FROM schema_version')?['n'], 1);
    second.dispose();
  });

  test('newer schema is refused without downgrading data', () {
    final raw=sqlite3.open(path);
    raw.execute('CREATE TABLE schema_version(version INTEGER PRIMARY KEY)');
    raw.execute('INSERT INTO schema_version(version) VALUES(99)');
    raw.execute('CREATE TABLE future_feature(secret TEXT)');
    raw.execute("INSERT INTO future_feature(secret) VALUES('preserve me')");
    raw.dispose();

    expect(() => DatabaseStore.open(path), throwsStateError);
    // Reopening read-only proves rollback was effective and locks released.
    final verify=sqlite3.open(path);
    try {
      expect(verify.select('SELECT version FROM schema_version').first['version'],99);
      expect(verify.select('SELECT secret FROM future_feature').first['secret'],'preserve me');
      expect(verify.select("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='products'")
        .first['n'],0);
    } finally {
      verify.dispose();
    }
  });
}