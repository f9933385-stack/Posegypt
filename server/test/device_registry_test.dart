import 'dart:convert';
import 'package:kasher_server/src/api.dart';
import 'package:kasher_server/src/devices.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late AuthService auth;
  late DeviceRegistry registry;
  late Map<String,Object?> bootstrap;
  late Principal owner;
  setUp(() {
    store=DatabaseStore.memory();engine=PosEngine(store);
    auth=AuthService(store);registry=DeviceRegistry(store);
    bootstrap=engine.bootstrap('متجر الأجهزة','الرئيسي','admin','device-owner-password-123');
    owner=Principal(bootstrap['user_id'] as String,
      bootstrap['tenant_id'] as String,bootstrap['branch_id'] as String,
      'owner','admin');
  });
  tearDown(()=>store.dispose());

  test('pairing tickets are one-use and only secret hashes are persisted',() {
    final ticket=registry.issue(owner,bootstrap['branch_id'] as String);
    final code=ticket['pairing_code'] as String;
    expect(code.length,greaterThanOrEqualTo(24));
    expect(store.rows('SELECT token_hash FROM device_pairing_tickets').single['token_hash'],
      isNot(code));
    final paired=registry.claim(code,'كاشير 1');
    expect(paired['device_secret'],isNotEmpty);
    final rows=store.rows('SELECT * FROM registered_devices');
    expect(rows.length,1);
    expect(rows.single['secret_hash'],isNot(paired['device_secret']));
    expect(()=>registry.claim(code,'كاشير 2'),throwsA(isA<DomainError>()));
    expect(registry.list(owner,bootstrap['branch_id'] as String).single.containsKey('secret_hash'),false);
  });

  test('bound sessions are revoked and non-bound tokens cannot enter LAN',() {
    final code=registry.issue(owner,bootstrap['branch_id'] as String)['pairing_code'] as String;
    final device=registry.claim(code,'كاشير جهاز');
    final session=auth.login(bootstrap['tenant_id'] as String,'admin','device-owner-password-123',
      deviceId:device['device_id'] as String,deviceSecret:device['device_secret'] as String,
      requireDevice:true);
    expect(session,isNotNull);
    final token=session!['token'] as String;
    expect(auth.authenticate('Bearer '+token,requireDevice:true),isNotNull);
    final legacy=auth.login(bootstrap['tenant_id'] as String,'admin','device-owner-password-123');
    expect(auth.authenticate('Bearer '+legacy!['token'].toString(),requireDevice:true),isNull);
    expect(auth.login(bootstrap['tenant_id'] as String,'admin','device-owner-password-123',
      deviceId:device['device_id'] as String,deviceSecret:'wrong-device-secret',
      requireDevice:true),isNull);
    expect(registry.revoke(owner,device['device_id'] as String,'فقد الجهاز')['revoked'],true);
    expect(auth.authenticate('Bearer '+token,requireDevice:true),isNull);
    expect(auth.login(bootstrap['tenant_id'] as String,'admin','device-owner-password-123',
      deviceId:device['device_id'] as String,deviceSecret:device['device_secret'] as String,
      requireDevice:true),isNull);
  });

  test('stock user cannot issue or revoke pairing tickets',() {
    final user=engine.command(owner,'create_user',{'username':'employee',
      'role':'stock','branch_id':bootstrap['branch_id'],
      'password':'test-employee-password-123'},'create-device-user-unique-key-123');
    final stock=Principal(user['id'] as String,owner.tenantId,owner.branchId,'stock','employee');
    expect(()=>registry.issue(stock,bootstrap['branch_id'] as String),
      throwsA(isA<DomainError>()));
    final ticket=registry.issue(owner,bootstrap['branch_id'] as String);
    final d=registry.claim(ticket['pairing_code'] as String,'Stock Desk');
    expect(()=>registry.revoke(stock,d['device_id'] as String,'غير مسموح'),
      throwsA(isA<DomainError>()));
    expect(registry.list(owner,bootstrap['branch_id'] as String).single['active'],1);
  });

  test('LAN API requires enrolled credentials and revokes tokens on next request',() async {
    final remote=KasherApi(engine,auth,enforceDevices:true);
    final local=KasherApi(engine,auth);
    Future<Response> call(KasherApi api,String verb,String path,
      {Map<String,dynamic>? body,String? token}) async =>
      await api.handler(Request(verb,Uri.parse('https://localhost'+path),
        headers:{if(body!=null)'content-type':'application/json',
          if(token!=null)'authorization':'Bearer '+token},
        body:body==null?null:jsonEncode(body)));
    final tenant=bootstrap['tenant_id'] as String, branch=bootstrap['branch_id'] as String;
    final normal=await call(remote,'POST','/api/v1/auth/login',
      body:{'tenant_id':tenant,'username':'admin','password':'device-owner-password-123'});
    expect(normal.statusCode,401);
    final bootstrapLogin=await call(local,'POST','/api/v1/auth/login',
      body:{'tenant_id':tenant,'username':'admin','password':'device-owner-password-123'});
    final session=(jsonDecode(await bootstrapLogin.readAsString()) as Map)['token'] as String;
    final ticketResponse=await call(local,'POST','/api/v1/devices/pairings',
      token:session,body:{'branch_id':branch});
    expect(ticketResponse.statusCode,201);
    final ticket=(jsonDecode(await ticketResponse.readAsString()) as Map)['pairing_code'] as String;
    final claim=await call(remote,'POST','/api/v1/devices/claim',
      body:{'pairing_code':ticket,'device_name':'اختبار HTTPS جهاز 1'});
    expect(claim.statusCode,201);
    final dev=jsonDecode(await claim.readAsString()) as Map;
    final login=await call(remote,'POST','/api/v1/auth/login',
      body:{'tenant_id':tenant,'username':'admin','password':'device-owner-password-123',
        'device_id':dev['device_id'],'device_secret':dev['device_secret']});
    expect(login.statusCode,200);
    final bound=(jsonDecode(await login.readAsString()) as Map)['token'] as String;
    expect((await call(remote,'GET','/api/v1/me',token:session)).statusCode,401);
    expect((await call(remote,'GET','/api/v1/me',token:bound)).statusCode,200);
    final devices=await call(remote,'GET','/api/v1/devices?branch_id='+branch,token:bound);
    expect(devices.statusCode,200);
    final listed=jsonDecode(await devices.readAsString()) as List;
    expect(listed.single.containsKey('secret_hash'),false);
    final revoked=await call(remote,'POST','/api/v1/devices/revoke',token:bound,
      body:{'device_id':dev['device_id'],'reason':'إلغاء جهاز اختبار'});
    expect(revoked.statusCode,201);
    expect((await call(remote,'GET','/api/v1/me',token:bound)).statusCode,401);
    final repeat=await call(remote,'POST','/api/v1/devices/claim',
      body:{'pairing_code':ticket,'device_name':'جهاز آخر'});
    expect(repeat.statusCode,401);
  });
}
