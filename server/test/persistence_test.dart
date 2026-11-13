import 'dart:io';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:test/test.dart';

void main() {
  test('offline restart preserves purchase, stock, documents and exact-once replay', () {
    final temp = Directory.systemTemp.createTempSync('kasher-persistence-');
    final file = temp.path + Platform.pathSeparator + 'branch.sqlite3';
    final key = 'offline-restart-idempotency-key-1234567890';
    late Map<String,Object?> bootstrap, product, supplier, purchase;
    late Map<String,dynamic> request;
    try {
      var store = DatabaseStore.open(file);
      var engine = PosEngine(store);
      bootstrap = engine.bootstrap('متجر اختبار', 'الرئيسي', 'admin', 'a-long-password-123');
      final owner = Principal(bootstrap['user_id'] as String, bootstrap['tenant_id'] as String,
          bootstrap['branch_id'] as String,'owner','admin');
      product = engine.command(owner,'create_product',
        {'sku':'PERSIST-01','name_ar':'سكر','sell_price_minor':320},
        'create-product-persistence-idempotent');
      supplier = engine.command(owner,'create_supplier',{'name':'مورد اختبار'},
        'create-supplier-persistence-idempotent');
      request = {'branch_id':bootstrap['branch_id'],'supplier_id':supplier['id'],
        'lines':[{'product_id':product['id'],'qty_milli':3000,'unit_cost_minor':190}],
        'payments':<Map<String,dynamic>>[]};
      purchase = engine.command(owner,'purchase',request,key);
      expect(purchase['total_minor'],570);
      expect(engine.listStock(owner,bootstrap['branch_id'] as String).single['qty_milli'],3000);
      store.dispose();

      store = DatabaseStore.open(file);
      engine = PosEngine(store);
      final restoredOwner = Principal(bootstrap['user_id'] as String,
        bootstrap['tenant_id'] as String,bootstrap['branch_id'] as String,'owner','admin');
      final same = engine.command(restoredOwner,'purchase',request,key);
      expect(same,purchase);
      expect(store.rows('SELECT id FROM documents WHERE kind=?',['purchase']).length,1);
      expect(engine.listStock(restoredOwner,bootstrap['branch_id'] as String)
        .single['qty_milli'],3000);
      final balance = engine.dashboard(restoredOwner,bootstrap['branch_id'] as String);
      expect(balance['stock_value_minor'],570);
      expect(balance['supplier_payables_minor'],570);

      final changed = Map<String,dynamic>.from(request);
      changed['payments']=[{'method':'cash','amount_minor':200}];
      expect(() => engine.command(restoredOwner,'purchase',changed,key),
        throwsA(isA<DomainError>()));
      expect(store.rows('SELECT id FROM documents WHERE kind=?',['purchase']).length,1);
      final integrity=store.first('PRAGMA integrity_check')?.values.single;
      expect(integrity,'ok');
      store.dispose();
    } finally {
      if(temp.existsSync()) temp.deleteSync(recursive:true);
    }
  });
}
