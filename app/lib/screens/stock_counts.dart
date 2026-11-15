import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

/// Two-person cycle-count review. Only approval changes branch ledger balances.
class StockCountsPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  final String role;
  const StockCountsPage({super.key,required this.api,
    required this.branchId,required this.role});
  @override State<StockCountsPage> createState()=>_StockCountsState();
}

class _StockCountsState extends State<StockCountsPage> {
  late Future<List<Map<String,dynamic>>> counts;
  late Future<List<Map<String,dynamic>>> warehouses;
  Future<Map<String,dynamic>>? selectedDetail;
  String? selectedId;
  bool busy=false;

  bool get canApprove=>widget.role=='owner' || widget.role=='manager';

  @override void initState(){super.initState();_refresh();}
  void _refresh(){
    setState((){
      counts=widget.api.list('counts',{'branch_id':widget.branchId});
      warehouses=widget.api.list('warehouses',{'branch_id':widget.branchId});
      if(selectedId!=null) selectedDetail=widget.api.get('counts/'+selectedId!);
    });
  }
  Future<void> _showCount(String id) async {
    setState((){
      selectedId=id;
      selectedDetail=widget.api.get('counts/'+id);
    });
  }
  Future<T?> _dialog<T>(Widget Function(BuildContext) builder)=>
    showDialog<T>(context:context,builder:builder);

