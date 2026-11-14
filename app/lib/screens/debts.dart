import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class DebtsPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const DebtsPage({super.key,required this.api,required this.branchId});
  @override State<DebtsPage> createState()=>_DebtsState();
}
class _DebtsState extends State<DebtsPage> {
  bool customer=true,saving=false;
  String? partyId;
  String method='cash';
  final amount=TextEditingController();
  late Future<List<Map<String,dynamic>>> parties;
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(()=>parties=widget.api.list(customer?'customers':'suppliers'));
  @override void dispose(){amount.dispose();super.dispose();}
  Future<void> _submit() async {
    if(partyId==null){alert(context,'اختر العميل أو المورد',error:true);return;}
    setState(()=>saving=true);
    try {
      final result=await widget.api.post(customer?'customers/receipts':'suppliers/payments',{
        'branch_id':widget.branchId,(customer?'customer_id':'supplier_id'):partyId,
        'amount_minor':parseMoney(amount.text),'method':method});
      if(!mounted)return;
      alert(context,'تم تسجيل الحركة. الرصيد المتبقي: ${money(asInt(result['remaining_minor']))}');
      amount.clear();_reload();
    }catch(e){alert(context,'تعذر تسجيل الحركة: $e',error:true);}
    finally{if(mounted)setState(()=>saving=false);}
  }
  @override Widget build(BuildContext context)=>SingleChildScrollView(child:Column(
    crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const SectionTitle('التحصيلات وسداد الموردين',subtitle:'تسويات الديون تؤثر على الحساب النقدي والمديونية فقط، وليس الربح.'),
      SegmentedButton<bool>(segments:const [ButtonSegment(value:true,label:Text('تحصيل من عميل')),
        ButtonSegment(value:false,label:Text('سداد لمورد'))],selected:{customer},onSelectionChanged:(value){
          setState(() {customer=value.first;partyId=null;});_reload();}),
      const SizedBox(height:12),AsyncPanel<List<Map<String,dynamic>>>(future:parties,onRetry:_reload,
        builder:(list)=>DropdownButtonFormField<String>(value:partyId,
          decoration:InputDecoration(labelText:customer?'العميل':'المورد'),
          items:list.map((p)=>DropdownMenuItem<String>(value:p['id'].toString(),
            child:Text('${p['name']}${p['balance_minor']!=null?' — ${money(asInt(p['balance_minor']))}':''}'))).toList(),
          onChanged:(p)=>setState(()=>partyId=p))),
      const SizedBox(height:12),TextField(controller:amount,keyboardType:TextInputType.number,
        decoration:const InputDecoration(labelText:'القيمة بالجنيه')),
      const SizedBox(height:12),DropdownButtonFormField<String>(value:method,
        decoration:const InputDecoration(labelText:'وسيلة الدفع'),
        items:const [DropdownMenuItem(value:'cash',child:Text('نقدي')),
          DropdownMenuItem(value:'card',child:Text('بطاقة')),
          DropdownMenuItem(value:'wallet',child:Text('محفظة')),
          DropdownMenuItem(value:'bank',child:Text('تحويل'))],
        onChanged:(v)=>setState(()=>method=v??method)),
      const SizedBox(height:20),FilledButton.icon(onPressed:saving?null:_submit,
        icon:const Icon(Icons.save),label:Text(saving?'جارٍ التسجيل':'اعتماد الحركة')),
    ]));
}
