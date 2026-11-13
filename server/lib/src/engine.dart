import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'money.dart';
import 'security.dart';
import 'store.dart';

class DomainError implements Exception {
  final String message;
  final int status;
  DomainError(this.message, [this.status=400]);
  @override String toString() => message;
}

class LedgerLine {
  final String account;
  final int debit,credit;
  LedgerLine(this.account,{this.debit=0,this.credit=0});
}

class PosEngine {
  final DatabaseStore store;
  const PosEngine(this.store);
  static final _uuid=Uuid();
  String _id() => _uuid.v4();
  String _now() => DateTime.now().toUtc().toIso8601String();

  Map<String,Object?> bootstrap(String name,String branchName,String username,String password) {
    if (store.first('SELECT id FROM tenants LIMIT 1') != null) throw DomainError('Database has already been initialized',409);
    if (password.length<12) throw DomainError('Admin password must contain at least 12 characters');
    return store.transaction(() {
      final tenantId=_id(), branchId=_id(), warehouseId=_id(), userId=_id(), time=_now();
      final salt=secureToken(18);
      store.exec('INSERT INTO tenants(id,name,created_at) VALUES(?,?,?)',[tenantId,nonEmpty(name,'tenant name'),time]);
      store.exec('INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES(?,?,?,?,?)',
        [branchId,tenantId,'BR01',nonEmpty(branchName,'branch name'),time]);
      store.exec('INSERT INTO warehouses(id,branch_id,name,is_default) VALUES(?,?,?,1)',[warehouseId,branchId,'صالة العرض']);
      store.exec('''INSERT INTO users(id,tenant_id,branch_id,username,password_salt,password_hash,role,created_at)
        VALUES(?,?,?,?,?,?,'owner',?)''',
        [userId,tenantId,branchId,nonEmpty(username,'username'),salt,pbkdf2(password,salt),time]);
      return {'tenant_id':tenantId,'branch_id':branchId,'warehouse_id':warehouseId,'user_id':userId};
    });
  }

  /// Write commands require an Idempotency-Key. Original results are replayed;
  /// accidentally reusing a key with different data is rejected.
  Map<String,Object?> command(Principal p,String action,Map<String,dynamic> body,String key) {
    if (key.length<16 || key.length>128) throw DomainError('Idempotency-Key must be 16..128 characters');
    final inputHash=sha256.convert(utf8.encode('$action:${jsonEncode(body)}')).toString();
    return store.transaction(() {
      final existing=store.first('SELECT * FROM idempotency_keys WHERE actor_id=? AND request_key=?',[p.id,key]);
      if(existing!=null) {
        if(existing['request_hash']!=inputHash) throw DomainError('Idempotency key reused with different request',409);
        return Map<String,Object?>.from(jsonDecode(existing['response_json'] as String) as Map);
      }
      final result=_execute(p,action,body);
      store.exec('INSERT INTO idempotency_keys(actor_id,request_key,request_hash,response_json,created_at) VALUES(?,?,?,?,?)',
        [p.id,key,inputHash,jsonEncode(result),_now()]);
      return result;
    });
  }

