import 'package:test/test.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late Principal owner;
  late String branch;
  var counter=0;
  String key()=> 'test-idempotency-key-${counter++}-random';
  Map<String,Object?> call(String action,Map<String,dynamic> body)=>engine.command(owner,action,body,key());
  setUp(() {
    store=DatabaseStore.memory();engine=PosEngine(store);
    final setup=engine.bootstrap('اختبار المتجر','الفرع الرئيسي','admin','correct-horse-12!');
    branch=setup['branch_id'] as String;
    owner=Principal(setup['user_id'] as String,setup['tenant_id'] as String,branch,'owner','admin');
  });
  tearDown(() => store.dispose());

  test('purchase, mixed sale, accounts and journal stay consistent', () {
    final product=call('create_product',{'sku':'A100','name_ar':'أرز','sell_price_minor':200});
    final supplier=call('create_supplier',{'name':'المورد'});
    final customer=call('create_customer',{'name':'العميل','credit_limit_minor':1000});
    final purchase=call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':10000,'unit_cost_minor':100}],
      'payments':[{'method':'cash','amount_minor':400}]});
    expect(purchase['total_minor'],1000);expect(purchase['due_minor'],600);
    final sales=call('sale',{'branch_id':branch,'customer_id':customer['id'],
      'lines':[{'product_id':product['id'],'qty_milli':3000}],
      'payments':[{'method':'cash','amount_minor':200}]});
    expect(sales['total_minor'],600);expect(sales['credit_minor'],400);
    expect(sales['cogs_minor'],300);
    final dash=engine.dashboard(owner,branch);
    expect(dash['stock_value_minor'],700);
    expect(dash['customer_receivables_minor'],400);
    expect(dash['supplier_payables_minor'],600);
    final imbalance=store.rows('''SELECT e.id, SUM(l.debit_minor-l.credit_minor) n
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      GROUP BY e.id HAVING n<>0''');
    expect(imbalance,isEmpty);
  });

  test('replaying same idempotency key does not duplicate stock', () {
    final p=call('create_product',{'sku':'B1','name_ar':'سكر','sell_price_minor':200});
    final s=call('create_supplier',{'name':'شركة'});
    final request={'branch_id':branch,'supplier_id':s['id'],
      'lines':[{'product_id':p['id'],'qty_milli':1000,'unit_cost_minor':100}],
      'payments':<Map<String,dynamic>>[]};
    final a=engine.command(owner,'purchase',request,'immutable-key-abcdef123456');
    final b=engine.command(owner,'purchase',request,'immutable-key-abcdef123456');
    expect(a['id'],b['id']);
    expect(engine.listStock(owner,branch).single['qty_milli'],1000);
    expect(()=>engine.command(owner,'purchase',{...request,'payments':[{'method':'cash','amount_minor':1}]},
      'immutable-key-abcdef123456'),throwsA(isA<DomainError>()));
  });

  test('insufficient stock rolls back document and movement', () {
    final p=call('create_product',{'sku':'C1','name_ar':'زيت','sell_price_minor':500});
    expect(()=>call('sale',{'branch_id':branch,
      'lines':[{'product_id':p['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':500}]}),throwsA(isA<DomainError>()));
    expect(engine.listDocuments(owner,branch),isEmpty);
    expect(store.rows('SELECT * FROM journal_entries'),isEmpty);
  });

  test('preparation transfers WAC with no artificial profit', () {
    final raw=call('create_product',{'sku':'CHEESE','name_ar':'جبنة خام','sell_price_minor':1000});
    final output=call('create_product',{'sku':'PACK','name_ar':'جبنة مجهزة','sell_price_minor':2500});
    final supplier=call('create_supplier',{'name':'توريد أجبان'});
    call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':raw['id'],'qty_milli':10000,'unit_cost_minor':10000}],
      'payments':<Map<String,dynamic>>[]});
    final prep=call('prepare',{'branch_id':branch,'source_product_id':raw['id'],
      'output_product_id':output['id'],'input_qty_milli':10000,'output_qty_milli':9500});
    expect(prep['allocated_cost_minor'],100000);
    expect(prep['waste_qty_milli'],500);
    expect(engine.dashboard(owner,branch)['stock_value_minor'],100000);
  });

  test('duplicate sale-return lines cannot refund more than originally sold', () {
    final product=call('create_product',{'sku':'RETURN-SALE','name_ar':'مكرونة','sell_price_minor':200});
    final supplier=call('create_supplier',{'name':'مورد'});
    call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':2000,'unit_cost_minor':100}],
      'payments':<Map<String,dynamic>>[]});
    final sale=call('sale',{'branch_id':branch,
      'lines':[{'product_id':product['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':200}]});
    final invoice=engine.readDocument(owner,sale['id'] as String);
    final lineId=(invoice['lines'] as List).single['id'];
    final before=engine.dashboard(owner,branch);
    final qty=engine.listStock(owner,branch).single['qty_milli'];
    expect(()=>call('sale_return',{'branch_id':branch,'original_id':sale['id'],
      'lines':[
        {'original_line_id':lineId,'qty_milli':1000},
        {'original_line_id':lineId,'qty_milli':1000},
      ]}),throwsA(isA<DomainError>()));
    expect(engine.dashboard(owner,branch),before);
    expect(engine.listStock(owner,branch).single['qty_milli'],qty);
  });

  test('duplicate supplier-return lines do not over-credit supplier', () {
    final product=call('create_product',{'sku':'RETURN-PURCHASE','name_ar':'لبن','sell_price_minor':400});
    final supplier=call('create_supplier',{'name':'مورد ألبان'});
    final purchase=call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':2000,'unit_cost_minor':100}],
      'payments':<Map<String,dynamic>>[]});
    final invoice=engine.readDocument(owner,purchase['id'] as String);
    final lineId=(invoice['lines'] as List).single['id'];
    final before=engine.dashboard(owner,branch);
    expect(()=>call('purchase_return',{'branch_id':branch,'original_id':purchase['id'],
      'lines':[
        {'original_line_id':lineId,'qty_milli':2000},
        {'original_line_id':lineId,'qty_milli':2000},
      ]}),throwsA(isA<DomainError>()));
    expect(engine.dashboard(owner,branch),before);
    expect(engine.listStock(owner,branch).single['qty_milli'],2000);
  });

  test('warehouse transfer is atomic and preserves weighted stock value', () {
    final product=call('create_product',{'sku':'TRANSFER-1','name_ar':'رز','sell_price_minor':500});
    final supplier=call('create_supplier',{'name':'مورد رز'});
    call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':10000,'unit_cost_minor':100}],
      'payments':<Map<String,dynamic>>[]});
    final warehouse=call('create_warehouse',{'branch_id':branch,'name':'المخزن الخلفي'});
    final initialValue=engine.dashboard(owner,branch)['stock_value_minor'];
    final result=call('transfer_warehouse',{'branch_id':branch,
      'source_warehouse_id':engine.listWarehouses(owner,branch).first['id'],
      'destination_warehouse_id':warehouse['id'],
      'product_id':product['id'],'qty_milli':4000});
    expect(result['cost_minor'],400);
    expect(engine.dashboard(owner,branch)['stock_value_minor'],initialValue);
    final balances=engine.listStock(owner,branch);
    expect(balances.fold<int>(0,(sum,row)=>sum+(row['qty_milli'] as int)),10000);
    expect(balances.fold<int>(0,(sum,row)=>sum+(row['cost_minor'] as int)),1000);
    final before=engine.listStock(owner,branch);
    expect(()=>call('transfer_warehouse',{'branch_id':branch,
      'source_warehouse_id':engine.listWarehouses(owner,branch).first['id'],
      'destination_warehouse_id':warehouse['id'],
      'product_id':product['id'],'qty_milli':999000}),throwsA(isA<DomainError>()));
    expect(engine.listStock(owner,branch),before);
  });

  test('credit limits are enforced server-side', () {
    final p=call('create_product',{'sku':'D1','name_ar':'ماء','sell_price_minor':500});
    final s=call('create_supplier',{'name':'مورد مياه'});
    final c=call('create_customer',{'name':'عميل محدود','credit_limit_minor':100});
    call('purchase',{'branch_id':branch,'supplier_id':s['id'],
      'lines':[{'product_id':p['id'],'qty_milli':5000,'unit_cost_minor':100}],
      'payments':<Map<String,dynamic>>[]});
    expect(()=>call('sale',{'branch_id':branch,'customer_id':c['id'],
      'lines':[{'product_id':p['id'],'qty_milli':1000}],
      'payments':<Map<String,dynamic>>[]}),throwsA(isA<DomainError>()));
    expect(engine.listDocuments(owner,branch).length,1);
  });
}

// The test harness also contains deliberately unauthenticated role inputs in
// separate tests; every API request must independently authenticate a session.

// Shift tests are separate so no live Flutter/Dart engine is required to run
// the Python operator consistency checker.
