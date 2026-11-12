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
