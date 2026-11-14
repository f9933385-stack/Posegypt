import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class PreparationPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const PreparationPage({super.key,required this.api,required this.branchId});
  @override State<PreparationPage> createState()=>_PreparationState();
}
class _PreparationState extends State<PreparationPage> {
  late Future<List<Map<String,dynamic>>> products;
  String? raw,output;
  final incoming=TextEditingController(),outgoing=TextEditingController();
  bool posting=false;
  @override void initState(){super.initState();products=widget.api.list('products');}
  @override void dispose(){incoming.dispose();outgoing.dispose();super.dispose();}
  Future<void> _create() async {
    if(raw==null||output==null){alert(context,'اختر الخام والمنتج النهائي',error:true);return;}
    setState(()=>posting=true);
    try {
      final result=await widget.api.post('inventory/preparations',{
        'branch_id':widget.branchId,'source_product_id':raw,'output_product_id':output,
        'input_qty_milli':parseQty(incoming.text),'output_qty_milli':parseQty(outgoing.text)});
      if(!mounted)return;
      alert(context,'تم اعتماد التجهيز. تكلفة المادة الخام: ${money(asInt(result['allocated_cost_minor']))}');
      incoming.clear();outgoing.clear();
    }catch(e){alert(context,'فشل التجهيز: $e',error:true);}
    finally{if(mounted)setState(()=>posting=false);}
  }
  @override Widget build(BuildContext context)=>SingleChildScrollView(child:Column(
    crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const SectionTitle('تجهيز وتقسيم المنتجات',
        subtitle:'خصم الخام وإضافة الناتج بنفس تكلفة الخام وبمعاملة ذرية واحدة.'),
      AsyncPanel<List<Map<String,dynamic>>>(future:products,
        onRetry:()=>setState(()=>products=widget.api.list('products')),
        builder:(items)=>Column(children:[
          DropdownButtonFormField<String>(value:raw,decoration:const InputDecoration(labelText:'المادة الخام'),
            items:items.map((x)=>DropdownMenuItem<String>(value:x['id'].toString(),
              child:Text(x['name_ar'].toString()))).toList(),
            onChanged:(v)=>setState(()=>raw=v)),
          const SizedBox(height:12),DropdownButtonFormField<String>(value:output,
            decoration:const InputDecoration(labelText:'المنتج المجهز'),
            items:items.map((x)=>DropdownMenuItem<String>(value:x['id'].toString(),
              child:Text(x['name_ar'].toString()))).toList(),
            onChanged:(v)=>setState(()=>output=v)),
        ])),
      const SizedBox(height:12),TextField(controller:incoming,decoration:const InputDecoration(
        labelText:'كمية الخام المصروفة (وحدة الأساس، حتى 3 منازل)')),
      const SizedBox(height:12),TextField(controller:outgoing,decoration:const InputDecoration(
        labelText:'كمية المنتج الناتج (وحدة الأساس، حتى 3 منازل)')),
      const SizedBox(height:12),const Text('يلزم توحيد المقاييس قبل احتساب الفاقد بالكميات. لا تُضاف تكلفة العمالة والعبوات تلقائيًا هنا.'),
      const SizedBox(height:20),FilledButton.icon(onPressed:posting?null:_create,
        icon:const Icon(Icons.check_circle_outline),label:const Text('اعتماد عملية التجهيز')),
    ]));
}
