import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'engine.dart';
import 'security.dart';
import 'store.dart';

void validateLicenseTrustKeys(Map<String,List<int>> keys) {
  if(keys.length>16) throw const FormatException('Too many license keys');
  for(final e in keys.entries) {
    if(!RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(e.key) || e.value.length!=32) {
      throw const FormatException('Invalid Ed25519 verifier key');
    }
  }
}

/// Signed license: base64url(raw JSON UTF-8) + '.' + base64url(Ed25519 signature).
/// Only PUBLIC verification keys exist on the branch server.
class DeviceLicensing {
  final DatabaseStore store;
  final Map<String,List<int>> trustKeys;
  final Ed25519 algorithm=Ed25519();
  DeviceLicensing(this.store,{required this.trustKeys}) {
    validateLicenseTrustKeys(trustKeys);
  }
  DateTime now()=>DateTime.now().toUtc();
  DateTime timestamp(Object? value,String field) {
    if(value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(value)) {
      throw DomainError('Invalid license timestamp: '+field,403);
    }
    final parsed=DateTime.tryParse(value);
    if(parsed==null || parsed.toUtc().toIso8601String().substring(0,19)+'Z'!=value) {
      throw DomainError('Invalid license date: '+field,403);
    }
    return parsed.toUtc();
  }
  Future<Map<String,dynamic>> verify(String raw) async {
    if(raw.length<60 || raw.length>8192 || raw.split('.').length!=2) {
      throw DomainError('Invalid signed license format',403);
    }
    try {
      final parts=raw.split('.');
      final bytes=base64Url.decode(base64Url.normalize(parts[0]));
      final signature=base64Url.decode(base64Url.normalize(parts[1]));
      if(bytes.isEmpty || bytes.length>4096 || signature.length!=64) {
        throw DomainError('Invalid signed license length',403);
      }
      final value=jsonDecode(utf8.decode(bytes));
      if(value is! Map<String,dynamic>) throw DomainError('Invalid license claims',403);
      final kid=value['key_id'];
      if(kid is! String || !trustKeys.containsKey(kid)) {
        throw DomainError('Untrusted license issuer',403);
      }
      final valid=await algorithm.verify(bytes,signature:Signature(signature,
        publicKey:SimplePublicKey(trustKeys[kid]!,type:KeyPairType.ed25519)));
      if(!valid) throw DomainError('Invalid license signature',403);
      if(value['kind']!='kasher-device-v1' || value['serial'] is! String ||
         value['tenant_id'] is! String || value['device_id'] is! String ||
         (value['serial'] as String).length<16 ||
         (value['serial'] as String).length>128 ||
         (value['tenant_id'] as String).isEmpty ||
         (value['device_id'] as String).isEmpty) {
        throw DomainError('Invalid license identity claims',403);
      }
      final start=timestamp(value['issued_at'],'issued_at');
      final end=timestamp(value['expires_at'],'expires_at');
      if(!end.isAfter(start) || end.difference(start)>const Duration(days:366)) {
        throw DomainError('License duration exceeds one year',403);
      }
      return value;
    } on DomainError {
      rethrow;
    } on Object {
      throw DomainError('Malformed signed license',403);
    }
  }
  void checkClock(String device,DateTime current) {
    final row=store.first('SELECT max_seen_at FROM license_clock_guards WHERE device_id=?',
      [device]);
    if(row==null)return;
    final last=DateTime.tryParse(row['max_seen_at'] as String);
    if(last==null || current.add(const Duration(minutes:5)).isBefore(last)) {
      throw DomainError('Server clock rollback detected; writes disabled',403);
    }
  }
  void observe(String device,DateTime current) {
    final value=current.toUtc().toIso8601String();
    store.exec('''INSERT INTO license_clock_guards(device_id,max_seen_at) VALUES(?,?)
      ON CONFLICT(device_id) DO UPDATE SET max_seen_at=excluded.max_seen_at
      WHERE license_clock_guards.max_seen_at<excluded.max_seen_at''',[device,value]);
  }
  Future<Map<String,Object?>> activate(Principal actor,String license) async {
    if(!['owner','manager'].contains(actor.role)) {
      throw DomainError('Only owner/manager may activate licenses',403);
    }
    final device=actor.deviceId;
    if(device==null) throw DomainError('Activate from an enrolled device',403);
    final claims=await verify(license),current=now();
    if(claims['device_id']!=device || claims['tenant_id']!=actor.tenantId) {
      throw DomainError('License belongs to another device or tenant',403);
    }
    if(timestamp(claims['issued_at'],'issued_at')
        .isAfter(current.add(const Duration(minutes:5))) ||
       !timestamp(claims['expires_at'],'expires_at').isAfter(current)) {
      throw DomainError('License is not currently valid',403);
    }
    return store.transaction(() {
      final dev=store.first('''SELECT branch_id FROM registered_devices
        WHERE id=? AND tenant_id=? AND active=1''',[device,actor.tenantId]);
      if(dev==null || (actor.role!='owner' && actor.branchId!=dev['branch_id'])) {
        throw DomainError('Enrolled device is inactive or forbidden',403);
      }
      checkClock(device,current);
      final old=store.first('SELECT token FROM device_licenses WHERE device_id=?',[device]);
      if(old?['token']==license) {
        return {'status':'active','device_id':device,'serial':claims['serial'],
          'expires_at':claims['expires_at'],'already_active':true};
      }
      final serialOwner=store.first('SELECT device_id FROM device_licenses WHERE serial=?',
        [claims['serial']]);
      if(serialOwner!=null && serialOwner['device_id']!=device) {
        throw DomainError('License serial already assigned',409);
      }
      store.exec('''INSERT INTO device_licenses(
        device_id,tenant_id,serial,key_id,token,issued_at,expires_at,
        activated_by,activated_at) VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(device_id) DO UPDATE SET serial=excluded.serial,
        key_id=excluded.key_id,token=excluded.token,
        issued_at=excluded.issued_at,expires_at=excluded.expires_at,
        activated_by=excluded.activated_by,activated_at=excluded.activated_at''',
        [device,actor.tenantId,claims['serial'],claims['key_id'],license,
        claims['issued_at'],claims['expires_at'],actor.id,current.toIso8601String()]);
      observe(device,current);
      store.exec('''INSERT INTO audit_logs(id,branch_id,actor_id,action,
        entity_id,details_json,created_at) VALUES(?,?,?,?,?,?,?)''',
        [secureToken(16),dev['branch_id'],actor.id,'license.activated',device,
         jsonEncode({'serial':claims['serial'],'expires_at':claims['expires_at'],
           'key_id':claims['key_id']}),current.toIso8601String()]);
      return {'status':'active','device_id':device,'serial':claims['serial'],
        'expires_at':claims['expires_at'],'already_active':false};
    });
  }
  Future<Map<String,Object?>> status(Principal actor) async {
    final device=actor.deviceId;
    if(device==null)return {'status':'not_bound','writable':false};
    final active=store.first('''SELECT active FROM registered_devices
      WHERE id=? AND tenant_id=?''',[device,actor.tenantId]);
    if(active==null || active['active']!=1) {
      return {'status':'device_revoked','writable':false};
    }
    final row=store.first('''SELECT * FROM device_licenses
      WHERE device_id=? AND tenant_id=?''',[device,actor.tenantId]);
    if(row==null)return {'status':'unlicensed','writable':false,'device_id':device};
    final current=now();
    String state='active';
    try {
      final claims=await verify(row['token'] as String);
      if(claims['device_id']!=device || claims['tenant_id']!=actor.tenantId ||
        claims['serial']!=row['serial'] || claims['expires_at']!=row['expires_at']) {
        throw DomainError('License database mismatch',403);
      }
      checkClock(device,current);
      if(!timestamp(claims['expires_at'],'expires_at').isAfter(current))state='expired';
    } on DomainError catch(e) {
      state=e.message.toLowerCase().contains('clock')?'clock_rollback':'invalid';
    }
    return {'status':state,'writable':state=='active','device_id':device,
      'serial':row['serial'],'expires_at':row['expires_at']};
  }
  Future<void> requireWritable(Principal actor) async {
    final device=actor.deviceId;
    if(device==null) throw DomainError('Enrolled licensed device required',403);
    final license=await status(actor);
    if(license['status']!='active') {
      throw DomainError('Device license '+license['status'].toString()+
        '; financial writes disabled',403);
    }
    store.transaction(() {
      final current=now();
      checkClock(device,current);
      observe(device,current);
    });
  }
}