  Future<void> _create() async {
    try {
      final available=await warehouses;
      if(!mounted)return;
      if(available.isEmpty){alert(context,'لا توجد مخازن',error:true);return;}
      String warehouse=available.first['id'].toString();
      final reason=TextEditingController();
      final data=await _dialog<Map<String,dynamic>>((ctx)=>StatefulBuilder(
        builder:(ctx,update)=>AlertDialog(
          title:const Text('فتح جرد جديد'),
          content:SizedBox(width:430,child:Column(mainAxisSize:MainAxisSize.min,children:[
            const Text('يتم تجميد لقطة من الأرصدة. أي حركة مخزون بعد ذلك تلغي صلاحية الجرد للاعتماد.'),
            const SizedBox(height:14),
            DropdownButtonFormField<String>(initialValue:warehouse,isExpanded:true,
              decoration:const InputDecoration(labelText:'المخزن'),
              items:available.map((w)=>DropdownMenuItem<String>(
                value:w['id'].toString(),child:Text(w['name'].toString()))).toList(),
              onChanged:(v){if(v!=null)update(()=>warehouse=v);}),
            const SizedBox(height:12),
            TextField(controller:reason,
              decoration:const InputDecoration(labelText:'سبب / اسم دورة الجرد')),
          ])),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
            FilledButton(onPressed:(){
              if(reason.text.trim().isEmpty){
                alert(ctx,'سبب الجرد مطلوب',error:true);return;
              }
              Navigator.pop(ctx,{'branch_id':widget.branchId,
                'warehouse_id':warehouse,'reason':reason.text.trim()});
            },child:const Text('فتح الجرد')),
          ],
        )));
      reason.dispose();
      if(data==null)return;
      setState(()=>busy=true);
      final created=await widget.api.post('counts',data);
      if(!mounted)return;
      alert(context,'تم فتح الجرد؛ الأرصدة لم تتغير');
      selectedId=created['id'].toString();
      _refresh();
    } catch(e) {
      if(mounted)alert(context,'تعذر فتح الجرد: '+e.toString(),error:true);
    } finally {if(mounted)setState(()=>busy=false);}
  }

  Future<void> _countLine(Map<String,dynamic> line) async {
    final qty=TextEditingController(text:line['counted_qty_milli']==null
      ?quantity(asInt(line['expected_qty_milli']))
      :quantity(asInt(line['counted_qty_milli'])));
    final valuation=TextEditingController(text:line['added_cost_minor']==null
      ?'':(asInt(line['added_cost_minor'])/100).toStringAsFixed(2));
    try {
      final data=await _dialog<Map<String,dynamic>>((ctx)=>AlertDialog(
        title:Text('تسجيل العد الفعلي: '+line['name_ar'].toString()),
        content:SizedBox(width:430,child:Column(mainAxisSize:MainAxisSize.min,children:[
          if(line['lot_no']!=null)
            Text('التشغيلة: '+line['lot_no'].toString()+
              ' • الانتهاء: '+line['expires_on'].toString()),
          Text('الكمية المتوقعة: '+quantity(asInt(line['expected_qty_milli']))),
          const SizedBox(height:12),
          TextField(controller:qty,autofocus:true,keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'الكمية المعدودة الفعلية (0 مسموح)')),
          const SizedBox(height:12),
          TextField(controller:valuation,keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'قيمة الزيادة الإجمالية بالجنيه (عند الزيادة فقط)')),
          const SizedBox(height:10),
          const Text('لا تتغير الكميات فعليًا قبل مراجعة المدير واعتماد الجرد.',
            style:TextStyle(fontSize:12)),
        ])),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
          FilledButton(onPressed:(){
            try {
              final actual=parseQty(qty.text), expected=asInt(line['expected_qty_milli']);
              if(actual<0)throw const FormatException();
              final added=actual>expected?parseMoney(valuation.text):0;
              if(actual>expected && added<=0)throw const FormatException();
              Navigator.pop(ctx,{'count_id':selectedId,'line_id':line['id'],
                'counted_qty_milli':actual,'added_cost_minor':added});
            }catch(_){alert(ctx,'تحقق من الكمية وتقييم التكلفة عند الزيادة',error:true);}
          },child:const Text('حفظ العد')),
        ],
      ));
      if(data==null)return;
      setState(()=>busy=true);
      await widget.api.post('counts/lines',data);
      if(mounted){alert(context,'تم حفظ العد؛ في انتظار الاعتماد');_refresh();}
    } catch(e) {
      if(mounted)alert(context,'تعذر تسجيل العد: '+e.toString(),error:true);
    } finally {
      qty.dispose();valuation.dispose();
      if(mounted)setState(()=>busy=false);
    }
  }

  Future<void> _transition(String action,Map<String,dynamic> count) async {
    final labels={'submit':'إرسال الجرد للمراجعة',
      'approve':'اعتماد الفروق وتحديث المخزون',
      'cancel':'إلغاء الجرد بلا تأثير على المخزون'};
    final isCancel=action=='cancel';
    final reason=TextEditingController();
    try {
      final accepted=await _dialog<bool>((ctx)=>AlertDialog(
        title:Text(labels[action] ?? 'تأكيد'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          Text(action=='approve'
            ?'سيتم تغيير كميات المخزون وتسجيل القيود المحاسبية. يجب أن يكون المعتمد شخصًا مختلفًا عن منشئ الجرد.'
            :'لن تتغير الأرصدة المالية حتى يتم اعتماد الجرد.'),
          if(isCancel)...[
            const SizedBox(height:12),
            TextField(controller:reason,
              decoration:const InputDecoration(labelText:'سبب الإلغاء')),
          ],
        ]),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('رجوع')),
          FilledButton(onPressed:(){
            if(isCancel && reason.text.trim().isEmpty){
              alert(ctx,'اكتب سبب الإلغاء',error:true);return;
            }
            Navigator.pop(ctx,true);
          },child:const Text('تأكيد')),
        ],
      ));
      if(accepted!=true)return;
      setState(()=>busy=true);
      final body={'count_id':count['id'],
        if(isCancel)'reason':reason.text.trim()};
      await widget.api.post('counts/'+action,body);
      if(mounted){alert(context,'تم تحديث حالة الجرد');_refresh();}
    }catch(e) {
      if(mounted)alert(context,'تعذر تغيير حالة الجرد: '+e.toString(),error:true);
    }finally {
      reason.dispose();
      if(mounted)setState(()=>busy=false);
    }
  }

  Widget _detail(Map<String,dynamic> detail) {
    final lines=(detail['lines'] as List).cast<Map<String,dynamic>>();
    final state=detail['status'].toString();
    final finished=lines.where((l)=>l['counted_qty_milli']!=null).length;
    return Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(
      crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Text('تفاصيل الجرد • '+state,style:Theme.of(context).textTheme.titleLarge),
        const SizedBox(height:8),
        Text('تم عد '+finished.toString()+' من '+lines.length.toString()+' بنود'),
        const SizedBox(height:12),
        Wrap(spacing:8,runSpacing:8,children:[
          if(state=='draft')FilledButton.icon(
            onPressed:busy || finished!=lines.length?null:()=>_transition('submit',detail),
            icon:const Icon(Icons.send_outlined),label:const Text('إرسال للمراجعة')),
          if(state=='submitted' && canApprove)FilledButton.icon(
            onPressed:busy?null:()=>_transition('approve',detail),
            icon:const Icon(Icons.verified_outlined),label:const Text('اعتماد المدير')),
          if((state=='draft' || state=='submitted') && canApprove)
            OutlinedButton.icon(onPressed:busy?null:()=>_transition('cancel',detail),
              icon:const Icon(Icons.cancel_outlined),label:const Text('إلغاء الجرد')),
        ]),
        const SizedBox(height:16),
        for(final line in lines)Card(clipBehavior:Clip.antiAlias,child:ListTile(
          title:Text(line['name_ar'].toString()),
          subtitle:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            if(line['lot_no']!=null)
              Text('تشغيلة: '+line['lot_no'].toString()+' • '+line['expires_on'].toString()),
            Text('المتوقع: '+quantity(asInt(line['expected_qty_milli']))+
              ' • المعدود: '+(line['counted_qty_milli']==null
                ?'لم يُعدّ':quantity(asInt(line['counted_qty_milli'])))),
          ]),
          trailing:state=='draft'?IconButton(
            onPressed:busy?null:()=>_countLine(line),
            icon:Icon(line['counted_qty_milli']==null?Icons.edit_note:Icons.edit),
            tooltip:'تسجيل أو تعديل العد'):null,
        )),
      ])));
  }

  @override Widget build(BuildContext context)=>Column(children:[
    SectionTitle('الجرد الدوري المعتمد',
      subtitle:'عدّ فعلي دون تغيير الأرصدة؛ اعتماد مستقل وفحص حركات المخزون.',
      action:FilledButton.icon(onPressed:busy?null:_create,
        icon:const Icon(Icons.add),label:const Text('جرد جديد'))),
    Expanded(child:AsyncPanel<List<Map<String,dynamic>>>(
      future:counts,onRetry:_refresh,builder:(list)=>ListView(children:[
        if(list.isEmpty)const EmptyState('لم تُفتح أي دورة جرد في هذا الفرع بعد.'),
        for(final item in list)Card(child:ListTile(
          title:Text('جرد '+item['warehouse_name'].toString()),
          subtitle:Text(item['reason'].toString()+
            ' • '+item['counted_lines'].toString()+'/'+item['line_count'].toString()),
          trailing:Text(item['status'].toString()),
          selected:selectedId==item['id'],
          onTap:()=>_showCount(item['id'].toString()),
        )),
        if(selectedDetail!=null)...[
          const SizedBox(height:12),
          AsyncPanel<Map<String,dynamic>>(future:selectedDetail!,
            onRetry:_refresh,builder:_detail),
        ],
      ]))),
  ]);
}
