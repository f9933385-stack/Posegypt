import 'package:flutter/material.dart';
import '../models/formats.dart';
import '../services/api.dart';
import '../widgets/common.dart';

/// Sender proposes movement of already-held banknotes; the cashier at the
/// destination independently confirms receipt. No new cash journal is posted.
class CashTransfersSection extends StatefulWidget {
  final ApiClient api;
  final String branchId,userId,role;
  final VoidCallback onChanged;
  const CashTransfersSection({super.key,required this.api,
    required this.branchId,required this.userId,required this.role,
    required this.onChanged});

  @override State<CashTransfersSection> createState()=>_CashTransfersSectionState();
}

class _CashTransfersSectionState extends State<CashTransfersSection> {
  late Future<Map<String,dynamic>> data;
  bool busy=false;
  bool get supervisor=>widget.role=='owner'||widget.role=='manager';
  Map<String,String> get query=>{'branch_id':widget.branchId};

  @override void initState(){super.initState();_reload();}
  Future<Map<String,dynamic>> _load() async {
    final drawers=await widget.api.list('shifts/drawers',query);
    final shifts=await widget.api.list('shifts',query);
    final transfers=await widget.api.list('shifts/transfers',query);
    return {'drawers':drawers,'shifts':shifts,'transfers':transfers};
  }

  void _reload(){
    if(mounted)setState(()=>data=_load());
  }

  Future<void> _post(String path,Map<String,dynamic> body) async {
    if(busy)return;
    setState(()=>busy=true);
    try {
      await widget.api.post(path,body);
      if(!mounted)return;
      alert(context,'تم تسجيل العملية بنجاح');
      _reload();
      widget.onChanged();
    }catch(e) {
      if(mounted)alert(context,'فشلت العملية: $e',error:true);
    }finally{
      if(mounted)setState(()=>busy=false);
    }
  }

  Future<void> _newTransfer(Map<String,dynamic> source,
      List<Map<String,dynamic>> destinations) async {
    if(destinations.isEmpty || busy)return;
    final amount=TextEditingController();
    final reason=TextEditingController();
    String selected=destinations.first['open_shift_id'].toString();
    String? error;
    try {
      final payload=await showDialog<Map<String,dynamic>>(
        context:context,builder:(ctx)=>StatefulBuilder(
          builder:(ctx,update)=>AlertDialog(
            title:const Text('طلب نقل نقدية بين درجين'),
            content:SizedBox(width:530,child:Column(
              mainAxisSize:MainAxisSize.min,children:[
                const Text('سيظل المبلغ في عهدتك حتى يعتمد الموظف '
                  'المستلم الاستلام من حسابه. لا ينشئ هذا الطلب قيدًا ماليًا جديدًا.'),
                const SizedBox(height:12),
                DropdownButtonFormField<String>(
                  value:selected,isExpanded:true,
                  decoration:const InputDecoration(labelText:'درج المستلم'),
                  items:[for(final d in destinations)
                    DropdownMenuItem<String>(
                      value:d['open_shift_id'].toString(),
                      child:Text(d['name'].toString()))],
                  onChanged:(value){
                    if(value!=null)update(()=>selected=value);
                  }),
                const SizedBox(height:10),
                TextField(controller:amount,
                  keyboardType:const TextInputType.numberWithOptions(decimal:true),
                  decoration:const InputDecoration(
                    labelText:'المبلغ بالجنيه',border:OutlineInputBorder())),
                const SizedBox(height:10),
                TextField(controller:reason,maxLines:2,
                  decoration:const InputDecoration(
                    labelText:'سبب النقل والمستند الداخلي',
                    border:OutlineInputBorder())),
                if(error!=null) Padding(padding:const EdgeInsets.only(top:8),
                  child:Text(error!,style:TextStyle(
                    color:Theme.of(ctx).colorScheme.error))),
              ])),
            actions:[
              TextButton(onPressed:()=>Navigator.pop(ctx),
                child:const Text('إلغاء')),
              FilledButton(onPressed:(){
                try {
                  final value=parseMoney(amount.text);
                  if(value<=0) {
                    throw const FormatException('المبلغ يجب أن يكون أكبر من صفر');
                  }
                  if(reason.text.trim().length<12) {
                    throw const FormatException('اكتب سبب النقل في 12 حرفًا على الأقل');
                  }
                  Navigator.pop(ctx,{
                    'branch_id':widget.branchId,
                    'source_shift_id':source['id'],
                    'destination_shift_id':selected,
                    'amount_minor':value,'reason':reason.text.trim(),
                  });
                }catch(e){update(()=>error=e.toString());}
              },child:const Text('إرسال طلب النقل')),
            ],
          )));
      if(payload==null || !mounted)return;
      await _post('shifts/transfers',payload);
    }finally{
      amount.dispose();
      reason.dispose();
    }
  }

