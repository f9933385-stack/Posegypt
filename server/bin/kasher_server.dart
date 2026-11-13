import 'dart:io';
import 'dart:convert';
import 'package:args/args.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:kasher_server/src/api.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';
import 'package:kasher_server/src/network_policy.dart';
import 'package:kasher_server/src/licensing.dart';

Future<void> main(List<String> args) async {
  final parser=ArgParser()
    ..addOption('db',defaultsTo:'data/kasher.sqlite3')
    ..addOption('bind',defaultsTo:'127.0.0.1')
    ..addOption('port',defaultsTo:'8787')
    ..addOption('tls-cert',help:'PEM certificate chain for non-loopback HTTPS')
    ..addOption('tls-key',help:'PEM private key for non-loopback HTTPS')
    ..addOption('name',defaultsTo:'سوبرماركت جديد')
    ..addOption('branch',defaultsTo:'الفرع الرئيسي')
    ..addOption('username',defaultsTo:'admin');
  final options=parser.parse(args);
  final action=options.rest.isEmpty?'serve':options.rest.first;
  final store=DatabaseStore.open(options['db'] as String);
  final engine=PosEngine(store);
  if(action=='init') {
    final password=Platform.environment['KASHER_ADMIN_PASSWORD'];
    if(password==null || password.length<12) {
      stderr.writeln('Set KASHER_ADMIN_PASSWORD (minimum 12 characters) before init.');
      exitCode=2;store.dispose();return;
    }
    try {
      final result=engine.bootstrap(options['name'] as String,options['branch'] as String,
        options['username'] as String,password);
      stdout.writeln('Initialized. Save these identifiers for the login screen:');
      result.forEach((key,value)=>stdout.writeln('$key=$value'));
    } on DomainError catch(e) {
      stderr.writeln(e.message);exitCode=1;
    }
    store.dispose();return;
  }
  if(action!='serve') { stderr.writeln('Usage: dart run bin/kasher_server.dart [init|serve]');exitCode=2;store.dispose();return; }
  final host=options['bind'] as String;
  final port=int.tryParse(options['port'] as String);
  if(port==null || port<1 || port>65535) {stderr.writeln('Invalid port');exitCode=2;store.dispose();return;}
  SecurityContext? transport;
  try {
    transport=branchTransport(
      bind:host,
      certificatePath:options['tls-cert'] as String?,
      privateKeyPath:options['tls-key'] as String?,
      privateKeyPassword:Platform.environment['KASHER_TLS_KEY_PASSWORD'],
    );
  } on FormatException catch(e) {
    stderr.writeln('Refusing unsafe server binding: ${e.message}');
    store.dispose();exitCode=2;return;
  } on FileSystemException catch(_) {
    stderr.writeln('TLS certificate/key could not be read');
    store.dispose();exitCode=2;return;
  }
  Map<String,List<int>> trustKeys={};
  final remote=!isLoopbackBind(host);
  try {
    final configured=Platform.environment['KASHER_LICENSE_PUBLIC_KEYS_JSON'];
    if(configured!=null && configured.trim().isNotEmpty) {
      final parsed=jsonDecode(configured);
      if(parsed is! Map || parsed.isEmpty) {
        throw const FormatException('Expected JSON map of key_id to Base64URL Ed25519 public key');
      }
      for(final entry in parsed.entries) {
        if(entry.key is! String || entry.value is! String) {
          throw const FormatException('Invalid license public key map');
        }
        trustKeys[entry.key as String]=base64Url.decode(
          base64Url.normalize(entry.value as String));
      }
    }
    if(remote && trustKeys.isEmpty) {
      throw const FormatException('Non-local branch service requires KASHER_LICENSE_PUBLIC_KEYS_JSON');
    }
    validateLicenseTrustKeys(trustKeys);
  } on FormatException catch(e) {
    stderr.writeln('Invalid license verifier configuration: ${e.message}');
    store.dispose();exitCode=2;return;
  }
  final api=KasherApi(engine,AuthService(store),
    enforceDevices:remote,enforceLicenses:remote,licenseTrustKeys:trustKeys);
  final server=await shelf_io.serve(api.handler,host,port,
    securityContext:transport,poweredByHeader:null);
  stdout.writeln('Kasher branch service running at ${transport==null?'http':'https'}://${server.address.host}:${server.port}');
  await ProcessSignal.sigint.watch().first;
  await server.close(force:true);
  store.dispose();
}
