import 'package:flutter/material.dart';
import '../models/formats.dart';
import '../services/api.dart';
import '../widgets/common.dart';

/// Cash physically held in the branch safe is not a new receipt or GL post.
/// Only a different manager can confirm that they counted and received it.
class CashSafeSection extends StatefulWidget {
  final ApiClient api;
  final String branchId,userId,role;
  final VoidCallback onChanged;
  const CashSafeSection({super.key,required this.api,
    required this.branchId,required this.userId,required this.role,
    required this.onChanged});

  @override State<CashSafeSection> createState()=>_CashSafeSectionState();
}

class _CashSafeSectionState extends State<CashSafeSection> {
  late Future<Map<String,dynamic>> future;
  bool busy=false;
  bool get supervisor=>widget.role=='owner'||widget.role=='manager';
  Map<String,String> get query=>{'branch_id':widget.branchId};

  @override void initState() {super.initState();_reload();}

  Future<Map<String,dynamic>> _load() async {
    final safe=await widget.api.get('shifts/safe',query);
    final shifts=await widget.api.list('shifts',query);
    final drops=await widget.api.list('shifts/safe/drops',query);
    return {'safe':safe,'shifts':shifts,'drops':drops};
  }

  void _reload(){
    if(mounted)setState(()=>future=_load());
  }

  Future<void> _post(String path,Map<String,dynamic> payload) async {
    if(busy)return;
    setState(()=>busy=true);
    try{
      await widget.api.post(path,payload);
      if(!mounted)return;
      alert(context,'تم تسجيل العملية وتحديث سجل عهدة الخزينة');
      _reload();
      widget.onChanged();
    }catch(e) {
      if(mounted)alert(context,'تعذرت العملية: $e',error:true);
    }finally {
      if(mounted)setState(()=>busy=false);
    }
  }

