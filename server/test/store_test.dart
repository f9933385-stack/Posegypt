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
    expect(first.first('SELECT MAX(version) AS v FROM schema_version')?['v'], 16);
    expect(first.first("SELECT name FROM sqlite_master WHERE name='products'")?['name'], 'products');
    first.dispose();
    final second=DatabaseStore.open(path);
    expect(second.first('SELECT COUNT(*) AS n FROM schema_version')?['n'], 16);
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
      expect(migrated.first('SELECT MAX(version) AS v FROM schema_version')?['v'],16);
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
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='device_licenses'")?['name'],'device_licenses');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='login_attempt_limits'")?['name'],'login_attempt_limits');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='debt_allocations'")?['name'],'debt_allocations');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='debt_allocation_lines'")?['name'],'debt_allocation_lines');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='debt_reconciliations'")?['name'],'debt_reconciliations');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='debt_reconciliation_lines'")?['name'],'debt_reconciliation_lines');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='debt_credit_allocations'")?['name'],'debt_credit_allocations');
      expect(migrated.first("SELECT name FROM sqlite_master WHERE name='license_clock_guards'")?['name'],'license_clock_guards');
      expect(migrated.rows('PRAGMA table_info(sessions)').any((x)=>x['name']=='device_id'),isTrue);
    } finally {
      migrated.dispose();
    }
  });

  test('v11 invoice payment allocations survive additive v12 migration', () {
    final raw=sqlite3.open(path);
    try {
      raw.execute('PRAGMA foreign_keys=ON');
      for(final migration in [
        schemaV1,schemaV2,schemaV3,schemaV4,schemaV5,schemaV6,
        schemaV7,schemaV8,schemaV9,schemaV10,schemaV11
      ]) {
        for(final sql in migration) {raw.execute(sql);}
      }
      raw.execute('CREATE TABLE schema_version(version INTEGER PRIMARY KEY)');
      for(var version=1;version<=11;version++) {
        raw.execute('INSERT INTO schema_version(version) VALUES(?)',[version]);
      }
      raw.execute("INSERT INTO tenants(id,name,created_at) VALUES('T','Tenant','now')");
      raw.execute("INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES('B','T','BR01','Main','now')");
      raw.execute("INSERT INTO warehouses(id,branch_id,name,is_default) VALUES('W','B','Main',1)");
      raw.execute("INSERT INTO users(id,tenant_id,branch_id,username,password_salt,password_hash,role,created_at) VALUES('U','T','B','admin','salt','hash','owner','now')");
      raw.execute("INSERT INTO suppliers(id,tenant_id,name,created_at) VALUES('S','T','Vendor','now')");
      raw.execute("""INSERT INTO documents(
        id,tenant_id,branch_id,warehouse_id,kind,number,party_id,
        subtotal_minor,discount_minor,tax_minor,total_minor,paid_minor,
        cost_minor,snapshot_json,created_by,created_at)
        VALUES('D','T','B','W','purchase','PUR-001','S',
          500,0,0,500,0,500,'{}','U','now')""");
      raw.execute("""INSERT INTO payments(
        id,branch_id,party_id,method,direction,amount_minor,created_at)
        VALUES('PAY','B','S','cash','out',100,'now')""");
      raw.execute("""INSERT INTO debt_allocations(
        id,payment_id,document_id,branch_id,party_id,party_type,
        amount_minor,created_at)
        VALUES('ALLOC','PAY','D','B','S','supplier',100,'now')""");
    } finally {raw.dispose();}
    final upgraded=DatabaseStore.open(path);
    try {
      expect(upgraded.first('SELECT MAX(version) AS v FROM schema_version')?['v'],16);
      expect(upgraded.first("SELECT amount_minor FROM debt_allocations WHERE id='ALLOC'")?['amount_minor'],100);
      expect(upgraded.first("SELECT amount_minor FROM payments WHERE id='PAY'")?['amount_minor'],100);
      expect(upgraded.first("SELECT name FROM sqlite_master WHERE name='debt_allocation_lines'")?['name'],
        'debt_allocation_lines');
      expect(upgraded.rows('PRAGMA foreign_key_check'),isEmpty);
    } finally {upgraded.dispose();}
  });

  test('v12 distributed payments survive v13/v14 migrations with original journal', () {
    final raw=sqlite3.open(path);
    try {
      raw.execute('PRAGMA foreign_keys=ON');
      for(final migration in [
        schemaV1,schemaV2,schemaV3,schemaV4,schemaV5,schemaV6,
        schemaV7,schemaV8,schemaV9,schemaV10,schemaV11,schemaV12
      ]) {
        for(final statement in migration) {raw.execute(statement);}
      }
      raw.execute('CREATE TABLE schema_version(version INTEGER PRIMARY KEY)');
      for(var version=1;version<=12;version++) {
        raw.execute('INSERT INTO schema_version(version) VALUES(?)',[version]);
      }
      raw.execute("INSERT INTO tenants(id,name,created_at) VALUES('T','Tenant','now')");
      raw.execute("INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES('B','T','BR01','Branch','now')");
      raw.execute("INSERT INTO warehouses(id,branch_id,name,is_default) VALUES('W','B','Main',1)");
      raw.execute("INSERT INTO users(id,tenant_id,branch_id,username,password_salt,password_hash,role,created_at) VALUES('U','T','B','admin','salt','hash','owner','now')");
      raw.execute("INSERT INTO suppliers(id,tenant_id,name,created_at) VALUES('S','T','Vendor','now')");
      for(final doc in ['D1','D2']) {
        raw.execute("""INSERT INTO documents(
          id,tenant_id,branch_id,warehouse_id,kind,number,party_id,
          subtotal_minor,discount_minor,tax_minor,total_minor,paid_minor,
          cost_minor,snapshot_json,created_by,created_at)
          VALUES(?,'T','B','W','purchase',?,'S',500,0,0,500,0,500,'{}','U','now')""",
          [doc,doc]);
      }
      raw.execute("""INSERT INTO payments(
        id,branch_id,party_id,method,direction,amount_minor,created_at)
        VALUES('PAY','B','S','cash','out',300,'now')""");
      for(final item in [
        ['LINE1','D1',100],['LINE2','D2',200]
      ]) {
        raw.execute("""INSERT INTO debt_allocation_lines(
          id,payment_id,document_id,branch_id,party_id,party_type,
          amount_minor,created_at)
          VALUES(?,'PAY',?,'B','S','supplier',?,'now')""",item);
      }
      raw.execute("""INSERT INTO journal_entries(
        id,branch_id,reference_type,reference_id,created_by,created_at)
        VALUES('J','B','out','PAY','U','now')""");
      raw.execute("""INSERT INTO journal_lines(
        id,entry_id,account,debit_minor,credit_minor)
        VALUES('L1','J','AP:S',300,0)""");
      raw.execute("""INSERT INTO journal_lines(
        id,entry_id,account,debit_minor,credit_minor)
        VALUES('L2','J','CASH',0,300)""");
    }finally{raw.dispose();}
    final upgraded=DatabaseStore.open(path);
    try {
      expect(upgraded.first('SELECT MAX(version) AS v FROM schema_version')?['v'],16);
      expect(upgraded.first("SELECT amount_minor FROM payments WHERE id='PAY'")?['amount_minor'],300);
      expect(upgraded.first("SELECT COUNT(*) AS n FROM debt_allocation_lines WHERE payment_id='PAY'")?['n'],2);
      expect(upgraded.first("SELECT SUM(amount_minor) AS total FROM debt_allocation_lines WHERE payment_id='PAY'")?['total'],300);
      expect(upgraded.first("SELECT SUM(debit_minor-credit_minor) AS balance FROM journal_lines WHERE entry_id='J'")?['balance'],0);
      expect(upgraded.first("SELECT name FROM sqlite_master WHERE name='debt_reconciliations'")?['name'],
        'debt_reconciliations');
      expect(upgraded.first("SELECT name FROM sqlite_master WHERE name='debt_credit_allocations'")?['name'],
        'debt_credit_allocations');
      expect(upgraded.rows('PRAGMA foreign_key_check'),isEmpty);
    }finally{upgraded.dispose();}
  });

  test('v13 migration backfills return credit to original invoice and preserves excess', () {
    final raw=sqlite3.open(path);
    try {
      raw.execute('PRAGMA foreign_keys=ON');
      for(final migration in [
        schemaV1,schemaV2,schemaV3,schemaV4,schemaV5,schemaV6,
        schemaV7,schemaV8,schemaV9,schemaV10,schemaV11,schemaV12,schemaV13
      ]) {
        for(final statement in migration) {raw.execute(statement);}
      }
      raw.execute('CREATE TABLE schema_version(version INTEGER PRIMARY KEY)');
      for(var version=1;version<=13;version++) {
        raw.execute('INSERT INTO schema_version(version) VALUES(?)',[version]);
      }
      raw.execute("INSERT INTO tenants(id,name,created_at) VALUES('T','Tenant','now')");
      raw.execute("INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES('B','T','BR01','Branch','now')");
      raw.execute("INSERT INTO warehouses(id,branch_id,name,is_default) VALUES('W','B','Main',1)");
      raw.execute("""INSERT INTO users(id,tenant_id,branch_id,username,password_salt,password_hash,role,created_at)
        VALUES('U','T','B','admin','salt','hash','owner','now')""");
      raw.execute("INSERT INTO customers(id,tenant_id,name,created_at) VALUES('C','T','Customer','now')");
      raw.execute("""INSERT INTO documents(
        id,tenant_id,branch_id,warehouse_id,kind,number,party_id,
        subtotal_minor,discount_minor,tax_minor,total_minor,paid_minor,
        cost_minor,snapshot_json,created_by,created_at)
        VALUES('SALE','T','B','W','sale','SAL-001','C',
          1000,0,0,1000,800,0,'{}','U','2026-01-01')""");
      raw.execute("""INSERT INTO documents(
        id,tenant_id,branch_id,warehouse_id,kind,number,party_id,original_id,
        subtotal_minor,discount_minor,tax_minor,total_minor,paid_minor,
        cost_minor,snapshot_json,created_by,created_at)
        VALUES('RET1','T','B','W','sale_return','RET-001','C','SALE',
          500,0,0,500,0,0,'{"refund_method":"credit"}','U','2026-01-02')""");
      raw.execute("""INSERT INTO documents(
        id,tenant_id,branch_id,warehouse_id,kind,number,party_id,original_id,
        subtotal_minor,discount_minor,tax_minor,total_minor,paid_minor,
        cost_minor,snapshot_json,created_by,created_at)
        VALUES('RET2','T','B','W','sale_return','RET-002','C','SALE',
          200,0,0,200,0,0,'{"refund_method":"credit"}','U','2026-01-03')""");
      raw.execute("""INSERT INTO payments(
        id,branch_id,party_id,method,direction,amount_minor,created_at)
        VALUES('PAY','B','C','cash','in',100,'2026-01-01')""");
      raw.execute("""INSERT INTO debt_allocations(
        id,payment_id,document_id,branch_id,party_id,party_type,amount_minor,created_at)
        VALUES('PAYALLOC','PAY','SALE','B','C','customer',100,'2026-01-01')""");
    }finally{raw.dispose();}
    final upgraded=DatabaseStore.open(path);
    try {
      expect(upgraded.first('SELECT MAX(version) AS v FROM schema_version')?['v'],16);
      expect(upgraded.first("""SELECT amount_minor FROM debt_credit_allocations
        WHERE credit_document_id='RET1' AND document_id='SALE'""")?['amount_minor'],100);
      expect(upgraded.first("""SELECT COUNT(*) AS n FROM debt_credit_allocations
        WHERE credit_document_id='RET2'""")?['n'],0);
      final available1=(upgraded.first("""SELECT d.total_minor-
        COALESCE((SELECT SUM(a.amount_minor) FROM debt_credit_allocations a
          WHERE a.credit_document_id=d.id),0) AS available
        FROM documents d WHERE d.id='RET1'""")!['available'] as int);
      final available2=(upgraded.first("""SELECT d.total_minor-
        COALESCE((SELECT SUM(a.amount_minor) FROM debt_credit_allocations a
          WHERE a.credit_document_id=d.id),0) AS available
        FROM documents d WHERE d.id='RET2'""")!['available'] as int);
      expect(available1,400);
      expect(available2,200);
      expect(upgraded.first("SELECT amount_minor FROM payments WHERE id='PAY'")?['amount_minor'],100);
      expect(upgraded.first("SELECT amount_minor FROM debt_allocations WHERE id='PAYALLOC'")?['amount_minor'],100);
      expect(upgraded.rows('PRAGMA foreign_key_check'),isEmpty);
    }finally{upgraded.dispose();}
    final reopened=DatabaseStore.open(path);
    try {
      expect(reopened.first("SELECT COUNT(*) AS n FROM debt_credit_allocations")?['n'],1);
    }finally{reopened.dispose();}
  });

  test('v14 shared shift and financial journal survive v15/v16 migrations',(){
    final raw=sqlite3.open(path);
    try {
      raw.execute('PRAGMA foreign_keys=ON');
      for(final migration in [
        schemaV1,schemaV2,schemaV3,schemaV4,schemaV5,schemaV6,
        schemaV7,schemaV8,schemaV9,schemaV10,schemaV11,
        schemaV12,schemaV13,schemaV14
      ]) {
        for(final statement in migration){raw.execute(statement);}
      }
      raw.execute('CREATE TABLE schema_version(version INTEGER PRIMARY KEY)');
      for(var v=1;v<=14;v++){
        raw.execute('INSERT INTO schema_version(version) VALUES(?)',[v]);
      }
      raw.execute("INSERT INTO tenants(id,name,created_at) VALUES('T','Original','now')");
      raw.execute("INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES('B','T','BR01','Branch','now')");
      raw.execute("INSERT INTO warehouses(id,branch_id,name,is_default) VALUES('W','B','Main',1)");
      raw.execute("INSERT INTO users(id,tenant_id,branch_id,username,password_salt,password_hash,role,created_at) VALUES('U','T','B','owner','s','h','owner','now')");
      raw.execute("INSERT INTO cash_shifts(id,branch_id,user_id,opening_minor,opened_at) VALUES('SHIFT','B','U',1000,'2026-01-01')");
      raw.execute("INSERT INTO journal_entries(id,branch_id,reference_type,reference_id,created_by,created_at) VALUES('J','B','sale','DOC','U','2026-01-01')");
      raw.execute("INSERT INTO journal_lines(id,entry_id,account,debit_minor,credit_minor) VALUES('L1','J','CASH',200,0)");
      raw.execute("INSERT INTO journal_lines(id,entry_id,account,debit_minor,credit_minor) VALUES('L2','J','SALES_REVENUE',0,200)");
    }finally{raw.dispose();}
    final upgraded=DatabaseStore.open(path);
    try {
      expect(upgraded.first('SELECT MAX(version) AS v FROM schema_version')?['v'],16);
      expect(upgraded.first("SELECT drawer_id FROM cash_shifts WHERE id='SHIFT'")?['drawer_id'],null);
      expect(upgraded.first("SELECT opening_minor FROM cash_shifts WHERE id='SHIFT'")?['opening_minor'],1000);
      expect(upgraded.first("SELECT SUM(debit_minor-credit_minor) AS n FROM journal_lines WHERE entry_id='J'")?['n'],0);
      expect(upgraded.first("SELECT COUNT(*) AS n FROM cash_shift_journal_links")?['n'],0);
      expect(upgraded.rows('PRAGMA foreign_key_check'),isEmpty);
    }finally{upgraded.dispose();}
    final again=DatabaseStore.open(path);
    try {
      expect(again.first('SELECT COUNT(*) AS n FROM schema_version')?['n'],16);
      expect(again.first("SELECT COUNT(*) AS n FROM cash_drawers")?['n'],0);
    }finally{again.dispose();}
  });

  test('v15 independent drawer, linked cash journals and shift counts survive v16',(){
    final raw=sqlite3.open(path);
    try {
      raw.execute('PRAGMA foreign_keys=ON');
      for(final migration in [
        schemaV1,schemaV2,schemaV3,schemaV4,schemaV5,schemaV6,
        schemaV7,schemaV8,schemaV9,schemaV10,schemaV11,
        schemaV12,schemaV13,schemaV14,schemaV15
      ]) {
        for(final sql in migration){raw.execute(sql);}
      }
      raw.execute('CREATE TABLE schema_version(version INTEGER PRIMARY KEY)');
      for(var v=1;v<=15;v++){
        raw.execute('INSERT INTO schema_version(version) VALUES(?)',[v]);
      }
      raw.execute("INSERT INTO tenants(id,name,created_at) VALUES('T','Original','2026-01-01')");
      raw.execute("INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES('B','T','BR01','Branch','2026-01-01')");
      raw.execute("INSERT INTO users(id,tenant_id,branch_id,username,password_salt,password_hash,role,created_at) VALUES('U','T','B','first','s','h','cashier','2026-01-01')");
      raw.execute("INSERT INTO users(id,tenant_id,branch_id,username,password_salt,password_hash,role,created_at) VALUES('V','T','B','second','s','h','cashier','2026-01-01')");
      raw.execute("INSERT INTO cash_drawers(id,branch_id,name,created_by,created_at) VALUES('D1','B','first drawer','U','2026-01-01')");
      raw.execute("INSERT INTO cash_drawers(id,branch_id,name,created_by,created_at) VALUES('D2','B','second drawer','V','2026-01-01')");
      raw.execute("""INSERT INTO cash_shifts(id,branch_id,user_id,drawer_id,
        opening_minor,opened_at) VALUES('S1','B','U','D1',500,'2026-01-01')""");
      raw.execute("""INSERT INTO cash_shifts(id,branch_id,user_id,drawer_id,
        opening_minor,opened_at) VALUES('S2','B','V','D2',700,'2026-01-01')""");
      raw.execute("""INSERT INTO journal_entries(
        id,branch_id,reference_type,reference_id,created_by,created_at)
        VALUES('J1','B','sale','DOC','U','2026-01-01')""");
      raw.execute("INSERT INTO journal_lines(id,entry_id,account,debit_minor,credit_minor) VALUES('L1','J1','CASH',250,0)");
      raw.execute("INSERT INTO journal_lines(id,entry_id,account,debit_minor,credit_minor) VALUES('L2','J1','SALES_REVENUE',0,250)");
      raw.execute("""INSERT INTO cash_shift_journal_links(
        journal_entry_id,shift_id,cash_delta_minor,created_at)
        VALUES('J1','S1',250,'2026-01-01')""");
    }finally{raw.dispose();}
    final upgraded=DatabaseStore.open(path);
    try {
      expect(upgraded.first('SELECT MAX(version) AS v FROM schema_version')?['v'],16);
      expect(upgraded.first("SELECT COUNT(*) AS total FROM cash_drawers")?['total'],2);
      expect(upgraded.first("SELECT drawer_id FROM cash_shifts WHERE id='S1'")?['drawer_id'],'D1');
      expect(upgraded.first("SELECT drawer_id FROM cash_shifts WHERE id='S2'")?['drawer_id'],'D2');
      expect(upgraded.first("SELECT cash_delta_minor FROM cash_shift_journal_links WHERE journal_entry_id='J1'")?['cash_delta_minor'],250);
      expect(upgraded.first("SELECT COUNT(*) AS n FROM cash_drawer_transfers")?['n'],0);
      expect(upgraded.first("SELECT SUM(debit_minor-credit_minor) AS net FROM journal_lines WHERE entry_id='J1'")?['net'],0);
      expect(upgraded.rows('PRAGMA foreign_key_check'),isEmpty);
    }finally{upgraded.dispose();}
    final reopened=DatabaseStore.open(path);
    try {
      expect(reopened.first("SELECT COUNT(*) AS n FROM schema_version")?['n'],16);
      expect(reopened.first("SELECT COUNT(*) AS n FROM cash_drawer_transfers")?['n'],0);
    }finally{reopened.dispose();}
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