  Map<String,Object?> _execute(Principal p,String action,Map<String,dynamic> input) {
    switch(action) {
      case 'create_product':
        _allow(p,['owner','manager','stock','purchasing']);
        final productId=_id(), now=_now();
        final sku=nonEmpty(input['sku'],'sku');
        final barcode=input['barcode'] == null || input['barcode']=='' ? null : nonEmpty(input['barcode'],'barcode');
        final price=strictInt(input['sell_price_minor'],'sell_price_minor');
        store.exec('''INSERT INTO products(id,tenant_id,sku,barcode,name_ar,name_en,category,base_unit,
          sell_price_minor,reorder_qty_milli,tax_rate_bp,track_expiry,created_at,updated_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
          [productId,p.tenantId,sku,barcode,nonEmpty(input['name_ar'],'name_ar'),input['name_en'],
           input['category'] ?? 'عام',input['base_unit'] ?? 'قطعة',price,
           strictInt(input['reorder_qty_milli'] ?? 0,'reorder_qty_milli'),
           strictInt(input['tax_rate_bp'] ?? 0,'tax_rate_bp'),
           input['track_expiry']==true ? 1:0,now,now]);
        _audit(p,'product.create',productId,{'sku':sku});
        return {'id':productId,'sku':sku};
      case 'create_product_unit':
        _allow(p,['owner','manager','stock']);
        final productId=nonEmpty(input['product_id'],'product_id');
        _product(p,productId);
        final name=nonEmpty(input['unit_name'],'unit_name');
        final factor=strictInt(input['factor_milli'],'factor_milli',min:1);
        final price=strictInt(input['sell_price_minor'],'sell_price_minor');
        if(factor>1000000000 || price>1000000000) throw DomainError('Unit factor or price exceeds allowed bounds');
        final barcode=input['barcode']==null || input['barcode']=='' ? null:
          nonEmpty(input['barcode'],'barcode');
        if(barcode!=null) {
          if(store.first('SELECT id FROM products WHERE tenant_id=? AND barcode=?',[p.tenantId,barcode])!=null ||
             store.first('''SELECT u.id FROM product_units u
               JOIN products p ON p.id=u.product_id
               WHERE p.tenant_id=? AND u.barcode=?''',[p.tenantId,barcode])!=null) {
            throw DomainError('Barcode already assigned to this tenant',409);
          }
        }
        final id=_id();
        store.exec('''INSERT INTO product_units
          (id,product_id,unit_name,factor_milli,sell_price_minor,barcode,created_at)
          VALUES(?,?,?,?,?,?,?)''',[id,productId,name,factor,price,barcode,_now()]);
        _audit(p,'product_unit.create',id,{'product_id':productId,'unit_name':name});
        if(p.branchId!=null) _outbox(p.branchId!,'product_unit',{'id':id,'product_id':productId});
        return {'id':id,'product_id':productId,'unit_name':name,'factor_milli':factor,
          'sell_price_minor':price,'barcode':barcode};
      case 'create_customer':
        _allow(p,['owner','manager','cashier']);
        final id=_id();
        store.exec('INSERT INTO customers(id,tenant_id,name,phone,credit_limit_minor,created_at) VALUES(?,?,?,?,?,?)',
          [id,p.tenantId,nonEmpty(input['name'],'name'),input['phone'],
           strictInt(input['credit_limit_minor'] ?? 0,'credit_limit_minor'),_now()]);
        _audit(p,'customer.create',id,input);
        return {'id':id};
      case 'create_supplier':
        _allow(p,['owner','manager','purchasing']);
        final id=_id();
        store.exec('INSERT INTO suppliers(id,tenant_id,name,phone,created_at) VALUES(?,?,?,?,?)',
          [id,p.tenantId,nonEmpty(input['name'],'name'),input['phone'],_now()]);
        _audit(p,'supplier.create',id,input);
        return {'id':id};
      case 'create_user':
        _allow(p,['owner']);
        final branch=_branch(p,input['branch_id']);
        final id=_id(),role=nonEmpty(input['role'],'role');
        if(!['owner','manager','cashier','stock','purchasing','viewer'].contains(role)) throw DomainError('Invalid role');
        final username=nonEmpty(input['username'],'username');
        final password=input['password'];
        if(password is! String || password.length<12) throw DomainError('Password must have at least 12 characters');
        final salt=secureToken(18);
        store.exec('''INSERT INTO users(id,tenant_id,branch_id,username,password_salt,password_hash,role,created_at)
          VALUES(?,?,?,?,?,?,?,?)''',[id,p.tenantId,branch,username,salt,pbkdf2(password,salt),role,_now()]);
        _audit(p,'user.create',id,{'username':username,'role':role,'branch_id':branch},branch);
        return {'id':id,'username':username,'role':role};
      case 'create_warehouse':
        _allow(p,['owner','manager']);
        final branch=_branch(p,input['branch_id']);
        final id=_id(), name=nonEmpty(input['name'],'name');
        store.exec('INSERT INTO warehouses(id,branch_id,name,is_default) VALUES(?,?,?,0)',
          [id,branch,name]);
        _audit(p,'warehouse.create',id,{'name':name},branch);
        _outbox(branch,'warehouse',{'id':id,'name':name});
        return {'id':id,'name':name,'branch_id':branch};
      case 'transfer_warehouse': return _transferWarehouse(p,input);
      case 'create_branch':
        _allow(p,['owner']);
        final id=_id(), wh=_id(),code=nonEmpty(input['code'],'code');
        store.exec('INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES(?,?,?,?,?)',
          [id,p.tenantId,code,nonEmpty(input['name'],'name'),_now()]);
        store.exec('INSERT INTO warehouses(id,branch_id,name,is_default) VALUES(?,?,?,1)',[wh,id,'صالة العرض']);
        _audit(p,'branch.create',id,{'code':code});
        return {'id':id,'warehouse_id':wh};
      case 'purchase': return _purchase(p,input);
      case 'sale': return _sale(p,input);
      case 'sale_return': return _saleReturn(p,input);
      case 'purchase_return': return _purchaseReturn(p,input);
      case 'customer_receipt': return _settle(p,input,customer:true);
      case 'supplier_payment': return _settle(p,input,customer:false);
      case 'expense': return _expense(p,input);
      case 'adjust_stock': return _adjust(p,input);
      case 'prepare': return _prepare(p,input);
      case 'shift_open': return _shiftOpen(p,input);
      case 'shift_close': return _shiftClose(p,input);
      default: throw DomainError('Unknown command',404);
    }
  }

  void _allow(Principal p,List<String> roles) {
    if (!roles.contains(p.role)) throw DomainError('Permission denied',403);
  }
  String _branch(Principal p, Object? requested) {
    final id=nonEmpty(requested ?? p.branchId,'branch_id');
    final b=store.first('SELECT id FROM branches WHERE id=? AND tenant_id=?',[id,p.tenantId]);
    if(b==null || (!p.isOwner && p.branchId!=id)) throw DomainError('Branch not permitted',403);
    return id;
  }
  String _warehouse(String branchId,Object? requested) {
    final w = requested == null
      ? store.first('SELECT * FROM warehouses WHERE branch_id=? AND is_default=1',[branchId])
      : store.first('SELECT * FROM warehouses WHERE branch_id=? AND id=?',[branchId,requested]);
    if(w==null) throw DomainError('Warehouse is not in requested branch',403);
    return w['id'] as String;
  }
  Map<String,Object?> _product(Principal p,String id) {
    final product=store.first('SELECT * FROM products WHERE id=? AND tenant_id=? AND active=1',[id,p.tenantId]);
    if(product==null) throw DomainError('Product not found or inactive',404);
    return product;
  }
  Map<String,Object?> _productUnit(Principal p,String productId,String unitId) {
    final unit=store.first('''SELECT u.* FROM product_units u
      JOIN products pr ON pr.id=u.product_id
      WHERE u.id=? AND u.product_id=? AND u.active=1 AND pr.tenant_id=? AND pr.active=1''',
      [unitId,productId,p.tenantId]);
    if(unit==null) throw DomainError('Unknown or forbidden product unit',404);
    return unit;
  }

  Map<String,Object?> _party(String table,Principal p,String id) {
    if(table!='customers' && table!='suppliers') throw StateError('Invalid table');
    final record=store.first('SELECT * FROM $table WHERE id=? AND tenant_id=?',[id,p.tenantId]);
    if(record==null) throw DomainError('Party is not part of your tenant',404);
    return record;
  }
  String _sequence(String branch,String kind) {
    store.exec('INSERT OR IGNORE INTO number_sequences(branch_id,document_type,next_number) VALUES(?,?,1)',[branch,kind]);
    final n=store.first('SELECT next_number FROM number_sequences WHERE branch_id=? AND document_type=?',[branch,kind])!['next_number'] as int;
    store.exec('UPDATE number_sequences SET next_number=? WHERE branch_id=? AND document_type=?',[n+1,branch,kind]);
    final code=store.first('SELECT code FROM branches WHERE id=?',[branch])!['code'];
    return '$code-${kind.toUpperCase()}-${DateTime.now().toUtc().year}-${n.toString().padLeft(7,'0')}';
  }
  void _post(Principal p,String branch,String type,String ref,List<LedgerLine> raw) {
    final lines=raw.where((r)=>r.debit!=0 || r.credit!=0).toList();
    final debits=lines.fold<int>(0,(sum,x)=>sum+x.debit);
    final credits=lines.fold<int>(0,(sum,x)=>sum+x.credit);
    if(debits!=credits || debits<=0) throw DomainError('Ledger not balanced',500);
    final entry=_id();
    store.exec('INSERT INTO journal_entries(id,branch_id,reference_type,reference_id,created_by,created_at) VALUES(?,?,?,?,?,?)',
      [entry,branch,type,ref,p.id,_now()]);
    for(final line in lines) {
      store.exec('INSERT INTO journal_lines(id,entry_id,account,debit_minor,credit_minor) VALUES(?,?,?,?,?)',
        [_id(),entry,line.account,line.debit,line.credit]);
    }
  }
  void _audit(Principal p,String action,String entity,Map<String,dynamic> details,[String? branch]) {
    store.exec('INSERT INTO audit_logs(id,branch_id,actor_id,action,entity_id,details_json,created_at) VALUES(?,?,?,?,?,?,?)',
      [_id(),branch ?? p.branchId,p.id,action,entity,jsonEncode(details),_now()]);
  }
  void _outbox(String branch,String topic,Map<String,Object?> data) {
    store.exec('INSERT INTO sync_outbox(id,branch_id,topic,payload_json,created_at) VALUES(?,?,?,?,?)',
      [_id(),branch,topic,jsonEncode(data),_now()]);
  }
  String _document(Principal p,String branch,String warehouse,String kind,String? party,
    int subtotal,int discount,int tax,int total,int paid,int cost,Map<String,dynamic> snapshot,{String? original}) {
    final id=_id();
    store.exec('''INSERT INTO documents(id,tenant_id,branch_id,warehouse_id,kind,number,party_id,original_id,
      subtotal_minor,discount_minor,tax_minor,total_minor,paid_minor,cost_minor,snapshot_json,created_by,created_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [id,p.tenantId,branch,warehouse,kind,_sequence(branch,kind),party,original,subtotal,discount,tax,total,paid,cost,
       jsonEncode(snapshot),p.id,_now()]);
    return id;
  }
  String _line(String doc,String product,int qty,int price,int disc,int tax,int cost,
      {String? originalLine,int? grossMinor,String? unitId,int? unitCount}) {
    final id=_id();
    store.exec('''INSERT INTO document_lines(id,document_id,product_id,qty_milli,
      unit_price_minor,discount_minor,tax_minor,cost_minor,original_line_id,
      gross_minor,unit_id,unit_count) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)''',
      [id,doc,product,qty,price,disc,tax,cost,originalLine,grossMinor,unitId,unitCount]);
    return id;
  }
  /// Positive movement adds exact landed cost; negative movement removes WAC cost.
  int _stock(Principal p,String branch,String warehouse,String product,int delta,int addCost,String kind,String ref) {
    if(delta==0) throw DomainError('Quantity cannot be zero');
    store.exec('''INSERT OR IGNORE INTO stock_balances(branch_id,warehouse_id,product_id,qty_milli,cost_minor)
      VALUES(?,?,?,0,0)''',[branch,warehouse,product]);
    final b=store.first('SELECT qty_milli,cost_minor FROM stock_balances WHERE branch_id=? AND warehouse_id=? AND product_id=?',
      [branch,warehouse,product])!;
    final qty=b['qty_milli'] as int,cost=b['cost_minor'] as int;
    int costDelta;
    if(delta>0) {
      if(addCost<0) throw DomainError('Negative stock cost');
      costDelta=addCost;
    } else {
      if(qty < -delta) throw DomainError('Insufficient stock',409);
      costDelta= -(-delta==qty ? cost : prorate(cost,-delta,qty));
    }
    final newQty=qty+delta, newCost=cost+costDelta;
    store.exec('UPDATE stock_balances SET qty_milli=?,cost_minor=? WHERE branch_id=? AND warehouse_id=? AND product_id=?',
      [newQty,newCost,branch,warehouse,product]);
    store.exec('''INSERT INTO inventory_movements(id,branch_id,warehouse_id,product_id,qty_change_milli,cost_change_minor,
      reference_type,reference_id,created_by,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)''',
      [_id(),branch,warehouse,product,delta,costDelta,kind,ref,p.id,_now()]);
    return costDelta.abs();
  }
  List<Map<String,dynamic>> _inputLines(Map<String,dynamic> input) {
    final raw=input['lines'];
    if(raw is! List || raw.isEmpty || raw.length>200) throw DomainError('Expected 1..200 lines');
    return raw.map((x) {
      if(x is! Map<String,dynamic>) throw DomainError('Invalid line');
      return x;
    }).toList();
  }
  List<Map<String,dynamic>> _payments(Map<String,dynamic> input) {
    final raw=input['payments'] ?? <dynamic>[];
    if(raw is! List || raw.length>8) throw DomainError('Invalid payment count');
    return raw.map((x) {
      if(x is! Map<String,dynamic>) throw DomainError('Invalid payment');
      final method=x['method'];
      if(!['cash','card','wallet','bank'].contains(method)) throw DomainError('Invalid payment method');
      strictInt(x['amount_minor'],'amount_minor',min:1);
      return x;
    }).toList();
  }
  String _payAccount(String method) => switch(method) {
    'cash'=>'CASH', 'card'=>'CARD_CLEARING', 'wallet'=>'WALLET', 'bank'=>'BANK',
    _=>throw DomainError('Invalid payment method')
  };
  void _savePayments(String doc,String branch,String? party,String direction,List<Map<String,dynamic>> payments) {
    for(final x in payments) {
      store.exec('''INSERT INTO payments(id,document_id,branch_id,party_id,method,direction,amount_minor,reference,created_at)
        VALUES(?,?,?,?,?,?,?,?,?)''',
        [_id(),doc,branch,party,x['method'],direction,x['amount_minor'],x['reference'],_now()]);
    }
  }
  Map<String,Object?> _purchase(Principal p,Map<String,dynamic> input) {
    _allow(p,['owner','manager','purchasing']);
    final branch=_branch(p,input['branch_id']), warehouse=_warehouse(branch,input['warehouse_id']);
    final supplier=nonEmpty(input['supplier_id'],'supplier_id');
    _party('suppliers',p,supplier);
    final items=<Map<String,dynamic>>[];
    var subtotal=0,discount=0,tax=0;
    for(final x in _inputLines(input)) {
      final product=nonEmpty(x['product_id'],'product_id');
      final data=_product(p,product);
      final qty=strictInt(x['qty_milli'],'qty_milli',min:1);
      final bonus=strictInt(x['bonus_qty_milli'] ?? 0,'bonus_qty_milli');
      final price=strictInt(x['unit_cost_minor'],'unit_cost_minor');
      final gross=lineAmount(price,qty), disc=strictInt(x['discount_minor'] ?? 0,'discount_minor');
      if(disc>gross) throw DomainError('Discount exceeds purchase line');
      final vat=taxAmount(gross-disc,data['tax_rate_bp'] as int);
      items.add({'product_id':product,'qty':qty+bonus,'ordered_qty':qty,'price':price,'discount':disc,
        'tax':vat,'net':gross-disc,'name':data['name_ar']});
      subtotal+=gross;discount+=disc;tax+=vat;
    }
    final total=subtotal-discount+tax, payments=_payments(input);
    final paid=payments.fold<int>(0,(s,x)=>s+(x['amount_minor'] as int));
    if(paid>total) throw DomainError('Payment exceeds purchase total');
    final doc=_document(p,branch,warehouse,'purchase',supplier,subtotal,discount,tax,total,paid,subtotal-discount,
      {'supplier_id':supplier,'lines':items,'payments':payments});
    for(final line in items) {
      _line(doc,line['product_id'] as String,line['qty'] as int,line['price'] as int,
        line['discount'] as int,line['tax'] as int,line['net'] as int);
      _stock(p,branch,warehouse,line['product_id'] as String,line['qty'] as int,line['net'] as int,'purchase',doc);
    }
    _savePayments(doc,branch,supplier,'out',payments);
    _post(p,branch,'purchase',doc,[
      LedgerLine('INVENTORY',debit:subtotal-discount),
      LedgerLine('VAT_INPUT',debit:tax), LedgerLine('AP:$supplier',credit:total),
      LedgerLine('AP:$supplier',debit:paid),
      ...payments.map((x)=>LedgerLine(_payAccount(x['method'] as String),credit:x['amount_minor'] as int)),
    ]);
    _audit(p,'purchase.posted',doc,{'total_minor':total,'paid_minor':paid},branch);
    _outbox(branch,'purchase',{'id':doc,'total_minor':total});
    return {'id':doc,'number':_docNumber(doc),'total_minor':total,'paid_minor':paid,'due_minor':total-paid};
  }

  Map<String,Object?> _sale(Principal p,Map<String,dynamic> input) {
    _allow(p,['owner','manager','cashier']);
    final branch=_branch(p,input['branch_id']), warehouse=_warehouse(branch,input['warehouse_id']);
    final customer=input['customer_id'] as String?;
    if(customer!=null) _party('customers',p,customer);
    final items=<Map<String,dynamic>>[];
    var subtotal=0,discount=0,tax=0;
    for(final x in _inputLines(input)) {
      final product=nonEmpty(x['product_id'],'product_id');
      final data=_product(p,product);
      final unitId=x['unit_id'];
      late final int qty,price,gross;
      int? unitCount;
      if(unitId!=null) {
        if(x.containsKey('qty_milli')) throw DomainError('Use either unit_count or qty_milli');
        final unit=_productUnit(p,product,nonEmpty(unitId,'unit_id'));
        unitCount=strictInt(x['unit_count'] ?? 1,'unit_count',min:1);
        if(unitCount>100000) throw DomainError('Unit count exceeds maximum');
        qty=unitCount*(unit['factor_milli'] as int);
        price=strictInt(x['unit_price_minor'] ?? unit['sell_price_minor'],'unit_price_minor');
        if(price>1000000000) throw DomainError('Price exceeds maximum');
        if(price!=(unit['sell_price_minor'] as int) && p.role=='cashier') {
          throw DomainError('Unit price override requires supervisor',403);
        }
        gross=price*unitCount;
      } else {
        if(x.containsKey('unit_count')) throw DomainError('unit_count requires unit_id');
        qty=strictInt(x['qty_milli'],'qty_milli',min:1);
        price=strictInt(x['unit_price_minor'] ?? data['sell_price_minor'],'unit_price_minor');
        if(price!=(data['sell_price_minor'] as int) && p.role=='cashier') {
          throw DomainError('Price override requires supervisor',403);
        }
        gross=lineAmount(price,qty);
      }
      final disc=strictInt(x['discount_minor'] ?? 0,'discount_minor');
      if(disc>gross) throw DomainError('Discount exceeds sale line');
      if(disc>0 && p.role=='cashier') throw DomainError('Discount requires supervisor',403);
      final vat=taxAmount(gross-disc,data['tax_rate_bp'] as int);
      items.add({'product_id':product,'qty':qty,'price':price,'gross':gross,
        'unit_id':unitId,'unit_count':unitCount,
        'discount':disc,'tax':vat,'net':gross-disc,'name':data['name_ar']});
      subtotal+=gross; discount+=disc; tax+=vat;
    }
    final total=subtotal-discount+tax, payments=_payments(input);
    final paid=payments.fold<int>(0,(s,x)=>s+(x['amount_minor'] as int));
    if(paid>total) throw DomainError('Payment exceeds sale total');
    if(paid<total && customer==null) throw DomainError('Credit sale requires customer');
    if(paid<total) {
      final party=_party('customers',p,customer!);
      final limit=party['credit_limit_minor'] as int;
      if(_accountBalance('AR:$customer') + total-paid > limit) throw DomainError('Customer credit limit exceeded',409);
    }
    final doc=_document(p,branch,warehouse,'sale',customer,subtotal,discount,tax,total,paid,0,
      {'customer_id':customer,'lines':items,'payments':payments});
    var cogs=0;
    for(final line in items) {
      final cost=_stock(p,branch,warehouse,line['product_id'] as String,-(line['qty'] as int),0,'sale',doc);
      cogs+=cost;
      _line(doc,line['product_id'] as String,line['qty'] as int,line['price'] as int,
        line['discount'] as int,line['tax'] as int,cost,
        grossMinor:line['gross'] as int,unitId:line['unit_id'] as String?,
        unitCount:line['unit_count'] as int?);
    }
    store.exec('UPDATE documents SET cost_minor=? WHERE id=?',[cogs,doc]);
    _savePayments(doc,branch,customer,'in',payments);
    _post(p,branch,'sale',doc,[
      ...payments.map((x)=>LedgerLine(_payAccount(x['method'] as String),debit:x['amount_minor'] as int)),
      if(total-paid>0) LedgerLine('AR:$customer',debit:total-paid),
      LedgerLine('SALES_REVENUE',credit:subtotal-discount),
      LedgerLine('VAT_OUTPUT',credit:tax),
      LedgerLine('COGS',debit:cogs),LedgerLine('INVENTORY',credit:cogs),
    ]);
    _audit(p,'sale.posted',doc,{'total_minor':total,'cost_minor':cogs},branch);
    _outbox(branch,'sale',{'id':doc,'total_minor':total});
    return {'id':doc,'number':_docNumber(doc),'total_minor':total,'paid_minor':paid,
      'credit_minor':total-paid,'cogs_minor':cogs,'gross_profit_minor':subtotal-discount-cogs};
  }

  String _docNumber(String doc) => store.first('SELECT number FROM documents WHERE id=?',[doc])!['number'] as String;
  int _accountBalance(String account) => (store.first('''SELECT COALESCE(SUM(l.debit_minor - l.credit_minor),0) AS balance
    FROM journal_lines l WHERE l.account=?''',[account])!['balance'] as int);

  Map<String,Object?> _settle(Principal p,Map<String,dynamic> input,{required bool customer}) {
    _allow(p,customer?['owner','manager','cashier']:['owner','manager','purchasing']);
    final branch=_branch(p,input['branch_id']);
    final party=nonEmpty(input[customer?'customer_id':'supplier_id'],'party_id');
    _party(customer?'customers':'suppliers',p,party);
    final amount=strictInt(input['amount_minor'],'amount_minor',min:1);
    final method=nonEmpty(input['method'],'method'),payAcc=_payAccount(method);
    final account='${customer?'AR':'AP'}:$party';
    final outstanding=_accountBalance(account) * (customer?1:-1);
    if(amount>outstanding) throw DomainError('Amount exceeds outstanding debt',409);
    final id=_id(),direction=customer?'in':'out';
    store.exec('''INSERT INTO payments(id,branch_id,party_id,method,direction,amount_minor,reference,created_at)
      VALUES(?,?,?,?,?,?,?,?)''',[id,branch,party,method,direction,amount,input['reference'],_now()]);
    _post(p,branch,direction,id,customer
      ? [LedgerLine(payAcc,debit:amount),LedgerLine(account,credit:amount)]
      : [LedgerLine(account,debit:amount),LedgerLine(payAcc,credit:amount)]);
    _audit(p,'debt.$direction',id,{'party_id':party,'amount_minor':amount},branch);
    _outbox(branch,'payment',{'id':id,'party_id':party,'direction':direction});
    return {'id':id,'remaining_minor':outstanding-amount};
  }

  Map<String,Object?> _expense(Principal p,Map<String,dynamic> input) {
    _allow(p,['owner','manager']);
    final branch=_branch(p,input['branch_id']);
    final category=nonEmpty(input['category'],'category');
    final amount=strictInt(input['amount_minor'],'amount_minor',min:1);
    final method=nonEmpty(input['method'],'method');
    final acc=_payAccount(method),id=_id();
    store.exec('''INSERT INTO expenses(id,branch_id,category,note,amount_minor,method,created_by,created_at)
      VALUES(?,?,?,?,?,?,?,?)''',[id,branch,category,input['note'],amount,method,p.id,_now()]);
    _post(p,branch,'expense',id,[LedgerLine('OPERATING_EXPENSE',debit:amount),LedgerLine(acc,credit:amount)]);
    _audit(p,'expense.posted',id,{'category':category,'amount_minor':amount},branch);
    _outbox(branch,'expense',{'id':id,'amount_minor':amount});
    return {'id':id,'amount_minor':amount};
  }

  Map<String,Object?> _adjust(Principal p,Map<String,dynamic> input) {
    _allow(p,['owner','manager','stock']);
    final branch=_branch(p,input['branch_id']), warehouse=_warehouse(branch,input['warehouse_id']);
    final product=nonEmpty(input['product_id'],'product_id');
    _product(p,product);
    final qty=input['qty_change_milli'];
    if(qty is! int || qty==0) throw DomainError('Adjustment quantity must be nonzero integer');
    final cost=strictInt(input['added_cost_minor'] ?? 0,'added_cost_minor');
    if(qty>0 && cost==0) throw DomainError('Positive adjustment requires valuation');
    final reason=nonEmpty(input['reason'],'reason');
    final id=_id(),deltaCost=_stock(p,branch,warehouse,product,qty,cost,'adjustment',id);
    _post(p,branch,'adjustment',id,qty>0
      ? [LedgerLine('INVENTORY',debit:deltaCost),LedgerLine('INVENTORY_ADJUSTMENT',credit:deltaCost)]
      : [LedgerLine('INVENTORY_ADJUSTMENT',debit:deltaCost),LedgerLine('INVENTORY',credit:deltaCost)]);
    _audit(p,'stock.adjust',id,{'product_id':product,'qty_change_milli':qty,'reason':reason},branch);
    _outbox(branch,'adjustment',{'id':id,'product_id':product,'qty_change_milli':qty});
    return {'id':id,'cost_change_minor':qty>0?deltaCost:-deltaCost};
  }

  /// Warehouse-to-warehouse transfer within ONE local branch database only.
  /// Cross-branch transfers require a signed dispatch/receive cloud protocol.
  Map<String,Object?> _transferWarehouse(Principal p,Map<String,dynamic> input) {
    _allow(p,['owner','manager','stock']);
    final branch=_branch(p,input['branch_id']);
    final source=_warehouse(branch,input['source_warehouse_id']);
    final destination=_warehouse(branch,input['destination_warehouse_id']);
    if(source==destination) throw DomainError('Source and destination warehouses must differ');
    final product=nonEmpty(input['product_id'],'product_id');
    _product(p,product);
    final qty=strictInt(input['qty_milli'],'qty_milli',min:1);
    final id=_id();
    final cost=_stock(p,branch,source,product,-qty,0,'warehouse_transfer_out',id);
    _stock(p,branch,destination,product,qty,cost,'warehouse_transfer_in',id);
    _audit(p,'warehouse.transfer',id,{'product_id':product,
      'qty_milli':qty,'source_warehouse_id':source,
      'destination_warehouse_id':destination,'cost_minor':cost},branch);
    _outbox(branch,'warehouse_transfer',{'id':id,'product_id':product,
      'source_warehouse_id':source,'destination_warehouse_id':destination,
      'qty_milli':qty,'cost_minor':cost});
    return {'id':id,'qty_milli':qty,'cost_minor':cost};
  }

  Map<String,Object?> _prepare(Principal p,Map<String,dynamic> input) {
    _allow(p,['owner','manager','stock']);
    final branch=_branch(p,input['branch_id']),warehouse=_warehouse(branch,input['warehouse_id']);
    final raw=nonEmpty(input['source_product_id'],'source_product_id');
    final output=nonEmpty(input['output_product_id'],'output_product_id');
    if(raw==output) throw DomainError('Raw and output products must be different');
    _product(p,raw);_product(p,output);
    final consumed=strictInt(input['input_qty_milli'],'input_qty_milli',min:1);
    final produced=strictInt(input['output_qty_milli'],'output_qty_milli',min:1);
    final id=_id(), cost=_stock(p,branch,warehouse,raw,-consumed,0,'preparation',id);
    _stock(p,branch,warehouse,output,produced,cost,'preparation',id);
    store.exec('''INSERT INTO preps(id,branch_id,source_product_id,output_product_id,input_milli,output_milli,
      allocated_cost_minor,created_at) VALUES(?,?,?,?,?,?,?,?)''',
      [id,branch,raw,output,consumed,produced,cost,_now()]);
    _audit(p,'preparation.posted',id,{'source':raw,'output':output,'consumed':consumed,'produced':produced},branch);
    _outbox(branch,'preparation',{'id':id,'allocated_cost_minor':cost});
    return {'id':id,'allocated_cost_minor':cost,'waste_qty_milli':consumed-produced};
  }
  /// Branch-level drawer shift. Only one shared till shift can be open per
  /// branch; simultaneous cash drawers require explicit per-drawer attribution.
  Map<String,Object?> _shiftOpen(Principal p,Map<String,dynamic> input) {
    _allow(p,['owner','manager','cashier']);
    final branch=_branch(p,input['branch_id']);
    if(store.first('SELECT id FROM cash_shifts WHERE branch_id=? AND closed_at IS NULL',[branch])!=null) {
      throw DomainError('A shift is already open in this branch',409);
    }
    final amount=strictInt(input['opening_minor'],'opening_minor');
    final id=_id(), opened=_now();
    store.exec('''INSERT INTO cash_shifts(id,branch_id,user_id,opening_minor,opened_at)
      VALUES(?,?,?,?,?)''',[id,branch,p.id,amount,opened]);
    _audit(p,'shift.opened',id,{'opening_minor':amount},branch);
    _outbox(branch,'shift_open',{'id':id,'opened_at':opened});
    return {'id':id,'opening_minor':amount,'opened_at':opened};
  }

  int _shiftCashDelta(String branch,String since) {
    return (store.first('''SELECT COALESCE(SUM(l.debit_minor-l.credit_minor),0) AS total
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      WHERE e.branch_id=? AND e.created_at>=? AND l.account='CASH' ''',
      [branch,since])!['total'] as int);
  }

  Map<String,Object?> _shiftClose(Principal p,Map<String,dynamic> input) {
    _allow(p,['owner','manager','cashier']);
    final branch=_branch(p,input['branch_id']);
    final id=nonEmpty(input['shift_id'],'shift_id');
    final shift=store.first('SELECT * FROM cash_shifts WHERE id=? AND branch_id=? AND closed_at IS NULL',[id,branch]);
    if(shift==null) throw DomainError('Open shift not found',404);
    if(p.role=='cashier' && shift['user_id']!=p.id) throw DomainError('Only your own shift can be closed',403);
    final actual=strictInt(input['closing_actual_minor'],'closing_actual_minor');
    final expected=(shift['opening_minor'] as int)+_shiftCashDelta(branch,shift['opened_at'] as String);
    final closed=_now();
    store.exec('''UPDATE cash_shifts SET closing_expected_minor=?,closing_actual_minor=?,closed_at=?
      WHERE id=? AND closed_at IS NULL''',[expected,actual,closed,id]);
    final difference=actual-expected;
    _audit(p,'shift.closed',id,{'expected_minor':expected,'actual_minor':actual,
      'difference_minor':difference},branch);
    _outbox(branch,'shift_close',{'id':id,'closed_at':closed});
    // Do not automatically book the variance as cash; requires manager review.
    return {'id':id,'expected_minor':expected,'actual_minor':actual,
      'difference_minor':difference,'closed_at':closed};
  }

  List<Map<String,Object?>> listShifts(Principal p,String branchId) {
    _allow(p,['owner','manager','cashier']);
    final branch=_branch(p,branchId);
    final shifts=store.rows('''SELECT id,branch_id,user_id,opening_minor,
        closing_expected_minor,closing_actual_minor,opened_at,closed_at
        FROM cash_shifts WHERE branch_id=? ORDER BY opened_at DESC LIMIT 100''',[branch]);
    if(p.role=='cashier') shifts.removeWhere((s)=>s['user_id']!=p.id);
    for(final shift in shifts) {
      if(shift['closed_at']==null && p.role=='cashier') shift.remove('closing_expected_minor');
    }
    return shifts;
  }

  Map<String,Object?> _original(Principal p,String id,String kind,String branch) {
    final doc=store.first('SELECT * FROM documents WHERE id=? AND tenant_id=? AND branch_id=? AND kind=? AND state=?',
      [id,p.tenantId,branch,kind,'posted']);
    if(doc==null) throw DomainError('Original document not found',404);
    return doc;
  }
  Map<String,Object?> _originalLine(String original,String id) {
    final l=store.first('SELECT * FROM document_lines WHERE id=? AND document_id=?',[id,original]);
    if(l==null) throw DomainError('Line does not belong to original document',400);
    final used=store.first('''SELECT COALESCE(SUM(l.qty_milli),0) AS used FROM document_lines l
       JOIN documents d ON d.id=l.document_id WHERE l.original_line_id=? AND d.state='posted' ''',[id])!['used'] as int;
    return {...l,'remaining':(l['qty_milli'] as int)-used};
  }
  Map<String,Object?> _saleReturn(Principal p,Map<String,dynamic> input) {
    _allow(p,['owner','manager']);
    final branch=_branch(p,input['branch_id']);
    final original=nonEmpty(input['original_id'],'original_id');
    final doc0=_original(p,original,'sale',branch);
    final warehouse=_warehouse(branch,input['warehouse_id'] ?? doc0['warehouse_id']);
    final customer=doc0['party_id'] as String?;
    final refundMethod=input['refund_method'] ?? 'cash';
    if(refundMethod!='cash' && refundMethod!='credit') throw DomainError('Return supports cash or customer credit');
    if(refundMethod=='credit' && customer==null) throw DomainError('Customer required for credit return');
    if(refundMethod=='cash' && ((doc0['paid_minor'] as int)<(doc0['total_minor'] as int))) {
      throw DomainError('Credit sales must be refunded to customer account');
    }
    final lines=<Map<String,dynamic>>[];
    final returnedLineIds=<String>{};
    var net=0,tax=0,cogs=0;
    for(final x in _inputLines(input)) {
      final lineId=nonEmpty(x['original_line_id'],'original_line_id');
      if(!returnedLineIds.add(lineId)) throw DomainError('Duplicate original line in the same return',409);
      final originalLine=_originalLine(original,lineId);
      final qty=strictInt(x['qty_milli'],'qty_milli',min:1);
      if(qty>(originalLine['remaining'] as int)) throw DomainError('Returned quantity exceeds sold quantity',409);
      final origQty=originalLine['qty_milli'] as int;
      final previouslyReturned=origQty-(originalLine['remaining'] as int);
      final origGross=(originalLine['gross_minor'] as int?) ??
        lineAmount(originalLine['unit_price_minor'] as int,origQty);
      final originalNet=origGross-(originalLine['discount_minor'] as int);
      final lineNet=prorate(originalNet,previouslyReturned+qty,origQty)-
        prorate(originalNet,previouslyReturned,origQty);
      final originalVat=originalLine['tax_minor'] as int;
      final lineVat=prorate(originalVat,previouslyReturned+qty,origQty)-
        prorate(originalVat,previouslyReturned,origQty);
      final originalCost=originalLine['cost_minor'] as int;
      final lineCost=prorate(originalCost,previouslyReturned+qty,origQty)-
        prorate(originalCost,previouslyReturned,origQty);
      lines.add({'original_line_id':lineId,'product_id':originalLine['product_id'],
        'qty':qty,'net':lineNet,'tax':lineVat,'cost':lineCost});
      net+=lineNet;tax+=lineVat;cogs+=lineCost;
    }
    final total=net+tax;
    if(total<=0) throw DomainError('Empty refund');
    final doc=_document(p,branch,warehouse,'sale_return',customer,net,0,tax,total,
      refundMethod=='cash'?total:0,cogs,
      {'original_id':original,'lines':lines,'refund_method':refundMethod},original:original);
    for(final line in lines) {
      _stock(p,branch,warehouse,line['product_id'] as String,line['qty'] as int,line['cost'] as int,'sale_return',doc);
      _line(doc,line['product_id'] as String,line['qty'] as int,0,0,line['tax'] as int,line['cost'] as int,
        originalLine:line['original_line_id'] as String);
    }
    if(refundMethod=='cash') {
      _savePayments(doc,branch,customer,'out',[{'method':'cash','amount_minor':total}]);
    }
    _post(p,branch,'sale_return',doc,[
      LedgerLine('SALES_RETURNS',debit:net),LedgerLine('VAT_OUTPUT',debit:tax),
      LedgerLine(refundMethod=='cash'?'CASH':'AR:$customer',credit:total),
      LedgerLine('INVENTORY',debit:cogs),LedgerLine('COGS',credit:cogs)
    ]);
    _audit(p,'sale.return',doc,{'original':original,'total_minor':total},branch);
    _outbox(branch,'sale_return',{'id':doc,'original':original});
    return {'id':doc,'total_minor':total};
  }

  Map<String,Object?> _purchaseReturn(Principal p,Map<String,dynamic> input) {
    _allow(p,['owner','manager','purchasing']);
    final branch=_branch(p,input['branch_id']);
    final original=nonEmpty(input['original_id'],'original_id');
    final doc0=_original(p,original,'purchase',branch);
    final warehouse=_warehouse(branch,input['warehouse_id'] ?? doc0['warehouse_id']);
    final supplier=doc0['party_id'] as String;
    final refundMethod=input['refund_method'] ?? 'credit';
    if(refundMethod!='credit' && refundMethod!='cash') throw DomainError('Unsupported supplier refund method');
    if(refundMethod=='cash' && (doc0['paid_minor'] as int)<(doc0['total_minor'] as int)) {
      throw DomainError('Cash refund requires a fully paid original purchase');
    }
    final lines=<Map<String,dynamic>>[];
    final returnedLineIds=<String>{};
    var net=0,tax=0,stockCost=0;
    final docId=_id();
    for(final x in _inputLines(input)) {
      final lineId=nonEmpty(x['original_line_id'],'original_line_id');
      if(!returnedLineIds.add(lineId)) throw DomainError('Duplicate original line in the same return',409);
      final originalLine=_originalLine(original,lineId);
      final qty=strictInt(x['qty_milli'],'qty_milli',min:1);
      if(qty>(originalLine['remaining'] as int)) throw DomainError('Returned quantity exceeds purchased quantity',409);
      final origQty=originalLine['qty_milli'] as int;
      final previouslyReturned=origQty-(originalLine['remaining'] as int);
      final originalNet=originalLine['cost_minor'] as int;
      final lineNet=prorate(originalNet,previouslyReturned+qty,origQty)-
        prorate(originalNet,previouslyReturned,origQty);
      final originalVat=originalLine['tax_minor'] as int;
      final lineVat=prorate(originalVat,previouslyReturned+qty,origQty)-
        prorate(originalVat,previouslyReturned,origQty);
      final removed=_stock(p,branch,warehouse,originalLine['product_id'] as String,-qty,0,'purchase_return',docId);
      lines.add({'original_line_id':lineId,'product_id':originalLine['product_id'],
        'qty':qty,'net':lineNet,'tax':lineVat,'cost':removed});
      net+=lineNet;tax+=lineVat;stockCost+=removed;
    }
    final total=net+tax;
    if(total<=0) throw DomainError('Empty supplier credit');
    final doc=_documentWithId(docId,p,branch,warehouse,'purchase_return',supplier,net,0,tax,total,refundMethod=='cash'?total:0,stockCost,
      {'original_id':original,'lines':lines,'refund_method':refundMethod},original:original);
    for(final line in lines) {
      _line(doc,line['product_id'] as String,line['qty'] as int,0,0,line['tax'] as int,line['cost'] as int,
        originalLine:line['original_line_id'] as String);
    }
    if(refundMethod=='cash') {
      _savePayments(doc,branch,supplier,'in',[{'method':'cash','amount_minor':total}]);
    }
    final variance=net-stockCost;
    _post(p,branch,'purchase_return',doc,[
      LedgerLine('AP:$supplier',debit:total),LedgerLine('INVENTORY',credit:stockCost),
      LedgerLine('VAT_INPUT',credit:tax),
      if(refundMethod=='cash') LedgerLine('CASH',debit:total),
      if(refundMethod=='cash') LedgerLine('AP:$supplier',credit:total),
      if(variance>0) LedgerLine('PURCHASE_VARIANCE',credit:variance),
      if(variance<0) LedgerLine('PURCHASE_VARIANCE',debit:-variance)
    ]);
    _audit(p,'purchase.return',doc,{'original':original,'total_minor':total},branch);
    _outbox(branch,'purchase_return',{'id':doc,'original':original});
    return {'id':doc,'supplier_credit_minor':refundMethod=='cash'?0:total,
      'cash_refund_minor':refundMethod=='cash'?total:0,'cost_variance_minor':variance};
  }
  String _documentWithId(String id,Principal p,String branch,String warehouse,String kind,String? party,
    int subtotal,int discount,int tax,int total,int paid,int cost,Map<String,dynamic> snapshot,{String? original}) {
    store.exec('''INSERT INTO documents(id,tenant_id,branch_id,warehouse_id,kind,number,party_id,original_id,
      subtotal_minor,discount_minor,tax_minor,total_minor,paid_minor,cost_minor,snapshot_json,created_by,created_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [id,p.tenantId,branch,warehouse,kind,_sequence(branch,kind),party,original,subtotal,discount,tax,total,paid,cost,
       jsonEncode(snapshot),p.id,_now()]);
    return id;
  }

  /// Query methods: SQL always binds tenant and branch scope; no raw user SQL.
  List<Map<String,Object?>> listUsers(Principal p) {
    _allow(p,['owner']);
    return store.rows('SELECT id,username,role,branch_id,active,created_at FROM users WHERE tenant_id=? ORDER BY username',
      [p.tenantId]);
  }

  List<Map<String,Object?>> listProductUnits(Principal p,String productId) {
    _product(p,productId);
    return store.rows('''SELECT id,product_id,unit_name,factor_milli,sell_price_minor,barcode
      FROM product_units WHERE product_id=? AND active=1 ORDER BY factor_milli''',[productId]);
  }

  List<Map<String,Object?>> listProducts(Principal p,{String search='',int limit=100}) => store.rows('''
    SELECT p.id,p.sku,p.barcode,p.name_ar,p.name_en,p.category,p.base_unit,p.sell_price_minor,
           p.reorder_qty_milli,p.tax_rate_bp,p.track_expiry,p.active
    FROM products p WHERE p.tenant_id=? AND p.active=1
    AND (p.name_ar LIKE ? OR p.sku LIKE ? OR p.barcode LIKE ?)
    ORDER BY p.name_ar LIMIT ?''',[p.tenantId,'%$search%','%$search%','%$search%',limit.clamp(1,200)]);

  List<Map<String,Object?>> listParties(Principal p,{required bool customers}) {
    if (!customers) _allow(p,['owner','manager','purchasing']);
    final result=store.rows('SELECT * FROM ${customers?'customers':'suppliers'} WHERE tenant_id=? ORDER BY name LIMIT 500',[p.tenantId]);
    return result.map((r) => {...r,
      if(p.role=='owner' || p.role=='manager') 'balance_minor':
        _accountBalance('${customers?'AR':'AP'}:${r['id']}')*(customers?1:-1)}).toList();
  }

  List<Map<String,Object?>> listWarehouses(Principal p,String branchId) {
    final branch=_branch(p,branchId);
    return store.rows('SELECT id,branch_id,name,is_default FROM warehouses WHERE branch_id=? ORDER BY is_default DESC,name',
      [branch]);
  }

  List<Map<String,Object?>> listBranches(Principal p) => store.rows(
    p.isOwner?'SELECT * FROM branches WHERE tenant_id=? ORDER BY code':'SELECT * FROM branches WHERE tenant_id=? AND id=?',
    p.isOwner?[p.tenantId]:[p.tenantId,p.branchId]);

  List<Map<String,Object?>> listStock(Principal p,String branchId) {
    final branch=_branch(p,branchId);
    final result=store.rows('''SELECT s.product_id,p.name_ar,p.sku,p.barcode,p.base_unit,p.sell_price_minor,
      s.warehouse_id,s.qty_milli,s.cost_minor,p.reorder_qty_milli
      FROM stock_balances s JOIN products p ON p.id=s.product_id
      WHERE s.branch_id=? AND p.tenant_id=? ORDER BY p.name_ar''',[branch,p.tenantId]);
    if(p.role=='cashier' || p.role=='viewer') {
      for(final row in result) {row.remove('cost_minor');}
    }
    return result;
  }

  List<Map<String,Object?>> listDocuments(Principal p,String branchId,{int limit=100}) {
    final branch=_branch(p,branchId);
    final result=store.rows('''SELECT id,kind,number,party_id,subtotal_minor,discount_minor,tax_minor,
      total_minor,paid_minor,cost_minor,state,created_at
      FROM documents WHERE tenant_id=? AND branch_id=? ORDER BY created_at DESC LIMIT ?''',
      [p.tenantId,branch,limit.clamp(1,200)]);
    if(p.role=='cashier' || p.role=='viewer') result.removeWhere((r)=>r['kind']!='sale' && r['kind']!='sale_return');
    if(p.role=='cashier' || p.role=='viewer') {
      for(final row in result) {row.remove('cost_minor');}
    }
    return result;
  }
  Map<String,Object?> readDocument(Principal p,String doc) {
    final d=store.first('SELECT * FROM documents WHERE id=? AND tenant_id=?',[doc,p.tenantId]);
    if(d==null) throw DomainError('Document not found',404);
    _branch(p,d['branch_id']);
    if((p.role=='cashier' || p.role=='viewer') && d['kind']!='sale' && d['kind']!='sale_return') throw DomainError('Permission denied',403);
    final lines=store.rows('''SELECT l.*, p.name_ar FROM document_lines l
      JOIN products p ON p.id=l.product_id WHERE l.document_id=?''',[doc]);
    if(p.role=='cashier' || p.role=='viewer') {
      d.remove('cost_minor');
      for(final line in lines){line.remove('cost_minor');}
    }
    return {...d,'lines':lines,
      'payments':store.rows('SELECT * FROM payments WHERE document_id=?',[doc])};
  }
  Map<String,Object?> dashboard(Principal p,String branchId) {
    _allow(p,['owner','manager']);
    final branch=_branch(p,branchId);
    int total(String where,List<Object?> args) => (store.first(where,args)!['n'] as int);
    final sales=total('''SELECT COALESCE(SUM(total_minor),0) n FROM documents
      WHERE branch_id=? AND kind='sale' AND state='posted' ''',[branch]);
    final returns=total('''SELECT COALESCE(SUM(total_minor),0) n FROM documents
      WHERE branch_id=? AND kind='sale_return' AND state='posted' ''',[branch]);
    final cogs=total('''SELECT COALESCE(SUM(CASE WHEN kind='sale' THEN cost_minor WHEN kind='sale_return' THEN -cost_minor ELSE 0 END),0) n
      FROM documents WHERE branch_id=? AND state='posted' ''',[branch]);
    final expenses=total('SELECT COALESCE(SUM(amount_minor),0) n FROM expenses WHERE branch_id=?',[branch]);
    final stock=total('SELECT COALESCE(SUM(cost_minor),0) n FROM stock_balances WHERE branch_id=?',[branch]);
    final cash=total('''SELECT COALESCE(SUM(l.debit_minor-l.credit_minor),0) n
      FROM journal_lines l JOIN journal_entries e ON e.id=l.entry_id
      WHERE e.branch_id=? AND l.account='CASH' ''',[branch]);
    final creditCustomers=total('''SELECT COALESCE(SUM(l.debit_minor-l.credit_minor),0) n
      FROM journal_lines l JOIN journal_entries e ON e.id=l.entry_id
      WHERE e.branch_id=? AND l.account LIKE 'AR:%' ''',[branch]);
    final supplierPayable=total('''SELECT COALESCE(SUM(l.credit_minor-l.debit_minor),0) n
      FROM journal_lines l JOIN journal_entries e ON e.id=l.entry_id
      WHERE e.branch_id=? AND l.account LIKE 'AP:%' ''',[branch]);
    return {'branch_id':branch,'sales_minor':sales-returns,'cost_of_goods_minor':cogs,
      'gross_profit_minor':sales-returns-cogs,'expenses_minor':expenses,
      'estimated_operating_profit_minor':sales-returns-cogs-expenses,
      'stock_value_minor':stock,'cash_minor':cash,'customer_receivables_minor':creditCustomers,
      'supplier_payables_minor':supplierPayable,
      'pending_sync':total('SELECT COUNT(*) n FROM sync_outbox WHERE branch_id=? AND synced_at IS NULL',[branch])};
  }
  List<Map<String,Object?>> audit(Principal p,String branchId) {
    _allow(p,['owner','manager']);
    final branch=_branch(p,branchId);
    return store.rows('SELECT * FROM audit_logs WHERE branch_id=? ORDER BY created_at DESC LIMIT 100',[branch]);
  }
  List<Map<String,Object?>> outbox(Principal p,String branchId) {
    _allow(p,['owner']);
    final branch=_branch(p,branchId);
    return store.rows('SELECT * FROM sync_outbox WHERE branch_id=? AND synced_at IS NULL ORDER BY created_at LIMIT 100',[branch]);
  }
}
