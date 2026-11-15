import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late Principal owner,reviewer,cashier;
  late String branch;
  var serial=0;
  Map<String,Object?> run(Principal actor,String action,Map<String,dynamic> body) =>
    engine.command(actor,action,body,'reconciliation-idempotency-${serial++}-long');

  setUp(() {
    store=DatabaseStore.memory();
    engine=PosEngine(store);
    final boot=engine.bootstrap('المراجعة','الرئيسي','admin',
      'test-admin-password-123');
    branch=boot['branch_id'] as String;
    owner=Principal(boot['user_id'] as String,
      boot['tenant_id'] as String,branch,'owner','admin');
    final mgr=run(owner,'create_user',{'username':'finance-review',
      'password':'long-finance-password-123','branch_id':branch,
      'role':'manager'});
    reviewer=Principal(mgr['id'] as String,owner.tenantId,branch,
      'manager','finance-review');
    final staff=run(owner,'create_user',{'username':'cashier-staff',
      'password':'long-cashier-password-123','branch_id':branch,
      'role':'cashier'});
    cashier=Principal(staff['id'] as String,owner.tenantId,branch,
      'cashier','cashier-staff');
  });
  tearDown(()=>store.dispose());

  test('two-person historical supplier reconciliation never posts cash or a second journal',() {
    final product=run(owner,'create_product',{
      'sku':'RECON-1','name_ar':'سكر','sell_price_minor':300});
    final supplier=run(owner,'create_supplier',{'name':'مورد قديم'});
    Map<String,Object?> purchase(int price)=>run(owner,'purchase',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],
        'qty_milli':1000,'unit_cost_minor':price}],
      'payments':<Map<String,dynamic>>[]});
    final first=purchase(700),second=purchase(500);
    final legacy=run(owner,'supplier_payment',{'branch_id':branch,
      'supplier_id':supplier['id'],'method':'bank',
      'amount_minor':400,'reference':'bank statement #A-18'});
    final paymentId=legacy['id'] as String;
    final party=supplier['id'] as String;
    expect(engine.listLegacyDebtPayments(owner,branch,party,customer:false),
      hasLength(1));
    final allocation=<Map<String,dynamic>>[
      {'invoice_id':first['id'],'amount_minor':250},
      {'invoice_id':second['id'],'amount_minor':150},
    ];
    final beforePayments=store.rows('SELECT id FROM payments').length;
    final beforeJournal=store.rows('SELECT id FROM journal_entries').length;
    final request=run(owner,'debt_reconciliation_request',{
      'branch_id':branch,'party_type':'supplier','party_id':party,
      'payment_id':paymentId,'reason':'تمت مراجعة كشف الحساب البنكي الأصلي',
      'allocations':allocation});
    final requestId=request['id'] as String;
    expect(request['status'],'pending');
    expect(engine.listDebtInvoices(owner,branch,party,customer:false)
      ['allocation_available'],false);
    expect(store.rows('SELECT * FROM debt_allocation_lines'),isEmpty);
    expect(store.rows('SELECT id FROM payments'),hasLength(beforePayments));
    expect(store.rows('SELECT id FROM journal_entries'),hasLength(beforeJournal));
    expect(() => run(owner,'debt_reconciliation_approve',{
      'reconciliation_id':requestId,
      'reason':'المدير الآخر يوافق على المطابقة'}),throwsA(
      isA<DomainError>().having((e)=>e.status,'status',403)));
    expect(() => run(cashier,'debt_reconciliation_approve',{
      'reconciliation_id':requestId,
      'reason':'موظف الكاشير يحاول الاعتماد'}),throwsA(
      isA<DomainError>().having((e)=>e.status,'status',403)));
    final approved=run(reviewer,'debt_reconciliation_approve',{
      'reconciliation_id':requestId,
      'reason':'تطابقت المستندات البنكية ومراجع الفواتير'});
    expect(approved['status'],'approved');
    expect(store.rows('SELECT id FROM payments'),hasLength(beforePayments));
    expect(store.rows('SELECT id FROM journal_entries'),hasLength(beforeJournal));
    expect(store.rows('SELECT * FROM debt_allocation_lines'),hasLength(2));
    expect(engine.listLegacyDebtPayments(owner,branch,party,customer:false),isEmpty);
    final report=engine.listDebtInvoices(owner,branch,party,customer:false);
    expect(report['allocation_available'],true);
    expect(report['unallocated_settlements_minor'],0);
    expect(report['balance_minor'],800);
    final open=report['invoices'] as List<Map<String,Object?>>;
    expect(open.firstWhere((x)=>x['id']==first['id'])['remaining_minor'],450);
    expect(open.firstWhere((x)=>x['id']==second['id'])['remaining_minor'],350);
    expect(engine.listDebtReconciliations(owner,branch,party,customer:false)
      .single['status'],'approved');
    expect(()=>run(reviewer,'debt_reconciliation_approve',{
      'reconciliation_id':requestId,
      'reason':'محاولة اعتماد ثانية لمطابقة مغلقة'}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    // After reconciliation, normal targeted invoice payment is available.
    final payment=run(owner,'supplier_payment',{'branch_id':branch,
      'supplier_id':party,'invoice_id':first['id'],
      'method':'cash','amount_minor':200});
    expect(payment['invoice_remaining_minor'],250);
    expect(engine.dashboard(owner,branch)['supplier_payables_minor'],600);
    final broken=store.rows('''SELECT e.id FROM journal_entries e
      JOIN journal_lines l ON l.entry_id=e.id
      GROUP BY e.id HAVING SUM(l.debit_minor-l.credit_minor)<>0''');
    expect(broken,isEmpty);
  });

  test('rejecting a request permits a new proposal while retaining old cash',() {
    final sku=run(owner,'create_product',{
      'sku':'RECON-2','name_ar':'فول','sell_price_minor':200});
    final supplier=run(owner,'create_supplier',{'name':'مورد 2'});
    final invoice=run(owner,'purchase',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':sku['id'],'qty_milli':1000,
        'unit_cost_minor':500}],'payments':<Map<String,dynamic>>[]});
    final payment=run(owner,'supplier_payment',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'amount_minor':200,'method':'cash'});
    final data=<String,dynamic>{
      'branch_id':branch,'party_type':'supplier','party_id':supplier['id'],
      'payment_id':payment['id'],'reason':'تقرير المطابقة الأساسي ومراجعته',
      'allocations':[{'invoice_id':invoice['id'],'amount_minor':200}],
    };
    final first=run(owner,'debt_reconciliation_request',data);
    expect(() => run(owner,'debt_reconciliation_request',data),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    final rejected=run(reviewer,'debt_reconciliation_reject',{
      'reconciliation_id':first['id'],
      'reason':'المرجع البنكي لا يطابق إيصال التوريد'});
    expect(rejected['status'],'rejected');
    expect(store.rows('SELECT * FROM debt_allocation_lines'),isEmpty);
    final second=run(owner,'debt_reconciliation_request',data);
    expect(second['id'],isNot(first['id']));
    expect(engine.listLegacyDebtPayments(owner,branch,supplier['id'] as String,
      customer:false).single['pending_request_id'],second['id']);
    run(reviewer,'debt_reconciliation_approve',{
      'reconciliation_id':second['id'],
      'reason':'تم تأكيد سند البنك من مصدر مستقل'});
    expect(store.rows('SELECT id FROM payments WHERE document_id IS NULL'),hasLength(1));
    expect(store.rows('SELECT * FROM debt_allocation_lines'),hasLength(1));
    expect(engine.dashboard(owner,branch)['supplier_payables_minor'],300);
  });

  test('stale invoice return prevents approval without changing the original journal',() {
    final sku=run(owner,'create_product',{
      'sku':'RECON-STALE','name_ar':'جبنة','sell_price_minor':200});
    final supplier=run(owner,'create_supplier',{'name':'مورد مرتجعات'});
    final invoice=run(owner,'purchase',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':sku['id'],'qty_milli':2000,
        'unit_cost_minor':250}],'payments':<Map<String,dynamic>>[]});
    final old=run(owner,'supplier_payment',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'amount_minor':300,'method':'cash'});
    final first=run(owner,'debt_reconciliation_request',{
      'branch_id':branch,'party_type':'supplier','party_id':supplier['id'],
      'payment_id':old['id'],'reason':'تقرير تفصيلي للمستندات الخاصة بالمورد',
      'allocations':[{'invoice_id':invoice['id'],'amount_minor':300}]});
    final line=store.first('SELECT id FROM document_lines WHERE document_id=?',
      [invoice['id']])!;
    // Return half the order for credit, decreasing that invoice to 250.
    run(owner,'purchase_return',{
      'branch_id':branch,'original_id':invoice['id'],
      'refund_method':'credit',
      'lines':[{'original_line_id':line['id'],'qty_milli':1000}]});
    final before=store.rows('SELECT id FROM journal_entries').length;
    expect(() => run(reviewer,'debt_reconciliation_approve',{
      'reconciliation_id':first['id'],
      'reason':'طلب اعتماد فاتورة تغير رصيدها بعد الطلب'}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    expect(store.rows('SELECT id FROM journal_entries'),hasLength(before));
    expect(store.rows('SELECT * FROM debt_allocation_lines'),isEmpty);
    expect(store.first('SELECT status FROM debt_reconciliations WHERE id=?',
      [first['id']])!['status'],'pending');
    run(reviewer,'debt_reconciliation_reject',{
      'reconciliation_id':first['id'],
      'reason':'تم رفض الطلب بسبب تغيير مستحق الفاتورة'});
  });

  test('requester cannot claim another party or branch, forge sums or duplicate documents',() {
    final sku=run(owner,'create_product',{
      'sku':'RECON-3','name_ar':'أرز','sell_price_minor':300});
    final supplier=run(owner,'create_supplier',{'name':'المورد الرئيسي'});
    final other=run(owner,'create_supplier',{'name':'مورد مختلف'});
    final invoice=run(owner,'purchase',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':sku['id'],'qty_milli':1000,
        'unit_cost_minor':600}],'payments':<Map<String,dynamic>>[]});
    final pay=run(owner,'supplier_payment',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'method':'cash','amount_minor':200});
    final otherBranch=run(owner,'create_branch',{
      'name':'فرع منفصل','code':'B37'});
    final base=<String,dynamic>{
      'branch_id':branch,'party_type':'supplier','party_id':supplier['id'],
      'payment_id':pay['id'],'reason':'مستندات تخص مراجعة المدفوعات السابقة',
      'allocations':[{'invoice_id':invoice['id'],'amount_minor':200}]
    };
    expect(()=>run(cashier,'debt_reconciliation_request',base),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    final rejected=[<String,dynamic>{...base,'party_id':other['id']},
      <String,dynamic>{...base,'branch_id':otherBranch['id']},
      <String,dynamic>{...base,'allocations':[
        {'invoice_id':invoice['id'],'amount_minor':100}]},
      <String,dynamic>{...base,'allocations':[
        {'invoice_id':invoice['id'],'amount_minor':100},
        {'invoice_id':invoice['id'],'amount_minor':100}]},
    ];
    for(final payload in rejected) {
      expect(()=>run(owner,'debt_reconciliation_request',payload),
        throwsA(isA<DomainError>()));
    }
    expect(store.rows('SELECT id FROM debt_reconciliations'),isEmpty);
    expect(store.rows('SELECT id FROM debt_reconciliation_lines'),isEmpty);
    expect(store.rows('SELECT * FROM debt_allocation_lines'),isEmpty);
    expect(engine.dashboard(owner,branch)['supplier_payables_minor'],400);
  });

  test('customer receipts may also be reconciled, and another branch manager cannot approve',() {
    final sku=run(owner,'create_product',{
      'sku':'RECON-CUSTOMER','name_ar':'شاي','sell_price_minor':300});
    final supplier=run(owner,'create_supplier',{'name':'شركة'});
    final customer=run(owner,'create_customer',{
      'name':'زبون','credit_limit_minor':2000});
    run(owner,'purchase',{
      'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':sku['id'],'qty_milli':2000,
        'unit_cost_minor':100}],'payments':<Map<String,dynamic>>[]});
    final invoice=run(owner,'sale',{
      'branch_id':branch,'customer_id':customer['id'],
      'lines':[{'product_id':sku['id'],'qty_milli':1000}],
      'payments':<Map<String,dynamic>>[]});
    final payment=run(owner,'customer_receipt',{
      'branch_id':branch,'customer_id':customer['id'],
      'method':'wallet','amount_minor':200});
    final otherBranch=run(owner,'create_branch',{'name':'فرع بعيد','code':'BR91'});
    final another=run(owner,'create_user',{
      'username':'other-manager','branch_id':otherBranch['id'],
      'role':'manager','password':'other-branch-long-password'});
    final outsider=Principal(another['id'] as String,owner.tenantId,
      otherBranch['id'] as String,'manager','other-manager');
    final request=run(owner,'debt_reconciliation_request',{
      'branch_id':branch,'party_type':'customer','party_id':customer['id'],
      'payment_id':payment['id'],
      'reason':'مراجعة إيصال العميل ومطابقته بفواتيره',
      'allocations':[{'invoice_id':invoice['id'],'amount_minor':200}]});
    expect(()=>run(outsider,'debt_reconciliation_approve',{
      'reconciliation_id':request['id'],
      'reason':'محاولة اعتماد خارج حدود الفرع المسموح'}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    final res=run(reviewer,'debt_reconciliation_approve',{
      'reconciliation_id':request['id'],
      'reason':'راجع المدير حركة المحفظة وفاتورة العميل'});
    expect(res['status'],'approved');
    expect(engine.listDebtInvoices(owner,branch,customer['id'] as String,
      customer:true)['allocation_available'],true);
    expect(engine.dashboard(owner,branch)['customer_receivables_minor'],100);
  });
}
