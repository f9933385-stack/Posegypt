import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class ExpensesPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const ExpensesPage({super.key,required this.api,required this.branchId});
  @override State<ExpensesPage> createState()=>_ExpensesState();
}
class _ExpensesState extends State<ExpensesPage> {
  final amount=TextEditingController(),notes=TextEditingController();
  final categories=['إيجار','كهرباء','مياه','إنترنت','رواتب','نقل','صيانة','نظافة','أخرى'];
  String category='إيجار',method='cash';
  bool saving=false;
  @override void dispose(){amount.dispose();notes.dispose();super.dispose();}
  Future<void> _save() async {
    setState(()=>saving=true);
    try {
      final saved=await widget.api.post('expenses',{'branch_id':widget.branchId,'category':category,
        'method':method,'amount_minor':parseMoney(amount.text),'note':notes.text});
      if(!mounted)return;
      alert(context,'تم تسجيل مصروف ${money(asInt(saved['amount_minor']))}');
      amount.clear();notes.clear();
    }catch(e){alert(context,'تعذر حفظ المصروف: $e',error:true);}
    finally{if(mounted)setState(()=>saving=false);}
  }
  @override Widget build(BuildContext context)=>SingleChildScrollView(child:Column(
    crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const SectionTitle('المصروفات',subtitle:'تُرحّل المصروفات مباشرة إلى الحسابات الداخلية ووسيلة الدفع.'),
      Card(child:Padding(padding:const EdgeInsets.all(20),child:Column(children:[
        DropdownButtonFormField<String>(value:category,decoration:const InputDecoration(labelText:'فئة المصروف'),
          items:categories.map((c)=>DropdownMenuItem(value:c,child:Text(c))).toList(),
          onChanged:(c)=>setState(()=>category=c??category)),
        const SizedBox(height:12),TextField(controller:amount,keyboardType:TextInputType.number,
          decoration:const InputDecoration(labelText:'القيمة بالجنيه المصري')),
        const SizedBox(height:12),TextField(controller:notes,decoration:const InputDecoration(labelText:'ملاحظات')),
        const SizedBox(height:12),DropdownButtonFormField<String>(value:method,
          decoration:const InputDecoration(labelText:'وسيلة السداد'),
          items:const [DropdownMenuItem(value:'cash',child:Text('نقدي')),
            DropdownMenuItem(value:'card',child:Text('بطاقة')),
            DropdownMenuItem(value:'wallet',child:Text('محفظة')),
            DropdownMenuItem(value:'bank',child:Text('تحويل بنكي'))],
          onChanged:(v)=>setState(()=>method=v??method)),
        const SizedBox(height:20),SizedBox(width:double.infinity,child:FilledButton.icon(
          onPressed:saving?null:_save,icon:const Icon(Icons.check),label:Text(saving?'جارٍ الحفظ':'حفظ المصروف'))),
      ]))),
    ]));
}
