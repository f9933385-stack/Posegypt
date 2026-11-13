import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:kasher_server/src/store.dart';
import 'package:kasher_server/src/schema.dart';
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
    expect(first.first('SELECT MAX(version) AS v FROM schema_version')?['v'], 8);
    expect(first.first("SELECT name FROM sqlite_master WHERE name='products'")?['name'], 'products');
    first.dispose();
    final second=DatabaseStore.open(path);
    expect(second.first('SELECT COUNT(*) AS n FROM schema_version')?['n'], 8);
    second.dispose();
  });

  test('existing v1 financial data migrates additively to v2', () {
    final raw=sqlite3.open(path);
    try {
      raw.execute('PRAGMA foreign_keys=ON');
      for(final sql in schemaV1) {raw.execute(sql);}
      raw.execute('CREATE TABLE schema_version(version INTEGER PRIMARY KEY)');
      raw.execute('INSERT INTO schema_version(version) VALUES(1)');
      raw.execute("INSERT INTO tenants(id,name,created_at) VALUES('T','Existing Store','old')");
      raw.execute("INSERT INTO products(id,tenant_id,sku,name_ar,sell_price_minor,created_at,updated_at) VALUES('P','T','P01','Old Product',500,'old','old')");
    } finally {
      raw.dispose();
    }
    final migrated=DatabaseStore.open(path);
    try {
      expect(migrated.first('SELECT MAX(version) AS v FROM schema_version')?['v'],8);
      expect(migrated.first("SELECT name_ar FROM products WHERE id='P'")?['name_ar'],'Old Product');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='product_units'")?['name'],
        'product_units');
      final columns=migrated.rows('PRAGMA table_info(document_lines)');
      expect(columns.any((x)=>x['name']=='gross_minor'),isTrue);
      expect(columns.any((x)=>x['name']=='unit_id'),isTrue);
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='batch_movements'")?['name'],'batch_movements');
      expect(migrated.rows('PRAGMA table_info(batches)').any((x)=>x['name']=='quarantined'),isTrue);
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='stock_counts'")?['name'],'stock_counts');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='price_promotions'")?['name'],'price_promotions');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='branch_shipments'")?['name'],'branch_shipments');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='branch_shipment_lots'")?['name'],'branch_shipment_lots');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='registered_devices'")?['name'],'registered_devices');
      expect(migrated.rows('PRAGMA table_info(sessions)').any((x)=>x['name']=='device_id'),isTrue);
    } finally {
      migrated.dispose();
    }
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