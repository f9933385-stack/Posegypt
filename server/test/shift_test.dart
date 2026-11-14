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
}
