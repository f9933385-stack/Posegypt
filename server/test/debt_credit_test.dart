import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late Principal owner;
  late String branch;
  var sequence=0;
  Map<String,Object?> call(String action,Map<String,dynamic> body) =>
    engine.command(owner,action,body,'credit-application-test-${sequence++}-key');

  setUp(() {
    store=DatabaseStore.memory();
    engine=PosEngine(store);
    final boot=engine.bootstrap('اختبار رصيد المرتجعات','الرئيسي',
      'admin','long-credit-admin-password-123');
    branch=boot['branch_id'] as String;
    owner=Principal(boot['user_id'] as String,boot['tenant_id'] as String,
      branch,'owner','admin');
  });
  tearDown(()=>store.dispose());

  test('customer return credit first reduces original due then applies to later invoice without cash posting',() {
    final product=call('create_product',{
      'sku':'CREDIT-CUSTOMER-1','name_ar':'منتج عميل',
      'sell_price_minor':500});
    final supplier=call('create_supplier',{'name':'مورد'});
    final customer=call('create_customer',{
      'name':'عميل لديه رصيد','credit_limit_minor':2000});
    call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':5000,
        'unit_cost_minor':100}],'payments':<Map<String,dynamic>>[]});
    final original=call('sale',{'branch_id':branch,
      'customer_id':customer['id'],
      'lines':[{'product_id':product['id'],'qty_milli':2000}],
      'payments':[{'method':'cash','amount_minor':800}]});
    final originalLine=store.first(
      'SELECT id FROM document_lines WHERE document_id=?',[original['id']])!;
    final returned=call('sale_return',{'branch_id':branch,
      'original_id':original['id'],'refund_method':'credit',
      'lines':[{'original_line_id':originalLine['id'],'qty_milli':1000}]});
    expect(returned['total_minor'],500);
    final sourceId=returned['id'] as String;
    final first=engine.listDebtInvoices(owner,branch,
      customer['id'] as String,customer:true);
    final oldInvoice=(first['invoices'] as List<Map<String,Object?>>)
      .singleWhere((x)=>x['id']==original['id']);
    expect(oldInvoice['return_credit_minor'],200);
    expect(oldInvoice['remaining_minor'],0);
    expect(first['available_credit_minor'],300);
    expect((first['credit_notes'] as List<Map<String,Object?>>)
      .single['available_minor'],300);

    final next=call('sale',{'branch_id':branch,
      'customer_id':customer['id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000}],
      'payments':<Map<String,dynamic>>[]});
    expect(engine.dashboard(owner,branch)['customer_receivables_minor'],200);
    final journalCount=store.rows('SELECT id FROM journal_entries').length;
    const idempotency='customer-credit-apply-once-123456';
    final body=<String,dynamic>{
      'branch_id':branch,'party_type':'customer','party_id':customer['id'],
      'credit_document_id':sourceId,'invoice_id':next['id'],
      'amount_minor':300,'reason':'رصيد مرتجع موثق يخص العميل',
    };
    final applied=engine.command(owner,'debt_credit_apply',body,idempotency);
    expect(engine.command(owner,'debt_credit_apply',body,idempotency),applied);
    expect(applied['credit_remaining_minor'],0);
    expect(applied['invoice_remaining_minor'],200);
    expect(store.rows('SELECT id FROM journal_entries'),hasLength(journalCount));
    expect(store.rows('SELECT * FROM debt_credit_allocations WHERE credit_document_id=?',
      [sourceId]),hasLength(2)); // 200 original invoice + 300 next invoice
    final after=engine.listDebtInvoices(owner,branch,
      customer['id'] as String,customer:true);
    expect(after['available_credit_minor'],0);
    expect((after['invoices'] as List<Map<String,Object?>>)
      .single['remaining_minor'],200);
    final receipt=call('customer_receipt',{
      'branch_id':branch,'customer_id':customer['id'],
      'invoice_id':next['id'],'method':'bank','amount_minor':200});
    expect(receipt['invoice_remaining_minor'],0);
    expect(engine.dashboard(owner,branch)['customer_receivables_minor'],0);
    expect(store.rows('''SELECT e.id FROM journal_entries e
      JOIN journal_lines l ON l.entry_id=e.id GROUP BY e.id
      HAVING SUM(l.debit_minor-l.credit_minor)<>0'''),isEmpty);
  });

  test('supplier return credit can settle a different purchase invoice and then normal payment',() {
    final product=call('create_product',{
      'sku':'CREDIT-SUPPLIER-1','name_ar':'منتج مورد',
      'sell_price_minor':800});
    final supplier=call('create_supplier',{'name':'مورد له رصيد'});
    final original=call('purchase',{'branch_id':branch,
      'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':2000,
        'unit_cost_minor':500}],
      'payments':[{'method':'cash','amount_minor':1000}]});
    final originalLine=store.first(
      'SELECT id FROM document_lines WHERE document_id=?',[original['id']])!;
    final returned=call('purchase_return',{'branch_id':branch,
      'original_id':original['id'],'refund_method':'credit',
      'lines':[{'original_line_id':originalLine['id'],'qty_milli':1000}]});
    expect(returned['supplier_credit_minor'],500);
    final creditId=store.first('''SELECT id FROM documents
      WHERE original_id=? AND kind='purchase_return' ORDER BY created_at DESC LIMIT 1''',
      [original['id']])!['id'] as String;
    final next=call('purchase',{'branch_id':branch,
      'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':2000,
        'unit_cost_minor':400}],
      'payments':<Map<String,dynamic>>[]});
    expect(engine.dashboard(owner,branch)['supplier_payables_minor'],300);
    final journalCount=store.rows('SELECT id FROM journal_entries').length;
    final applied=call('debt_credit_apply',{
      'branch_id':branch,'party_type':'supplier','party_id':supplier['id'],
      'credit_document_id':creditId,'invoice_id':next['id'],
      'amount_minor':500,'reason':'رصيد مرتجع مثبت من المورد'});
    expect(applied['credit_remaining_minor'],0);
    expect(applied['invoice_remaining_minor'],300);
    expect(store.rows('SELECT id FROM journal_entries'),hasLength(journalCount));
    expect(engine.listDebtInvoices(owner,branch,
      supplier['id'] as String,customer:false)['available_credit_minor'],0);
    final payment=call('supplier_payment',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'invoice_id':next['id'],'method':'bank','amount_minor':300});
    expect(payment['invoice_remaining_minor'],0);
    expect(engine.dashboard(owner,branch)['supplier_payables_minor'],0);
    expect(store.rows('''SELECT e.id FROM journal_entries e
      JOIN journal_lines l ON l.entry_id=e.id GROUP BY e.id
      HAVING SUM(l.debit_minor-l.credit_minor)<>0'''),isEmpty);
  });

  test('credit application rejects wrong parties, cash refunds, stale targets and excess amounts atomically',() {
    final product=call('create_product',{
      'sku':'CREDIT-GUARD-1','name_ar':'منتج حراسة',
      'sell_price_minor':400});
    final supplier=call('create_supplier',{'name':'المورد'});
    final customer=call('create_customer',{
      'name':'العميل','credit_limit_minor':2000});
    final other=call('create_customer',{
      'name':'عميل آخر','credit_limit_minor':2000});
    call('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':5000,
        'unit_cost_minor':100}],'payments':<Map<String,dynamic>>[]});
    final sale=call('sale',{'branch_id':branch,
      'customer_id':customer['id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':400}]});
    final line=store.first('SELECT id FROM document_lines WHERE document_id=?',
      [sale['id']])!;
    final cashReturn=call('sale_return',{'branch_id':branch,
      'original_id':sale['id'],'refund_method':'cash',
      'lines':[{'original_line_id':line['id'],'qty_milli':1000}]});
    final cashReturnId=cashReturn['id'] as String;
    final newInvoice=call('sale',{'branch_id':branch,
      'customer_id':customer['id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':400}]});
    final creditReturn=call('sale_return',{'branch_id':branch,
      'original_id':newInvoice['id'],'refund_method':'credit',
      'lines':[{'original_line_id':store.first(
        'SELECT id FROM document_lines WHERE document_id=?',[newInvoice['id']])!['id'],
        'qty_milli':1000}]});
    final source=creditReturn['id'] as String;
    final otherSale=call('sale',{'branch_id':branch,
      'customer_id':other['id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000}],
      'payments':<Map<String,dynamic>>[]});
    final base=<String,dynamic>{
      'branch_id':branch,'party_type':'customer','party_id':customer['id'],
      'credit_document_id':source,'invoice_id':otherSale['id'],
      'amount_minor':100,'reason':'تطبيق رصيد موثق على فاتورة أخرى',
    };
    expect(()=>call('debt_credit_apply',base),throwsA(isA<DomainError>()));
    expect(()=>call('debt_credit_apply',{
      ...base,'invoice_id':newInvoice['id'],'amount_minor':401}),
      throwsA(isA<DomainError>()));
    expect(()=>call('debt_credit_apply',{
      ...base,'party_id':other['id']}),
      throwsA(isA<DomainError>()));
    expect(()=>call('debt_credit_apply',{
      ...base,'credit_document_id':cashReturnId,
      'invoice_id':newInvoice['id']}),
      throwsA(isA<DomainError>()));
    expect(store.rows('SELECT * FROM debt_credit_allocations WHERE credit_document_id=?',
      [source]),isEmpty);
    expect(engine.listDebtInvoices(owner,branch,
      customer['id'] as String,customer:true)['available_credit_minor'],400);
  });
}
