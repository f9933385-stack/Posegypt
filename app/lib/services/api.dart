import 'dart:convert';
import 'dart:math';
import 'network_policy.dart';
import 'package:http/http.dart' as http;

class ApiFailure implements Exception {
  final String message;
  final int status;
  ApiFailure(this.message,this.status);
  @override String toString()=>message;
}

class ApiClient {
  final String baseUrl;
  String? token;
  ApiClient(String endpoint,{this.token}) : baseUrl=validateBranchEndpoint(endpoint);
  final Map<String,String> _pendingKeys={};
  Uri uri(String path,[Map<String,String>? params]) =>
    Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'),'')}/api/v1/$path').replace(queryParameters:params);
  Map<String,String> headers({String? idempotencyKey}) => {
    if(token!=null) 'Authorization':'Bearer $token',
    'Content-Type':'application/json',
    if(idempotencyKey!=null) 'Idempotency-Key':idempotencyKey,
  };
  String _idempotencyKey() {
    final r=Random.secure();
    return List.generate(32,(_)=>r.nextInt(256).toRadixString(16).padLeft(2,'0')).join();
  }
  Future<dynamic> _parse(http.Response r) async {
    final body=jsonDecode(utf8.decode(r.bodyBytes));
    if(r.statusCode>=400) throw ApiFailure(body is Map ? (body['error']?.toString() ?? 'فشل الطلب') : 'فشل الطلب',r.statusCode);
    return body;
  }
  Future<List<Map<String,dynamic>>> list(String path,[Map<String,String>? params]) async {
    final response=await http.get(uri(path,params),headers:headers()).timeout(const Duration(seconds:12));
    final decoded=await _parse(response) as List<dynamic>;
    return decoded.map((x)=>Map<String,dynamic>.from(x as Map)).toList();
  }
  Future<Map<String,dynamic>> get(String path,[Map<String,String>? params]) async {
    final response=await http.get(uri(path,params),headers:headers()).timeout(const Duration(seconds:12));
    return Map<String,dynamic>.from(await _parse(response) as Map);
  }
  Future<Map<String,dynamic>> post(String path,Map<String,dynamic> body,{bool idempotent=true}) async {
    final encoded=jsonEncode(body);
    final signature='$path|$encoded';
    // After a network timeout the same payload retries with the same key,
    // avoiding duplicate documents when the server committed before disconnect.
    final key=idempotent ? _pendingKeys.putIfAbsent(signature,_idempotencyKey) : null;
    try {
      final response=await http.post(uri(path),headers:headers(idempotencyKey:key),body:encoded)
        .timeout(const Duration(seconds:20));
      final parsed=Map<String,dynamic>.from(await _parse(response) as Map);
      if(key!=null)_pendingKeys.remove(signature);
      return parsed;
    } on ApiFailure catch(e) {
      if(key!=null && e.status<500)_pendingKeys.remove(signature);
      rethrow;
    }
  }
}
