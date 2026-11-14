import 'package:flutter/material.dart';
import '../models/formats.dart';
import '../services/api.dart';
import '../widgets/common.dart';

/// Warehouse movements within one local branch host, not cross-branch sync.
class WarehousesPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  final String role;
  const WarehousesPage({super.key,required this.api,required this.branchId,required this.role});
  @override State<WarehousesPage> createState()=>_WarehousesPageState();
}

class _WarehousesPageState extends State<WarehousesPage> {
  late Future<List<Map<String,dynamic>>> warehouses;
  late Future<List<Map<String,dynamic>>> balances;
  late Future<List<Map<String,dynamic>>> products;
  bool busy=false;
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(() {
    warehouses=widget.api.list('warehouses',{'branch_id':widget.branchId});
    balances=widget.api.list('stock',{'branch_id':widget.branchId});
    products=widget.api.list('products');
  });

  Future<void> _createWarehouse() async {
    final controller=TextEditingController();
    try {
      final name=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('إنشاء مخزن جديد داخل الفرع'),
        content:TextField(controller:controller,autofocus:true,
          decoration:const InputDecoration(labelText:'اسم المخزن')),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,controller.text.trim()),child:const Text('إنشاء')),
        ],
      ));
      if(name==null || name.isEmpty)return;
      setState(()=>busy=true);
      await widget.api.post('warehouses',{'branch_id':widget.branchId,'name':name});
      if(mounted){alert(context,'تم إنشاء المخزن');_reload();}
    } catch(e) {if(mounted)alert(context,'تعذر إنشاء المخزن: $e',error:true);}
    finally {controller.dispose();if(mounted)setState(()=>busy=false);}
  }

  Future<void> _transfer(List<Map<String,dynamic>> warehouses) async {
    if(warehouses.length<2){alert(context,'أنشئ مخزنًا ثانيًا أولًا',error:true);return;}
    final availableProducts=await products;
    if(!mounted)return;
    if(availableProducts.isEmpty){alert(context,'أضف أصنافًا أولًا',error:true);return;}
    final amount=TextEditingController();
    String? source=warehouses.first['id'].toString();
    String? destination=warehouses[1]['id'].toString();
    String? product=availableProducts.first['id'].toString();
    try {
      final data=await showDialog<Map<String,dynamic>>(context:context,
        builder:(ctx)=>StatefulBuilder(builder:(ctx,update)=>AlertDialog(
          title:const Text('تحويل مخزون بين مخزنين'),
          content:SizedBox(width:480,child:Column(mainAxisSize:MainAxisSize.min,children:[
            DropdownButtonFormField<String>(initialValue:source,isExpanded:true,
              decoration:const InputDecoration(labelText:'المخزن المصدر'),
              items:warehouses.map((w)=>DropdownMenuItem<String>(value:w['id'].toString(),
                child:Text(w['name'].toString()))).toList(),
              onChanged:(v)=>update(()=>source=v)),
            const SizedBox(height:12),
            DropdownButtonFormField<String>(initialValue:destination,isExpanded:true,
              decoration:const InputDecoration(labelText:'المخزن المستلم'),
              items:warehouses.map((w)=>DropdownMenuItem<String>(value:w['id'].toString(),
                child:Text(w['name'].toString()))).toList(),
              onChanged:(v)=>update(()=>destination=v)),
            const SizedBox(height:12),
            DropdownButtonFormField<String>(initialValue:product,isExpanded:true,
              decoration:const InputDecoration(labelText:'الصنف'),
              items:availableProducts.map((p)=>DropdownMenuItem<String>(value:p['id'].toString(),
                child:Text(p['name_ar'].toString()))).toList(),
              onChanged:(v)=>update(()=>product=v)),
            const SizedBox(height:12),
            TextField(controller:amount,keyboardType:TextInputType.number,
              decoration:const InputDecoration(labelText:'الكمية بوحدة الصنف الأساسية')),
            const SizedBox(height:8),
            const Text('لا يمكن إتمام تحويل كمية غير متاحة في المخزن المصدر.',
              style:TextStyle(fontSize:12)),
          ])),actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
            FilledButton(onPressed:(){
              try {
                final qty=parseQty(amount.text);
                if(qty<=0 || source==destination || source==null || destination==null || product==null){
                  alert(ctx,'تحقق من المخازن والكمية',error:true);return;
                }
                Navigator.pop(ctx,{
                  'branch_id':widget.branchId,'source_warehouse_id':source,
                  'destination_warehouse_id':destination,'product_id':product,'qty_milli':qty,
                });
              }catch(_){alert(ctx,'كمية غير صالحة',error:true);}
            },child:const Text('اعتماد التحويل')),
          ],
        )));
      if(data==null)return;
      setState(()=>busy=true);
      await widget.api.post('inventory/transfers',data);
      if(mounted){alert(context,'تم تحويل الكمية وتحديث المخزنين');_reload();}
    }catch(e){if(mounted)alert(context,'فشل التحويل: $e',error:true);}
    finally {amount.dispose();if(mounted)setState(()=>busy=false);}
  }

  @override Widget build(BuildContext context)=>Column(children:[
    SectionTitle('المخازن الداخلية',
      subtitle:'تحويلات ذرية بين مخازن الفرع. تحويلات الفروع المنفصلة تحتاج مزامنة مستقلة.',
      action:widget.role=='owner' || widget.role=='manager'
        ?FilledButton.icon(onPressed:busy?null:_createWarehouse,icon:const Icon(Icons.add),label:const Text('مخزن جديد')):null),
    Expanded(child:AsyncPanel<List<Map<String,dynamic>>>(future:warehouses,onRetry:_reload,builder:(list)=>
      AsyncPanel<List<Map<String,dynamic>>>(future:balances,onRetry:_reload,builder:(items)=>ListView(children:[
        if(list.length>=2) Align(alignment:AlignmentDirectional.centerStart,
          child:FilledButton.icon(onPressed:busy?null:()=>_transfer(list),
            icon:const Icon(Icons.swap_horiz),label:const Text('تحويل مخزون'))),
        const SizedBox(height:14),
        for(final wh in list) Card(child:ExpansionTile(
          leading:Icon(wh['is_default']==1?Icons.store:Icons.warehouse),
          title:Text(wh['name'].toString()),
          subtitle:Text(wh['is_default']==1?'مخزن الفرع الأساسي':'مخزن إضافي'),
          children:[
            for(final item in items.where((s)=>s['warehouse_id']==wh['id']))
              ListTile(title:Text(item['name_ar'].toString()),
                subtitle:Text('SKU: ${item['sku']}'),
                trailing:Text('الكمية: ${quantity(asInt(item['qty_milli']))}')),
            if(items.every((s)=>s['warehouse_id']!=wh['id']))
              const ListTile(title:Text('لا توجد أصناف في هذا المخزن')),
          ],
        )),
        if(list.isEmpty)const EmptyState('لا توجد مخازن للفرع'),
      ])))),
  ]);
}
