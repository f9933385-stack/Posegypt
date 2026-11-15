import 'dart:io';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:test/test.dart';

void main() {
  test('failed-login throttle survives restart and expires independently per identity', () {
    final directory = Directory.systemTemp.createTempSync('kasher-login-limits-');
    final path = directory.path + Platform.pathSeparator + 'branch.sqlite3';
    final now = DateTime.utc(2026, 11, 15, 9);
    try {
      var db = DatabaseStore.open(path);
      var limiter = LoginAttemptLimiter(db);
      for (var i = 0; i < LoginAttemptLimiter.maximumFailures; i++) {
        limiter.registerFailure('tenant-A', 'admin', now: now);
      }
      expect(limiter.isBlocked('tenant-A', 'admin', now: now), isTrue);
      expect(limiter.isBlocked('tenant-A', 'other-user', now: now), isFalse);
      expect(limiter.isBlocked('tenant-B', 'admin', now: now), isFalse);
      final stored = db.rows('SELECT identity_hash, failure_count FROM login_attempt_limits');
      expect(stored.single['failure_count'], LoginAttemptLimiter.maximumFailures);
      expect(stored.single['identity_hash'], isNot(contains('admin')));
      db.dispose();

      db = DatabaseStore.open(path);
      limiter = LoginAttemptLimiter(db);
      expect(limiter.isBlocked('tenant-A', 'admin', now: now.add(const Duration(minutes: 4))), isTrue);
      final expired = now.add(const Duration(minutes: 5));
      expect(limiter.isBlocked('tenant-A', 'admin', now: expired), isFalse);
      limiter.registerFailure('tenant-A', 'admin', now: expired);
      expect(db.first('SELECT failure_count FROM login_attempt_limits')?['failure_count'], 1);
      expect(limiter.isBlocked('tenant-A', 'admin', now: expired), isFalse);
      limiter.clear('tenant-A', 'admin');
      expect(db.rows('SELECT * FROM login_attempt_limits'), isEmpty);
      db.dispose();
    } finally {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });
}
