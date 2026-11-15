/// Immutable projection of an already-posted sale; no client-side
/// recomputation of authoritative prices is used to generate receipt amounts.
class SaleReceipt {
  final String id,number,storeName,branchName,cashierName,createdAt,notice;
  final int subtotalMinor,discountMinor,taxMinor,totalMinor,paidMinor,dueMinor;
  final List<ReceiptLine> lines;
  final List<ReceiptPayment> payments;
  const SaleReceipt._({
    required this.id,required this.number,required this.storeName,
    required this.branchName,required this.cashierName,required this.createdAt,
    required this.notice,required this.subtotalMinor,required this.discountMinor,
    required this.taxMinor,required this.totalMinor,required this.paidMinor,
    required this.dueMinor,required this.lines,required this.payments,
  });

  factory SaleReceipt.fromJson(Map<String,dynamic> source) {
    String str(String key,{int max=200}) {
      final x=source[key];
      if(x is! String || x.trim().isEmpty || x.length>max) {
        throw FormatException('بيانات الإيصال غير صالحة: $key');
      }
      return x.trim().replaceAll(RegExp(r'[\x00-\x1f]'),' ');
    }
    int amount(String key) => minorInt(source[key],key);
    if(source['kind']!='sale' || source['currency']!='EGP') {
      throw const FormatException('هذا المستند ليس إيصال بيع بالجنيه المصري');
    }
    final raw=source['lines'];
    if(raw is! List || raw.isEmpty || raw.length>250) {
      throw const FormatException('بيانات بنود الإيصال غير مكتملة');
    }
    final lines=raw.map((item)=>ReceiptLine.fromJson(
      Map<String,dynamic>.from(item as Map))).toList(growable:false);
    final rawPayments=source['payments'];
    if(rawPayments is! List || rawPayments.length>50) {
      throw const FormatException('مدفوعات الإيصال غير صالحة');
    }
    final payments=rawPayments.map((p)=>ReceiptPayment.fromJson(
      Map<String,dynamic>.from(p as Map))).toList(growable:false);
    final gross=lines.fold<int>(0,(v,item)=>v+item.grossMinor);
    final discount=lines.fold<int>(0,(v,item)=>v+item.discountMinor);
    final tax=lines.fold<int>(0,(v,item)=>v+item.taxMinor);
    final paid=payments.fold<int>(0,(v,item)=>v+item.amountMinor);
    final total=amount('total_minor');
    final due=amount('due_minor');
    if(gross!=amount('subtotal_minor') ||
       discount!=amount('discount_minor') ||
       tax!=amount('tax_minor') ||
       gross-discount+tax!=total ||
       paid!=amount('paid_minor') ||
       total-paid!=due) {
      throw const FormatException('إجمالي الإيصال غير متطابق؛ الطباعة موقوفة');
    }
    return SaleReceipt._(
      id:str('document_id',max:128),
      number:str('number',max:128),
      storeName:str('store_name'),
      branchName:str('branch_name'),
      cashierName:str('cashier_name'),
      createdAt:str('created_at',max:80),
      notice:str('notice_ar',max:260),
      subtotalMinor:gross,discountMinor:discount,taxMinor:tax,
      totalMinor:total,paidMinor:paid,dueMinor:due,
      lines:List.unmodifiable(lines),payments:List.unmodifiable(payments),
    );
  }
}

int minorInt(Object? raw,String label) {
  if(raw is! int || raw<0 || raw>1000000000000000) {
    throw FormatException('قيمة غير صالحة في الإيصال: $label');
  }
  return raw;
}

class ReceiptLine {
  final String name,sku,unitName;
  final int qtyMilli,priceMinor,grossMinor,discountMinor,taxMinor,totalMinor;
  final int? unitCount;
  const ReceiptLine._({
    required this.name,required this.sku,required this.unitName,
    required this.qtyMilli,required this.priceMinor,required this.grossMinor,
    required this.discountMinor,required this.taxMinor,required this.totalMinor,
    required this.unitCount,
  });
  factory ReceiptLine.fromJson(Map<String,dynamic> data) {
    final quantity=minorInt(data['qty_milli'],'qty_milli');
    final gross=minorInt(data['gross_minor'],'gross_minor');
    final discount=minorInt(data['discount_minor'],'discount_minor');
    final vat=minorInt(data['tax_minor'],'tax_minor');
    final total=minorInt(data['total_minor'],'line_total_minor');
    final price=minorInt(data['unit_price_minor'],'unit_price_minor');
    final count=data['unit_count'];
    if(quantity<=0 || discount>gross || total!=gross-discount+vat ||
       (count!=null && (count is! int || count<=0))) {
      throw const FormatException('إجمالي أو كمية بند الإيصال غير صالح');
    }
    String read(String name){
      final x=data[name];
      if(x is! String || x.isEmpty || x.length>200) {
        throw FormatException('اسم بند غير صالح: $name');
      }
      return x.replaceAll(RegExp(r'[\x00-\x1f]'),' ');
    }
    return ReceiptLine._(name:read('name_ar'),sku:read('sku'),
      unitName:read('unit_name'),qtyMilli:quantity,priceMinor:price,
      grossMinor:gross,discountMinor:discount,taxMinor:vat,
      totalMinor:total,unitCount:count as int?);
  }
}

class ReceiptPayment {
  final String method;
  final int amountMinor;
  const ReceiptPayment._(this.method,this.amountMinor);
  factory ReceiptPayment.fromJson(Map<String,dynamic> data) {
    const allowed=['cash','card','wallet','bank'];
    final method=data['method'];
    final amount=minorInt(data['amount_minor'],'payment');
    if(method is! String || !allowed.contains(method) || amount<=0) {
      throw const FormatException('طريقة سداد غير معتمدة');
    }
    return ReceiptPayment._(method,amount);
  }
}
