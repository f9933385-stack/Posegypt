import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:kasher_server/src/api.dart';
import 'package:kasher_server/src/devices.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/licensing.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseStore store;
  late PosEngine engine;
  late DeviceRegistry registry;
  late DeviceLicensing licenses;
  late AuthService auth;
  late Principal owner;
  late String deviceId,deviceSecret,tenant,branch;
  late SimpleKeyPair pair;
  late SimplePublicKey publicKey;

  String urlEncode(List<int> bytes)=>base64Url.encode(bytes).replaceAll('=','');

  Future<String> sign({String? device,String? tenantId,String? serial,
    int days=365,DateTime? issued}) async {
    final start=(issued??DateTime.now().toUtc().subtract(const Duration(days:1)))
      .toUtc();
    final clean=DateTime.utc(start.year,start.month,start.day,
      start.hour,start.minute,start.second);
    final payload={
      'kind':'kasher-device-v1','key_id':'test-key',
      'serial':serial??'test-serial-unique-1234567890',
      'tenant_id':tenantId??tenant,'device_id':device??deviceId,
      'issued_at':clean.toIso8601String().substring(0,19)+'Z',
      'expires_at':clean.add(Duration(days:days)).toIso8601String().substring(0,19)+'Z'
    };
    final raw=utf8.encode(jsonEncode(payload));
    final signature=await Ed25519().sign(raw,keyPair:pair);
    return urlEncode(raw)+'.'+urlEncode(signature.bytes);
  }

  setUp(() async {
    store=DatabaseStore.memory();
    engine=PosEngine(store);
    registry=DeviceRegistry(store);
    auth=AuthService(store);
    final setup=engine.bootstrap('متجر ترخيص','الفرع الرئيسي','admin',
      'very-strong-owner-password');
    tenant=setup['tenant_id'] as String;
    branch=setup['branch_id'] as String;
    final basic=Principal(setup['user_id'] as String,tenant,branch,'owner','admin');
    final ticket=registry.issue(basic,branch);
    final device=registry.claim(ticket['pairing_code'] as String,
      'اختبار كاشير 1',expectedTenant:tenant);
    deviceId=device['device_id'] as String;
    deviceSecret=device['device_secret'] as String;
    owner=Principal(basic.id,tenant,branch,'owner','admin',deviceId:deviceId);
    pair=await Ed25519().newKeyPair();
    publicKey=await pair.extractPublicKey();
    licenses=DeviceLicensing(store,trustKeys:{'test-key':publicKey.bytes});
  });
  tearDown(()=>store.dispose());

  test('trusted signature grants one year and expires into read-only',() async {
    expect((await licenses.status(owner))['status'],'unlicensed');
    expect(()=>licenses.requireWritable(owner),throwsA(isA<DomainError>()));
    final token=await sign();
    final activated=await licenses.activate(owner,token);
    expect(activated['status'],'active');
    expect(activated['already_active'],false);
    expect((await licenses.activate(owner,token))['already_active'],true);
    await licenses.requireWritable(owner);
    expect((await licenses.status(owner))['writable'],true);
    expect(store.rows('SELECT serial FROM device_licenses').length,1);
    expect(store.rows("SELECT action FROM audit_logs WHERE action='license.activated'").length,1);
    store.exec("UPDATE device_licenses SET expires_at='2000-01-01T00:00:00Z'");
    expect((await licenses.status(owner))['status'],'invalid');
    expect(()=>licenses.requireWritable(owner),throwsA(isA<DomainError>()));
  });

  test('altered license, foreign device or tenant and untrusted key rejected',() async {
    final correct=await sign();
    final parts=correct.split('.');
    final decoded=String.fromCharCodes(base64Url.decode(base64Url.normalize(parts[0])));
    final tampered=decoded.replaceFirst('kasher-device-v1','forged-device-v1');
    expect(()=>licenses.activate(owner,urlEncode(utf8.encode(tampered))+'.'+parts[1]),
      throwsA(isA<DomainError>()));
    expect(()=>licenses.activate(owner,await sign(device:'another-device')),
      throwsA(isA<DomainError>()));
    expect(()=>licenses.activate(owner,await sign(tenantId:'another-tenant')),
      throwsA(isA<DomainError>()));
    final altered=correct.substring(0,correct.length-2)+'zz';
    expect(()=>licenses.activate(owner,altered),throwsA(isA<DomainError>()));
    expect(store.rows('SELECT * FROM device_licenses'),isEmpty);
  });

  test('expired, future, or excessive-duration issuance is rejected',() async {
    expect(()=>licenses.activate(owner,await sign(issued:DateTime.utc(2020,1,1))),
      throwsA(isA<DomainError>()));
    expect(()=>licenses.activate(owner,await sign(
      issued:DateTime.now().toUtc().add(const Duration(days:3)))),
      throwsA(isA<DomainError>()));
    expect(()=>licenses.activate(owner,await sign(days:367)),
      throwsA(isA<DomainError>()));
  });

  test('clock rollback guard blocks writes and renewal on same persistent device',() async {
    await licenses.activate(owner,await sign());
    store.exec("UPDATE license_clock_guards SET max_seen_at='2099-01-01T00:00:00Z'");
    expect((await licenses.status(owner))['status'],'clock_rollback');
    expect(()=>licenses.requireWritable(owner),throwsA(isA<DomainError>()));
    expect(()=>licenses.activate(owner,await sign(serial:'renewal-new-serial-987654321')),
      throwsA(isA<DomainError>()));
  });

  test('revoking enrolled device disables licensed operations',() async {
    await licenses.activate(owner,await sign());
    final basic=Principal(owner.id,tenant,branch,'owner','admin');
    registry.revoke(basic,deviceId,'الجهاز مفقود');
    expect((await licenses.status(owner))['status'],'device_revoked');
    expect(()=>licenses.requireWritable(owner),throwsA(isA<DomainError>()));
  });

  test('server HTTP: unlicensed LAN is read-only until owner activates signed token',() async {
    final api=KasherApi(engine,auth,enforceDevices:true,enforceLicenses:true,
      licenseTrustKeys:{'test-key':publicKey.bytes});
    final login=auth.login(tenant,'admin','very-strong-owner-password',
      deviceId:deviceId,deviceSecret:deviceSecret,requireDevice:true)!;
    final session=login['token'] as String;
    var counter=0;
    Future<Response> call(String method,String route,{Object? body}) async {
      return await api.handler(Request(method,Uri.parse('https://localhost/api/v1/'+route),
        headers:{'authorization':'Bearer '+session,
          if(body!=null)'content-type':'application/json',
          'idempotency-key':'license-http-'+(counter++).toString()+'-123456789012345'},
        body:body==null?null:jsonEncode(body)));
    }
    final before=await call('GET','products');
    expect(before.statusCode,200);
    final blocked=await call('POST','products',body:{
      'sku':'NO-LICENSE','name_ar':'ممنوع','sell_price_minor':250});
    expect(blocked.statusCode,403);
    expect(store.rows('SELECT id FROM products'),isEmpty);
    final token=await sign();
    final activation=await call('POST','licenses/activate',body:{'license_token':token});
    expect(activation.statusCode,201,
      reason:await activation.readAsString());
    final accepted=await call('POST','products',body:{
      'sku':'ALLOWED','name_ar':'مرخص','sell_price_minor':250});
    expect(accepted.statusCode,201,reason:await accepted.readAsString());
    expect(store.rows('SELECT id FROM products').length,1);
    final state=await call('GET','licenses/status');
    final detail=jsonDecode(await state.readAsString()) as Map;
    expect(detail['writable'],true);
    expect(detail.containsKey('token'),false);
    store.exec("UPDATE license_clock_guards SET max_seen_at='2099-01-01T00:00:00Z'");
    final denied=await call('POST','products',body:{
      'sku':'DENIED','name_ar':'تم حظرها','sell_price_minor':250});
    expect(denied.statusCode,403);
    expect((await call('GET','products')).statusCode,200);
    expect(store.rows('SELECT id FROM products').length,1);
  });

  test('cross-language Python Ed25519 sample signature is understood by Dart',() async {
    const publicRaw='A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg';
    const issued='eyJkZXZpY2VfaWQiOiJURVNULURFVklDRSIsImV4cGlyZXNfYXQiOiIyMDI3LTAxLTAxVDAwOjAwOjAwWiIsImlzc3VlZF9hdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDBaIiwia2V5X2lkIjoidGVzdC12MSIsImtpbmQiOiJrYXNoZXItZGV2aWNlLXYxIiwic2VyaWFsIjoidGVzdC1zaWduZWQtYW5udWFsLXNlcmlhbC0wMDEiLCJ0ZW5hbnRfaWQiOiJURVNULVRFTkFOVCJ9.k4kf9vhFP5J9hBnsmBfcOaM57ccgD2bNshs48UuWzJUL-3zWcgZUMVmTTLQOYKwREwbxtq7nj3b991A9EbpkAQ';
    final checker=DeviceLicensing(store,trustKeys:{
      'test-v1':base64Url.decode(base64Url.normalize(publicRaw))});
    final claims=await checker.verify(issued);
    expect(claims['serial'],'test-signed-annual-serial-001');
    expect(claims['kind'],'kasher-device-v1');
  });
}
