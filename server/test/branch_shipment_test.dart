import 'package:test/test.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';

void main() {
  late DatabaseStore db;
  late PosEngine engine;
  late Principal owner,receiver,sourceManager;
  late String sourceBranch,destinationBranch,sourceWarehouse,destinationWarehouse;
  var sequence=0;

  Map<String,Object?> cmd(Principal person,String action,Map<String,dynamic> body) =>
    engine.command(person,action,body,'branch-shipment-'+(sequence++).toString()+'-unique-123456');

  setUp(() {
    db=DatabaseStore.memory();
    engine=PosEngine(db);
    final setup=engine.bootstrap('متجر تحويلات','الفرع الأول','admin',
      'branch-owner-password-123');
    sourceBranch=setup['branch_id'] as String;
    sourceWarehouse=setup['warehouse_id'] as String;
    owner=Principal(setup['user_id'] as String,setup['tenant_id'] as String,
      sourceBranch,'owner','admin');
    final created=cmd(owner,'create_branch',{'name':'الفرع الثاني','code':'BR02'});
    destinationBranch=created['id'] as String;
    destinationWarehouse=created['warehouse_id'] as String;
    final mgr=cmd(owner,'create_user',{'username':'branch-two-manager',
      'password':'manager-two-password-123','role':'manager',
      'branch_id':destinationBranch});
    receiver=Principal(mgr['id'] as String,owner.tenantId,
      destinationBranch,'manager','branch-two-manager');
    final from=cmd(owner,'create_user',{'username':'branch-one-manager',
      'password':'manager-one-password-123','role':'manager',
      'branch_id':sourceBranch});
    sourceManager=Principal(from['id'] as String,owner.tenantId,
      sourceBranch,'manager','branch-one-manager');
  });
  tearDown(()=>db.dispose());

  Map<String,Object?> seeded(String sku,{bool tracked=false}) {
    final product=cmd(owner,'create_product',{
      'sku':sku,'name_ar':'أرز تحويل','sell_price_minor':220,
      'track_expiry':tracked});
    final supplier=cmd(owner,'create_supplier',{'name':'مورد النقل'});
    cmd(owner,'purchase',{'branch_id':sourceBranch,'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':7000,
        'unit_cost_minor':100,
        if(tracked)'lot_no':if(tracked)'NEAR',if(tracked)'expires_on':'2030-01-01'}],
      'payments':<Map<String,dynamic>>[]});
    if(tracked) {
      cmd(owner,'purchase',{'branch_id':sourceBranch,'supplier_id':supplier['id'],
        'lines':[{'product_id':product['id'],'qty_milli':4000,
          'unit_cost_minor':100,'lot_no':'FAR','expires_on':'2032-01-01'}],
        'payments':<Map<String,dynamic>>[]});
    }
    return product;
  }

  Map<String,dynamic> request(String product,{int qty=3000}) => {
    'source_branch_id':sourceBranch,'destination_branch_id':destinationBranch,
    'source_warehouse_id':sourceWarehouse,'destination_warehouse_id':destinationWarehouse,
    'product_id':product,'qty_milli':qty,
  };

  test('dispatch removes source stock into transit; independent receiver posts destination',(){
    final product=seeded('SHIPPED-1');
    final args=request(product['id'] as String);
    final ticket=cmd(sourceManager,'branch_shipment_dispatch',args);
    final id=ticket['id'] as String;
    expect(ticket['status'],'in_transit');
    expect(ticket['qty_milli'],3000);
    expect(ticket['cost_minor'],300);
    expect(engine.listStock(owner,sourceBranch).single['qty_milli'],4000);
    expect(engine.listStock(owner,destinationBranch),isEmpty);
    expect(engine.listBranchShipments(receiver,destinationBranch).single['id'],id);
    final received=cmd(receiver,'branch_shipment_receive',{'shipment_id':id});
    expect(received['status'],'received');
    expect(engine.listStock(owner,destinationBranch).single['qty_milli'],3000);
    expect(engine.listStock(owner,destinationBranch).single['cost_minor'],300);
    expect(engine.listStock(owner,sourceBranch).single['cost_minor'],400);
    expect(engine.readBranchShipment(receiver,id)['received_by'],receiver.id);
    expect(()=>cmd(receiver,'branch_shipment_receive',{'shipment_id':id}),
      throwsA(isA<DomainError>()));
    final transit=db.first('''SELECT COALESCE(SUM(l.debit_minor-l.credit_minor),0) AS balance
      FROM journal_lines l WHERE l.account='IN_TRANSIT' ''');
    expect(transit?['balance'],0);
    final broken=db.rows('''SELECT j.id FROM journal_entries j JOIN journal_lines l
      ON j.id=l.entry_id GROUP BY j.id
      HAVING SUM(l.debit_minor-l.credit_minor)<>0''');
    expect(broken,isEmpty);
    expect(db.rows("SELECT id FROM inventory_movements WHERE reference_type='branch_dispatch'").length,1);
    expect(db.rows("SELECT id FROM inventory_movements WHERE reference_type='branch_receive'").length,1);
  });

  test('shipment dispatch idempotency cannot deduct goods twice',(){
    final p=seeded('SHIP-IDEMP');
    final args=request(p['id'] as String);
    const key='same-branch-shipment-key-123456789';
    final one=engine.command(owner,'branch_shipment_dispatch',args,key);
    final two=engine.command(owner,'branch_shipment_dispatch',args,key);
    expect(one['id'],two['id']);
    expect(db.rows('SELECT id FROM branch_shipments').length,1);
    expect(engine.listStock(owner,sourceBranch).single['qty_milli'],4000);
    expect(()=>engine.command(owner,'branch_shipment_dispatch',
      {...args,'qty_milli':1000},key),throwsA(isA<DomainError>()));
  });

  test('FEFO lot identity survives dispatch and receipt in separate branch',(){
    final p=seeded('SHIP-LOTS',tracked:true);
    final ticket=cmd(owner,'branch_shipment_dispatch',
      request(p['id'] as String,qty:9000));
    final id=ticket['id'] as String;
    final pending=engine.readBranchShipment(owner,id);
    final lots=(pending['lots'] as List).cast<Map<String,Object?>>();
    expect(lots.map((x)=>x['lot_no']).toList(),['NEAR','FAR']);
    expect(lots.map((x)=>x['qty_milli']).toList(),[7000,2000]);
    expect(engine.listLots(owner,sourceBranch,productId:p['id'] as String)
      .map((x)=>x['qty_milli']).toList(),[0,2000]);
    cmd(receiver,'branch_shipment_receive',{'shipment_id':id});
    final destination=engine.listLots(owner,destinationBranch,productId:p['id'] as String);
    expect(destination.map((x)=>x['lot_no']).toList(),['NEAR','FAR']);
    expect(destination.map((x)=>x['qty_milli']).toList(),[7000,2000]);
    expect(engine.listStock(owner,destinationBranch).single['qty_milli'],9000);
    final sale=cmd(receiver,'sale',{'branch_id':destinationBranch,
      'lines':[{'product_id':p['id'],'qty_milli':3000}],
      'payments':[{'method':'cash','amount_minor':660}]});
    expect(sale['total_minor'],660);
    expect(engine.listLots(owner,destinationBranch,productId:p['id'] as String)
      .map((x)=>x['qty_milli']).toList(),[4000,2000]);
  });

  test('cancellation returns same lots to source and releases transit value',(){
    final p=seeded('SHIP-CANCEL',tracked:true);
    final ticket=cmd(owner,'branch_shipment_dispatch',
      request(p['id'] as String,qty:8000));
    final id=ticket['id'] as String;
    expect(cmd(sourceManager,'branch_shipment_cancel',{'shipment_id':id,
      'reason':'إلغاء الشحن'})['status'],'cancelled');
    expect(engine.listStock(owner,sourceBranch).single['qty_milli'],11000);
    expect(engine.listStock(owner,destinationBranch),isEmpty);
    expect(engine.listLots(owner,sourceBranch,productId:p['id'] as String)
      .map((x)=>x['qty_milli']).toList(),[7000,4000]);
    expect(()=>cmd(receiver,'branch_shipment_receive',{'shipment_id':id}),
      throwsA(isA<DomainError>()));
    expect(()=>cmd(owner,'branch_shipment_cancel',{'shipment_id':id,'reason':'كرر'}),
      throwsA(isA<DomainError>()));
    final transit=db.first('''SELECT COALESCE(SUM(l.debit_minor-l.credit_minor),0) AS balance
      FROM journal_lines l WHERE l.account='IN_TRANSIT' ''');
    expect(transit?['balance'],0);
  });

  test('wrong branch and self-receipt denied without changes',(){
    final p=seeded('SHIP-AUTH');
    final ticket=cmd(owner,'branch_shipment_dispatch',request(p['id'] as String));
    final id=ticket['id'] as String;
    expect(()=>cmd(owner,'branch_shipment_receive',{'shipment_id':id}),
      throwsA(isA<DomainError>()));
    expect(()=>cmd(sourceManager,'branch_shipment_receive',{'shipment_id':id}),
      throwsA(isA<DomainError>()));
    expect(()=>cmd(receiver,'branch_shipment_cancel',{'shipment_id':id,'reason':'x'}),
      throwsA(isA<DomainError>()));
    expect(engine.listStock(owner,destinationBranch),isEmpty);
    expect(engine.readBranchShipment(owner,id)['status'],'in_transit');
  });

  test('insufficient source stock or nonexistent destination do not create shipment',(){
    final p=seeded('SHIP-NO-STOCK');
    expect(()=>cmd(owner,'branch_shipment_dispatch',
      request(p['id'] as String,qty:9000)),throwsA(isA<DomainError>()));
    expect(()=>cmd(owner,'branch_shipment_dispatch',
      {...request(p['id'] as String),'destination_branch_id':'unknown-branch'}),
      throwsA(isA<DomainError>()));
    expect(db.rows('SELECT * FROM branch_shipments'),isEmpty);
    expect(engine.listStock(owner,sourceBranch).single['qty_milli'],7000);
    expect(db.rows("SELECT id FROM journal_entries WHERE reference_type='branch_dispatch'"),isEmpty);
  });
}
