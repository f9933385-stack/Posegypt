import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasher_app/models/sale_receipt.dart';
import 'package:kasher_app/screens/receipt_print.dart';

Map<String,dynamic> fixture()=>{
  'kind':'sale','currency':'EGP',
  'document_id':'sale-1','number':'SALE-0001',
  'store_name':'متجر القاهرة','branch_name':'فرع مدينة نصر',
  'cashier_name':'cashier','created_at':'2026-11-14T10:30:00Z',
  'subtotal_minor':1500,'discount_minor':0,'tax_minor':150,
  'total_minor':1650,'paid_minor':1250,'due_minor':400,
  'notice_ar':'مستند بيع داخلي — ليس إيصالًا ضريبيًا إلكترونيًا معتمدًا',
  'lines':[{
    'sku':'RICE-001','name_ar':'أرز مصري',
    'qty_milli':1500,'unit_name':'كيلو','unit_count':null,
    'unit_price_minor':1000,'gross_minor':1500,
    'discount_minor':0,'tax_minor':150,'total_minor':1650
  }],
  'payments':[{'method':'cash','amount_minor':1000},
    {'method':'card','amount_minor':250}]
};

void main() {
  test('receipt uses immutable server amounts and exact EGP minor units',() {
    final r=SaleReceipt.fromJson(fixture());
    expect(r.totalMinor,1650);
    expect(r.taxMinor,150);
    expect(r.paidMinor,1250);
    expect(r.dueMinor,400);
    expect(r.lines.single.name,'أرز مصري');
    expect(r.lines.single.qtyMilli,1500);
  });

  test('receipt rejects tampered server line, total, tax or payment sums',() {
    final base=fixture();
    final wrongTotal={...base,'total_minor':1651};
    expect(()=>SaleReceipt.fromJson(wrongTotal),throwsFormatException);
    final wrongTax={...base,'tax_minor':151};
    expect(()=>SaleReceipt.fromJson(wrongTax),throwsFormatException);
    final wrongPaid={...base,'paid_minor':1251};
    expect(()=>SaleReceipt.fromJson(wrongPaid),throwsFormatException);
    final badLine={...base,'lines':[
      {...(base['lines'] as List).first as Map,'total_minor':1651}
    ]};
    expect(()=>SaleReceipt.fromJson(badLine),throwsFormatException);
  });

  test('receipt rejects other document types, foreign currency and negative data',() {
    final base=fixture();
    expect(()=>SaleReceipt.fromJson({...base,'kind':'purchase'}),
      throwsFormatException);
    expect(()=>SaleReceipt.fromJson({...base,'currency':'USD'}),
      throwsFormatException);
    expect(()=>SaleReceipt.fromJson({...base,'due_minor':-1}),
      throwsFormatException);
    expect(()=>SaleReceipt.fromJson({...base,'lines':[]}),
      throwsFormatException);
    final invalidMethod={...base,'payments':[
      {'method':'unsupported','amount_minor':1250}
    ]};
    expect(()=>SaleReceipt.fromJson(invalidMethod),throwsFormatException);
  });

  testWidgets('Arabic receipt sheet shows separate tax, paid and outstanding',
      (tester) async {
    final receipt=SaleReceipt.fromJson(fixture());
    await tester.pumpWidget(MaterialApp(home:Scaffold(
      body:SingleChildScrollView(child:ReceiptPaper(receipt:receipt)))));
    expect(find.text('متجر القاهرة'),findsOneWidget);
    expect(find.text('فرع مدينة نصر'),findsOneWidget);
    expect(find.text('أرز مصري'),findsOneWidget);
    expect(find.text('الإجمالي'),findsOneWidget);
    expect(find.text('المتبقي على العميل'),findsOneWidget);
    expect(find.textContaining('ليس إيصالًا ضريبيًا إلكترونيًا معتمدًا'),
      findsOneWidget);
  });
}
