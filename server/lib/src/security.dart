import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'store.dart';

final Random _random = Random.secure();
String secureToken([int byteCount = 32]) => base64Url.encode(List<int>.generate(byteCount, (_) => _random.nextInt(256))).replaceAll('=', '');
String hashToken(String s) => sha256.convert(utf8.encode(s)).toString();

/// PBKDF2-HMAC-SHA256; 210,000 rounds, 32-byte derived key.
/// Can be migrated to Argon2id when a vetted provider is selected.
String pbkdf2(String password, String salt, {int rounds=210000}) {
  final saltBytes = base64Url.decode(base64Url.normalize(salt));
  final hmac = Hmac(sha256, utf8.encode(password));
  var u = hmac.convert([...saltBytes, 0, 0, 0, 1]).bytes;
  final output = List<int>.from(u);
  for (var i = 1; i < rounds; i++) {
    u = hmac.convert(u).bytes;
    for (var k=0; k<32; k++) { output[k] ^= u[k]; }
  }
  return base64Url.encode(output);
}

bool safeEqual(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var mismatch = x.length ^ y.length;
  final limit = x.length > y.length ? x.length : y.length;
  for (var i=0;i<limit;i++) { mismatch |= (i<x.length ? x[i] : 0) ^ (i<y.length ? y[i] : 0); }
  return mismatch == 0;
}

class Principal {
  final String id, tenantId, role, name;
  final String? branchId;
  Principal(this.id,this.tenantId,this.branchId,this.role,this.name);
  bool get isOwner => role == 'owner';
  bool get isManager => role == 'manager';
}

class AuthService {
  final DatabaseStore store;
  AuthService(this.store);
  Map<String,Object?>? login(String tenantId,String username,String password) {
    final user = store.first('SELECT * FROM users WHERE tenant_id=? AND username=? AND active=1',[tenantId,username]);
    if (user == null) return null;
    final actual = pbkdf2(password,user['password_salt'] as String);
    if (!safeEqual(actual,user['password_hash'] as String)) return null;
    final token = secureToken();
    final now = DateTime.now().toUtc();
    store.exec('INSERT INTO sessions(token_hash,user_id,expires_at,created_at) VALUES(?,?,?,?)',
      [hashToken(token),user['id'],now.add(const Duration(hours:12)).toIso8601String(),now.toIso8601String()]);
    return {'token':token,'tenant_id':tenantId,'user_id':user['id'],'branch_id':user['branch_id'],
      'role':user['role'],'username':username};
  }
  Principal? authenticate(String? authorization) {
    if (authorization == null || !authorization.startsWith('Bearer ')) return null;
    final token = authorization.substring(7).trim();
    final u = store.first('''SELECT u.* FROM sessions s JOIN users u ON s.user_id=u.id
      WHERE s.token_hash=? AND s.expires_at>? AND u.active=1''',
      [hashToken(token),DateTime.now().toUtc().toIso8601String()]);
    if (u == null) return null;
    return Principal(u['id'] as String,u['tenant_id'] as String,u['branch_id'] as String?,u['role'] as String,u['username'] as String);
  }
  void logout(String token) => store.exec('DELETE FROM sessions WHERE token_hash=?',[hashToken(token)]);
}