  Future<void> _createSafe() async {
    if(!supervisor || busy)return;
    final controller=TextEditingController(text:'الخزينة الرئيسية');
    try{
      final name=await showDialog<String>(context:context,builder:(ctx) {
        return AlertDialog(
          title:const Text('تسجيل خزينة رئيسية للفرع'),
          content:Column(mainAxisSize:MainAxisSize.min,children:[
            const Text('تبدأ الخزينة برصيد صفر. لا يُضاف إليها نقد '
              'إلا بعد طلب تسليم واعتماد مدير مختلف عن الموظف المرسل.'),
            const SizedBox(height:10),
            TextField(controller:controller,maxLength:60,
              decoration:const InputDecoration(labelText:'اسم خزينة الفرع')),
          ]),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),
              child:const Text('إلغاء')),
            FilledButton(onPressed:()=>Navigator.pop(ctx,controller.text.trim()),
              child:const Text('تسجيل الخزينة')),
          ],
        );
      });
      if(name==null || name.isEmpty || !mounted)return;
      await _post('shifts/safe',{'branch_id':widget.branchId,'name':name});
    }finally {controller.dispose();}
  }

  Future<void> _request(Map<String,dynamic> shift) async {
    if(busy)return;
    final amount=TextEditingController();
    final reason=TextEditingController();
    String? error;
    try{
      final payload=await showDialog<Map<String,dynamic>>(
        context:context,builder:(ctx) {
          return StatefulBuilder(builder:(ctx,update) {
            return AlertDialog(
              title:const Text('تسليم نقدية إلى الخزينة'),
              content:SizedBox(width:520,child:Column(
                mainAxisSize:MainAxisSize.min,children:[
                  const Text('هذا طلب تسليم معلق. تظل النقدية في عهدة الدرج '
                    'حتى يؤكد مدير آخر استلامها وعدّها فعليًا.'),
                  const SizedBox(height:8),
                  Text('الدرج: ${shift['drawer_name']}'),
                  const SizedBox(height:12),
                  TextField(controller:amount,
                    keyboardType:const TextInputType.numberWithOptions(decimal:true),
                    decoration:const InputDecoration(labelText:'المبلغ بالجنيه',
                      border:OutlineInputBorder())),
                  const SizedBox(height:12),
                  TextField(controller:reason,maxLines:2,
                    decoration:const InputDecoration(
                      labelText:'سبب التسليم والمرجع المستندي',
                      border:OutlineInputBorder())),
                  if(error!=null) Text(error!,style:TextStyle(
                    color:Theme.of(ctx).colorScheme.error)),
                ])),
              actions:[
                TextButton(onPressed:()=>Navigator.pop(ctx),
                  child:const Text('إلغاء')),
                FilledButton(onPressed:(){
                  try {
                    final n=parseMoney(amount.text);
                    if(n<=0) {
                      throw const FormatException('أدخل مبلغًا أكبر من صفر');
                    }
                    if(reason.text.trim().length<12){
                      throw const FormatException('سبب التسليم يجب ألا يقل عن 12 حرفًا');
                    }
                    Navigator.pop(ctx,{
                      'branch_id':widget.branchId,
                      'source_shift_id':shift['id'],
                      'amount_minor':n,'reason':reason.text.trim(),
                    });
                  }catch(e){update(()=>error=e.toString());}
                },child:const Text('إرسال طلب التسليم')),
              ],
            );
          });
        });
      if(payload!=null && mounted) {
        await _post('shifts/safe/drops',payload);
      }
    }finally{
      amount.dispose();
      reason.dispose();
    }
  }

  Future<void> _review(Map<String,dynamic> drop,String action) async {
    if(busy)return;
    final controller=TextEditingController();
    try{
      final reason=await showDialog<String>(context:context,builder:(ctx){
        return AlertDialog(
          title:Text(action=='approve'?'تأكيد استلام الخزينة':
            action=='reject'?'رفض التسليم':'إلغاء طلب التسليم'),
          content:Column(mainAxisSize:MainAxisSize.min,children:[
            Text('المبلغ: ${money(asInt(drop['amount_minor']))} '
              '— من درج ${drop['drawer_name']}'),
            const SizedBox(height:8),
            const Text('يُعتمد الاستلام فقط بعد العدّ الفعلي والتأكد '
              'من محضر التسليم. لا ينشئ الاعتماد حركة نقد جديدة.'),
            const SizedBox(height:10),
            TextField(controller:controller,maxLines:2,
              decoration:const InputDecoration(
                labelText:'سبب القرار أو مرجع الاستلام')),
          ]),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),
              child:const Text('إلغاء')),
            FilledButton(onPressed:(){
              if(controller.text.trim().length<12){
                alert(ctx,'اكتب سببًا موثقًا من 12 حرفًا على الأقل',error:true);
                return;
              }
              Navigator.pop(ctx,controller.text.trim());
            },child:Text(action=='approve'?'تأكيد الاستلام':
              action=='reject'?'رفض الطلب':'إلغاء الطلب')),
          ],
        );
      });
      if(reason==null || !mounted)return;
      await _post('shifts/safe/drops/$action',{
        'drop_id':drop['id'],'reason':reason});
    }finally{controller.dispose();}
  }

  @override Widget build(BuildContext context) =>
    AsyncPanel<Map<String,dynamic>>(future:future,onRetry:_reload,builder:(data) {
      final safe=Map<String,dynamic>.from(data['safe'] as Map);
      final shifts=(data['shifts'] as List<dynamic>)
        .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
      final drops=(data['drops'] as List<dynamic>)
        .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
      final myOpen=shifts.where((x)=>
        x['user_id']==widget.userId && x['closed_at']==null &&
        x['drawer_id']!=null).toList();
      return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        const SizedBox(height:18),
        Row(children:[
          Expanded(child:Text('الخزينة النقدية الرئيسية',
            style:Theme.of(context).textTheme.titleLarge)),
          IconButton(onPressed:busy?null:_reload,
            tooltip:'تحديث الخزينة',icon:const Icon(Icons.refresh)),
        ]),
        if(safe['registered']!=true) ...[
          const Text('لم تُسجّل خزينة نقدية لهذا الفرع. '
            'تأكد أولًا من تفعيل الأدراج المستقلة.'),
          if(supervisor) OutlinedButton.icon(
            onPressed:busy?null:_createSafe,
            icon:const Icon(Icons.account_balance_outlined),
            label:const Text('إنشاء خزينة الفرع')),
        ] else ...[
          Text('${safe['name']} — الرصيد المتوقع '
            '${money(asInt(safe['balance_minor']))}',
            style:const TextStyle(fontWeight:FontWeight.bold)),
          const Text('الرصيد المعروض هو مجموع تسليمات العهدة المعتمدة '
            'وليس كشف حساب بنكي أو جردًا فعليًا للخزينة.'),
          const SizedBox(height:8),
          if(myOpen.isNotEmpty)
            OutlinedButton.icon(
              onPressed:busy?null:()=>_request(myOpen.first),
              icon:const Icon(Icons.savings_outlined),
              label:const Text('تسليم جزء من عهدتي للخزينة')),
          const SizedBox(height:8),
          for(final drop in drops.take(100)) Card(
            child:Padding(padding:const EdgeInsets.all(12),
              child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                Text('${money(asInt(drop['amount_minor']))} '
                  '— ${drop['drawer_name']} — ${drop['status']}',
                  style:const TextStyle(fontWeight:FontWeight.w600)),
                Text('مقدم الطلب: ${drop['sender_name']} '
                  '— ${drop['requested_at']}'),
                Text('السبب: ${drop['reason']}'),
                if(drop['review_reason']!=null)
                  Text('تعليق المراجع: ${drop['review_reason']}'),
                if(drop['status']=='pending') Wrap(spacing:8,children:[
                  if(supervisor && drop['requested_by']!=widget.userId) ...[
                    FilledButton(onPressed:busy?null:
                      ()=>_review(drop,'approve'),
                      child:const Text('اعتماد استلام الخزينة')),
                    OutlinedButton(onPressed:busy?null:
                      ()=>_review(drop,'reject'),
                      child:const Text('رفض')),
                  ],
                  if(drop['requested_by']==widget.userId)
                    TextButton(onPressed:busy?null:
                      ()=>_review(drop,'cancel'),
                      child:const Text('إلغاء الطلب')),
                ]),
              ])),
          ),
          if(drops.isEmpty)const Text('لا توجد تسليمات نقدية مسجلة'),
        ],
      ]);
    });
}
