import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/lan_escpos_printer.dart';

import '../models/sale_receipt.dart';
import '../services/api.dart';
import '../widgets/common.dart';

/// Arabic text is rasterized by Flutter before PDF printing to avoid
/// hardware-specific ESC/POS Arabic codepage incompatibilities.
class ReceiptPaper extends StatelessWidget {
  final SaleReceipt receipt;
  const ReceiptPaper({super.key,required this.receipt});
  String amount(int value)=>(value~/100).toString()+'.'+
    (value%100).toString().padLeft(2,'0')+' ج.م';
  String qty(int milli) {
    if(milli%1000==0)return (milli~/1000).toString();
    final frac=(milli%1000).toString().padLeft(3,'0')
      .replaceFirst(RegExp(r'0+$'),'');
    return (milli~/1000).toString()+'.'+frac;
  }
  String paymentName(String method) => switch(method) {
    'cash'=>'نقدي','card'=>'بطاقة','wallet'=>'محفظة',
    'bank'=>'تحويل',_=>'غير معروف'
  };

  @override Widget build(BuildContext context) {
    const style=TextStyle(fontSize:12,color:Colors.black,height:1.45);
    Widget pair(String label,String value,{bool strong=false})=>Padding(
      padding:const EdgeInsets.symmetric(vertical:2),
      child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Expanded(child:Text(label,style:style.copyWith(
          fontWeight:strong?FontWeight.bold:FontWeight.normal))),
        Text(value,style:style.copyWith(
          fontWeight:strong?FontWeight.bold:FontWeight.normal)),
      ]),
    );
    return Directionality(textDirection:TextDirection.rtl,
      child:Container(width:302,padding:const EdgeInsets.all(12),
        color:Colors.white,child:DefaultTextStyle(style:style,
          child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,
            mainAxisSize:MainAxisSize.min,children:[
            Text(receipt.storeName,textAlign:TextAlign.center,
              style:style.copyWith(fontSize:17,fontWeight:FontWeight.bold)),
            Text(receipt.branchName,textAlign:TextAlign.center),
            const SizedBox(height:8),
            Text('فاتورة بيع '+receipt.number,textAlign:TextAlign.center,
              style:style.copyWith(fontWeight:FontWeight.bold)),
            Text('التاريخ UTC: '+receipt.createdAt,textAlign:TextAlign.center,
              textDirection:TextDirection.ltr,style:style.copyWith(fontSize:10)),
            Text('الكاشير: '+receipt.cashierName,textAlign:TextAlign.center),
            const Divider(thickness:1,color:Colors.black),
            for(final item in receipt.lines)...[
              Text(item.name,style:style.copyWith(fontWeight:FontWeight.bold)),
              pair(
                item.unitCount==null
                  ?qty(item.qtyMilli)+' '+item.unitName+' × '+amount(item.priceMinor)
                  :item.unitCount.toString()+' '+item.unitName+' × '+amount(item.priceMinor),
                amount(item.totalMinor)),
              if(item.discountMinor>0)pair('خصم البند',amount(item.discountMinor)),
              if(item.taxMinor>0)pair('ضريبة البند',amount(item.taxMinor)),
              const Divider(height:12,color:Color(0xFFBBBBBB)),
            ],
            pair('المجموع قبل الخصم والضريبة',amount(receipt.subtotalMinor)),
            if(receipt.discountMinor>0)
              pair('الخصومات',amount(receipt.discountMinor)),
            pair('الضريبة',amount(receipt.taxMinor)),
            const Divider(thickness:1,color:Colors.black),
            pair('الإجمالي',amount(receipt.totalMinor),strong:true),
            for(final p in receipt.payments)
              pair('المدفوع — '+paymentName(p.method),amount(p.amountMinor)),
            if(receipt.dueMinor>0)
              pair('المتبقي على العميل',amount(receipt.dueMinor),strong:true),
            const Divider(thickness:1,color:Colors.black),
            const Text('شكرًا لتعاملكم معنا',textAlign:TextAlign.center),
            const SizedBox(height:8),
            Text(receipt.notice,textAlign:TextAlign.center,
              style:style.copyWith(fontSize:10,fontWeight:FontWeight.bold)),
            Text('نسخة مطبوعة من مستند بيع مسجل',textAlign:TextAlign.center,
              style:style.copyWith(fontSize:10)),
            const SizedBox(height:6),
          ]))),
    );
  }
}

