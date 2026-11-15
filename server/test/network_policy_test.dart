import 'dart:convert';
import 'dart:io';
import 'package:kasher_server/src/network_policy.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

void main() {
  test('only exact loopback interfaces permit plaintext HTTP',() {
    for(final host in ['localhost','LOCALHOST','127.0.0.1','::1','[::1]']) {
      expect(isLoopbackBind(host),true,reason:host);
      expect(branchTransport(bind:host),null);
    }
    for(final host in ['0.0.0.0','192.168.1.3','10.2.3.4','localhost.evil',
      '127.0.0.2','::','example.com']) {
      expect(isLoopbackBind(host),false,reason:host);
      expect(()=>branchTransport(bind:host),throwsA(isA<FormatException>()),
        reason:'LAN plaintext not allowed for '+host);
    }
  });

  test('remote TLS configuration requires a certificate and private key pair',() {
    expect(()=>branchTransport(bind:'0.0.0.0',certificatePath:'missing.crt'),
      throwsA(isA<FormatException>()));
    expect(()=>branchTransport(bind:'0.0.0.0',privateKeyPath:'missing.key'),
      throwsA(isA<FormatException>()));
    expect(()=>branchTransport(bind:'127.0.0.1',certificatePath:'missing.crt'),
      throwsA(isA<FormatException>()));
    expect(()=>branchTransport(bind:'192.168.1.3',
      certificatePath:'does-not-exist.pem',privateKeyPath:'does-not-exist.key'),
      throwsA(isA<FormatException>()));
  });

  test('real shelf HTTPS listener serves with independently trusted test certificate',() async {
    final hasOpenssl=await Process.run('openssl',['version']).then((x)=>x.exitCode==0)
      .catchError((Object _) => false);
    if(!hasOpenssl) return;
    final temp=await Directory.systemTemp.createTemp('kasher-tls-test-');
    HttpServer? server;
    HttpClient? client;
    try {
      final certificate=File(temp.path+Platform.pathSeparator+'test.cert.pem');
      final key=File(temp.path+Platform.pathSeparator+'test.key.pem');
      final make=await Process.run('openssl',[
        'req','-x509','-newkey','rsa:2048','-sha256','-nodes',
        '-days','1','-keyout',key.path,'-out',certificate.path,
        '-subj','/CN=localhost',
        '-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'
      ]);
      expect(make.exitCode,0,reason:'Unable to generate ephemeral TLS test certificate');
      final transport=branchTransport(bind:'0.0.0.0',
        certificatePath:certificate.path,privateKeyPath:key.path);
      expect(transport,isNotNull);
      server=await shelf_io.serve((Request r)=>Response.ok('secure'),
        '127.0.0.1',0,securityContext:transport,poweredByHeader:null);
      final trust=SecurityContext(withTrustedRoots:false)
        ..setTrustedCertificates(certificate.path);
      client=HttpClient(context:trust);
      final req=await client.getUrl(Uri.parse(
        'https://127.0.0.1:'+server.port.toString()+'/health'));
      final res=await req.close();
      expect(res.statusCode,200);
      expect(await res.transform(utf8.decoder).join(),'secure');
    } finally {
      client?.close(force:true);
      await server?.close(force:true);
      await temp.delete(recursive:true);
    }
  });
}
