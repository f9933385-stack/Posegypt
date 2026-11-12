import 'dart:io';
import 'package:args/args.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:kasher_server/src/api.dart';
import 'package:kasher_server/src/engine.dart';
import 'package:kasher_server/src/security.dart';
import 'package:kasher_server/src/store.dart';

Future<void> main(List<String> args) async {
  final parser=ArgParser()
    ..addOption('db',defaultsTo:'data/kasher.sqlite3')
    ..addOption('bind',defaultsTo:'127.0.0.1')
    ..addOption('port',defaultsTo:'8787')
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
  if(host!='127.0.0.1' && host!='localhost') {
    stderr.writeln('WARNING: LAN mode uses HTTP without TLS. Use trusted isolated LAN only; do not expose to Internet.');
  }
  final api=KasherApi(engine,AuthService(store));
  final server=await shelf_io.serve(api.handler,host,port);
  stdout.writeln('Kasher branch service running at http://${server.address.host}:${server.port}');
  await ProcessSignal.sigint.watch().first;
  await server.close(force:true);
  store.dispose();
}