class SaleReceiptDialog extends StatefulWidget {
  final SaleReceipt receipt;
  const SaleReceiptDialog({super.key,required this.receipt});
  @override State<SaleReceiptDialog> createState()=>_SaleReceiptDialogState();
}

class _SaleReceiptDialogState extends State<SaleReceiptDialog> {
  final _paper=GlobalKey();
  bool _printing=false;

  Future<void> _print() async {
    if(_printing)return;
    setState(()=>_printing=true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary=_paper.currentContext?.findRenderObject();
      if(boundary is! RenderRepaintBoundary) {
        throw const FormatException('تعذرت معاينة الإيصال قبل الطباعة');
      }
      if(boundary.size.height>4800 || boundary.size.height<100) {
        throw const FormatException('الإيصال طويل جدًا للطباعة في ورقة واحدة');
      }
      final image=await boundary.toImage(pixelRatio:2);
      try {
        final data=await image.toByteData(format:ui.ImageByteFormat.png);
        if(data==null) throw const FormatException('تعذر إنشاء صورة الإيصال');
        final bytes=data.buffer.asUint8List();
        const width=80*PdfPageFormat.mm;
        final height=width*boundary.size.height/boundary.size.width;
        final pageFormat=PdfPageFormat(width,height,marginAll:0);
        final pdf=pw.Document(compress:true);
        pdf.addPage(pw.Page(pageFormat:pageFormat,
          margin:pw.EdgeInsets.zero,
          build:(context)=>pw.Image(pw.MemoryImage(bytes),fit:pw.BoxFit.fill)));
        await Printing.layoutPdf(
          name:'Kasher-receipt-'+widget.receipt.number,
          format:pageFormat,
          onLayout:(_)=>pdf.save());
        // Print-dialog handoff does not prove physical printer output.
      } finally {
        image.dispose();
      }
    } catch(e) {
      if(mounted)alert(context,'تعذرت طباعة الإيصال: '+e.toString(),error:true);
    } finally {
      if(mounted)setState(()=>_printing=false);
    }
  }


