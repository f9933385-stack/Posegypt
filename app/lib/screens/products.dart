import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class ProductsPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const ProductsPage({super.key,required this.api,required this.branchId});
  @override State<ProductsPage> createState()=>_ProductsState();
}
class _ProductsState extends State<ProductsPage> {
  late Future<List<Map<String,dynamic>>> products,stock;
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(() {
    products=widget.api.list('products');stock=widget.api.list('stock',{'branch_id':widget.branchId});
  });
  Future<void> _createProduct() async {
    final sku=TextEditingController(),barcode=TextEditingController(),name=TextEditingController(),
      price=TextEditingController(),unit=TextEditingController(text:'قطعة'),reorder=TextEditingController(text:'0');
    final result=await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('إضافة صنف جديد'),content:SizedBox(width:480,child:SingleChildScrollView(child:Column(
        mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:name,decoration:const InputDecoration(labelText:'اسم الصنف بالعربية')),
          const SizedBox(height:10),TextField(controller:sku,decoration:const InputDecoration(labelText:'SKU')),
          const SizedBox(height:10),TextField(controller:barcode,decoration:const InputDecoration(labelText:'الباركود (اختياري)')),
          const SizedBox(height:10),TextField(controller:price,keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'سعر البيع بالجنيه')),
          const SizedBox(height:10),TextField(controller:unit,decoration:const InputDecoration(labelText:'وحدة الأساس')),
          const SizedBox(height:10),TextField(controller:reorder,keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'حد إعادة الطلب')),
        ]))),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
        FilledButton(onPressed:(){try {Navigator.pop(ctx,{'sku':sku.text,'barcode':barcode.text,
          'name_ar':name.text,'base_unit':unit.text,'sell_price_minor':parseMoney(price.text),
          'reorder_qty_milli':parseQty(reorder.text)});}catch(_){alert(ctx,'تأكد من صحة السعر والكمية',error:true);}},
          child:const Text('إضافة'))]));
    for(final c in [sku,barcode,name,price,unit,reorder]){c.dispose();}
    if(result==null)return;
    try {await widget.api.post('products',result);if(mounted){alert(context,'تمت إضافة الصنف');_reload();}}
    catch(e){if(mounted)alert(context,'تعذر الإضافة: $e',error:true);}
  }
  Future<void> _createUnit(Map<String,dynamic> product) async {
    final name=TextEditingController(),factor=TextEditingController(text:'12'),
      price=TextEditingController(),barcode=TextEditingController();
    final input=await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>AlertDialog(
      title:Text('إضافة وحدة بيع: '+product['name_ar'].toString()),
      content:SizedBox(width:460,child:SingleChildScrollView(child:Column(
        mainAxisSize:MainAxisSize.min,children:[
          const Text('مثال: كرتونة = 12 قطعة. المخزون يبقى بوحدة الأساس، وسعر الكرتونة مستقل.'),
          const SizedBox(height:12),
          TextField(controller:name,decoration:const InputDecoration(labelText:'اسم الوحدة (كرتونة/علبة)')),
          const SizedBox(height:10),
          TextField(controller:factor,keyboardType:TextInputType.number,
            decoration:InputDecoration(labelText:'كم '+product['base_unit'].toString()+' داخل الوحدة؟')),
          const SizedBox(height:10),
          TextField(controller:price,keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'سعر بيع الوحدة بالجنيه')),
          const SizedBox(height:10),
          TextField(controller:barcode,decoration:const InputDecoration(labelText:'باركود الوحدة (اختياري)')),
        ]))),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
        FilledButton(onPressed:(){
          try {
            final multiplier=parseQty(factor.text);
            if(multiplier<=0 || name.text.trim().isEmpty)throw const FormatException('Invalid unit');
            Navigator.pop(ctx,{'product_id':product['id'],'unit_name':name.text.trim(),
              'factor_milli':multiplier,'sell_price_minor':parseMoney(price.text),
              'barcode':barcode.text.trim()});
          }catch(_){alert(ctx,'تأكد من اسم الوحدة ومعامل التحويل وسعرها',error:true);}
        },child:const Text('إضافة')),
      ],
    ));
    for(final c in [name,factor,price,barcode]){c.dispose();}
    if(input==null)return;
    try {
      await widget.api.post('units',input);
      if(mounted) alert(context,'تم إضافة وحدة البيع بنجاح');
    }catch(e){if(mounted)alert(context,'تعذر إضافة الوحدة: $e',error:true);}
  }

  Future<void> _adjust(Map<String,dynamic> product) async {
    final qty=TextEditingController(),cost=TextEditingController(text:'0'),reason=TextEditingController();
    final result=await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>AlertDialog(
      title:Text('تسوية مخزون: ${product['name_ar']}'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        const Text('للزيادة أدخل كمية موجبة وتكلفتها؛ وللنقص أدخل كمية سالبة.'),
        const SizedBox(height:10),TextField(controller:qty,decoration:const InputDecoration(labelText:'التغير في الكمية (+ أو -)')),
        const SizedBox(height:10),TextField(controller:cost,decoration:const InputDecoration(labelText:'تكلفة الكمية المضافة بالجنيه')),
        const SizedBox(height:10),TextField(controller:reason,decoration:const InputDecoration(labelText:'سبب التسوية')),
      ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
        FilledButton(onPressed:(){try {
          final q=qty.text.startsWith('-')?-parseQty(qty.text.substring(1)):parseQty(qty.text);
          Navigator.pop(ctx,{'product_id':product['id'],'branch_id':widget.branchId,
            'qty_change_milli':q,'added_cost_minor':parseMoney(cost.text),'reason':reason.text});
        }catch(_){alert(ctx,'قيم غير صالحة',error:true);}},child:const Text('اعتماد'))]));
    for(final c in [qty,cost,reason]){c.dispose();}
    if(result==null)return;
    try {await widget.api.post('inventory/adjustments',result);if(mounted){alert(context,'تم تحديث المخزون');_reload();}}
    catch(e){if(mounted)alert(context,'فشلت التسوية: $e',error:true);}
  }
  @override Widget build(BuildContext context)=>Column(children:[
    SectionTitle('الأصناف والمخزون',subtitle:'الأصناف الحقيقية في قاعدة البيانات وحركات المخزون المعتمدة.',
      action:FilledButton.icon(onPressed:_createProduct,icon:const Icon(Icons.add),label:const Text('صنف جديد'))),
    Expanded(child:AsyncPanel<List<Map<String,dynamic>>>(future:products,onRetry:_reload,
      builder:(list)=>AsyncPanel<List<Map<String,dynamic>>>(future:stock,onRetry:_reload,builder:(balances){
        if(list.isEmpty)return const EmptyState('ابدأ بإضافة المنتجات، ثم سجّل المشتريات لإدخال مخزونها.');
        return ListView.builder(itemCount:list.length,itemBuilder:(context,i){final p=list[i];
          final available=balances.where((b)=>b['product_id']==p['id']).fold<int>(0,(sum,b)=>sum+asInt(b['qty_milli']));
          final low=available<asInt(p['reorder_qty_milli']);
          return Card(child:ListTile(leading:CircleAvatar(child:Icon(low?Icons.warning_amber:Icons.inventory_2_outlined)),
            title:Text(p['name_ar'].toString()),subtitle:Text('${p['sku']} • ${p['base_unit']} • رصيد ${quantity(available)}'),
            trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(money(asInt(p['sell_price_minor']))),
              IconButton(onPressed:()=>_createUnit(p),tooltip:'إضافة وحدة بيع (كرتونة/علبة)',
                icon:const Icon(Icons.all_inbox_outlined)),
              IconButton(onPressed:()=>_adjust(p),tooltip:'تسوية المخزون',icon:const Icon(Icons.tune))])));});
      }))),
  ]);
}
