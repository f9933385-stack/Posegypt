import 'dart:async';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'engine.dart';
import 'devices.dart';
import 'licensing.dart';
import 'security.dart';

class KasherApi {
  final PosEngine engine;
  final AuthService auth;
  final bool enforceDevices;
  final bool enforceLicenses;
  final DeviceRegistry devices;
  final DeviceLicensing licensing;
  KasherApi(this.engine,this.auth,{
    this.enforceDevices=false,
    this.enforceLicenses=false,
    Map<String,List<int>> licenseTrustKeys=const {},
  }) : devices=DeviceRegistry(auth.store),
       licensing=DeviceLicensing(auth.store,trustKeys:licenseTrustKeys) {
    if(enforceLicenses && licenseTrustKeys.isEmpty) {
      throw StateError('License enforcement requires a trusted Ed25519 public key');
    }
  }
  final Map<String,List<DateTime>> _loginFailures={};

  Response _json(Object? value,{int status=200}) => Response(status,body:jsonEncode(value),
    headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store',
      'x-content-type-options':'nosniff'});
  Principal _p(Request r) {
    final p=auth.authenticate(r.headers['authorization'],requireDevice:enforceDevices);
    if(p==null) throw DomainError('Unauthorized',401);
    return p;
  }
  Future<Map<String,dynamic>> _body(Request req) async {
    if(!((req.headers['content-type'] ?? '').startsWith('application/json'))) throw DomainError('Content-Type must be application/json',415);
    // Reject oversized requests while streaming, before buffering unbounded data.
    final bytes=<int>[];
    await for(final chunk in req.read()) {
      if(bytes.length+chunk.length>131072) throw DomainError('Body too large',413);
      bytes.addAll(chunk);
    }
    final decoded=jsonDecode(utf8.decode(bytes));
    if(decoded is! Map<String,dynamic>) throw DomainError('Expected a JSON object');
    return decoded;
  }
  String _branch(Request req) {
    final b=req.url.queryParameters['branch_id'];
    if(b==null || b.isEmpty) throw DomainError('branch_id query required');
    return b;
  }
  Future<Response> _write(Request r,String command) async {
    final p=_p(r), key=r.headers['idempotency-key'];
    if(key==null) throw DomainError('Idempotency-Key header required',400);
    if(enforceLicenses) await licensing.requireWritable(p);
    return _json(engine.command(p,command,await _body(r),key),status:201);
  }
  Handler get handler {
    final router=Router();
    router.get('/health', (Request r)=>_json({'status':'ok','service':'kasher-local','version':'0.1.0'}));
    router.post('/api/v1/auth/login', (Request r) async {
      final body=await _body(r);
      final tenant=body['tenant_id'],username=body['username'],password=body['password'];
      if(tenant is! String || username is! String || password is! String) throw DomainError('Missing credentials',400);
      // In-process per-identity throttling. Still require TLS and durable auth controls for production.
      final attemptKey=tenant.trim()+':'+username.trim();
      final now=DateTime.now().toUtc();
      final recent=_loginFailures.putIfAbsent(attemptKey,()=> <DateTime>[]);
      recent.removeWhere((x)=>x.isBefore(now.subtract(const Duration(minutes:5))));
      if(recent.length>=8) throw DomainError('Too many login attempts. Try later.',429);
      final deviceId=body['device_id'],deviceSecret=body['device_secret'];
      if(deviceId!=null && deviceId is! String) throw DomainError('Invalid device credentials',400);
      if(deviceSecret!=null && deviceSecret is! String) throw DomainError('Invalid device credentials',400);
      final result=auth.login(tenant,username,password,
        deviceId:deviceId as String?,deviceSecret:deviceSecret as String?,
        requireDevice:enforceDevices);
      if(result==null) {recent.add(now);throw DomainError('Invalid credentials',401);}
      _loginFailures.remove(attemptKey);
      return _json(result);
    });
    router.post('/api/v1/auth/logout', (Request r) {
      _p(r);
      final token=r.headers['authorization']!.substring(7);
      auth.logout(token);
      return _json({'ok':true});
    });
    router.post('/api/v1/devices/claim',(Request r) async {
      final body=await _body(r);
      if(body['pairing_code'] is! String || body['device_name'] is! String ||
          body['tenant_id'] is! String) {
        throw DomainError('Pairing code and device name required',400);
      }
      return _json(devices.claim(body['pairing_code'] as String,
        body['device_name'] as String,
        expectedTenant:body['tenant_id'] as String),status:201);
    });
    router.get('/api/v1/devices',(Request r)=>
      _json(devices.list(_p(r),_branch(r))));
    router.post('/api/v1/devices/pairings',(Request r) async {
      final actor=_p(r),body=await _body(r);
      if(body['branch_id'] is! String) throw DomainError('branch_id required',400);
      return _json(devices.issue(actor,body['branch_id'] as String),status:201);
    });
    router.post('/api/v1/devices/revoke',(Request r) async {
      final actor=_p(r),body=await _body(r);
      if(body['device_id'] is! String || body['reason'] is! String) {
        throw DomainError('device_id and reason required',400);
      }
      return _json(devices.revoke(actor,body['device_id'] as String,
        body['reason'] as String),status:201);
    });
    router.get('/api/v1/licenses/status', (Request r) async {
      return _json(await licensing.status(_p(r)));
    });
    router.post('/api/v1/licenses/activate', (Request r) async {
      final actor=_p(r),key=r.headers['idempotency-key'];
      if(key==null || key.length<16 || key.length>128) {
        throw DomainError('Idempotency-Key header required (16..128)',400);
      }
      final input=await _body(r);
      if(input['license_token'] is! String) {
        throw DomainError('Signed license_token required',400);
      }
      return _json(await licensing.activate(actor,input['license_token'] as String),
        status:201);
    });
    router.get('/api/v1/me', (Request r) {
      final p=_p(r);
      return _json({'id':p.id,'tenant_id':p.tenantId,'branch_id':p.branchId,'role':p.role,'username':p.name});
    });
    router.get('/api/v1/users', (Request r)=>_json(engine.listUsers(_p(r))));
    router.get('/api/v1/branches', (Request r)=>_json(engine.listBranches(_p(r))));
    router.get('/api/v1/warehouses', (Request r)=>_json(engine.listWarehouses(_p(r),_branch(r))));
    router.get('/api/v1/branch-shipments', (Request r)=>
      _json(engine.listBranchShipments(_p(r),_branch(r))));
    router.get('/api/v1/branch-shipments/<id>', (Request r,String id)=>
      _json(engine.readBranchShipment(_p(r),id)));

    router.get('/api/v1/promotions', (Request r)=>
      _json(engine.listPromotions(_p(r),r.url.queryParameters['product_id'] ?? '')));
    router.get('/api/v1/units', (Request r)=>_json(engine.listProductUnits(_p(r),
      r.url.queryParameters['product_id'] ?? '')));
    router.get('/api/v1/products', (Request r)=>_json(engine.listProducts(_p(r),
      search:r.url.queryParameters['q'] ?? '')));
    router.get('/api/v1/customers', (Request r)=>_json(engine.listParties(_p(r),customers:true)));
    router.get('/api/v1/suppliers', (Request r)=>_json(engine.listParties(_p(r),customers:false)));
    router.get('/api/v1/lots', (Request r)=>_json(engine.listLots(_p(r),_branch(r),
      warehouseId:r.url.queryParameters['warehouse_id'],
      productId:r.url.queryParameters['product_id'])));
    router.get('/api/v1/counts', (Request r)=>_json(engine.listCounts(_p(r),_branch(r))));
    router.get('/api/v1/counts/<id>', (Request r,String id)=>_json(engine.readCount(_p(r),id)));
    router.get('/api/v1/stock', (Request r)=>_json(engine.listStock(_p(r),_branch(r))));
    router.get('/api/v1/documents', (Request r)=>_json(engine.listDocuments(_p(r),_branch(r))));
    router.get('/api/v1/documents/<id>', (Request r,String id)=>_json(engine.readDocument(_p(r),id)));
    router.get('/api/v1/receipts/<id>', (Request r,String id)=>
      _json(engine.saleReceipt(_p(r),id)));
    router.get('/api/v1/dashboard', (Request r)=>_json(engine.dashboard(_p(r),_branch(r))));
    router.get('/api/v1/audit', (Request r)=>_json(engine.audit(_p(r),_branch(r))));
    router.get('/api/v1/shifts', (Request r)=>_json(engine.listShifts(_p(r),_branch(r))));
    router.get('/api/v1/sync/outbox', (Request r)=>_json(engine.outbox(_p(r),_branch(r))));
    final commands={
      'promotions':'create_promotion','promotions/stop':'stop_promotion',
      'users':'create_user','products':'create_product','units':'create_product_unit','customers':'create_customer','suppliers':'create_supplier',
      'branches':'create_branch','warehouses':'create_warehouse',
      'branch-shipments/dispatch':'branch_shipment_dispatch',
      'branch-shipments/receive':'branch_shipment_receive',
      'branch-shipments/cancel':'branch_shipment_cancel',
      'inventory/transfers':'transfer_warehouse','lots/quarantine':'set_lot_quarantine','purchases':'purchase','sales':'sale','sales/returns':'sale_return',
      'purchases/returns':'purchase_return','customers/receipts':'customer_receipt',
      'suppliers/payments':'supplier_payment','expenses':'expense',
      'counts':'count_open','counts/lines':'count_line','counts/submit':'count_submit',
      'counts/approve':'count_approve','counts/cancel':'count_cancel',
      'inventory/adjustments':'adjust_stock','inventory/preparations':'prepare',
      'shifts/open':'shift_open','shifts/close':'shift_close',
    };
    commands.forEach((path,command){router.post('/api/v1/$path',(Request r)=>_write(r,command));});
    return (Request r) async {
      try {
        return await router.call(r);
      } on DomainError catch(e) {
        return _json({'error':e.message},status:e.status);
      } on FormatException catch(_) {
        return _json({'error':'Invalid input format'},status:400);
      } on ArgumentError catch(_) {
        return _json({'error':'Invalid numeric input'},status:400);
      } on Object {
        // Never leak SQL, password hashes or internal paths over LAN.
        // Internal errors should be sent to a sanitized operational logger.
        return _json({'error':'Internal server error'},status:500);
      }
    };
  }
}