  Future<void> _printLan() async {
    if(_printing)return;
    try {
      final prefs=await SharedPreferences.getInstance();
      if(!mounted)return;
      final address=TextEditingController(text:prefs.getString('escpos_host')??'');
      var dots=prefs.getInt('escpos_dots')??576;
      if(dots!=384 && dots!=576)dots=576;
      var cut=prefs.getBool('escpos_cut')??false;
      try {
        final choice=await showDialog<({String host,int dots,bool cut})>(
          context:context,builder:(ctx)=>StatefulBuilder(
          builder:(ctx,change)=>AlertDialog(
            title:const Text('الطابعة الحرارية على شبكة المتجر'),
            content:SizedBox(width:470,child:Column(
              mainAxisSize:MainAxisSize.min,children:[
              const Text('الطابعة لازم تدعم ESC/POS GS v 0 وتكون على LAN معزولة. لا يتم التأكد من خروج الورقة تلقائيًا.'),
              const SizedBox(height:12),
              TextField(controller:address,keyboardType:TextInputType.url,
                textDirection:TextDirection.ltr,
                decoration:const InputDecoration(
                  labelText:'IP الطابعة المحلية (TCP 9100)',
                  hintText:'192.168.1.50')),
              const SizedBox(height:12),
              DropdownButtonFormField<int>(
                value:dots,decoration:const InputDecoration(labelText:'عرض رأس الطباعة'),
                items:const [
                  DropdownMenuItem(value:576,child:Text('80 مم — 576 نقطة')),
                  DropdownMenuItem(value:384,child:Text('58 مم — 384 نقطة')),
                ],onChanged:(v){if(v!=null)change(()=>dots=v);}),
              CheckboxListTile(
                value:cut,dense:true,
                title:const Text('إرسال أمر قطع الورق (فقط لطابعة تدعمه)'),
                onChanged:(v)=>change(()=>cut=v??false)),
            ])),
            actions:[
              TextButton(onPressed:()=>Navigator.pop(ctx),
                child:const Text('إلغاء')),
              FilledButton(onPressed:(){
                try {
                  final host=LanEscPosPrinter.validateHost(address.text);
                  Navigator.pop(ctx,(host:host,dots:dots,cut:cut));
                } on FormatException catch(e) {
                  alert(ctx,e.message,error:true);
                }
              },child:const Text('إرسال للطابعة')),
            ],
          )));
        if(choice==null || !mounted)return;
        await prefs.setString('escpos_host',choice.host);
        await prefs.setInt('escpos_dots',choice.dots);
        await prefs.setBool('escpos_cut',choice.cut);
        if(!mounted)return;
        setState(()=>_printing=true);
        try {
          await WidgetsBinding.instance.endOfFrame;
          final boundary=_paper.currentContext?.findRenderObject();
          if(boundary is! RenderRepaintBoundary ||
              boundary.size.width<=0 || boundary.size.height<=0) {
            throw const FormatException('معاينة الإيصال غير جاهزة');
          }
          // Slight padding avoids an out-of-range width from pixel rounding.
          final pixelRatio=(choice.dots-2)/boundary.size.width;
          final image=await boundary.toImage(pixelRatio:pixelRatio);
          try {
            if(image.width>choice.dots ||
               image.height>LanEscPosPrinter.maxImageHeight ||
               image.height<=0) {
              throw const FormatException('الإيصال أطول من قدرة الطابعة في مهمة واحدة');
            }
            final bytes=await image.toByteData(
              format:ui.ImageByteFormat.rawRgba);
            if(bytes==null)throw const FormatException('تعذر استخراج بيانات صورة الإيصال');
            final raster=LanEscPosPrinter.encodeRaster(
              bytes.buffer.asUint8List(bytes.offsetInBytes,bytes.lengthInBytes),
              imageWidth:image.width,imageHeight:image.height,
              paperDots:choice.dots,cut:choice.cut);
            await LanEscPosPrinter.send(host:choice.host,rasterBytes:raster);
          }finally{image.dispose();}
          if(mounted) {
            alert(context,'تم إرسال الإيصال للطابعة. تأكد من خروج الورقة؛ الاتصال وحده لا يؤكد الطباعة.');
          }
        }catch(e){
          if(mounted)alert(context,'نتيجة الإرسال غير مؤكدة: $e. افحص الطابعة قبل إعادة الطباعة لتجنب نسختين.',error:true);
        }finally{
          if(mounted)setState(()=>_printing=false);
        }
      }finally{address.dispose();}
    }catch(e){
      if(mounted)alert(context,'إعداد الطابعة غير متاح: $e',error:true);
    }
  }

  @override Widget build(BuildContext context)=>AlertDialog(
    title:const Text('معاينة إيصال البيع — عرض 80 مم'),
    content:SizedBox(width:355,height:530,child:SingleChildScrollView(
      child:Center(child:RepaintBoundary(key:_paper,
        child:ReceiptPaper(receipt:widget.receipt))))),
    actions:[
      TextButton(onPressed:_printing?null:()=>Navigator.pop(context),
        child:const Text('إغلاق')),
      OutlinedButton.icon(onPressed:_printing?null:_printLan,
        icon:const Icon(Icons.receipt_long_outlined),
        label:const Text('طباعة حرارية LAN')),
      FilledButton.icon(onPressed:_printing?null:_print,
        icon:const Icon(Icons.print_outlined),
        label:Text(_printing?'جارٍ فتح الطابعة...':'طباعة / حفظ PDF')),
    ],
  );
}

Future<void> showSaleReceiptDialog(
    BuildContext context,ApiClient api,String documentId) async {
  final raw=await api.get('receipts/$documentId');
  final receipt=SaleReceipt.fromJson(raw);
  if(!context.mounted)return;
  await showDialog<void>(context:context,builder:(ctx)=>
    SaleReceiptDialog(receipt:receipt));
}
