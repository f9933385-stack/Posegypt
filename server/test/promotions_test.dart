import 'package:test/test.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';

void main() {
  late DatabaseStore db;
  late PosEngine engine;
  late Principal owner,cashier;
  late String branch;
  var seq=0;
  Map<String,Object?> act(Principal p,String op,Map<String,dynamic> body) =>
    engine.command(p,op,body,'promo-regression-'+(seq++).toString()+'-safe-123456789');

  setUp(() {
    db=DatabaseStore.memory();
    engine=PosEngine(db);
    final data=engine.bootstrap('تجربة عروض','الرئيسي','admin','test-secure-admin-123');
    branch=data['branch_id'] as String;
    owner=Principal(data['user_id'] as String,data['tenant_id'] as String,branch,'owner','admin');
    final u=act(owner,'create_user',{'username':'cashier-promos',
      'password':'cashier-promos-password-123','role':'cashier','branch_id':branch});
    cashier=Principal(u['id'] as String,owner.tenantId,branch,'cashier','cashier-promos');
  });
  tearDown(()=>db.dispose());

  Map<String,Object?> item(String sku) {
    final p=act(owner,'create_product',{'sku':sku,'name_ar':'منتج عرض','sell_price_minor':200});
    final sup=act(owner,'create_supplier',{'name':'مورد للاختبار'});
    act(owner,'purchase',{'branch_id':branch,'supplier_id':sup['id'],
      'lines':[{'product_id':p['id'],'qty_milli':10000,'unit_cost_minor':80}],
      'payments':<Map<String,dynamic>>[]});
    return p;
  }

  Map<String,Object?> offer(Object? productId,{
      Object? unitId,int price=150,String from='2025-01-01T00:00:00Z',
      String until='2030-12-31T00:00:00Z'}) {
    return act(owner,'create_promotion',{
      'product_id':productId,'title':'خصم الافتتاح',
      'promo_price_minor':price,'starts_at':from,'ends_at':until,
      if(unitId!=null)'unit_id':unitId});
  }

  test('cashier automatically uses current promotion but cannot override price',() {
    final p=item('PROMO-BASE');
    final prom=offer(p['id']);
    final row=engine.listProducts(cashier,search:'PROMO-BASE').single;
    expect(row['sell_price_minor'],200);
    expect(row['effective_sell_price_minor'],150);
    expect(row['promotion_id'],prom['id']);
    final sold=act(cashier,'sale',{'branch_id':branch,
      'lines':[{'product_id':p['id'],'qty_milli':2000}],
      'payments':[{'method':'cash','amount_minor':300}]});
    expect(sold['total_minor'],300);
    final details=(engine.readDocument(owner,sold['id'] as String)['lines'] as List).single;
    expect(details['unit_price_minor'],150);
    expect(details['gross_minor'],300);
    expect(sold['cogs_minor'],160);
    expect(()=>act(cashier,'sale',{'branch_id':branch,
      'lines':[{'product_id':p['id'],'qty_milli':1000,'unit_price_minor':200}],
      'payments':[{'method':'cash','amount_minor':200}]}),
      throwsA(isA<DomainError>()));
    expect(engine.listStock(owner,branch).single['qty_milli'],8000);
  });

  test('unit-specific carton offer does not override base price',() {
    final p=item('PROMO-UNIT');
    final u=act(owner,'create_product_unit',{'product_id':p['id'],
      'unit_name':'علبة','factor_milli':2000,'sell_price_minor':380});
    final offered=offer(p['id'],unitId:u['id'],price:325);
    final units=engine.listProductUnits(cashier,p['id'] as String);
    expect(units.single['effective_sell_price_minor'],325);
    expect(units.single['promotion_id'],offered['id']);
    expect(engine.listProducts(cashier,search:'PROMO-UNIT').single['effective_sell_price_minor'],200);
    final sold=act(cashier,'sale',{'branch_id':branch,
      'lines':[{'product_id':p['id'],'unit_id':u['id'],'unit_count':2}],
      'payments':[{'method':'cash','amount_minor':650}]});
    expect(sold['total_minor'],650);
    expect(sold['cogs_minor'],320);
  });

  test('overlapping offers rejected, future offers do not apply early',() {
    final p=item('PROMO-OVERLAP');
    offer(p['id'],price:150);
    expect(()=>offer(p['id'],price:130,from:'2029-01-01T00:00:00Z',
      until:'2031-01-01T00:00:00Z'),throwsA(isA<DomainError>()));
    expect(()=>offer(p['id'],price:100,from:'2028-01-01T00:00:00Z',
      until:'2027-01-01T00:00:00Z'),throwsA(isA<DomainError>()));
    final other=item('PROMO-FUTURE');
    offer(other['id'],price:100,from:'2031-01-01T00:00:00Z',
      until:'2032-01-01T00:00:00Z');
    expect(engine.listProducts(cashier,search:'PROMO-FUTURE').single['effective_sell_price_minor'],200);
  });

  test('owner can stop promotion, restoring normal price immediately',() {
    final p=item('PROMO-STOP');
    final o=offer(p['id']);
    expect(engine.listProducts(cashier,search:'PROMO-STOP').single['effective_sell_price_minor'],150);
    expect(()=>act(cashier,'stop_promotion',{'promotion_id':o['id'],
      'reason':'محاولة غير مصرح بها'}),throwsA(isA<DomainError>()));
    expect(act(owner,'stop_promotion',{'promotion_id':o['id'],'reason':'انتهاء التخفيض'})['active'],false);
    expect(engine.listProducts(cashier,search:'PROMO-STOP').single['effective_sell_price_minor'],200);
    expect(()=>act(owner,'stop_promotion',{'promotion_id':o['id'],'reason':'إعادة'}),throwsA(isA<DomainError>()));
    expect(act(cashier,'sale',{'branch_id':branch,
      'lines':[{'product_id':p['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':200}]})['total_minor'],200);
  });

  test('wrong tenant promotion and invalid time formats fail closed',() {
    final p=item('PROMO-VALIDATE');
    expect(()=>offer(p['id'],price:200),throwsA(isA<DomainError>()));
    expect(()=>offer(p['id'],price:0),throwsA(isA<DomainError>()));
    expect(()=>offer(p['id'],price:110,from:'2025-02-30T00:00:00Z'),
      throwsA(isA<DomainError>()));
    expect(()=>offer(p['id'],price:110,from:'2025-01-01'),
      throwsA(isA<DomainError>()));
    expect(()=>act(cashier,'create_promotion',{
      'product_id':p['id'],'title':'x','promo_price_minor':1,
      'starts_at':'2025-01-01T00:00:00Z','ends_at':'2030-01-01T00:00:00Z'}),
      throwsA(isA<DomainError>()));
    expect(engine.listPromotions(owner,p['id'] as String),isEmpty);
  });
}
