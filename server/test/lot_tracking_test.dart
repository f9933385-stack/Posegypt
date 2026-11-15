import 'package:test/test.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late Principal owner;
  late String branch, warehouse;
  var seq=0;
  Map<String,Object?> op(String action,Map<String,dynamic> body) =>
    engine.command(owner,action,body,'expiry-test-key-'+(seq++).toString()+'-unique-123456789');

  setUp(() {
    store=DatabaseStore.memory(); engine=PosEngine(store);
    final setup=engine.bootstrap('متجر اختبار','الرئيسي','admin','expiry-test-strong-password');
    owner=Principal(setup['user_id'] as String,setup['tenant_id'] as String,
      setup['branch_id'] as String,'owner','admin');
    branch=setup['branch_id'] as String; warehouse=setup['warehouse_id'] as String;
  });
  tearDown(() => store.dispose());

  Map<String,Object?> product(String sku)=>op('create_product',{
    'sku':sku,'name_ar':'لبن','sell_price_minor':200,'track_expiry':true
  });
  Map<String,Object?> supplier()=>op('create_supplier',{'name':'مورد'});
  Map<String,Object?> purchase(String productId,String supplierId,int qty,String lot,String expiry)=>
    op('purchase',{'branch_id':branch,'supplier_id':supplierId,'lines':[
      {'product_id':productId,'qty_milli':qty,'unit_cost_minor':100,
        'lot_no':lot,'expires_on':expiry}
    ],'payments':<Map<String,dynamic>>[]});
  Map<String,Object?> sale(String productId,int qty)=>op('sale',{'branch_id':branch,
    'lines':[{'product_id':productId,'qty_milli':qty}],
    'payments':[{'method':'cash','amount_minor':qty*200~/1000}]});

  test('FEFO selects earliest expiry and returns restore original source lots',() {
    final p=product('FEFO-A'), sup=supplier();
    purchase(p['id'] as String,sup['id'] as String,3000,'LOT-A','2030-01-01');
    purchase(p['id'] as String,sup['id'] as String,5000,'LOT-B','2032-01-01');
    final sold=sale(p['id'] as String,4000);
    expect(sold['cogs_minor'],400);
    expect(engine.listLots(owner,branch,productId:p['id'] as String)
      .map((x)=>x['qty_milli']).toList(),[0,4000]);
    final line=(engine.readDocument(owner,sold['id'] as String)['lines'] as List).single;
    final saleMoves=store.rows('''SELECT qty_change_milli FROM batch_movements
      WHERE document_line_id=? AND reference_type='sale' ORDER BY qty_change_milli''',[line['id']]);
    expect(saleMoves.map((x)=>x['qty_change_milli']).toList(),[-3000,-1000]);
    final returned=op('sale_return',{'branch_id':branch,'original_id':sold['id'],
      'refund_method':'cash','lines':[{'original_line_id':line['id'],'qty_milli':2000}]});
    expect(returned['total_minor'],400);
    expect(engine.listLots(owner,branch,productId:p['id'] as String)
      .map((x)=>x['qty_milli']).toList(),[2000,4000]);
    expect(engine.listStock(owner,branch).single['qty_milli'],6000);
  });

  test('expired intake and expired sales are rejected atomically',() {
    final p=product('EXPIRED-A'), sup=supplier();
    expect(()=>purchase(p['id'] as String,sup['id'] as String,
      1000,'OLD','2020-02-29'),throwsA(isA<DomainError>()));
    expect(store.rows("SELECT id FROM documents WHERE kind='purchase'"),isEmpty);
    purchase(p['id'] as String,sup['id'] as String,1000,'PERISH','2031-01-01');
    // Simulate the expiry date passing without altering application clock.
    store.exec("UPDATE batches SET expires_on='2020-01-01' WHERE product_id=?",[p['id']]);
    expect(()=>sale(p['id'] as String,1000),throwsA(isA<DomainError>()));
    expect(engine.listStock(owner,branch).single['qty_milli'],1000);
    expect(engine.listLots(owner,branch,productId:p['id'] as String)
      .single['sellable_qty_milli'],0);
    expect(store.rows("SELECT id FROM documents WHERE kind='sale'"),isEmpty);
  });

  test('same-branch transfer preserves expiry lot and value',() {
    final p=product('FEFO-TRANSFER'), sup=supplier();
    purchase(p['id'] as String,sup['id'] as String,4000,'LOT-Z','2031-02-01');
    final secondary=op('create_warehouse',{'branch_id':branch,'name':'الثلاجة'});
    op('transfer_warehouse',{'branch_id':branch,'source_warehouse_id':warehouse,
      'destination_warehouse_id':secondary['id'],'product_id':p['id'],'qty_milli':1500});
    final list=engine.listLots(owner,branch,productId:p['id'] as String);
    expect(list.length,2);
    expect(list.singleWhere((x)=>x['warehouse_id']==warehouse)['qty_milli'],2500);
    final moved=list.singleWhere((x)=>x['warehouse_id']==secondary['id']);
    expect(moved['qty_milli'],1500);
    expect(moved['lot_no'],'LOT-Z');
    expect(moved['expires_on'],'2031-02-01');
    expect(engine.dashboard(owner,branch)['stock_value_minor'],400);
  });

  test('supplier return cannot take units from a different receipt lot',() {
    final p=product('LOT-RETURN'), sup=supplier();
    final first=purchase(p['id'] as String,sup['id'] as String,2000,'FIRST','2030-01-01');
    purchase(p['id'] as String,sup['id'] as String,3000,'SECOND','2031-01-01');
    sale(p['id'] as String,1500);
    final orig=(engine.readDocument(owner,first['id'] as String)['lines'] as List).single;
    expect(()=>op('purchase_return',{'branch_id':branch,'original_id':first['id'],
      'lines':[{'original_line_id':orig['id'],'qty_milli':1000}]}),
      throwsA(isA<DomainError>()));
    expect(engine.listLots(owner,branch,productId:p['id'] as String)
      .map((x)=>x['qty_milli']).toList(),[500,3000]);
  });

  test('stock adjustments require explicit batch and logged correction',() {
    final p=product('LOT-COUNT'), sup=supplier();
    purchase(p['id'] as String,sup['id'] as String,2000,'COUNT-A','2030-01-01');
    expect(()=>op('adjust_stock',{'branch_id':branch,'product_id':p['id'],
      'qty_change_milli':-500,'reason':'تالف'}),throwsA(isA<DomainError>()));
    final lot=engine.listLots(owner,branch).single;
    op('adjust_stock',{'branch_id':branch,'product_id':p['id'],
      'qty_change_milli':-500,'batch_id':lot['id'],'reason':'تالف'});
    op('adjust_stock',{'branch_id':branch,'product_id':p['id'],
      'qty_change_milli':500,'lot_no':'COUNT-B','expires_on':'2032-01-01',
      'added_cost_minor':50,'reason':'إضافة الجرد'});
    expect(engine.listLots(owner,branch).fold<int>(0,(sum,row)=>
      sum+(row['qty_milli'] as int)),2000);
    expect(engine.listStock(owner,branch).single['qty_milli'],2000);
  });

  test('quarantine blocks FEFO, staff may block but only manager can release', () {
    final p=product('QUARANTINE'),sup=supplier();
    purchase(p['id'] as String,sup['id'] as String,2000,'RECALLED','2030-01-01');
    purchase(p['id'] as String,sup['id'] as String,3000,'SAFE','2031-01-01');
    final first=engine.listLots(owner,branch,productId:p['id'] as String).first;
    final user=op('create_user',{'branch_id':branch,'role':'stock',
      'username':'stock-user','password':'strong-pass-for-stock-user'});
    final staff=Principal(user['id'] as String,owner.tenantId,branch,'stock','stock-user');
    final request={'branch_id':branch,'warehouse_id':warehouse,
      'batch_id':first['id'],'quarantined':true,'reason':'فحص جودة'};
    engine.command(staff,'set_lot_quarantine',request,
      'stock-quarantine-key-12345678900000');
    final rows=engine.listLots(owner,branch,productId:p['id'] as String);
    expect(rows.first['quarantined'],true);
    expect(rows.first['sellable_qty_milli'],0);
    expect(()=>engine.command(staff,'set_lot_quarantine',{
      ...request,'quarantined':false},'stock-release-denied-123456789000'),
      throwsA(isA<DomainError>()));
    final sold=sale(p['id'] as String,3000);
    expect(sold['total_minor'],600);
    expect(engine.listLots(owner,branch,productId:p['id'] as String)
      .map((x)=>x['qty_milli']).toList(),[2000,0]);
    expect(()=>sale(p['id'] as String,1000),throwsA(isA<DomainError>()));
    op('set_lot_quarantine',{...request,'quarantined':false,
      'reason':'نتيجة الفحص سليمة'});
    expect(engine.listLots(owner,branch,productId:p['id'] as String).first['quarantined'],false);
    expect(sale(p['id'] as String,1000)['total_minor'],200);
    expect(store.rows("SELECT action FROM audit_logs WHERE action LIKE 'lot.%'").length,2);
  });

  test('preparation does not silently discard tracked provenance',() {
    final p=product('TRACKED-PREP'), sup=supplier();
    final output=op('create_product',{'sku':'OUT','name_ar':'مُجهّز','sell_price_minor':350});
    purchase(p['id'] as String,sup['id'] as String,1000,'PREP','2031-01-01');
    expect(()=>op('prepare',{'branch_id':branch,'source_product_id':p['id'],
      'output_product_id':output['id'],'input_qty_milli':1000,'output_qty_milli':1000}),
      throwsA(isA<DomainError>()));
    expect(engine.listStock(owner,branch).single['qty_milli'],1000);
  });
}
