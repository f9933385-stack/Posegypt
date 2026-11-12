import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class DraftPurchase {
  final Map<String,dynamic> product;
  final TextEditingController qty=TextEditingController(text:'1');
  final TextEditingController cost=TextEditingController();
  DraftPurchase(this.product);
  void dispose(){qty.dispose();cost.dispose();}
}
class PurchasesPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const PurchasesPage({super.key,required this.api,required this.branchId});
  @override State<PurchasesPage> createState()=>_PurchasesState();
}
class _PurchasesState extends State<PurchasesPage> {
  late Future<List<Map<String,dynamic>>> suppliers,products;
  String? supplierId,selectedProduct;
  final payment=TextEditingController(text:'0');
  String method='cash';
  final lines=<DraftPurchase>[];
  bool posting=false;
  @override void initState(){super.initState();suppliers=widget.api.list('suppliers');products=widget.api.list('products');}
  @override void dispose(){for(final x in lines){x.dispose();}payment.dispose();super.dispose();}
  Future<void> _save() async {
    if(supplierId==null || lines.isEmpty) {alert(context,'اختر المورد والأصناف أولًا',error:true);return;}
    setState(()=>posting=true);
    try {
      final due=<Map<String,dynamic>>[];
      for(final item in lines){due.add({'product_id':item.product['id'],
        'qty_milli':parseQty(item.qty.text),'unit_cost_minor':parseMoney(item.cost.text)});}
      final value=parseMoney(payment.text);
      final saved=await widget.api.post('purchases',{'branch_id':widget.branchId,'supplier_id':supplierId,
        'lines':due,'payments':value>0?[{'method':method,'amount_minor':value}]:[]});
      if(!mounted)return;
      alert(context,'تم اعتماد شراء رقم ${saved['number']}، المتبقي ${money(asInt(saved['due_minor']))}');
      setState(() {for(final x in lines){x.dispose();}lines.clear();payment.text='0';});
    }catch(e){alert(context,'فشل اعتماد المشتريات: $e',error:true);}
    finally{if(mounted)setState(()=>posting=false);}
  }
  @override Widget build(BuildContext context)=>Column(children:[
    SectionTitle('المشتريات والموردون',subtitle:'شراء نقدي أو آجل أو جزئي، يحفظ المخزون والمديونية في معاملة واحدة.'),
    Expanded(child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      AsyncPanel<List<Map<String,dynamic>>>(future:suppliers,
        onRetry:()=>setState(()=>suppliers=widget.api.list('suppliers')),
        builder:(list)=>DropdownButtonFormField<String>(value:supplierId,
          decoration:const InputDecoration(labelText:'المورد'),
          items:list.map((s)=>DropdownMenuItem<String>(value:s['id'].toString(),child:Text(s['name'].toString()))).toList(),
          onChanged:(s)=>setState(()=>supplierId=s))),
      const SizedBox(height:12),AsyncPanel<List<Map<String,dynamic>>>(future:products,
        onRetry:()=>setState(()=>products=widget.api.list('products')),
        builder:(list)=>Row(children:[Expanded(child:DropdownButtonFormField<String>(value:selectedProduct,
          decoration:const InputDecoration(labelText:'أضف صنفًا إلى الفاتورة'),
          items:list.map((p)=>DropdownMenuItem<String>(value:p['id'].toString(),child:Text(p['name_ar'].toString()))).toList(),
          onChanged:(v)=>setState(()=>selectedProduct=v))),
          const SizedBox(width:8),IconButton(onPressed:selectedProduct==null?null:(){
            final item=list.firstWhere((x)=>x['id']==selectedProduct);
            setState(()=>lines.add(DraftPurchase(item)));
          },icon:const Icon(Icons.add_circle))])),
      const SizedBox(height:16),
      for(var i=0;i<lines.length;i++)Card(child:Padding(padding:const EdgeInsets.all(12),child:Row(children:[
        Expanded(flex:3,child:Text(lines[i].product['name_ar'].toString())),
        const SizedBox(width:8),Expanded(flex:2,child:TextField(controller:lines[i].qty,
          decoration:const InputDecoration(labelText:'كمية'))),
        const SizedBox(width:8),Expanded(flex:2,child:TextField(controller:lines[i].cost,
          decoration:const InputDecoration(labelText:'تكلفة الوحدة (ج.م)'))),
        IconButton(onPressed:(){setState(()=>lines.removeAt(i).dispose());},icon:const Icon(Icons.delete_outline))
      ]))),
      const SizedBox(height:12),TextField(controller:payment,
        decoration:const InputDecoration(labelText:'المبلغ المدفوع الآن (0 للشراء الآجل)')),
      const SizedBox(height:12),DropdownButtonFormField<String>(value:method,
        items:const [DropdownMenuItem(value:'cash',child:Text('نقدي')),
          DropdownMenuItem(value:'card',child:Text('بطاقة')),
          DropdownMenuItem(value:'wallet',child:Text('محفظة')),
          DropdownMenuItem(value:'bank',child:Text('تحويل بنكي'))],
        onChanged:(value)=>setState(()=>method=value??'cash')),
      const SizedBox(height:20),FilledButton.icon(onPressed:posting?null:_save,
        icon:const Icon(Icons.save_outlined),label:Text(posting?'جارٍ الاعتماد':'اعتماد فاتورة الشراء')),
    ]))),
  ]);
}
