import 'package:test/test.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';

void main(){
  test('branch shift opens, counts cash ledger, closes blind and refuses duplicate close',(){
    final store=DatabaseStore.memory();
    try {
      final engine=PosEngine(store);
      final setup=engine.bootstrap('سوبرماركت','فرع','owner','very-safe-password-123');
      final branch=setup['branch_id'] as String;
      final owner=Principal(setup['user_id'] as String,setup['tenant_id'] as String,branch,'owner','owner');
      var next=0;
      Map<String,Object?> cmd(String action,Map<String,dynamic> data)=>
        engine.command(owner,action,data,'test-shift-idempotency-${next++}');
      final shift=cmd('shift_open',{'branch_id':branch,'opening_minor':10000});
      expect(engine.listShifts(owner,branch).first['id'],shift['id']);
      expect(()=>cmd('shift_open',{'branch_id':branch,'opening_minor':100}),throwsA(isA<DomainError>()));
      final supplier=cmd('create_supplier',{'name':'Supplier'});
      final product=cmd('create_product',{'sku':'SKU-1','name_ar':'أرز','sell_price_minor':200});
      cmd('purchase',{'branch_id':branch,'supplier_id':supplier['id'],
        'lines':[{'product_id':product['id'],'qty_milli':1000,'unit_cost_minor':100}],
        'payments':<Map<String,dynamic>>[]});
      cmd('sale',{'branch_id':branch,
        'lines':[{'product_id':product['id'],'qty_milli':1000}],
        'payments':[{'method':'cash','amount_minor':200}]});
      final close=cmd('shift_close',{'branch_id':branch,'shift_id':shift['id'],'closing_actual_minor':10150});
      expect(close['expected_minor'],10200);
      expect(close['difference_minor'],-50);
      expect(()=>cmd('shift_close',{'branch_id':branch,'shift_id':shift['id'],
        'closing_actual_minor':10150}),throwsA(isA<DomainError>()));
    } finally {store.dispose();}
  });


  test('two independent tills attribute cash to their own active shift only',() {
    final store=DatabaseStore.memory();
    try {
      final engine=PosEngine(store);
      final boot=engine.bootstrap('اختبار الأدراج','فرع','owner',
        'very-safe-password-123');
      final branch=boot['branch_id'] as String;
      final owner=Principal(boot['user_id'] as String,
        boot['tenant_id'] as String,branch,'owner','owner');
      var seq=0;
      Map<String,Object?> cmd(Principal actor,String action,Map<String,dynamic> data)=>
        engine.command(actor,action,data,'multi-drawer-test-${seq++}-replay-key');

      final legacy=cmd(owner,'shift_open',{'branch_id':branch,'opening_minor':300});
      expect(()=>cmd(owner,'cash_drawer_create',{
        'branch_id':branch,'name':'الصندوق الأول'}),
        throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
      cmd(owner,'shift_close',{'branch_id':branch,'shift_id':legacy['id'],
        'closing_actual_minor':300});
      final first=cmd(owner,'cash_drawer_create',
        {'branch_id':branch,'name':'الصندوق الأول'});
      final second=cmd(owner,'cash_drawer_create',
        {'branch_id':branch,'name':'الصندوق الثاني'});
      expect(engine.listCashDrawers(owner,branch),hasLength(2));
      final user1=cmd(owner,'create_user',{'branch_id':branch,
        'username':'cashier-one','password':'cashier-one-very-long-123',
        'role':'cashier'});
      final user2=cmd(owner,'create_user',{'branch_id':branch,
        'username':'cashier-two','password':'cashier-two-very-long-123',
        'role':'cashier'});
      final a=Principal(user1['id'] as String,owner.tenantId,branch,
        'cashier','cashier-one');
      final b=Principal(user2['id'] as String,owner.tenantId,branch,
        'cashier','cashier-two');
      final supplier=cmd(owner,'create_supplier',{'name':'مورد'});
      final product=cmd(owner,'create_product',{
        'sku':'MULTITILL-1','name_ar':'سكر','sell_price_minor':250});
      cmd(owner,'purchase',{'branch_id':branch,'supplier_id':supplier['id'],
        'lines':[{'product_id':product['id'],'qty_milli':8000,
          'unit_cost_minor':100}],'payments':<Map<String,dynamic>>[]});
      final cashSale=<String,dynamic>{'branch_id':branch,
        'lines':[{'product_id':product['id'],'qty_milli':1000}],
        'payments':[{'method':'cash','amount_minor':250}]};
      final beforeDocuments=engine.listDocuments(owner,branch).length;
      expect(()=>cmd(a,'sale',cashSale),
        throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
      expect(engine.listDocuments(owner,branch),hasLength(beforeDocuments));
      expect(engine.listStock(owner,branch).single['qty_milli'],8000);

      final shiftA=cmd(a,'shift_open',{'branch_id':branch,
        'cash_drawer_id':first['id'],'opening_minor':10000});
      final shiftB=cmd(b,'shift_open',{'branch_id':branch,
        'cash_drawer_id':second['id'],'opening_minor':5000});
      expect(()=>cmd(b,'shift_open',{'branch_id':branch,
        'cash_drawer_id':first['id'],'opening_minor':300}),
        throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
      expect(()=>cmd(a,'shift_open',{'branch_id':branch,
        'cash_drawer_id':second['id'],'opening_minor':300}),
        throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
      final saleA=cmd(a,'sale',cashSale);
      expect(saleA['total_minor'],250);
      final saleB=cmd(b,'sale',cashSale);
      expect(saleB['total_minor'],250);
      // A non-cash payment does not enter either physical till.
      cmd(owner,'sale',{'branch_id':branch,
        'lines':[{'product_id':product['id'],'qty_milli':1000}],
        'payments':[{'method':'card','amount_minor':250}]});
      final links=store.rows('''SELECT l.shift_id,l.cash_delta_minor,e.created_by
        FROM cash_shift_journal_links l
        JOIN journal_entries e ON e.id=l.journal_entry_id''');
      expect(links,hasLength(2));
      expect(links.firstWhere((r)=>r['shift_id']==shiftA['id'])['created_by'],a.id);
      expect(links.firstWhere((r)=>r['shift_id']==shiftB['id'])['created_by'],b.id);
      expect(links.every((r)=>r['cash_delta_minor']==250),true);
      expect(()=>cmd(a,'shift_close',{'branch_id':branch,
        'shift_id':shiftB['id'],'closing_actual_minor':5250}),
        throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
      final closedA=cmd(a,'shift_close',{'branch_id':branch,
        'shift_id':shiftA['id'],'closing_actual_minor':10220});
      expect(closedA['expected_minor'],10250);
      expect(closedA['difference_minor'],-30);
      expect(()=>cmd(a,'sale',cashSale),
        throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
      final closedB=cmd(b,'shift_close',{'branch_id':branch,
        'shift_id':shiftB['id'],'closing_actual_minor':5250});
      expect(closedB['expected_minor'],5250);
      expect(closedB['difference_minor'],0);
      expect(engine.dashboard(owner,branch)['cash_minor'],500);
      expect(store.rows('''SELECT e.id FROM journal_entries e
        JOIN journal_lines l ON l.entry_id=e.id GROUP BY e.id
        HAVING SUM(l.debit_minor-l.credit_minor)<>0'''),isEmpty);
    }finally{store.dispose();}
  });

  test('other-operator drawer closure needs supervisor reason and no guessed cash',(){
    final store=DatabaseStore.memory();
    try {
      final engine=PosEngine(store);
      final boot=engine.bootstrap('اختبار إغلاق','الفرع','owner',
        'very-safe-password-123');
      final branch=boot['branch_id'] as String;
      final owner=Principal(boot['user_id'] as String,
        boot['tenant_id'] as String,branch,'owner','owner');
      var seq=0;
      Map<String,Object?> cmd(Principal p,String action,Map<String,dynamic> data)=>
        engine.command(p,action,data,'shift-override-test-${seq++}-unique');
      final drawer=cmd(owner,'cash_drawer_create',
        {'branch_id':branch,'name':'درج المبيعات'});
      final user=cmd(owner,'create_user',{'branch_id':branch,
        'username':'worker','password':'worker-long-password-123',
        'role':'cashier'});
      final cashier=Principal(user['id'] as String,owner.tenantId,branch,
        'cashier','worker');
      final opened=cmd(cashier,'shift_open',{
        'branch_id':branch,'cash_drawer_id':drawer['id'],
        'opening_minor':1000});
      expect(()=>cmd(owner,'shift_close',{'branch_id':branch,
        'shift_id':opened['id'],'closing_actual_minor':1000}),
        throwsA(isA<DomainError>()));
      final result=cmd(owner,'shift_close',{'branch_id':branch,
        'shift_id':opened['id'],'closing_actual_minor':900,
        'override_reason':'جرد مستقل بعد غياب الموظف'});
      expect(result['difference_minor'],-100);
      final audit=engine.audit(owner,branch);
      expect(audit.any((r)=>r['action']=='shift.closed' &&
        (r['details_json'] as String).contains('override_reason')),true);
      final newShift=cmd(cashier,'shift_open',{
        'branch_id':branch,'cash_drawer_id':drawer['id'],
        'opening_minor':900});
      expect(newShift['drawer_id'],drawer['id']);
    }finally{store.dispose();}
  });
}
