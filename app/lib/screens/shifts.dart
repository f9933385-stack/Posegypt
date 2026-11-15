import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

/// A branch can operate legacy one-shift mode or opt into independently
/// attributed drawers. Cash entries are assigned by the server to the
/// logged-in operator's active drawer shift, never trusted from the UI.
class ShiftsPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  final String role;
  final String userId;
  const ShiftsPage({super.key,required this.api,required this.branchId,
    required this.role,required this.userId});
  @override State<ShiftsPage> createState()=>_ShiftsPageState();
}

class _ShiftsPageState extends State<ShiftsPage> {
  final openingCount=TextEditingController();
  final closingCount=TextEditingController();
  late Future<List<Map<String,dynamic>>> shifts;
  late Future<List<Map<String,dynamic>>> drawers;
  String? selectedDrawer;
  bool busy=false;
  bool get manager=>widget.role=='owner'||widget.role=='manager';

  @override void initState(){super.initState();_reload();}
  @override void dispose(){
    openingCount.dispose();
    closingCount.dispose();
    super.dispose();
  }

  void _reload()=>setState((){
    shifts=widget.api.list('shifts',{'branch_id':widget.branchId});
    drawers=widget.api.list('shifts/drawers',{'branch_id':widget.branchId});
  });

  Future<void> _createDrawer() async {
    final name=TextEditingController();
    try {
      final entered=await showDialog<String>(context:context,builder:(ctx)=>
        AlertDialog(
          title:const Text('إضافة درج نقدية مستقل'),
          content:SizedBox(width:410,child:Column(mainAxisSize:MainAxisSize.min,children:[
            const Text('تنبيه: بعد إضافة أول درج، يلزم فتح وردية لكل مستخدم '
              'قبل أي عملية نقدية. تأكد من إغلاق الوردية المشتركة أولًا.'),
            const SizedBox(height:12),
            TextField(controller:name,maxLength:60,
              decoration:const InputDecoration(labelText:'اسم الدرج أو الكاشير')),
          ])),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
            FilledButton(onPressed:()=>Navigator.pop(ctx,name.text.trim()),
              child:const Text('إنشاء الدرج')),
          ],
        ));
      if(entered==null||entered.isEmpty||!mounted)return;
      setState(()=>busy=true);
      try {
        await widget.api.post('shifts/drawers',{
          'branch_id':widget.branchId,'name':entered});
        if(mounted){alert(context,'تمت إضافة الدرج النقدية');_reload();}
      }catch(e){
        if(mounted)alert(context,'تعذر إنشاء الدرج: $e',error:true);
      }finally{if(mounted)setState(()=>busy=false);}
    }finally{name.dispose();}
  }

  Future<void> _submit({required bool close,String? id,String? drawerId,
      String? overrideReason}) async {
    if(busy)return;
    setState(()=>busy=true);
    try {
      final amount=parseMoney(close?closingCount.text:openingCount.text);
      final result=await widget.api.post(close?'shifts/close':'shifts/open',{
        'branch_id':widget.branchId,
        if(close) 'shift_id':id,
        if(!close && drawerId!=null) 'cash_drawer_id':drawerId,
        if(overrideReason!=null) 'override_reason':overrideReason,
        (close?'closing_actual_minor':'opening_minor'):amount,
      });
      if(!mounted)return;
      if(close){closingCount.clear();}else{openingCount.clear();}
      if(close) {
        alert(context,'تم الإغلاق. المتوقع ${money(asInt(result['expected_minor']))}'
          ' — الفرق ${money(asInt(result['difference_minor']))}');
      } else {
        alert(context,'تم فتح وردية الدرج بنجاح');
      }
      _reload();
    }catch(e){
      if(mounted)alert(context,'فشلت العملية: $e',error:true);
    }finally{if(mounted)setState(()=>busy=false);}
  }

  Future<void> _close(Map<String,dynamic> shift) async {
    String? note;
    if(shift['user_id']!=widget.userId){
      if(!manager)return;
      final reason=TextEditingController();
      try {
        note=await showDialog<String>(context:context,builder:(ctx)=>
          AlertDialog(
            title:const Text('إغلاق وردية موظف آخر'),
            content:SizedBox(width:400,child:Column(mainAxisSize:MainAxisSize.min,children:[
              const Text('سيُحفظ السبب في سجل التدقيق. يجب عدّ الدرج '
                'وإدخال النقدية الفعلية قبل الإغلاق.'),
              TextField(controller:reason,maxLines:2,
                decoration:const InputDecoration(
                  labelText:'سبب إغلاق الوردية (12 حرفًا على الأقل)')),
            ])),
            actions:[
              TextButton(onPressed:()=>Navigator.pop(ctx),
                child:const Text('إلغاء')),
              FilledButton(onPressed:()=>Navigator.pop(ctx,reason.text.trim()),
                child:const Text('اعتماد السبب')),
            ],
          ));
      }finally{reason.dispose();}
      if(note==null||!mounted)return;
    }
    await _submit(close:true,id:shift['id'].toString(),overrideReason:note);
  }

  @override Widget build(BuildContext context)=>
    SingleChildScrollView(child:Column(
      crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        const SectionTitle('الورديات والخزينة',
          subtitle:'عهدة مستقلة لكل درج عند تفعيل الأدراج. '
            'الإغلاق أعمى ولا يسجل الفرق النقدي تلقائيًا.'),
        AsyncPanel<List<Map<String,dynamic>>>(future:drawers,
          onRetry:_reload,builder:(available)=>
          AsyncPanel<List<Map<String,dynamic>>>(future:shifts,
            onRetry:_reload,builder:(all){
            final active=all.where((s)=>s['closed_at']==null).toList();
            final ownActive=active.where((s)=>s['user_id']==widget.userId).toList();
            final independent=available.isNotEmpty;
            final freeDrawers=available.where((d)=>
              d['active']==1&&d['open_shift_id']==null).toList();
            final chosen=freeDrawers.any((d)=>d['id']==selectedDrawer)
              ?selectedDrawer
              :(freeDrawers.isEmpty?null:freeDrawers.first['id'].toString());
            final canOpen=independent?ownActive.isEmpty&&chosen!=null:active.isEmpty;
            return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
              if(manager) Align(alignment:Alignment.centerRight,
                child:OutlinedButton.icon(onPressed:busy?null:_createDrawer,
                  icon:const Icon(Icons.add_box_outlined),
                  label:const Text('إضافة درج نقدية'))),
              if(independent) ...[
                Text('عدد الأدراج: ${available.length} — '
                  'الورديات المفتوحة: ${active.length}'),
                const SizedBox(height:8),
                const Text('تُربط الحركات النقدية تلقائيًا بوردية حساب الموظف '
                  'الحالي؛ الحركات غير النقدية لا تدخل عهدة الدرج.'),
              ]else const Text('وضع الورديات المشتركة (القديم): وردية واحدة للفرع. '
                'أنشئ درجًا من حساب المدير لتفعيل العهد المنفصلة.'),
              const SizedBox(height:12),
              Card(child:Padding(padding:const EdgeInsets.all(18),
                child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                  Text(canOpen?'فتح وردية جديدة':
                    'الورديات المفتوحة',style:Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height:12),
                  if(independent&&canOpen) DropdownButtonFormField<String>(
                    value:chosen,isExpanded:true,
                    decoration:const InputDecoration(labelText:'الدرج النقدية'),
                    items:[for(final d in freeDrawers)
                      DropdownMenuItem<String>(value:d['id'].toString(),
                        child:Text(d['name'].toString()))],
                    onChanged:(value)=>setState(()=>selectedDrawer=value)),
                  if(canOpen) ...[
                    const SizedBox(height:12),
                    TextField(controller:openingCount,keyboardType:TextInputType.number,
                      decoration:const InputDecoration(
                        labelText:'النقدية الافتتاحية بالجنيه')),
                    const SizedBox(height:14),
                    FilledButton.icon(
                      onPressed:busy?null:()=>_submit(close:false,drawerId:chosen),
                      icon:const Icon(Icons.lock_open),
                      label:const Text('فتح الوردية')),
                  ] else if(ownActive.isNotEmpty)
                    const Text('لديك وردية مفتوحة. أغلقها قبل فتح وردية جديدة.')
                  else const Text('لا يوجد درج شاغر أو توجد وردية مفتوحة مشتركة.'),
                  if(active.isNotEmpty) ...[
                    const SizedBox(height:12),
                    TextField(controller:closingCount,
                      keyboardType:TextInputType.number,
                      decoration:const InputDecoration(
                        labelText:'النقدية الفعلية بعد عدّ الدرج الذي ستغلقه')),
                    for(final shift in active) ListTile(
                      title:Text(shift['drawer_name']?.toString()??'خزينة الفرع'),
                      subtitle:Text('${shift['operator_name']} — ${shift['opened_at']}'),
                      trailing:FilledButton(
                        onPressed:busy?null:()=>_close(shift),
                        child:const Text('إغلاق')),
                    ),
                  ],
                ]))),
              const SizedBox(height:16),
              Text('آخر الورديات',style:Theme.of(context).textTheme.titleLarge),
              for(final shift in all) ListTile(
                leading:Icon(shift['closed_at']==null?
                  Icons.lock_open:Icons.lock_outline),
                title:Text(shift['drawer_name']?.toString()??'الخزينة المشتركة'),
                subtitle:Text('${shift['operator_name']} • '
                  '${shift['opened_at']} • '
                  '${shift['closed_at']==null?'مفتوحة':'مغلقة'}'),
                trailing:shift['closing_actual_minor']==null?null:
                  moneyText(shift['closing_actual_minor']),
              ),
              if(all.isEmpty)const EmptyState('لا توجد ورديات مسجلة'),
            ]);
          })),
      ]));
