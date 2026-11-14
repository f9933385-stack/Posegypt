import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

/// One branch-level drawer shift at a time in this development release.
/// No cashier can view the expected amount before submitting the count.
class ShiftsPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const ShiftsPage({super.key,required this.api,required this.branchId});
  @override State<ShiftsPage> createState()=>_ShiftsPageState();
}

class _ShiftsPageState extends State<ShiftsPage> {
  final counted=TextEditingController();
  late Future<List<Map<String,dynamic>>> shifts;
  bool busy=false;
  @override void initState(){super.initState();_reload();}
  @override void dispose(){counted.dispose();super.dispose();}
  void _reload()=>setState(()=>shifts=widget.api.list('shifts',{'branch_id':widget.branchId}));

  Future<void> _submit({required bool close,String? id}) async {
    setState(()=>busy=true);
    try {
      final amount=parseMoney(counted.text);
      final result=await widget.api.post(close?'shifts/close':'shifts/open',{
        'branch_id':widget.branchId,
        if(close) 'shift_id':id,
        (close?'closing_actual_minor':'opening_minor'):amount,
      });
      if(!mounted)return;
      counted.clear();
      if(close) {
        alert(context,'تم الإغلاق. المتوقع ${money(asInt(result['expected_minor']))} — الفرق ${money(asInt(result['difference_minor']))}');
      } else {
        alert(context,'تم فتح الوردية بنجاح');
      }
      _reload();
    } catch(e) {
      alert(context,'فشلت العملية: $e',error:true);
    } finally {
      if(mounted)setState(()=>busy=false);
    }
  }

  @override Widget build(BuildContext context)=>SingleChildScrollView(child:Column(
    crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    const SectionTitle('الورديات والخزينة',subtitle:'وردية واحدة مشتركة لكل فرع. إغلاق أعمى: أدخل المبلغ الذي عدّدته دون رؤية المتوقع.'),
    AsyncPanel<List<Map<String,dynamic>>>(future:shifts,onRetry:_reload,builder:(list){
      final active=list.where((s)=>s['closed_at']==null).toList();
      final shift=active.isEmpty?null:active.first;
      return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Card(child:Padding(padding:const EdgeInsets.all(20),child:Column(
          crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Text(shift==null?'فتح وردية جديدة':'إغلاق الوردية المفتوحة',style:Theme.of(context).textTheme.titleLarge),
          const SizedBox(height:12),
          if(shift!=null) Text('بداية الوردية: ${shift['opened_at']}'),
          const SizedBox(height:12),
          TextField(controller:counted,keyboardType:TextInputType.number,
            decoration:InputDecoration(labelText:shift==null?'النقدية الافتتاحية بالجنيه':'النقدية الفعلية بعد العد بالجنيه')),
          const SizedBox(height:16),
          FilledButton.icon(onPressed:busy?null:()=>_submit(close:shift!=null,id:shift?['id']?.toString()),
            icon:Icon(shift==null?Icons.lock_open:Icons.lock),
            label:Text(busy?'جارٍ الحفظ':shift==null?'فتح الوردية':'اعتماد الإغلاق')),
        ]))),
        const SizedBox(height:16),
        Text('آخر الورديات',style:Theme.of(context).textTheme.titleLarge),
        for(final s in list) ListTile(
          leading:Icon(s['closed_at']==null?Icons.lock_open:Icons.lock_outline),
          title:Text('الوردية ${s['id'].toString().substring(0,8)}'),
          subtitle:Text('بدأت: ${s['opened_at']}   ${s['closed_at']==null?'مفتوحة':'انتهت: ${s['closed_at']}'}'),
          trailing:s['closing_actual_minor']==null?null:moneyText(s['closing_actual_minor']),
        ),
        if(list.isEmpty)const EmptyState('لا توجد ورديات مسجلة'),
      ]);
    }),
  ]));
}
