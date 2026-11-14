import 'dart:convert';
import 'package:kasher_server/src/api.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseStore store;
  late KasherApi api;
  late Map<String,Object?> setup;
  setUp(() {
    store=DatabaseStore.memory();
    final engine=PosEngine(store);
    setup=engine.bootstrap('سوبرماركت تجريبي','الرئيسي','admin','a-strong-password-123');
    api=KasherApi(engine,AuthService(store));
  });
  tearDown(() => store.dispose());

  Future<Response> send(String method,String path,{Object? body,Map<String,String>? headers}) async {
    final request=Request(method,Uri.parse('http://localhost$path'),
      headers:{if(body!=null)'content-type':'application/json',...?headers},
      body:body==null?null:jsonEncode(body));
    return await api.handler(request);
  }

  Future<String> token() async {
    final r=await send('POST','/api/v1/auth/login',body:{
      'tenant_id':setup['tenant_id'],'username':'admin','password':'a-strong-password-123'});
    expect(r.statusCode,200);
    return (jsonDecode(await r.readAsString()) as Map<String,dynamic>)['token'] as String;
  }

  test('health, auth, post, and idempotent replay through the API',() async {
    expect((await send('GET','/health')).statusCode,200);
    expect((await send('GET','/api/v1/products')).statusCode,401);
    final authToken=await token();
    final h={'authorization':'Bearer $authToken','idempotency-key':'integration-key-123456789'};
    final body={'sku':'API-1','name_ar':'أرز تجريبي','sell_price_minor':320};
    final first=await send('POST','/api/v1/products',headers:h,body:body);
    final second=await send('POST','/api/v1/products',headers:h,body:body);
    expect(first.statusCode,201);expect(second.statusCode,201);
    expect(await first.readAsString(),await second.readAsString());
    final products=await send('GET','/api/v1/products',headers:{'authorization':'Bearer $authToken'});
    final list=jsonDecode(await products.readAsString()) as List;
    expect(list.length,1);
    expect((await send('POST','/api/v1/auth/logout',headers:{
      'authorization':'Bearer $authToken'},body:{})).statusCode,200);
    expect((await send('GET','/api/v1/products',headers:{'authorization':'Bearer $authToken'})).statusCode,401);
  });

  test('HTTP stocktake runs through roles and only posts on independent approval',() async {
    final admin=await token();
    var counter=0;
    Future<Map<String,dynamic>> post(String route,String credential,Map<String,dynamic> data) async {
      final response=await send('POST','/api/v1/'+route,
        headers:{'authorization':'Bearer '+credential,
          'idempotency-key':'http-stocktake-'+(counter++).toString()+'-unique-123456789'},
        body:data);
      final raw=await response.readAsString();
      expect(response.statusCode,201,
        reason:'Expected HTTP 201 for '+route+'; body: '+raw);
      return Map<String,dynamic>.from(jsonDecode(raw) as Map);
    }

    final product=await post('products',admin,{
      'sku':'HTTP-STOCKTAKE','name_ar':'أرز','sell_price_minor':250});
    final supplier=await post('suppliers',admin,{'name':'مورد الجرد'});
    await post('purchases',admin,{'branch_id':setup['branch_id'],
      'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':2000,'unit_cost_minor':100}],
      'payments':<Map<String,dynamic>>[]});
    await post('users',admin,{'branch_id':setup['branch_id'],
      'username':'count-worker','password':'count-worker-strong-password',
      'role':'stock'});
    final login=await send('POST','/api/v1/auth/login',body:{
      'tenant_id':setup['tenant_id'],'username':'count-worker',
      'password':'count-worker-strong-password'});
    expect(login.statusCode,200);
    final worker=(jsonDecode(await login.readAsString()) as Map)['token'] as String;
    final count=await post('counts',worker,{
      'branch_id':setup['branch_id'],'warehouse_id':setup['warehouse_id'],
      'reason':'جرد موافقات عبر HTTP'});
    final countResponse=await send('GET','/api/v1/counts/'+count['id'].toString(),
      headers:{'authorization':'Bearer '+worker});
    expect(countResponse.statusCode,200);
    final loaded=jsonDecode(await countResponse.readAsString()) as Map;
    final first=(loaded['lines'] as List).single as Map;
    expect(first['expected_qty_milli'],2000);
    expect(first.containsKey('expected_cost_minor'),false);
    await post('counts/lines',worker,{'count_id':count['id'],
      'line_id':first['id'],'counted_qty_milli':1000});
    final still2000=await send('GET','/api/v1/stock?branch_id='+setup['branch_id'].toString(),
      headers:{'authorization':'Bearer '+admin});
    expect((jsonDecode(await still2000.readAsString()) as List).single['qty_milli'],2000);
    await post('counts/submit',worker,{'count_id':count['id']});
    final forbidden=await send('POST','/api/v1/counts/approve',
      headers:{'authorization':'Bearer '+worker,
        'idempotency-key':'forbidden-approval-test-123456789'},
      body:{'count_id':count['id']});
    expect(forbidden.statusCode,403);
    final approved=await post('counts/approve',admin,{'count_id':count['id']});
    expect(approved['status'],'posted');
    final after=await send('GET','/api/v1/stock?branch_id='+setup['branch_id'].toString(),
      headers:{'authorization':'Bearer '+admin});
    final finalStock=(jsonDecode(await after.readAsString()) as List).single as Map;
    expect(finalStock['qty_milli'],1000);
    expect(finalStock['cost_minor'],100);
    expect(store.rows('''SELECT e.id FROM journal_entries e
      JOIN journal_lines l ON e.id=l.entry_id
      GROUP BY e.id HAVING SUM(l.debit_minor-l.credit_minor)<>0'''),isEmpty);
  });

  test('HTTP inter-branch shipment needs independent destination manager',() async {
    final admin=await token();
    var n=0;
    Future<Map<String,dynamic>> post(String route,String credential,
        Map<String,dynamic> body) async {
      final response=await send('POST','/api/v1/'+route,
        headers:{'authorization':'Bearer '+credential,
          'idempotency-key':'api-shipment-test-'+(n++).toString()+'-unique-12345678'},
        body:body);
      final raw=await response.readAsString();
      expect(response.statusCode,201,reason:'POST '+route+' returned '+raw);
      return Map<String,dynamic>.from(jsonDecode(raw) as Map);
    }

    final branch2=await post('branches',admin,{'name':'مخزن شرق',
      'code':'BR22'});
    final secondBranch=branch2['id'] as String;
    final destinationWh=branch2['warehouse_id'] as String;
    await post('users',admin,{'branch_id':secondBranch,'username':'delivery-manager',
      'password':'delivery-manager-strong-123','role':'manager'});
    final login=await send('POST','/api/v1/auth/login',body:{
      'tenant_id':setup['tenant_id'],'username':'delivery-manager',
      'password':'delivery-manager-strong-123'});
    expect(login.statusCode,200);
    final manager=(jsonDecode(await login.readAsString()) as Map)['token'] as String;
    final product=await post('products',admin,{'sku':'SHIP-HTTP-1',
      'name_ar':'صنف تحويل','sell_price_minor':300});
    final supplier=await post('suppliers',admin,{'name':'مورد التحويل'});
    await post('purchases',admin,{'branch_id':setup['branch_id'],
      'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':6000,'unit_cost_minor':100}],
      'payments':<Map<String,dynamic>>[]});
    final dispatched=await post('branch-shipments/dispatch',admin,{
      'source_branch_id':setup['branch_id'],
      'destination_branch_id':secondBranch,
      'source_warehouse_id':setup['warehouse_id'],
      'destination_warehouse_id':destinationWh,
      'product_id':product['id'],'qty_milli':2500,
    });
    expect(dispatched['status'],'in_transit');

    final listed=await send('GET',
      '/api/v1/branch-shipments?branch_id='+secondBranch,
      headers:{'authorization':'Bearer '+manager});
    expect(listed.statusCode,200);
    final shipments=jsonDecode(await listed.readAsString()) as List;
    expect(shipments.length,1);
    expect((shipments.single as Map)['status'],'in_transit');
    final forbidden=await send('POST','/api/v1/branch-shipments/receive',
      headers:{'authorization':'Bearer '+admin,
        'idempotency-key':'shipment-self-receipt-denied-1234567'},
      body:{'shipment_id':dispatched['id']});
    expect(forbidden.statusCode,403);

    final received=await post('branch-shipments/receive',manager,{
      'shipment_id':dispatched['id']});
    expect(received['status'],'received');
    final destination=await send('GET','/api/v1/stock?branch_id='+secondBranch,
      headers:{'authorization':'Bearer '+admin});
    expect(destination.statusCode,200);
    final stock=(jsonDecode(await destination.readAsString()) as List).single as Map;
    expect(stock['qty_milli'],2500);
    expect(stock['cost_minor'],250);
  });

  test('oversized JSON requests are rejected without buffering indefinitely',() async {
    final tooLarge={'unused':List<String>.filled(140000,'x').join()};
    final response=await send('POST','/api/v1/auth/login',body:tooLarge);
    expect(response.statusCode,413);
  });

  test('repeated bad passwords are temporarily throttled',() async {
    for(var i=0;i<8;i++) {
      final r=await send('POST','/api/v1/auth/login',body:{
        'tenant_id':setup['tenant_id'],'username':'admin','password':'not-correct'});
      expect(r.statusCode,401);
    }
    final limit=await send('POST','/api/v1/auth/login',body:{
      'tenant_id':setup['tenant_id'],'username':'admin','password':'not-correct'});
    expect(limit.statusCode,429);
  });
}
