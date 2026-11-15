import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late Principal owner,manager,cashier,second;
  late String branch,shiftId,safeId;
  var seq=0;
  Map<String,Object?> run(Principal actor,String action,Map<String,dynamic> body) =>
    engine.command(actor,action,body,'branch-safe-test-${seq++}-unique-key');

  setUp((){
    store=DatabaseStore.memory();
    engine=PosEngine(store);
    final setup=engine.bootstrap('خزينة نقدية','فرع المتجر','admin',
      'very-strong-password-1234');
    branch=setup['branch_id'] as String;
    owner=Principal(setup['user_id'] as String,setup['tenant_id'] as String,
      branch,'owner','admin');
    Principal add(String username,String role) {
      final user=run(owner,'create_user',{'branch_id':branch,'username':username,
        'password':'long-user-password-1234','role':role});
      return Principal(user['id'] as String,owner.tenantId,branch,role,username);
    }
    manager=add('vault-manager','manager');
    cashier=add('vault-cashier','cashier');
    second=add('second-cashier','cashier');
    expect(()=>run(owner,'cash_safe_create',{'branch_id':branch,
      'name':'الخزينة الرئيسية'}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    final drawer=run(owner,'cash_drawer_create',{'branch_id':branch,
      'name':'درج المبيعات'});
    safeId=run(owner,'cash_safe_create',{'branch_id':branch,
      'name':'الخزينة الرئيسية'})['id'] as String;
    shiftId=run(cashier,'shift_open',{'branch_id':branch,
      'cash_drawer_id':drawer['id'],'opening_minor':1200})['id'] as String;
  });
  tearDown(()=>store.dispose());

  Map<String,dynamic> request(int amount)=>{'branch_id':branch,
    'source_shift_id':shiftId,'amount_minor':amount,
    'reason':'محضر استلام نقدية في خزينة الفرع'};
  Map<String,dynamic> review(String id)=>{'drop_id':id,
    'reason':'تم العد الفعلي داخل الخزينة وتوقيع المحضر'};

  test('safe receives only independently approved drops; physical total and GL unchanged',(){
    final cashBefore=engine.dashboard(owner,branch)['cash_minor'];
    final journals=store.rows('SELECT id FROM journal_entries').length;
    final safeBefore=engine.readCashSafe(owner,branch);
    expect(safeBefore['balance_minor'],0);
    expect(safeBefore['id'],safeId);
    final pending=run(cashier,'cash_safe_drop_request',request(450));
    expect(pending['status'],'pending');
    expect(engine.readCashSafe(owner,branch)['balance_minor'],0);
    expect(store.rows('SELECT id FROM journal_entries'),hasLength(journals));
    expect(engine.listCashSafeDrops(cashier,branch),hasLength(1));
    expect(engine.listCashSafeDrops(second,branch),isEmpty);

    expect(()=>run(cashier,'cash_safe_drop_approve',
      review(pending['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    expect(()=>run(cashier,'shift_close',{'branch_id':branch,
      'shift_id':shiftId,'closing_actual_minor':750}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    expect(()=>run(second,'cash_safe_drop_approve',
      review(pending['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    final approve=run(manager,'cash_safe_drop_approve',
      review(pending['id'] as String));
    expect(approve['status'],'approved');
    expect(approve['safe_balance_minor'],450);
    expect(approve['sender_expected_minor'],750);
    expect(engine.readCashSafe(owner,branch)['balance_minor'],450);
    expect(store.rows('SELECT id FROM journal_entries'),hasLength(journals));
    expect(engine.dashboard(owner,branch)['cash_minor'],cashBefore);
    expect(()=>run(manager,'cash_safe_drop_approve',
      review(pending['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    final close=run(cashier,'shift_close',{'branch_id':branch,
      'shift_id':shiftId,'closing_actual_minor':725});
    expect(close['expected_minor'],750);
    expect(close['difference_minor'],-25);
    expect(engine.readCashSafe(manager,branch)['balance_minor'],450);
    expect(engine.audit(owner,branch)
      .any((x)=>x['action']=='cash_safe_drop.approved'),true);
  });

  test('rejected and cancelled safe drops never count as cash in vault',(){
    final first=run(cashier,'cash_safe_drop_request',request(200));
    final rejected=run(manager,'cash_safe_drop_reject',
      review(first['id'] as String));
    expect(rejected['status'],'rejected');
    final secondDrop=run(cashier,'cash_safe_drop_request',request(300));
    expect(()=>run(second,'cash_safe_drop_cancel',
      review(secondDrop['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    final cancelled=run(cashier,'cash_safe_drop_cancel',
      review(secondDrop['id'] as String));
    expect(cancelled['status'],'cancelled');
    expect(engine.readCashSafe(owner,branch)['balance_minor'],0);
    expect(run(cashier,'shift_close',{'branch_id':branch,
      'shift_id':shiftId,'closing_actual_minor':1200})['difference_minor'],0);
    expect(store.rows('SELECT id FROM journal_entries'),isEmpty);
  });

  test('a stale second safe drop is rejected if another approved drop spent the balance',(){
    final first=run(cashier,'cash_safe_drop_request',request(750));
    final secondDrop=run(cashier,'cash_safe_drop_request',request(650));
    final accepted=run(manager,'cash_safe_drop_approve',
      review(first['id'] as String));
    expect(accepted['safe_balance_minor'],750);
    expect(()=>run(manager,'cash_safe_drop_approve',
      review(secondDrop['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    expect(store.first('SELECT status FROM cash_safe_drops WHERE id=?',
      [secondDrop['id']])!['status'],'pending');
    run(manager,'cash_safe_drop_reject',review(secondDrop['id'] as String));
    expect(run(cashier,'shift_close',{'branch_id':branch,
      'shift_id':shiftId,'closing_actual_minor':450})['expected_minor'],450);
    expect(engine.readCashSafe(owner,branch)['balance_minor'],750);
  });

  test('no same-user supervisor approval, overdraw, cross-branch or forged source',(){
    expect(()=>run(cashier,'cash_safe_create',{
      'branch_id':branch,'name':'خزينة أخرى'}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    expect(()=>run(owner,'cash_safe_create',{
      'branch_id':branch,'name':'خزينة أخرى'}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',409)));
    final invalid=[request(0),request(-20),request(1201),
      request(1000000001),{...request(30),'reason':'short'}];
    for(final body in invalid) {
      expect(()=>run(cashier,'cash_safe_drop_request',body),
        throwsA(isA<Exception>()));
    }
    expect(()=>run(second,'cash_safe_drop_request',request(30)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    final otherBranch=run(owner,'create_branch',{
      'name':'فرع آخر','code':'SAFEB2'});
    expect(()=>run(cashier,'cash_safe_drop_request',{
      ...request(30),'branch_id':otherBranch['id']}),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    expect(store.rows('SELECT * FROM cash_safe_drops'),isEmpty);

    // A manager operating a till must not approve their own handover.
    final secondDrawer=run(owner,'cash_drawer_create',{
      'branch_id':branch,'name':'درج المدير'});
    final managerShift=run(manager,'shift_open',{'branch_id':branch,
      'cash_drawer_id':secondDrawer['id'],'opening_minor':600});
    final self=run(manager,'cash_safe_drop_request',{
      'branch_id':branch,'source_shift_id':managerShift['id'],
      'amount_minor':250,'reason':'تسليم نقدية من عهدة المدير للخزينة'});
    expect(()=>run(manager,'cash_safe_drop_approve',review(self['id'] as String)),
      throwsA(isA<DomainError>().having((e)=>e.status,'status',403)));
    expect(run(owner,'cash_safe_drop_approve',
      review(self['id'] as String))['safe_balance_minor'],250);
  });

  test('failed operations preserve idempotency and no double-counted journal',(){
    const key='same-safe-drop-idempotency-key-12345';
    final first=engine.command(cashier,'cash_safe_drop_request',
      request(500),key);
    expect(engine.command(cashier,'cash_safe_drop_request',
      request(500),key),first);
    expect(()=>engine.command(cashier,'cash_safe_drop_request',
      request(501),key),throwsA(isA<DomainError>().having(
        (e)=>e.status,'status',409)));
    expect(store.rows('SELECT id FROM cash_safe_drops'),hasLength(1));
    expect(run(manager,'cash_safe_drop_approve',
      review(first['id'] as String))['safe_balance_minor'],500);
    expect(store.rows('SELECT * FROM journal_entries'),isEmpty);
    expect(store.rows('SELECT * FROM cash_shift_journal_links'),isEmpty);
    expect(engine.dashboard(owner,branch)['cash_minor'],0);
  });
}
