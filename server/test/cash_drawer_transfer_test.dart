import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late Principal owner,one,two,three;
  late String branch;
  late String firstShift,secondShift;
  var serial=0;
  Map<String,Object?> run(Principal p,String action,Map<String,dynamic> body) =>
    engine.command(p,action,body,'cash-transfer-test-${serial++}-unique-key');

  setUp(() {
    store=DatabaseStore.memory();
    engine=PosEngine(store);
    final setup=engine.bootstrap('تسليم عهدة','الفرع الأول','owner',
      'very-safe-password-123');
    branch=setup['branch_id'] as String;
    owner=Principal(setup['user_id'] as String,setup['tenant_id'] as String,
      branch,'owner','owner');
    final firstDrawer=run(owner,'cash_drawer_create',{
      'branch_id':branch,'name':'درج أ'});
    final secondDrawer=run(owner,'cash_drawer_create',{
      'branch_id':branch,'name':'درج ب'});
    Principal create(String name) {
      final result=run(owner,'create_user',{
        'branch_id':branch,'username':name,
        'password':'account-password-123456','role':'cashier'});
      return Principal(result['id'] as String,owner.tenantId,branch,
        'cashier',name);
    }
    one=create('cashier-one');
    two=create('cashier-two');
    three=create('cashier-three');
    firstShift=run(one,'shift_open',{'branch_id':branch,
      'cash_drawer_id':firstDrawer['id'],'opening_minor':1000})['id'] as String;
    secondShift=run(two,'shift_open',{'branch_id':branch,
      'cash_drawer_id':secondDrawer['id'],'opening_minor':400})['id'] as String;
  });
  tearDown(()=>store.dispose());

  Map<String,dynamic> proposal(int amount,{String? dest}) => {
    'branch_id':branch,'source_shift_id':firstShift,
    'destination_shift_id':dest??secondShift,'amount_minor':amount,
    'reason':'تسليم عهدة نقدية بالمستند الداخلي',
  };
  Map<String,dynamic> decision(String id) => {
    'transfer_id':id,'reason':'تم عد المبلغ وتسليمه وتوقيعه',
  };

  test('recipient-approved cash moves between two expected drawer balances but never changes GL',() {
    final vendor=run(owner,'create_supplier',{'name':'المورد'});
    final product=run(owner,'create_product',{
      'sku':'TRANSFER-1','name_ar':'صنف','sell_price_minor':200});
    run(owner,'purchase',{'branch_id':branch,'supplier_id':vendor['id'],
      'lines':[{'product_id':product['id'],'qty_milli':2000,
        'unit_cost_minor':100}],'payments':<Map<String,dynamic>>[]});
    run(one,'sale',{'branch_id':branch,
      'lines':[{'product_id':product['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':200}]});
    final cashBefore=engine.dashboard(owner,branch)['cash_minor'];
    final journalBefore=store.rows('SELECT id FROM journal_entries').length;

    const idempotency='cash-transfer-unique-replay-12345678';
    final pending=engine.command(one,'cash_transfer_request',proposal(350),idempotency);
    expect(engine.command(one,'cash_transfer_request',proposal(350),idempotency),pending);
    expect(pending['status'],'pending');
    expect(store.rows('SELECT * FROM cash_drawer_transfers'),hasLength(1));
    expect(store.rows('SELECT * FROM journal_entries'),hasLength(journalBefore));
    expect(engine.dashboard(owner,branch)['cash_minor'],cashBefore);

    final q=engine.listCashTransfers(one,branch);
    expect(q,hasLength(1));
    expect(q.single['status'],'pending');
    expect(engine.listCashTransfers(three,branch),isEmpty);
    expect(()=>run(one,'cash_transfer_approve',decision(pending['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    expect(()=>run(owner,'cash_transfer_approve',decision(pending['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    expect(()=>run(one,'shift_close',{'branch_id':branch,
      'shift_id':firstShift,'closing_actual_minor':850}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    expect(()=>run(two,'shift_close',{'branch_id':branch,
      'shift_id':secondShift,'closing_actual_minor':750}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));

    final accepted=run(two,'cash_transfer_approve',decision(pending['id'] as String));
    expect(accepted['status'],'approved');
    expect(accepted['sender_expected_minor'],850);
    expect(accepted['receiver_expected_minor'],750);
    expect(store.rows('SELECT * FROM journal_entries'),hasLength(journalBefore));
    expect(engine.dashboard(owner,branch)['cash_minor'],cashBefore);
    expect(()=>run(two,'cash_transfer_approve',decision(pending['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    final closedOne=run(one,'shift_close',{'branch_id':branch,
      'shift_id':firstShift,'closing_actual_minor':830});
    final closedTwo=run(two,'shift_close',{'branch_id':branch,
      'shift_id':secondShift,'closing_actual_minor':750});
    expect(closedOne['expected_minor'],850);
    expect(closedOne['difference_minor'],-20);
    expect(closedTwo['expected_minor'],750);
    expect(closedTwo['difference_minor'],0);
    expect(store.rows('''SELECT e.id FROM journal_entries e
      JOIN journal_lines l ON l.entry_id=e.id GROUP BY e.id
      HAVING SUM(l.debit_minor-l.credit_minor)<>0'''),isEmpty);
    expect(engine.audit(owner,branch)
      .any((x)=>x['action']=='cash_transfer.approved'),true);
  });

  test('invalid cross-branch, negative, oversized and self transfers never modify cash',(){
    final otherBranch=run(owner,'create_branch',{
      'name':'فرع آخر','code':'TRANSFER-B2'});
    final drawer=run(owner,'cash_drawer_create',{
      'branch_id':otherBranch['id'],'name':'درج فرع آخر'});
    final distant=run(owner,'shift_open',{
      'branch_id':otherBranch['id'],'cash_drawer_id':drawer['id'],
      'opening_minor':300});
    final invalid=[
      proposal(-1),proposal(0),proposal(1001),proposal(1000000001),
      proposal(10,dest:firstShift),
      proposal(10,dest:distant['id'] as String),
      {...proposal(10),'reason':'short'},
    ];
    for(final payload in invalid){
      expect(()=>run(one,'cash_transfer_request',payload),
        throwsA(isA<Exception>()));
    }
    expect(()=>run(three,'cash_transfer_request',proposal(10)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    expect(store.rows('SELECT * FROM cash_drawer_transfers'),isEmpty);
    expect(store.rows('SELECT * FROM journal_entries'),isEmpty);
    expect(engine.dashboard(owner,branch)['cash_minor'],0);
  });

  test('receiver may reject and sender may cancel; no cash or journal change',(){
    final a=run(one,'cash_transfer_request',proposal(150));
    expect(()=>run(three,'cash_transfer_reject',decision(a['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    expect(()=>run(owner,'cash_transfer_reject',decision(a['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    final rejected=run(two,'cash_transfer_reject',decision(a['id'] as String));
    expect(rejected['status'],'rejected');
    final b=run(one,'cash_transfer_request',proposal(200));
    expect(()=>run(two,'cash_transfer_cancel',decision(b['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    final cancelled=run(one,'cash_transfer_cancel',decision(b['id'] as String));
    expect(cancelled['status'],'cancelled');
    expect(store.rows('SELECT * FROM journal_entries'),isEmpty);
    expect(engine.dashboard(owner,branch)['cash_minor'],0);
    final oneClose=run(one,'shift_close',{'branch_id':branch,
      'shift_id':firstShift,'closing_actual_minor':1000});
    final twoClose=run(two,'shift_close',{'branch_id':branch,
      'shift_id':secondShift,'closing_actual_minor':400});
    expect(oneClose['expected_minor'],1000);
    expect(twoClose['expected_minor'],400);
  });

  test('approval recalculates sender balance after another accepted transfer',(){
    final x=run(one,'cash_transfer_request',proposal(700));
    final y=run(one,'cash_transfer_request',proposal(600));
    final approved=run(two,'cash_transfer_approve',decision(x['id'] as String));
    expect(approved['sender_expected_minor'],300);
    expect(()=>run(two,'cash_transfer_approve',decision(y['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    expect(store.first('SELECT status FROM cash_drawer_transfers WHERE id=?',
      [y['id']])!['status'],'pending');
    run(two,'cash_transfer_reject',decision(y['id'] as String));
    final closed=run(one,'shift_close',{'branch_id':branch,
      'shift_id':firstShift,'closing_actual_minor':300});
    expect(closed['difference_minor'],0);
    expect(run(two,'shift_close',{'branch_id':branch,
      'shift_id':secondShift,'closing_actual_minor':1100})['difference_minor'],0);
    expect(store.rows('SELECT * FROM cash_shift_journal_links'),isEmpty);
  });

  test('no transfers can be requested without independent active drawers',(){
    final no=run(one,'shift_close',{'branch_id':branch,
      'shift_id':firstShift,'closing_actual_minor':1000});
    expect(no['difference_minor'],0);
    expect(()=>run(one,'cash_transfer_request',proposal(50)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    expect(store.rows('SELECT * FROM cash_drawer_transfers'),isEmpty);
  });
}