  Future<void> _review(Map<String,dynamic> transfer,String action) async {
    if(busy)return;
    final note=TextEditingController();
    try {
      final reason=await showDialog<String>(context:context,builder:(ctx)=>
        AlertDialog(
          title:Text(action=='approve'?'اعتماد استلام النقدية':
            action=='cancel'?'إلغاء طلب النقل':'رفض استلام النقدية'),
          content:SizedBox(width:470,child:Column(
            mainAxisSize:MainAxisSize.min,children:[
              Text('القيمة: ${money(asInt(transfer['amount_minor']))} '
                '— من ${transfer['source_drawer_name']} '
                'إلى ${transfer['destination_drawer_name']}'),
              const SizedBox(height:8),
              const Text('اعتمد الاستلام فقط بعد العد الفعلي للمبلغ. '
                'لا تتغير عهدة الأدراج إلا عند الاعتماد.'),
              const SizedBox(height:12),
              TextField(controller:note,maxLines:2,
                decoration:const InputDecoration(
                  labelText:'سبب القرار أو مرجع استلام النقدية')),
            ])),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),
              child:const Text('تراجع')),
            FilledButton(onPressed:(){
              if(note.text.trim().length<12){
                alert(ctx,'اكتب سببًا موثقًا من 12 حرفًا على الأقل',error:true);
                return;
              }
              Navigator.pop(ctx,note.text.trim());
            },child:Text(action=='approve'?'تأكيد الاستلام':
              action=='cancel'?'إلغاء الطلب':'رفض الاستلام')),
          ],
        ));
      if(reason==null || !mounted)return;
      await _post('shifts/transfers/$action',{
        'transfer_id':transfer['id'],'reason':reason});
    }finally{note.dispose();}
  }

  @override Widget build(BuildContext context)=>
    AsyncPanel<Map<String,dynamic>>(
      future:data,onRetry:_reload,builder:(raw){
        final drawers=(raw['drawers'] as List<dynamic>)
          .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
        final shifts=(raw['shifts'] as List<dynamic>)
          .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
        final transfers=(raw['transfers'] as List<dynamic>)
          .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
        if(drawers.isEmpty)return const SizedBox.shrink();
        final own=shifts.where((x)=>
          x['user_id']==widget.userId && x['closed_at']==null &&
          x['drawer_id']!=null).toList();
        final source=own.isEmpty?null:own.first;
        final destinations=drawers.where((x)=>
          x['open_shift_id']!=null &&
          (source==null || x['open_shift_id']!=source['id']) &&
          x['active']==1).toList();
        final outstanding=transfers.where((x)=>x['status']=='pending').toList();
        return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          const SizedBox(height:20),
          Row(children:[
            Expanded(child:Text('نقل النقدية بين الأدراج',
              style:Theme.of(context).textTheme.titleLarge)),
            IconButton(onPressed:busy?null:_reload,
              tooltip:'تحديث التحويلات',icon:const Icon(Icons.refresh)),
          ]),
          const Text('يطلب الموظف المرسل النقل، ويعتمد الموظف المستلم '
            'الاستلام من حسابه بعد عدّ النقدية.'),
          const SizedBox(height:8),
          if(source!=null && destinations.isNotEmpty)
            OutlinedButton.icon(
              onPressed:busy?null:()=>_newTransfer(source,destinations),
              icon:const Icon(Icons.compare_arrows),
              label:const Text('إنشاء طلب نقل من درجك'))
          else const Text('لفتح طلب جديد تحتاج إلى وردية درج مفتوحة '
            'ودرْج آخر مفتوح لموظف مختلف.'),
          if(outstanding.isNotEmpty) ...[
            const SizedBox(height:8),
            Text('طلبات قيد المراجعة: ${outstanding.length}',
              style:const TextStyle(fontWeight:FontWeight.w600)),
          ],
          for(final transfer in transfers.take(100)) Card(
            child:Padding(padding:const EdgeInsets.all(10),
              child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                Text('${money(asInt(transfer['amount_minor']))} — '
                  '${transfer['source_drawer_name']} ← '
                  '${transfer['destination_drawer_name']}',
                  style:const TextStyle(fontWeight:FontWeight.w600)),
                const SizedBox(height:4),
                Text('الحالة: ${transfer['status']} '
                  '— ${transfer['requested_at']}'),
                Text('السبب: ${transfer['reason']}'),
                if(transfer['review_reason']!=null)
                  Text('سبب القرار: ${transfer['review_reason']}'),
                if(transfer['status']=='pending') Wrap(spacing:8,children:[
                  if(transfer['destination_user_id']==widget.userId) ...[
                    FilledButton(onPressed:busy?null:
                      ()=>_review(transfer,'approve'),
                      child:const Text('اعتماد استلام النقدية')),
                    OutlinedButton(onPressed:busy?null:
                      ()=>_review(transfer,'reject'),
                      child:const Text('رفض')),
                  ],
                  if(transfer['source_user_id']==widget.userId)
                    TextButton(onPressed:busy?null:
                      ()=>_review(transfer,'cancel'),
                      child:const Text('إلغاء الطلب')),
                ]),
              ])),
          ),
          if(transfers.isEmpty)const Text('لا توجد تحويلات عهدة مسجلة'),
        ]);
      });
}
