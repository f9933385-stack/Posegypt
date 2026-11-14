import 'dart:convert';
import 'package:kasher_server/src/api.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseStore db;
  late PosEngine engine;
  late Principal owner;
  late Map<String,Object?> setup;
  var sequence=0;
  Map<String,Object?> run(String command,Map<String,dynamic> body,{Principal? actor}) =>
    engine.command(actor??owner,command,body,
      'receipt-test-'+(sequence++).toString()+'-unique-123456789');

  setUp(() {
    db=DatabaseStore.memory();
    engine=PosEngine(db);
    setup=engine.bootstrap('سوبر ماركت الأمان','الفرع الرئيسي',
      'admin','receipt-test-admin-password-123');
    owner=Principal(setup['user_id'] as String,setup['tenant_id'] as String,
      setup['branch_id'] as String,'owner','admin');
  });
  tearDown(()=>db.dispose());

  Map<String,Object?> createProduct(String sku,{int tax=0}) {
    final p=run('create_product',{'sku':sku,'name_ar':'أرز مصري',
      'sell_price_minor':1000,'tax_rate_bp':tax});
    final supplier=run('create_supplier',{'name':'مورد للفاتورة'});
    run('purchase',{'branch_id':setup['branch_id'],
      'supplier_id':supplier['id'],
      'lines':[{'product_id':p['id'],'qty_milli':20000,'unit_cost_minor':450}],
      'payments':<Map<String,dynamic>>[]});
    return p;
  }

  test('persisted sale reconciles tax, payment methods and exact base quantity',() {
    final product=createProduct('RECEIPT-BASE',tax:1000);
    final sold=run('sale',{'branch_id':setup['branch_id'],
      'lines':[{'product_id':product['id'],'qty_milli':1500}],
      'payments':[{'method':'cash','amount_minor':1000},
        {'method':'card','amount_minor':650}]});
    expect(sold['total_minor'],1650);
    final receipt=engine.saleReceipt(owner,sold['id'] as String);
    expect(receipt['store_name'],'سوبر ماركت الأمان');
    expect(receipt['branch_name'],'الفرع الرئيسي');
    expect(receipt['number'],sold['number']);
    expect(receipt['kind'],'sale');
    expect(receipt['subtotal_minor'],1500);
    expect(receipt['discount_minor'],0);
    expect(receipt['tax_minor'],150);
    expect(receipt['total_minor'],1650);
    expect(receipt['paid_minor'],1650);
    expect(receipt['due_minor'],0);
    final lines=(receipt['lines'] as List).cast<Map<String,Object?>>();
    expect(lines.single['qty_milli'],1500);
    expect(lines.single['gross_minor'],1500);
    expect(lines.single['tax_minor'],150);
    expect(lines.single['total_minor'],1650);
    expect((receipt['payments'] as List).length,2);
    final json=jsonEncode(receipt);
    expect(json.contains('cost_minor'),false);
    expect(json.contains('password'),false);
    expect(json.contains('party_id'),false);
    expect(json.contains('snapshot_json'),false);
    expect(json.contains('إيصالًا ضريبيًا إلكترونيًا معتمدًا'),true);
  });

  test('carton display uses immutable unit count and persisted monetary gross',() {
    final p=createProduct('RECEIPT-CARTON');
    final unit=run('create_product_unit',{'product_id':p['id'],
      'unit_name':'كرتونة','factor_milli':2000,'sell_price_minor':1750});
    final sold=run('sale',{'branch_id':setup['branch_id'],
      'lines':[{'product_id':p['id'],'unit_id':unit['id'],'unit_count':2}],
      'payments':[{'method':'wallet','amount_minor':3500}]});
    final receipt=engine.saleReceipt(owner,sold['id'] as String);
    final line=(receipt['lines'] as List).single as Map<String,Object?>;
    expect(line['unit_name'],'كرتونة');
    expect(line['unit_count'],2);
    expect(line['qty_milli'],4000);
    expect(line['unit_price_minor'],1750);
    expect(line['gross_minor'],3500);
    expect(receipt['total_minor'],3500);
  });

  test('receipt projection rejects fake amounts and corrupted payments',() {
    final p=createProduct('RECEIPT-CHECK');
    final sold=run('sale',{'branch_id':setup['branch_id'],
      'lines':[{'product_id':p['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':1000}]});
    final id=sold['id'] as String;
    db.exec('UPDATE document_lines SET gross_minor=gross_minor+1 WHERE document_id=?',
      [id]);
    expect(()=>engine.saleReceipt(owner,id),throwsA(isA<DomainError>()));
    db.exec('UPDATE document_lines SET gross_minor=gross_minor-1 WHERE document_id=?',
      [id]);
    expect(engine.saleReceipt(owner,id)['total_minor'],1000);
    db.exec('UPDATE payments SET amount_minor=999 WHERE document_id=?',[id]);
    expect(()=>engine.saleReceipt(owner,id),throwsA(isA<DomainError>()));
  });

  test('purchase receipts are rejected; unknown documents and wrong branch forbidden',() {
    final product=createProduct('RECEIPT-RBAC');
    final purchase=db.first("SELECT id FROM documents WHERE kind='purchase'")!;
    expect(()=>engine.saleReceipt(owner,purchase['id'] as String),
      throwsA(isA<DomainError>()));
    expect(()=>engine.saleReceipt(owner,'missing'),throwsA(isA<DomainError>()));
    final sold=run('sale',{'branch_id':setup['branch_id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':1000}]});
    final branch=run('create_branch',{'name':'فرع 2','code':'BR02'});
    final otherManager=run('create_user',{'username':'manager2',
      'password':'manager-two-password-123','role':'manager',
      'branch_id':branch['id']});
    final other=Principal(otherManager['id'] as String,owner.tenantId,
      branch['id'] as String,'manager','manager2');
    expect(()=>engine.saleReceipt(other,sold['id'] as String),
      throwsA(isA<DomainError>()));
  });

  test('HTTP receipt endpoint refuses anonymous requests and serves exact posted totals',() async {
    final p=createProduct('RECEIPT-HTTP');
    final sold=run('sale',{'branch_id':setup['branch_id'],
      'lines':[{'product_id':p['id'],'qty_milli':1000}],
      'payments':[{'method':'cash','amount_minor':1000}]});
    final api=KasherApi(engine,AuthService(db));
    Future<Response> request(String path,{String? token}) async =>
      api.handler(Request('GET',Uri.parse('http://localhost'+path),
        headers:{if(token!=null)'authorization':'Bearer '+token}));
    final url='/api/v1/receipts/'+sold['id'].toString();
    expect((await request(url)).statusCode,401);
    final bearer=AuthService(db).login(owner.tenantId,'admin',
      'receipt-test-admin-password-123')!['token'] as String;
    final response=await request(url,token:bearer);
    expect(response.statusCode,200);
    final body=jsonDecode(await response.readAsString()) as Map<String,dynamic>;
    expect(body['total_minor'],1000);
    expect(body['lines'],isA<List>());
    expect(body.containsKey('cost_minor'),false);
  });
}
