import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class ReturnsPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const ReturnsPage({super.key,required this.api,required this.branchId});
  @override State<ReturnsPage> createState()=>_ReturnsState();
}
class _ReturnsState extends State<ReturnsPage> {
  late Future<List<Map<String,dynamic>>> documents;
  Map<String,dynamic>? selectedDoc;
  Map<String,dynamic>? full;
  String? lineId;
  final qty=TextEditingController(text:'1');
  String method='cash';
  bool posting=false,loading=false;
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(()=>documents=widget.api.list('documents',{'branch_id':widget.branchId}));
  @override void dispose(){qty.dispose();super.dispose();}
  Future<void> _choose(String id,List<Map<String,dynamic>> docs) async {
    setState(() {selectedDoc=docs.firstWhere((x)=>x['id']==id);full=null;lineId=null;loading=true;
      method=selectedDoc?['kind']=='purchase'?'credit':'cash';});
    try {final d=await widget.api.get('documents/$id');if(mounted)setState(()=>full=d);}
    catch(e){if(mounted)alert(context,'تعذر تحميل المستند: $e',error:true);}
    finally{if(mounted)setState(()=>loading=false);}
  }
  Future<void> _submit() async {
    if(selectedDoc==null||lineId==null)return;
    setState(()=>posting=true);
    try {
      final isSale=selectedDoc!['kind']=='sale';
      final result=await widget.api.post(isSale?'sales/returns':'purchases/returns',{
        'branch_id':widget.branchId,'original_id':selectedDoc!['id'],
        'refund_method':method,
        'lines':[{'original_line_id':lineId,'qty_milli':parseQty(qty.text)}]});
      if(!mounted)return;
      alert(context,'تم إنشاء المرتجع ${result['id']}');
      setState(() {selectedDoc=null;full=null;lineId=null;});_reload();
    }catch(e){alert(context,'تعذّر اعتماد المرتجع: $e',error:true);}
    finally{if(mounted)setState(()=>posting=false);}
  }
  @override Widget build(BuildContext context)=>SingleChildScrollView(child:Column(
    crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const SectionTitle('مرتجعات المبيعات والمشتريات',subtitle:'المرتجع مرتبط بالمستند الأصلي ولا يقبل كمية أكثر من المعتمدة.'),
      AsyncPanel<List<Map<String,dynamic>>>(future:documents,onRetry:_reload,builder:(list){
        final selectable=list.where((x)=>x['kind']=='sale'||x['kind']=='purchase').toList();
        return DropdownButtonFormField<String>(value:selectedDoc?['id']?.toString(),
          decoration:const InputDecoration(labelText:'الفاتورة الأصلية'),
          items:selectable.map((x)=>DropdownMenuItem<String>(value:x['id'].toString(),
            child:Text('${x['number']} • ${x['kind']} • ${money(asInt(x['total_minor']))}'))).toList(),
          onChanged:(id){if(id!=null)_choose(id,selectable);});
      }),
      const SizedBox(height:12),if(loading) const LinearProgressIndicator(),
      if(full!=null) ...[
        DropdownButtonFormField<String>(value:lineId,
          decoration:const InputDecoration(labelText:'البند المرتجع'),
          items:[for(final x in (full!['lines'] as List)) DropdownMenuItem<String>(
            value:x['id'].toString(),child:Text('${x['product_id']} — ${quantity(asInt(x['qty_milli']))}'))],
          onChanged:(v)=>setState(()=>lineId=v)),
        const SizedBox(height:12),TextField(controller:qty,decoration:const InputDecoration(labelText:'الكمية المرتجعة')),
        if(selectedDoc?['kind']=='sale' || selectedDoc?['kind']=='purchase') ...[
          const SizedBox(height:12),DropdownButtonFormField<String>(value:method,
            decoration:const InputDecoration(labelText:'طريقة الاسترداد'),
            items:[const DropdownMenuItem(value:'cash',child:Text('استرداد نقدي (فاتورة مسددة بالكامل)')),
              DropdownMenuItem(value:'credit',child:Text(selectedDoc?['kind']=='sale'?'رصيد على حساب العميل':'رصيد لدى المورد'))],
            onChanged:(v)=>setState(()=>method=v??method)),
        ],
        const SizedBox(height:20),FilledButton.icon(onPressed:posting?null:_submit,
          icon:const Icon(Icons.assignment_return_outlined),label:const Text('اعتماد المرتجع')),
      ],
    ]));
}
