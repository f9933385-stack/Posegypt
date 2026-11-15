import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late Principal owner;
  late String branch;
  var serial=0;
  Map<String,Object?> command(String action,Map<String,dynamic> data) =>
    engine.command(owner,action,data,'split-payment-test-${serial++}-long-key');

  setUp(() {
    store=DatabaseStore.memory();
    engine=PosEngine(store);
    final boot=engine.bootstrap('Split payment store','Main','admin',
      'very-long-admin-password-123');
    branch=boot['branch_id'] as String;
    owner=Principal(boot['user_id'] as String,
      boot['tenant_id'] as String,branch,'owner','admin');
  });
  tearDown(()=>store.dispose());

  test('one supplier payment settles multiple invoices exactly once and keeps balanced books',() {
    final sku=command('create_product',{
      'sku':'SPLIT-1','name_ar':'بسكويت','sell_price_minor':500});
    final vendor=command('create_supplier',{'name':'مورد فواتير'});
    Map<String,Object?> buy(int cost)=>command('purchase',{
      'branch_id':branch,'supplier_id':vendor['id'],
      'lines':[{'product_id':sku['id'],'qty_milli':1000,
        'unit_cost_minor':cost}], 'payments':<Map<String,dynamic>>[]});
    final a=buy(700),b=buy(500);
    final request=<String,dynamic>{
      'branch_id':branch,'supplier_id':vendor['id'],
      'method':'bank','amount_minor':900,
      'allocations':[
        {'invoice_id':a['id'],'amount_minor':600},
        {'invoice_id':b['id'],'amount_minor':300},
      ],
    };
    const key='unique-supplier-split-payment-12345678';
    final result=engine.command(owner,'supplier_payment',request,key);
    expect(engine.command(owner,'supplier_payment',request,key),result);
    expect(result['remaining_minor'],300);
    final rows=(result['allocations'] as List<Map<String,Object?>>);
    expect(rows.map((x)=>x['invoice_remaining_minor']).toList(),[100,200]);
    final saved=store.rows('SELECT * FROM debt_allocation_lines');
    expect(saved,hasLength(2));
    expect(store.rows('SELECT id FROM payments WHERE document_id IS NULL'),hasLength(1));
    final report=engine.listDebtInvoices(owner,branch,
      vendor['id'] as String,customer:false);
    expect(report['unallocated_settlements_minor'],0);
    expect(report['balance_minor'],300);
    final invoices=report['invoices'] as List<Map<String,Object?>>;
    expect(invoices.firstWhere((x)=>x['id']==a['id'])['remaining_minor'],100);
    expect(invoices.firstWhere((x)=>x['id']==b['id'])['remaining_minor'],200);
    final badJournal=store.rows('''SELECT e.id FROM journal_entries e
      JOIN journal_lines l ON l.entry_id=e.id
      GROUP BY e.id HAVING SUM(l.debit_minor-l.credit_minor)<>0''');
    expect(badJournal,isEmpty);
    // Existing single-invoice allocation is still valid alongside split payments.
    final single=command('supplier_payment',{'branch_id':branch,
      'supplier_id':vendor['id'],'method':'cash','amount_minor':50,
      'invoice_id':a['id']});
    expect(single['invoice_remaining_minor'],50);
    expect(engine.listDebtInvoices(owner,branch,
      vendor['id'] as String,customer:false)['balance_minor'],250);
  });

  test('bad split amounts, duplicates and foreign parties roll back every record',() {
    final sku=command('create_product',{
      'sku':'SPLIT-INVALID','name_ar':'ملح','sell_price_minor':200});
    final supplier=command('create_supplier',{'name':'المورد الصحيح'});
    final other=command('create_supplier',{'name':'مورد آخر'});
    Map<String,Object?> buy(String party,int cost)=>command('purchase',{
      'branch_id':branch,'supplier_id':party,
      'lines':[{'product_id':sku['id'],'qty_milli':1000,
        'unit_cost_minor':cost}],'payments':<Map<String,dynamic>>[]});
    final a=buy(supplier['id'] as String,700);
    final b=buy(supplier['id'] as String,400);
    final foreign=buy(other['id'] as String,100);
    final base=<String,dynamic>{
      'branch_id':branch,'supplier_id':supplier['id'],
      'method':'cash','amount_minor':500
    };
    final invalid=<List<Map<String,dynamic>>>[
      [{'invoice_id':a['id'],'amount_minor':100}],
      [{'invoice_id':a['id'],'amount_minor':250},
       {'invoice_id':a['id'],'amount_minor':250}],
      [{'invoice_id':a['id'],'amount_minor':450},
       {'invoice_id':b['id'],'amount_minor':100}],
      [{'invoice_id':foreign['id'],'amount_minor':250},
       {'invoice_id':a['id'],'amount_minor':250}],
      [{'invoice_id':a['id'],'amount_minor':750}],
    ];
    for(final allocations in invalid) {
      expect(()=>command('supplier_payment',{
        ...base,'allocations':allocations
      }),throwsA(isA<DomainError>()));
    }
    expect(()=>command('supplier_payment',{
      ...base,'invoice_id':a['id'],
      'allocations':[{'invoice_id':b['id'],'amount_minor':500}]
    }),throwsA(isA<DomainError>()));
    expect(store.rows('SELECT * FROM debt_allocation_lines'),isEmpty);
    expect(store.rows('SELECT * FROM payments WHERE document_id IS NULL'),isEmpty);
    expect(engine.dashboard(owner,branch)['supplier_payables_minor'],1200);
    final foreignBranch=command('create_branch',{
      'name':'فرع آخر','code':'SPLIT-OTHER'});
    expect(()=>command('supplier_payment',{
      ...base,'branch_id':foreignBranch['id'],
      'allocations':[{'invoice_id':a['id'],'amount_minor':500}]
    }),throwsA(isA<DomainError>()));
    expect(store.rows('SELECT * FROM debt_allocation_lines'),isEmpty);
  });

  test('customer split receipts account for credit returns, and legacy remains blocked',() {
    final sku=command('create_product',{
      'sku':'SPLIT-CUST','name_ar':'سكر','sell_price_minor':200});
    final supplier=command('create_supplier',{'name':'توريدات'});
    final buyer=command('create_customer',{
      'name':'عميل تجزئة','credit_limit_minor':2000});
    command('purchase',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':sku['id'],'qty_milli':6000,
        'unit_cost_minor':100}], 'payments':<Map<String,dynamic>>[]});
    Map<String,Object?> sell()=>command('sale',{
      'branch_id':branch,'customer_id':buyer['id'],
      'lines':[{'product_id':sku['id'],'qty_milli':2000}],
      'payments':<Map<String,dynamic>>[]});
    final a=sell(),b=sell();
    final row=store.first('SELECT id FROM document_lines WHERE document_id=?',[a['id']])!;
    command('sale_return',{'branch_id':branch,'original_id':a['id'],
      'refund_method':'credit',
      'lines':[{'original_line_id':row['id'],'qty_milli':1000}]});
    final settlement=command('customer_receipt',{
      'branch_id':branch,'customer_id':buyer['id'],
      'amount_minor':450,'method':'wallet',
      'allocations':[
        {'invoice_id':a['id'],'amount_minor':150},
        {'invoice_id':b['id'],'amount_minor':300},
      ]});
    expect(settlement['remaining_minor'],150);
    expect((settlement['allocations'] as List<Map<String,Object?>>)
      .map((x)=>x['invoice_remaining_minor']).toList(),[50,100]);
    expect(engine.dashboard(owner,branch)['customer_receivables_minor'],150);
    command('customer_receipt',{
      'branch_id':branch,'customer_id':buyer['id'],
      'amount_minor':50,'method':'cash'});
    final report=engine.listDebtInvoices(owner,branch,
      buyer['id'] as String,customer:true);
    expect(report['allocation_available'],false);
    expect(report['unallocated_settlements_minor'],50);
    expect(()=>command('customer_receipt',{
      'branch_id':branch,'customer_id':buyer['id'],
      'amount_minor':100,'method':'cash',
      'allocations':[{'invoice_id':b['id'],'amount_minor':100}]
    }),throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    expect(store.rows('SELECT * FROM debt_allocation_lines'),hasLength(2));
  });
}
