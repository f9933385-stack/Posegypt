import 'dart:io';

/// Network binding restrictions for the local-first branch server.
///
/// Unencrypted HTTP is permitted only on the host's own loopback interface.
/// Every other bind address MUST present a TLS server identity and key.
bool isLoopbackBind(String host) {
  final value=host.trim().toLowerCase();
  return value=='127.0.0.1' || value=='localhost' ||
    value=='::1' || value=='[::1]';
}

/// Builds TLS configuration without ever printing or persisting the private key.
/// No app trust override: clients must verify the certificate hostname and
/// certificate chain using normal OS trust validation.
SecurityContext? branchTransport({
  required String bind,
  String? certificatePath,
  String? privateKeyPath,
  String? privateKeyPassword,
}) {
  final cert=certificatePath?.trim();
  final key=privateKeyPath?.trim();
  final hasCert=cert!=null && cert.isNotEmpty;
  final hasKey=key!=null && key.isNotEmpty;
  if(hasCert!=hasKey) {
    throw const FormatException('Both --tls-cert and --tls-key must be configured');
  }
  if(!isLoopbackBind(bind) && (!hasCert || !hasKey)) {
    throw const FormatException('Non-loopback branch server requires TLS certificate and key');
  }
  if(!hasCert) return null;
  final certFile=File(cert);
  final keyFile=File(key!);
  if(!certFile.existsSync() || !keyFile.existsSync()) {
    throw const FormatException('TLS certificate or private key file is missing');
  }
  if(certFile.lengthSync()==0 || keyFile.lengthSync()==0) {
    throw const FormatException('TLS certificate or private key file is empty');
  }
  final context=SecurityContext(withTrustedRoots:false)
    ..useCertificateChain(cert)
    ..usePrivateKey(key,password:privateKeyPassword);
  return context;
}
