import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class DraftPurchase {
  final Map<String,dynamic> product;
  Map<String,dynamic>? selectedUnit;
  final TextEditingController qty=TextEditingController(text:'1');
  final TextEditingController cost=TextEditingController();
  final TextEditingController lotNo=TextEditingController();
  final TextEditingController expiresOn=TextEditingController();
  DraftPurchase(this.product);
  void dispose(){qty.dispose();cost.dispose();lotNo.dispose();expiresOn.dispose();}
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
  Future<void> _chooseUnit(DraftPurchase line) async {
    try {
      final units=await widget.api.list('units',{'product_id':line.product['id'].toString()});
      if(!mounted)return;
      final options=<Map<String,dynamic>?>[null,...units];
      final result=await showDialog<int>(context:context,builder:(ctx)=>AlertDialog(
        title:Text('اختر وحدة توريد: '+line.product['name_ar'].toString()),
        content:SizedBox(width:480,child:ListView.builder(
          shrinkWrap:true,itemCount:options.length,itemBuilder:(ctx,index){
            final u=options[index];
            return ListTile(
              leading:Icon(u==null?Icons.inventory_2_outlined:Icons.all_inbox_outlined),
              title:Text(u==null?'وحدة الأساس: '+line.product['base_unit'].toString()
                :u['unit_name'].toString()),
              subtitle:Text(u==null?'الكمية بوحدة الأساس':
                'تساوي '+quantity(asInt(u['factor_milli']))+' من وحدة الأساس'),
              onTap:()=>Navigator.pop(ctx,index));
          })),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),
          child:const Text('إلغاء'))],
      ));
      if(result==null || !mounted)return;
      setState((){
        line.selectedUnit=options[result];
        line.qty.text='1';
        line.cost.clear();
      });
    }catch(e){
      if(mounted)alert(context,'تعذر تحميل وحدات الصنف: '+e.toString(),error:true);
    }
  }

  Future<void> _save() async {
    if(supplierId==null || lines.isEmpty) {alert(context,'اختر المورد والأصناف أولًا',error:true);return;}
    setState(()=>posting=true);
    try {
      final due=<Map<String,dynamic>>[];
      for(final item in lines){
        final tracked=item.product['track_expiry']==1;
        if(tracked && (item.lotNo.text.trim().isEmpty ||
           item.expiresOn.text.trim().isEmpty)) {
          throw const FormatException('رقم التشغيلة وتاريخ الصلاحية مطلوبان');
        }
        final alternate=item.selectedUnit;
        final count=alternate==null?null:int.parse(item.qty.text.trim());
        if(count!=null && (count<=0 || count>100000)) {
          throw const FormatException('عدد الكراتين يجب أن يكون عددًا صحيحًا موجبًا');
        }
        due.add({'product_id':item.product['id'],
          if(alternate==null)'qty_milli':parseQty(item.qty.text),
          if(alternate!=null)'unit_id':alternate['id'],
          if(alternate!=null)'unit_count':count,
          'unit_cost_minor':parseMoney(item.cost.text),
          if(tracked)'lot_no':item.lotNo.text.trim(),
          if(tracked)'expires_on':item.expiresOn.text.trim()});
      }
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
      for(var i=0;i<lines.length;i++)Card(child:Padding(
        padding:const EdgeInsets.all(12),child:Column(children:[
        Row(children:[
          Expanded(flex:3,child:Column(
            crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text(lines[i].product['name_ar'].toString()),
              TextButton.icon(onPressed:()=>_chooseUnit(lines[i]),
                icon:const Icon(Icons.all_inbox_outlined,size:18),
                label:Text(lines[i].selectedUnit?['unit_name']?.toString() ??
                  'وحدة الأساس / اختر كرتونة')),
            ])),
          const SizedBox(width:8),Expanded(flex:2,child:TextField(controller:lines[i].qty,
            keyboardType:TextInputType.number,
            decoration:InputDecoration(labelText:lines[i].selectedUnit==null
              ?'كمية أساس':'عدد كراتين'))),
          const SizedBox(width:8),Expanded(flex:2,child:TextField(controller:lines[i].cost,
            keyboardType:TextInputType.number,
            decoration:InputDecoration(labelText:lines[i].selectedUnit==null
              ?'تكلفة وحدة الأساس (ج.م)':'تكلفة الكرتونة (ج.م)'))),
          IconButton(onPressed:(){setState(()=>lines.removeAt(i).dispose());},
            icon:const Icon(Icons.delete_outline)),
        ]),
        if(lines[i].product['track_expiry']==1)...[
          const SizedBox(height:10),
          const Text('يلزم تسجيل تشغيلة كل بند وتاريخ الانتهاء حتى يُقبل توريد هذا الصنف.'),
          const SizedBox(height:8),
          Row(children:[
            Expanded(child:TextField(controller:lines[i].lotNo,
              decoration:const InputDecoration(labelText:'رقم التشغيلة LOT'))),
            const SizedBox(width:8),
            Expanded(child:TextField(controller:lines[i].expiresOn,
              decoration:const InputDecoration(labelText:'تاريخ الانتهاء YYYY-MM-DD'))),
          ]),
        ],
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
