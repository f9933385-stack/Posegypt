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

  test('fully paid supplier purchase can be refunded as cash', () {
    final product=call('create_product',{'sku':'CASH-RETURN','name_ar':'دقيق','sell_price_minor':250});
    final supplier=call('create_supplier',{'name':'مورد دقيق'});
    final purchase=call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':10000,'unit_cost_minor':100}],
      'payments':[{'method':'cash','amount_minor':1000}]});
    final invoice=engine.readDocument(owner,purchase['id'] as String);
    final lineId=(invoice['lines'] as List).single['id'];
    final returned=call('purchase_return',{'branch_id':branch,
      'original_id':purchase['id'],'refund_method':'cash',
      'lines':[{'original_line_id':lineId,'qty_milli':4000}]});
    expect(returned['cash_refund_minor'],400);
    expect(returned['supplier_credit_minor'],0);
    final dash=engine.dashboard(owner,branch);
    expect(dash['stock_value_minor'],600);
    expect(dash['cash_minor'],-600);
    expect(dash['supplier_payables_minor'],0);
    expect(engine.listStock(owner,branch).single['qty_milli'],6000);
  });

  test('partial refunds conserve original pennies over repeated returns', () {
    final product=call('create_product',{'sku':'ROUND-1','name_ar':'عينة','sell_price_minor':3});
    final supplier=call('create_supplier',{'name':'المورد'});
    call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000,'unit_cost_minor':2}],
      'payments':<Map<String,dynamic>>[]});
    final sale=call('sale',{'branch_id':branch,
      'lines':[{'product_id':product['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':3}]});
    final lineId=(engine.readDocument(owner,sale['id'] as String)['lines'] as List).single['id'];
    Map<String,Object?> refund() => call('sale_return',{
      'branch_id':branch,'original_id':sale['id'],'refund_method':'cash',
      'lines':[{'original_line_id':lineId,'qty_milli':500}]});
    expect(refund()['total_minor'],2);
    expect(refund()['total_minor'],1);
    expect(engine.dashboard(owner,branch)['cash_minor'],0);
    expect(engine.dashboard(owner,branch)['sales_minor'],0);
    expect(engine.listStock(owner,branch).single['qty_milli'],1000);
  });

  test('carton sale uses exact unit price and returns conserve every piaster', () {
    final product=call('create_product',{'sku':'CARTON-1','name_ar':'عبوات أرز',
      'sell_price_minor':15,'barcode':'2212000000000'});
    final carton=call('create_product_unit',{
      'product_id':product['id'],'unit_name':'كرتونة 12',
      'factor_milli':12000,'sell_price_minor':161,
      'barcode':'2212000000001',
    });
    final supplier=call('create_supplier',{'name':'مورد أرز'});
    call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':24000,'unit_cost_minor':10}],
      'payments':<Map<String,dynamic>>[]});
    final sold=call('sale',{'branch_id':branch,
      'lines':[{'product_id':product['id'],'unit_id':carton['id'],'unit_count':1}],
      'payments':[{'method':'cash','amount_minor':161}]});
    expect(sold['total_minor'],161);
    expect(sold['cogs_minor'],120);
    final document=engine.readDocument(owner,sold['id'] as String);
    final line=(document['lines'] as List).single;
    expect(line['gross_minor'],161);
    expect(line['qty_milli'],12000);
    expect(line['unit_count'],1);
    expect(engine.listStock(owner,branch).single['qty_milli'],12000);
    final first=call('sale_return',{'branch_id':branch,'original_id':sold['id'],
      'refund_method':'cash','lines':[{'original_line_id':line['id'],'qty_milli':6000}]});
    final second=call('sale_return',{'branch_id':branch,'original_id':sold['id'],
      'refund_method':'cash','lines':[{'original_line_id':line['id'],'qty_milli':6000}]});
    expect((first['total_minor'] as int)+(second['total_minor'] as int),161);
    expect(engine.listStock(owner,branch).single['qty_milli'],24000);
    final balances=store.rows('''SELECT e.id, SUM(l.debit_minor-l.credit_minor) AS delta
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      GROUP BY e.id HAVING delta<>0''');
    expect(balances,isEmpty);
  });

  test('product unit barcodes cannot collide in either direction', () {
    final product=call('create_product',{'sku':'UNIT-BC-1','name_ar':'بسكويت',
      'sell_price_minor':30,'barcode':'1234567890123'});
    expect(()=>call('create_product_unit',{'product_id':product['id'],
      'unit_name':'علبة','factor_milli':6000,'sell_price_minor':150,
      'barcode':'1234567890123'}),throwsA(isA<DomainError>()));
    final unit=call('create_product_unit',{'product_id':product['id'],
      'unit_name':'علبة','factor_milli':6000,'sell_price_minor':150,
      'barcode':'1234567890124'});
    expect(engine.listProductUnits(owner,product['id'] as String).single['id'],unit['id']);
    expect(()=>call('create_product',{'sku':'UNIT-BC-2',
      'name_ar':'شيء آخر','sell_price_minor':5,
      'barcode':'1234567890124'}),throwsA(isA<DomainError>()));
  });

  test('a product unit cannot be sold for another product', () {
    final a=call('create_product',{'sku':'U-A','name_ar':'أ','sell_price_minor':30});
    final b=call('create_product',{'sku':'U-B','name_ar':'ب','sell_price_minor':30});
    final unit=call('create_product_unit',{'product_id':a['id'],
      'unit_name':'كرتونة','factor_milli':12000,'sell_price_minor':300});
    expect(()=>call('sale',{'branch_id':branch,
      'lines':[{'product_id':b['id'],'unit_id':unit['id'],'unit_count':1}],
      'payments':[{'method':'cash','amount_minor':300}]}),
      throwsA(isA<DomainError>()));
    expect(store.rows('SELECT id FROM documents WHERE kind=?',['sale']),isEmpty);
  });

  test('searching a carton barcode resolves product and matching unit exactly', () {
    final product=call('create_product',{'sku':'SEARCH-1','name_ar':'حليب',
      'sell_price_minor':50,'barcode':'2100000000000'});
    final unit=call('create_product_unit',{'product_id':product['id'],
      'unit_name':'كرتونة 6','factor_milli':6000,'sell_price_minor':270,
      'barcode':'2100000000001'});
    final list=engine.listProducts(owner,search:'2100000000001');
    expect(list.length,1);
    expect(list.single['id'],product['id']);
    expect(list.single['matched_unit_id'],unit['id']);
    final base=engine.listProducts(owner,search:'2100000000000');
    expect(base.single['matched_unit_id'],null);
  });

  test('carton purchase keeps exact gross cost, base inventory and supplier payable', () {
    final product=call('create_product',{'sku':'PUR-CARTON-1','name_ar':'بسكويت',
      'sell_price_minor':20});
    final unit=call('create_product_unit',{'product_id':product['id'],
      'unit_name':'كرتونة 12','factor_milli':12000,'sell_price_minor':220});
    final supplier=call('create_supplier',{'name':'مورد الكراتين'});
    final bought=call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'unit_id':unit['id'],
        'unit_count':3,'unit_cost_minor':185}],
      'payments':<Map<String,dynamic>>[]});
    expect(bought['total_minor'],555);
    expect(bought['due_minor'],555);
    final lines=(engine.readDocument(owner,bought['id'] as String)['lines'] as List);
    final docLine=lines.single;
    expect(docLine['qty_milli'],36000);
    expect(docLine['gross_minor'],555);
    expect(docLine['unit_id'],unit['id']);
    expect(docLine['unit_count'],3);
    expect(docLine['unit_price_minor'],185);
    expect(engine.listStock(owner,branch).single['qty_milli'],36000);
    expect(engine.listStock(owner,branch).single['cost_minor'],555);
    expect(engine.dashboard(owner,branch)['stock_value_minor'],555);
    expect(engine.dashboard(owner,branch)['supplier_payables_minor'],555);
    final first=call('purchase_return',{'branch_id':branch,'original_id':bought['id'],
      'lines':[{'original_line_id':docLine['id'],'qty_milli':18000}]});
    final second=call('purchase_return',{'branch_id':branch,'original_id':bought['id'],
      'lines':[{'original_line_id':docLine['id'],'qty_milli':18000}]});
    expect((first['supplier_credit_minor'] as int)+(second['supplier_credit_minor'] as int),555);
    expect(engine.listStock(owner,branch).single['qty_milli'],0);
    expect(engine.listStock(owner,branch).single['cost_minor'],0);
    expect(store.rows('''SELECT e.id,SUM(l.debit_minor-l.credit_minor) AS difference
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      GROUP BY e.id HAVING difference<>0'''),isEmpty);
  });

  test('carton buying handles bonus and expiry lots without changing invoice total', () {
    final product=call('create_product',{'sku':'PUR-CARTON-LOT',
      'name_ar':'حليب مبرد','sell_price_minor':30,'track_expiry':true});
    final unit=call('create_product_unit',{'product_id':product['id'],
      'unit_name':'صندوق 6','factor_milli':6000,'sell_price_minor':165});
    final supplier=call('create_supplier',{'name':'مورد اللبن'});
    final doc=call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'unit_id':unit['id'],
        'unit_count':2,'unit_cost_minor':151,'bonus_qty_milli':1000,
        'lot_no':'MILK-42','expires_on':'2031-10-01'}],
      'payments':[{'method':'cash','amount_minor':302}]});
    expect(doc['total_minor'],302);
    final stock=engine.listStock(owner,branch).single;
    expect(stock['qty_milli'],13000);
    expect(stock['cost_minor'],302);
    final lots=engine.listLots(owner,branch,productId:product['id'] as String);
    expect(lots.single['qty_milli'],13000);
    expect(lots.single['lot_no'],'MILK-42');
    final line=(engine.readDocument(owner,doc['id'] as String)['lines'] as List).single;
    expect(line['unit_count'],2);
    expect(line['gross_minor'],302);
    expect(line['qty_milli'],13000);
  });

  test('alternate purchase units cannot be applied to another product or double-quantity', () {
    final first=call('create_product',{'sku':'PUR-UNIT-A','name_ar':'أرز',
      'sell_price_minor':20});
    final second=call('create_product',{'sku':'PUR-UNIT-B','name_ar':'مكرونة',
      'sell_price_minor':20});
    final unit=call('create_product_unit',{'product_id':first['id'],
      'unit_name':'كيس 10','factor_milli':10000,'sell_price_minor':180});
    final supplier=call('create_supplier',{'name':'مورد'});
    Map<String,dynamic> purchaseLine(Map<String,dynamic> line) =>
      {'branch_id':branch,'supplier_id':supplier['id'],
        'lines':[line],'payments':<Map<String,dynamic>>[]};
    expect(()=>call('purchase',purchaseLine({
      'product_id':second['id'],'unit_id':unit['id'],
      'unit_count':1,'unit_cost_minor':150})),throwsA(isA<DomainError>()));
    expect(()=>call('purchase',purchaseLine({
      'product_id':first['id'],'unit_id':unit['id'],'qty_milli':1000,
      'unit_count':1,'unit_cost_minor':150})),throwsA(isA<DomainError>()));
    expect(()=>call('purchase',purchaseLine({
      'product_id':first['id'],'unit_count':1,'unit_cost_minor':150
    })),throwsA(isA<DomainError>()));
    expect(store.rows("SELECT id FROM documents WHERE kind='purchase'"),isEmpty);
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
