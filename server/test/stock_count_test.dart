import 'package:test/test.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late Principal owner,stock,second;
  late String branch,warehouse;
  var seq=0;
  Map<String,Object?> act(Principal principal,String action,Map<String,dynamic> input)=>
    engine.command(principal,action,input,'count-test-'+(seq++).toString()+'-unique-key-123456789');

  setUp(() {
    store=DatabaseStore.memory();
    engine=PosEngine(store);
    final setup=engine.bootstrap('محل الجرد','الفرع','admin','test-strong-password-123');
    branch=setup['branch_id'] as String;
    warehouse=setup['warehouse_id'] as String;
    owner=Principal(setup['user_id'] as String,setup['tenant_id'] as String,branch,'owner','admin');
    final worker=act(owner,'create_user',{
      'username':'inventory-worker','password':'stock-worker-strong-123',
      'role':'stock','branch_id':branch});
    stock=Principal(worker['id'] as String,owner.tenantId,branch,'stock','inventory-worker');
    final manager=act(owner,'create_user',{
      'username':'branch-manager','password':'manager-password-123',
      'role':'manager','branch_id':branch});
    second=Principal(manager['id'] as String,owner.tenantId,branch,'manager','branch-manager');
  });
  tearDown(()=>store.dispose());

  Map<String,Object?> product(String sku,{bool tracked=false})=>
    act(owner,'create_product',{'sku':sku,'name_ar':'منتج للاختبار',
      'sell_price_minor':250,'track_expiry':tracked});
  Map<String,Object?> receive(String sku,int qty,int unitCost,{bool tracked=false}) {
    final p=product(sku,tracked:tracked);
    final supplier=act(owner,'create_supplier',{'name':'مورد اختبار'});
    act(owner,'purchase',{'branch_id':branch,'supplier_id':supplier['id'],
      'lines':[{'product_id':p['id'],'qty_milli':qty,
        'unit_cost_minor':unitCost,
        if(tracked)'lot_no':'LOT-'+sku,
        if(tracked)'expires_on':'2031-01-01'}],
      'payments':<Map<String,dynamic>>[]});
    return p;
  }
  Map<String,Object?> open(Principal user)=>
    act(user,'count_open',{'branch_id':branch,'warehouse_id':warehouse,
      'reason':'جرد وردية ميداني'});
  Map<String,Object?> line(String id)=>(
    engine.readCount(stock,id)['lines'] as List).cast<Map<String,Object?>>().single;
  void record(String id,Object? lineId,int counted,{int? added})=>
    act(stock,'count_line',{'count_id':id,'line_id':lineId,
      'counted_qty_milli':counted,
      if(added!=null)'added_cost_minor':added});

  test('stocktake is draft until independent approval; increase posts exact cost',(){
    final p=receive('ST-ADD',1000,100);
    final count=open(stock);
    final id=count['id'] as String;
    expect(count['status'],'draft');
    final first=line(id);
    expect(first['expected_qty_milli'],1000);
    expect(engine.listCounts(stock,branch).single['status'],'draft');
    record(id,first['id'],1500,added:50);
    expect(engine.listStock(owner,branch).single['qty_milli'],1000);
    expect(engine.listStock(owner,branch).single['cost_minor'],100);
    expect(act(stock,'count_submit',{'count_id':id})['status'],'submitted');
    expect(()=>act(stock,'count_approve',{'count_id':id}),throwsA(isA<DomainError>()));
    final outcome=act(owner,'count_approve',{'count_id':id});
    expect(outcome['status'],'posted');
    expect(outcome['changed_lines'],1);
    expect(outcome['value_added_minor'],50);
    expect(engine.listStock(owner,branch).single['qty_milli'],1500);
    expect(engine.listStock(owner,branch).single['cost_minor'],150);
    expect(engine.dashboard(owner,branch)['stock_value_minor'],150);
    expect(engine.readCount(owner,id)['approved_by'],owner.id);
    expect(store.rows("SELECT id FROM inventory_movements WHERE reference_type='stock_count' AND reference_id=?",[id]).length,1);
    expect(store.rows("SELECT e.id FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id GROUP BY e.id HAVING SUM(l.debit_minor-l.credit_minor)<>0"),isEmpty);
    expect(()=>act(owner,'count_approve',{'count_id':id}),throwsA(isA<DomainError>()));
    expect(p['sku'],'ST-ADD');
  });

  test('zero quantity can be recorded and posts weighted-average full write-off',(){
    receive('ST-ZERO',3000,100);
    final id=open(stock)['id'] as String;
    record(id,line(id)['id'],0);
    act(stock,'count_submit',{'count_id':id});
    final result=act(second,'count_approve',{'count_id':id});
    expect(result['value_removed_minor'],300);
    expect(engine.listStock(owner,branch).single['qty_milli'],0);
    expect(engine.listStock(owner,branch).single['cost_minor'],0);
    expect(engine.dashboard(owner,branch)['stock_value_minor'],0);
  });

  test('unrecorded lines prevent submission and count entries may be cancelled',(){
    receive('ST-NO-INPUT',1000,100);
    final id=open(stock)['id'] as String;
    expect(()=>act(stock,'count_submit',{'count_id':id}),throwsA(isA<DomainError>()));
    expect(()=>open(stock),throwsA(isA<DomainError>()));
    expect(act(owner,'count_cancel',{'count_id':id,'reason':'تأجيل الجرد'})['status'],'cancelled');
    expect(open(stock)['status'],'draft');
    expect(engine.listStock(owner,branch).single['qty_milli'],1000);
  });

  test('warehouse sale after snapshot makes submitted count stale with no writes',(){
    final p=receive('ST-STALE',2000,100);
    final id=open(stock)['id'] as String;
    record(id,line(id)['id'],1000);
    act(owner,'sale',{'branch_id':branch,'lines':[{
      'product_id':p['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':250}]});
    expect(()=>act(stock,'count_submit',{'count_id':id}),throwsA(isA<DomainError>()));
    expect(engine.listStock(owner,branch).single['qty_milli'],1000);
    expect(store.rows("SELECT id FROM inventory_movements WHERE reference_type='stock_count'"),isEmpty);
  });

  test('stock changes after submitting forbid manager posting stale count',(){
    final p=receive('ST-STALE-2',2000,100);
    final id=open(stock)['id'] as String;
    record(id,line(id)['id'],1000);
    act(stock,'count_submit',{'count_id':id});
    act(owner,'sale',{'branch_id':branch,'lines':[{
      'product_id':p['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':250}]});
    expect(()=>act(owner,'count_approve',{'count_id':id}),throwsA(isA<DomainError>()));
    expect(engine.listStock(owner,branch).single['qty_milli'],1000);
    expect(engine.readCount(owner,id)['status'],'submitted');
  });

  test('lot count preserves tracked lots and movement audit',(){
    final p=receive('ST-LOT',2000,100,tracked:true);
    final id=open(stock)['id'] as String;
    final countLine=line(id);
    expect(countLine['batch_id'],isNotNull);
    record(id,countLine['id'],1500);
    act(stock,'count_submit',{'count_id':id});
    act(owner,'count_approve',{'count_id':id});
    final lots=engine.listLots(owner,branch,productId:p['id'] as String);
    expect(lots.single['qty_milli'],1500);
    expect(engine.listStock(owner,branch).single['qty_milli'],1500);
    expect(engine.listStock(owner,branch).single['cost_minor'],150);
    final movements=store.rows("SELECT qty_change_milli FROM batch_movements WHERE reference_type='stock_count'");
    expect(movements.single['qty_change_milli'],-500);
  });

  test('positive stocktake variance requires independently priced cost',(){
    receive('ST-PRICE',1000,100);
    final id=open(stock)['id'] as String;
    expect(()=>record(id,line(id)['id'],1500),throwsA(isA<DomainError>()));
    expect(engine.readCount(stock,id)['lines'] != null,isTrue);
    expect(engine.listStock(owner,branch).single['qty_milli'],1000);
  });

  test('posted stocktake does not permit editing or cancellation',(){
    receive('ST-CLOSED',1000,100);
    final id=open(stock)['id'] as String;
    record(id,line(id)['id'],1000);
    act(stock,'count_submit',{'count_id':id});
    act(owner,'count_approve',{'count_id':id});
    expect(()=>record(id,line(id)['id'],900),throwsA(isA<DomainError>()));
    expect(()=>act(owner,'count_cancel',{'count_id':id,'reason':'إلغاء بعد الاعتماد'}),
      throwsA(isA<DomainError>()));
    expect(store.rows("SELECT id FROM inventory_movements WHERE reference_type='stock_count'"),isEmpty);
  });
}
