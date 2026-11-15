import 'package:flutter_test/flutter_test.dart';
import 'package:kasher_app/services/network_policy.dart';
import 'package:kasher_app/services/api.dart';

void main() {
  test('remote branch connections are TLS-only and retain trusted host',() {
    expect(validateBranchEndpoint('https://branch.example.com:8787'),
      'https://branch.example.com:8787');
    expect(validateBranchEndpoint('  https://branch.example.com:8787/  '),
      'https://branch.example.com:8787');
    expect(ApiClient('https://store.example.com').baseUrl,
      'https://store.example.com');
    expect(validateBranchEndpoint('https://192.168.1.10:8787'),
      'https://192.168.1.10:8787');
  });

  test('exact local loopback is the only exception for plaintext',() {
    for(final host in ['localhost','127.0.0.1','[::1]']) {
      expect(validateBranchEndpoint('http://'+host+':8787'),
        'http://'+host+':8787');
    }
    for(final host in ['192.168.1.10','10.0.0.15','0.0.0.0','example.com',
      'localhost.evil','127.0.0.2']) {
      expect(()=>ApiClient('http://'+host+':8787'),throwsFormatException,
        reason:host);
    }
  });

  test('url credentials, paths, fragments and foreign schemes are rejected',() {
    final bad=[
      'ftp://store.example.com','https://username:password@host.example',
      'https://server.example/api/v1','https://server.example/?token=secret',
      'https://server.example/#admin','http://store.example.com',
      'https://','not-an-endpoint'
    ];
    for(final input in bad) {
      expect(()=>validateBranchEndpoint(input),throwsFormatException,
        reason:input);
    }
  });
}
