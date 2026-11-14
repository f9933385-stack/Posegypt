import 'dart:convert';
import 'security.dart';
import 'engine.dart';
import 'store.dart';

/// Enrollment is an explicit owner/manager action. Client secrets and pairing
/// codes are returned once and only their SHA-256 hashes are retained.
class DeviceRegistry {
  final DatabaseStore store;
  DeviceRegistry(this.store);

  String _now()=>DateTime.now().toUtc().toIso8601String();

  void _audit(Principal actor,String branch,String action,String entity,
      Map<String,Object?> details) {
    store.exec('''INSERT INTO audit_logs(id,branch_id,actor_id,action,entity_id,
      details_json,created_at) VALUES(?,?,?,?,?,?,?)''',
      [secureToken(16),branch,actor.id,action,entity,jsonEncode(details),_now()]);
  }

  String _branch(Principal actor,String branchId) {
    if(actor.role!='owner' && actor.role!='manager') {
      throw DomainError('Only owner/manager can manage branch devices',403);
    }
    final row=store.first('SELECT id FROM branches WHERE id=? AND tenant_id=?',
      [branchId,actor.tenantId]);
    if(row==null || (actor.role!='owner' && actor.branchId!=branchId)) {
      throw DomainError('Branch not found or forbidden',403);
    }
    return branchId;
  }

  List<Map<String,Object?>> list(Principal actor,String branchId) {
    final branch=_branch(actor,branchId);
    return store.rows('''SELECT id,name,branch_id,active,created_at,last_seen_at,
      revoked_at FROM registered_devices WHERE tenant_id=? AND branch_id=?
      ORDER BY created_at DESC,id DESC LIMIT 250''',[actor.tenantId,branch]);
  }

  Map<String,Object?> issue(Principal actor,String branchId) {
    final branch=_branch(actor,branchId);
    return store.transaction(() {
      final ticket=secureToken(24);
      final now=DateTime.now().toUtc();
      final expiry=now.add(const Duration(minutes:10)).toIso8601String();
      store.exec('''INSERT INTO device_pairing_tickets
        (token_hash,tenant_id,branch_id,created_by,created_at,expires_at)
        VALUES(?,?,?,?,?,?)''',
        [hashToken(ticket),actor.tenantId,branch,actor.id,now.toIso8601String(),expiry]);
      _audit(actor,branch,'device.pairing_issued',branch,
        {'valid_minutes':10});
      return {'pairing_code':ticket,'expires_at':expiry,
        'branch_id':branch,'single_use':true};
    });
  }

  Map<String,Object?> claim(String code,String label,{String? expectedTenant}) {
    if(code.length<24 || code.length>128) {
      throw DomainError('Invalid or expired device pairing code',401);
    }
    final name=label.trim();
    if(name.isEmpty || name.length>80) throw DomainError('Device name must be 1..80 characters',400);
    return store.transaction(() {
      final ticket=store.first('''SELECT * FROM device_pairing_tickets
        WHERE token_hash=? AND claimed_at IS NULL AND expires_at>?''',
        [hashToken(code),_now()]);
      if(ticket==null || (expectedTenant!=null && ticket['tenant_id']!=expectedTenant)) {
        throw DomainError('Invalid or expired device pairing code',401);
      }
      final id=secureToken(18),secret=secureToken(32),now=_now();
      store.exec('''INSERT INTO registered_devices
        (id,tenant_id,branch_id,name,secret_hash,created_by,created_at)
        VALUES(?,?,?,?,?,?,?)''',
        [id,ticket['tenant_id'],ticket['branch_id'],name,
          hashToken(secret),ticket['created_by'],now]);
      store.exec('UPDATE device_pairing_tickets SET claimed_at=? WHERE token_hash=?',
        [now,ticket['token_hash']]);
      store.exec('''INSERT INTO audit_logs(id,branch_id,actor_id,action,entity_id,
        details_json,created_at) VALUES(?,?,?,?,?,?,?)''',
        [secureToken(16),ticket['branch_id'],ticket['created_by'],
          'device.paired',id,jsonEncode({'name':name}),now]);
      // NEVER log secret, persist it as plaintext, or include it in audit rows.
      return {'device_id':id,'device_secret':secret,
        'tenant_id':ticket['tenant_id'],'branch_id':ticket['branch_id'],
        'name':name};
    });
  }

  Map<String,Object?> revoke(Principal actor,String id,String reason) {
    final why=reason.trim();
    if(why.isEmpty || why.length>200) throw DomainError('Revocation reason must be 1..200 characters');
    return store.transaction(() {
      final d=store.first('''SELECT * FROM registered_devices
        WHERE id=? AND tenant_id=?''',[id,actor.tenantId]);
      if(d==null) throw DomainError('Device not found',404);
      final branch=_branch(actor,d['branch_id'] as String);
      if(d['active']!=1) throw DomainError('Device already revoked',409);
      store.exec('''UPDATE registered_devices SET active=0,
        revoked_by=?,revoked_at=? WHERE id=?''',[actor.id,_now(),id]);
      store.exec('DELETE FROM sessions WHERE device_id=?',[id]);
      _audit(actor,branch,'device.revoked',id,{'reason':why});
      return {'id':id,'revoked':true};
    });
  }
}
