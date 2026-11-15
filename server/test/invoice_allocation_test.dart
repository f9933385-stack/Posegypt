import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late Principal owner;
  late String branch;
  var counter=0;
  Map<String,Object?> command(String name,Map<String,dynamic> body) =>
    engine.command(owner,name,body,'invoice-allocation-test-${counter++}-123456789');

  setUp(() {
    store=DatabaseStore.memory();
    engine=PosEngine(store);
    final boot=engine.bootstrap('اختبار الفواتير','الرئيسي','owner','long-admin-password-123');
    branch=boot['branch_id'] as String;
    owner=Principal(boot['user_id'] as String,boot['tenant_id'] as String,
      branch,'owner','owner');
  });
  tearDown(()=>store.dispose());

  test('supplier payments allocate to one invoice, never another, and replay exactly once',() {
    final product=command('create_product',{
      'sku':'INV-SUP-1','name_ar':'مكرونة','sell_price_minor':300});
    final supplier=command('create_supplier',{'name':'مورد الفواتير'});
    Map<String,Object?> purchase(int cost)=>command('purchase',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000,
        'unit_cost_minor':cost}],'payments':<Map<String,dynamic>>[]});
    final first=purchase(1000),second=purchase(500);
    final report=engine.listDebtInvoices(owner,branch,supplier['id'] as String,
      customer:false);
    expect(report['allocation_available'],true);
    expect(report['balance_minor'],1500);
    expect(report['invoices'],hasLength(2));
    const key='same-invoice-payment-exact-once-123456';
    final request=<String,dynamic>{'branch_id':branch,'supplier_id':supplier['id'],
      'method':'cash','amount_minor':400,'invoice_id':first['id']};
    final saved=engine.command(owner,'supplier_payment',request,key);
    expect(engine.command(owner,'supplier_payment',request,key),saved);
    expect(saved['invoice_remaining_minor'],600);
    expect(store.rows('SELECT * FROM debt_allocations'),hasLength(1));
    expect(store.rows('SELECT * FROM payments WHERE document_id IS NULL'),hasLength(1));
    final after=engine.listDebtInvoices(owner,branch,supplier['id'] as String,
      customer:false);
    final invoices=(after['invoices'] as List<Map<String,Object?>>);
    expect(invoices.firstWhere((x)=>x['id']==first['id'])['remaining_minor'],600);
    expect(invoices.firstWhere((x)=>x['id']==second['id'])['remaining_minor'],500);
    expect(()=>command('supplier_payment',{
      ...request,'amount_minor':601}),throwsA(isA<DomainError>()));
    expect(store.rows('SELECT * FROM debt_allocations'),hasLength(1));

    final other=command('create_branch',{'name':'فرع آخر','code':'B99'});
    expect(()=>command('supplier_payment',{
      ...request,'branch_id':other['id'],'amount_minor':1}),
      throwsA(isA<DomainError>()));
    expect(engine.dashboard(owner,branch)['supplier_payables_minor'],1100);
    expect(engine.dashboard(owner,other['id'] as String)['supplier_payables_minor'],0);
    final unbalanced=store.rows('''SELECT e.id FROM journal_entries e
      JOIN journal_lines l ON e.id=l.entry_id
      GROUP BY e.id HAVING SUM(l.debit_minor-l.credit_minor)<>0''');
    expect(unbalanced,isEmpty);
  });

  test('credit returns reduce original customer invoice, not another invoice',() {
    final product=command('create_product',{
      'sku':'INV-CUST-1','name_ar':'أرز','sell_price_minor':300});
    final supplier=command('create_supplier',{'name':'مورد'});
    final customer=command('create_customer',{
      'name':'عميل','credit_limit_minor':5000});
    command('purchase',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':5000,
        'unit_cost_minor':100}],'payments':<Map<String,dynamic>>[]});
    final sale=command('sale',{
      'branch_id':branch,'customer_id':customer['id'],
      'lines':[{'product_id':product['id'],'qty_milli':3000}],
      'payments':<Map<String,dynamic>>[]});
    final line=store.first('SELECT id FROM document_lines WHERE document_id=?',
      [sale['id']])!;
    command('sale_return',{'branch_id':branch,'original_id':sale['id'],
      'refund_method':'credit',
      'lines':[{'original_line_id':line['id'],'qty_milli':1000}]});
    final customerId=customer['id'] as String;
    final report=engine.listDebtInvoices(owner,branch,customerId,customer:true);
    expect(report['balance_minor'],600);
    final original=(report['invoices'] as List<Map<String,Object?>>).single;
    expect(original['return_credit_minor'],300);
    expect(original['remaining_minor'],600);
    expect(()=>command('customer_receipt',{
      'branch_id':branch,'customer_id':customerId,'amount_minor':601,
      'method':'cash','invoice_id':sale['id']}),
      throwsA(isA<DomainError>()));
    final receipt=command('customer_receipt',{
      'branch_id':branch,'customer_id':customerId,'amount_minor':400,
      'method':'cash','invoice_id':sale['id']});
    expect(receipt['invoice_remaining_minor'],200);
    expect(engine.dashboard(owner,branch)['customer_receivables_minor'],200);
    expect((engine.listDebtInvoices(owner,branch,customerId,customer:true)['invoices']
      as List<Map<String,Object?>>).single['remaining_minor'],200);
    expect(()=>command('customer_receipt',{
      'branch_id':branch,'customer_id':customerId,'amount_minor':1,
      'method':'cash','invoice_id':'different-id'}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',404)));
    final different=command('create_customer',{
      'name':'آخر','credit_limit_minor':1000});
    expect(()=>command('customer_receipt',{
      'branch_id':branch,'customer_id':different['id'],'amount_minor':1,
      'method':'cash','invoice_id':sale['id']}),
      throwsA(isA<DomainError>()));
  });

  test('legacy unallocated receipts explicitly block new document allocation',() {
    final product=command('create_product',{
      'sku':'INV-LEG-1','name_ar':'عدس','sell_price_minor':250});
    final supplier=command('create_supplier',{'name':'مورد قديم'});
    final invoice=command('purchase',{'branch_id':branch,
      'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000,
        'unit_cost_minor':800}],'payments':<Map<String,dynamic>>[]});
    command('supplier_payment',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'amount_minor':100,'method':'cash'});
    final report=engine.listDebtInvoices(owner,branch,
      supplier['id'] as String,customer:false);
    expect(report['unallocated_settlements_minor'],100);
    expect(report['allocation_available'],false);
    expect(()=>command('supplier_payment',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'amount_minor':100,'method':'cash','invoice_id':invoice['id']}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    expect(store.rows('SELECT * FROM debt_allocations'),isEmpty);
    expect(engine.dashboard(owner,branch)['supplier_payables_minor'],700);
  });
}
