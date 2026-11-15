/// Only local loopback may use HTTP. All remote branch connections must
/// authenticate the HTTPS server using the operating system trust store.
///
/// Never add a client-wide badCertificateCallback or an unvalidated self-signed
/// certificate trust exception: bearer tokens and passwords cross this link.
String validateBranchEndpoint(String raw) {
  final input=raw.trim();
  final value=Uri.tryParse(input);
  if(value==null || !value.hasAuthority || value.host.isEmpty ||
      (value.scheme!='http' && value.scheme!='https')) {
    throw const FormatException('أدخل رابط خادم صحيح يبدأ بـ https://');
  }
  if(value.userInfo.isNotEmpty || value.hasQuery || value.hasFragment ||
      (value.path.isNotEmpty && value.path!='/')) {
    throw const FormatException('عنوان الخادم لا يسمح بمسار أو بيانات تسجيل أو معاملات إضافية');
  }
  if(value.scheme=='http') {
    final host=value.host.toLowerCase();
    if(host!='localhost' && host!='127.0.0.1' && host!='::1') {
      throw const FormatException('اتصال الأجهزة الأخرى يتطلب HTTPS بشهادة موثوقة');
    }
  }
  return value.origin;
}
