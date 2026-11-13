import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device credentials are stored in OS-protected storage (Windows DPAPI,
/// Android Keystore). Never write these values to SharedPreferences/logs.
class EnrolledDevice {
  final String id,secret;
  const EnrolledDevice(this.id,this.secret);
}

class DeviceVault {
  final FlutterSecureStorage storage;
  const DeviceVault({this.storage=const FlutterSecureStorage()});

  String key(String baseUrl,String tenantId)=>
    'kasher_device_v1:$baseUrl:$tenantId';

  Future<EnrolledDevice?> read(String baseUrl,String tenantId) async {
    final raw=await storage.read(key:key(baseUrl,tenantId));
    if(raw==null) return null;
    try {
      final parsed=jsonDecode(raw);
      if(parsed is! Map || parsed['id'] is! String || parsed['secret'] is! String ||
          (parsed['id'] as String).isEmpty || (parsed['secret'] as String).length<32) {
        return null;
      }
      return EnrolledDevice(parsed['id'] as String,parsed['secret'] as String);
    } on FormatException {
      return null;
    }
  }

  Future<void> write(String baseUrl,String tenantId,EnrolledDevice device) async {
    await storage.write(key:key(baseUrl,tenantId),
      value:jsonEncode({'id':device.id,'secret':device.secret}));
  }

  Future<void> clear(String baseUrl,String tenantId) async {
    await storage.delete(key:key(baseUrl,tenantId));
  }
}
