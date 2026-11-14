import 'package:intl/intl.dart';

String money(int minor) => '${NumberFormat('#,##0.00', 'en').format(minor/100)} ج.م';
String quantity(int milli) {
  if(milli%1000==0) return '${milli~/1000}';
  return (milli/1000).toStringAsFixed(3).replaceFirst(RegExp(r'0+$'),'').replaceFirst(RegExp(r'\.$'),'');
}
/// Parse decimal text exactly; never convert money/quantities through double.
int parseFixed(String text,{int digits=2}) {
  final normalized=text.trim().replaceAll(' ','').replaceAll(',','').replaceAll('٫','.');
  if(!RegExp(r'^\d+(\.\d+)?$').hasMatch(normalized)) throw const FormatException('أدخل رقمًا صحيحًا موجبًا');
  final split=normalized.split('.');
  final frac=split.length>1 ? split[1] : '';
  if(frac.length>digits) throw FormatException('الحد الأقصى $digits أرقام بعد الفاصلة');
  return int.parse(split[0])*pow10(digits) + int.parse(frac.padRight(digits,'0'));
}
int pow10(int n) {var x=1;for(var i=0;i<n;i++) x*=10;return x;}
int parseMoney(String text)=>parseFixed(text,digits:2);
int parseQty(String text)=>parseFixed(text,digits:3);
int asInt(Object? x) => x is int ? x : int.tryParse('$x') ?? 0;
String apiError(Object e) => e.toString().replaceFirst('Exception: ','');
