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

  test('debt statements enforce branch and party scope at HTTP boundary',() async {
    final admin=await token();
    final headers={'authorization':'Bearer $admin'};
    var count=0;
    Future<Map<String,dynamic>> post(String path,Map<String,dynamic> body) async {
      final response=await send('POST','/api/v1/$path',body:body,
        headers:{...headers,
          'idempotency-key':'debt-statement-test-${count++}-12345678901234'});
      final raw=await response.readAsString();
      expect(response.statusCode,201,reason:raw);
      return Map<String,dynamic>.from(jsonDecode(raw) as Map);
    }
    final supplier=await post('suppliers',{'name':'مورد الكشف'});
    final newBranch=await post('branches',{'name':'فرع اختبار','code':'BR58'});
    final other=newBranch['id'] as String;
    await post('users',{'branch_id':other,'username':'branch-manager-statement',
      'password':'long-manager-password-123','role':'manager'});
    final login=await send('POST','/api/v1/auth/login',body:{
      'tenant_id':setup['tenant_id'],'username':'branch-manager-statement',
      'password':'long-manager-password-123'});
    expect(login.statusCode,200);
    final manager=(jsonDecode(await login.readAsString()) as Map)['token'] as String;
    final scoped={'authorization':'Bearer $manager'};
    final party=supplier['id'];
    final forbidden=await send('GET',
      '/api/v1/debts/statement?branch_id=${setup['branch_id']}&party_type=supplier&party_id=$party',
      headers:scoped);
    expect(forbidden.statusCode,403);
    expect((await send('GET',
      '/api/v1/suppliers?branch_id=${setup['branch_id']}',headers:scoped)).statusCode,403);
    final permitted=await send('GET',
      '/api/v1/debts/statement?branch_id=$other&party_type=supplier&party_id=$party',
      headers:scoped);
    expect(permitted.statusCode,200);
    final report=jsonDecode(await permitted.readAsString()) as Map;
    expect(report['balance_minor'],0);
    expect(report['entries'],isEmpty);
    expect((await send('GET',
      '/api/v1/debts/statement?branch_id=$other&party_type=invalid&party_id=$party',
      headers:scoped)).statusCode,400);
    expect((await send('GET',
      '/api/v1/debts/statement?branch_id=$other&party_type=supplier&party_id=nonexistent',
      headers:scoped)).statusCode,404);
  });

  test('HTTP invoice allocation returns audited remaining amounts and is idempotent',() async {
    final admin=await token();
    var i=0;
    Future<Map<String,dynamic>> post(String route,Map<String,dynamic> body,
        {String? key}) async {
      final response=await send('POST','/api/v1/$route',body:body,
        headers:{'authorization':'Bearer $admin',
          'idempotency-key':key ?? 'http-invoice-alloc-${i++}-123456789'});
      final raw=await response.readAsString();
      expect(response.statusCode,201,reason:raw);
      return Map<String,dynamic>.from(jsonDecode(raw) as Map);
    }
    final supplier=await post('suppliers',{'name':'مورد تخصيص'});
    final product=await post('products',{
      'sku':'INV-HTTP-1','name_ar':'بقوليات','sell_price_minor':250});
    final invoice=await post('purchases',{
      'branch_id':setup['branch_id'],'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000,
        'unit_cost_minor':700}],'payments':<Map<String,dynamic>>[]});
    final headers={'authorization':'Bearer $admin'};
    final path='/api/v1/debts/invoices?branch_id=${setup['branch_id']}&party_id=${supplier['id']}&party_type=supplier';
    final list=await send('GET',path,headers:headers);
    expect(list.statusCode,200);
    final before=jsonDecode(await list.readAsString()) as Map;
    expect(before['allocation_available'],true);
    expect((before['invoices'] as List).single['remaining_minor'],700);
    const paymentKey='http-invoice-alloc-retry-key-12345678';
    final body={'branch_id':setup['branch_id'],
      'supplier_id':supplier['id'],'invoice_id':invoice['id'],
      'method':'cash','amount_minor':200};
    final first=await post('suppliers/payments',body,key:paymentKey);
    final again=await post('suppliers/payments',body,key:paymentKey);
    expect(again,first);
    expect(first['invoice_remaining_minor'],500);
    final afterResp=await send('GET',path,headers:headers);
    final after=jsonDecode(await afterResp.readAsString()) as Map;
    expect((after['invoices'] as List).single['remaining_minor'],500);
    expect(after['balance_minor'],500);
    expect(store.rows('SELECT * FROM debt_allocations'),hasLength(1));
    expect((await send('GET',
      '/api/v1/debts/invoices?branch_id=${setup['branch_id']}&party_id=${supplier['id']}&party_type=invalid',
      headers:headers)).statusCode,400);
    expect((await send('GET',
      '/api/v1/debts/invoices?branch_id=${setup['branch_id']}&party_id=missing&party_type=supplier',
      headers:headers)).statusCode,404);
  });

  test('HTTP split receipt is one payment with two documented invoice allocations',() async {
    final admin=await token();
    final auth={'authorization':'Bearer $admin'};
    var count=0;
    Future<Map<String,dynamic>> create(String endpoint,Map<String,dynamic> data,
        {String? idempotencyKey}) async {
      final response=await send('POST','/api/v1/$endpoint',
        headers:{...auth,'idempotency-key':
          idempotencyKey ?? 'http-split-account-${count++}-long-key'},
        body:data);
      final raw=await response.readAsString();
      expect(response.statusCode,201,reason:raw);
      return Map<String,dynamic>.from(jsonDecode(raw) as Map);
    }
    final supplier=await create('suppliers',{'name':'مورد توزيع دفعات'});
    final product=await create('products',{
      'sku':'HTTP-SPLIT-1','name_ar':'شاي','sell_price_minor':500});
    Future<Map<String,dynamic>> buy(int cost)=>create('purchases',{
      'branch_id':setup['branch_id'],'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000,
        'unit_cost_minor':cost}],'payments':<Map<String,dynamic>>[]});
    final a=await buy(700),b=await buy(500);
    final body=<String,dynamic>{'branch_id':setup['branch_id'],
      'supplier_id':supplier['id'],'method':'bank','amount_minor':800,
      'allocations':[
        {'invoice_id':a['id'],'amount_minor':500},
        {'invoice_id':b['id'],'amount_minor':300},
      ]};
    const idem='http-split-repeat-key-1234567890';
    final response=await create('suppliers/payments',body,idempotencyKey:idem);
    expect(await create('suppliers/payments',body,idempotencyKey:idem),response);
    final records=response['allocations'] as List<dynamic>;
    expect(records,hasLength(2));
    expect(records.map((x)=>(x as Map)['invoice_remaining_minor']).toList(),[200,200]);
    expect(response['remaining_minor'],400);
    final url='/api/v1/debts/invoices?branch_id=${setup['branch_id']}&party_id=${supplier['id']}&party_type=supplier';
    final list=await send('GET',url,headers:auth);
    expect(list.statusCode,200);
    final data=jsonDecode(await list.readAsString()) as Map;
    expect(data['balance_minor'],400);
    expect((data['invoices'] as List).length,2);
    expect(store.rows('SELECT * FROM payments WHERE document_id IS NULL'),hasLength(1));
    expect(store.rows('SELECT * FROM debt_allocation_lines'),hasLength(2));
    final invalid=await send('POST','/api/v1/suppliers/payments',
      headers:{...auth,'idempotency-key':'http-split-invalid-key-12345678'},
      body:{...body,'amount_minor':799});
    expect(invalid.statusCode,409);
    expect(store.rows('SELECT * FROM debt_allocation_lines'),hasLength(2));
  });

  test('HTTP legacy reconciliation requires independent approval and posts no second cash',() async {
    final admin=await token();
    var sequence=0;
    Future<Map<String,dynamic>> post(String route,String bearer,
        Map<String,dynamic> body,{String? idempotency}) async {
      final reply=await send('POST','/api/v1/$route',body:body,
        headers:{'authorization':'Bearer $bearer','idempotency-key':
          idempotency ?? 'http-legacy-reconcile-${sequence++}-idempotent-key'});
      final text=await reply.readAsString();
      expect(reply.statusCode,201,reason:text);
      return Map<String,dynamic>.from(jsonDecode(text) as Map);
    }
    final supplier=await post('suppliers',admin,{'name':'مورد التحصيل القديم'});
    final product=await post('products',admin,{
      'sku':'HTTP-OLD-MATCH','name_ar':'برغل','sell_price_minor':300});
    final purchase=await post('purchases',admin,{
      'branch_id':setup['branch_id'],'supplier_id':supplier['id'],
      'lines':[{'product_id':product['id'],'qty_milli':1000,
        'unit_cost_minor':600}],'payments':<Map<String,dynamic>>[]});
    final original=await post('suppliers/payments',admin,{
      'branch_id':setup['branch_id'],'supplier_id':supplier['id'],
      'method':'cash','amount_minor':250});
    final managerUser=await post('users',admin,{
      'branch_id':setup['branch_id'],'username':'review-api-manager',
      'password':'strong-review-api-password-123','role':'manager'});
    expect(managerUser['role'],'manager');
    final login=await send('POST','/api/v1/auth/login',body:{
      'tenant_id':setup['tenant_id'],
      'username':'review-api-manager',
      'password':'strong-review-api-password-123'});
    expect(login.statusCode,200);
    final manager=(jsonDecode(await login.readAsString()) as Map)['token'] as String;
    final query='/api/v1/debts/unallocated?branch_id=${setup['branch_id']}'
      '&party_type=supplier&party_id=${supplier['id']}';
    final initial=await send('GET',query,
      headers:{'authorization':'Bearer $admin'});
    expect(initial.statusCode,200);
    expect(jsonDecode(await initial.readAsString()),hasLength(1));
    const repeatKey='historical-review-http-request-retry-123456';
    final requestData=<String,dynamic>{
      'branch_id':setup['branch_id'],'party_id':supplier['id'],
      'party_type':'supplier','payment_id':original['id'],
      'reason':'كشوفات البنك وسند توريد المخزون موثقة',
      'allocations':[{'invoice_id':purchase['id'],'amount_minor':250}]
    };
    final proposed=await post('debts/reconciliations',admin,requestData,
      idempotency:repeatKey);
    expect(await post('debts/reconciliations',admin,requestData,
      idempotency:repeatKey),proposed);
    expect(proposed['status'],'pending');
    final beforeJournal=store.rows('SELECT id FROM journal_entries').length;
    final requesterApproves=await send('POST',
      '/api/v1/debts/reconciliations/approve',body:{
        'reconciliation_id':proposed['id'],
        'reason':'محاولة اعتماد الطلب بمعرف صاحبه'},
      headers:{'authorization':'Bearer $admin',
        'idempotency-key':'http-self-approval-123456789'});
    expect(requesterApproves.statusCode,403);
    final approved=await post('debts/reconciliations/approve',
      manager,{'reconciliation_id':proposed['id'],
        'reason':'تمت المراجعة المستقلة للمستندات الأصلية'});
    expect(approved['status'],'approved');
    expect(store.rows('SELECT id FROM journal_entries'),hasLength(beforeJournal));
    expect(store.rows('SELECT id FROM debt_allocation_lines'),hasLength(1));
    final remaining=await send('GET',query,
      headers:{'authorization':'Bearer $admin'});
    expect(jsonDecode(await remaining.readAsString()),isEmpty);
    final report=await send('GET',
      '/api/v1/debts/invoices?branch_id=${setup['branch_id']}'
      '&party_type=supplier&party_id=${supplier['id']}',
      headers:{'authorization':'Bearer $admin'});
    expect(report.statusCode,200);
    final snapshot=jsonDecode(await report.readAsString()) as Map;
    expect(snapshot['balance_minor'],350);
    expect(snapshot['allocation_available'],true);
    expect((snapshot['invoices'] as List).single['remaining_minor'],350);
    final reviewList=await send('GET',
      '/api/v1/debts/reconciliations?branch_id=${setup['branch_id']}'
      '&party_type=supplier&party_id=${supplier['id']}',
      headers:{'authorization':'Bearer $manager'});
    expect(reviewList.statusCode,200);
    expect((jsonDecode(await reviewList.readAsString()) as List).single['status'],
      'approved');
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
    // A new API instance must not reset a lockout (the state lives in SQLite).
    api=KasherApi(PosEngine(store),AuthService(store));
    final validButBlocked=await send('POST','/api/v1/auth/login',body:{
      'tenant_id':setup['tenant_id'],'username':'admin','password':'a-strong-password-123'});
    expect(validButBlocked.statusCode,429);
    expect(store.first('SELECT COUNT(*) n FROM login_attempt_limits')?['n'],1);
    // Expiry is checked against database time window, without sleeping.
    store.exec('UPDATE login_attempt_limits SET window_started_at=?',
      [DateTime.now().toUtc().subtract(const Duration(minutes:6)).toIso8601String()]);
    final validAfterWindow=await send('POST','/api/v1/auth/login',body:{
      'tenant_id':setup['tenant_id'],'username':'admin','password':'a-strong-password-123'});
    expect(validAfterWindow.statusCode,200);
    expect(store.first('SELECT COUNT(*) n FROM login_attempt_limits')?['n'],0);
  });
}
