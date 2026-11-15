import 'package:flutter/material.dart';
import '../models/formats.dart';
import '../services/api.dart';
import '../widgets/common.dart';

/// Human-reviewed reallocation of an ALREADY POSTED payment. No cash is
/// collected here. A second, different manager must approve each proposal.
class DebtReconciliationDialog extends StatefulWidget {
  final ApiClient api;
  final String branchId, partyId;
  final bool customer;
  const DebtReconciliationDialog({super.key,required this.api,
    required this.branchId,required this.partyId,required this.customer});

  @override State<DebtReconciliationDialog> createState()=>
    _DebtReconciliationDialogState();
}

class _DebtReconciliationDialogState extends State<DebtReconciliationDialog> {
  late Future<Map<String,dynamic>> future;
  bool busy=false;

  Map<String,String> get query=>{
    'branch_id':widget.branchId,'party_id':widget.partyId,
    'party_type':widget.customer?'customer':'supplier'};

  @override void initState(){super.initState();future=_load();}
  Future<Map<String,dynamic>> _load() async {
    final payments=await widget.api.list('debts/unallocated',query);
    final requests=await widget.api.list('debts/reconciliations',query);
    final open=await widget.api.get('debts/invoices',query);
    return {'payments':payments,'requests':requests,
      'invoices':open['invoices'] as List<dynamic>};
  }
  void _reload(){if(mounted)setState(()=>future=_load());}

  Future<void> _request(Map<String,dynamic> payment,
      List<Map<String,dynamic>> invoices) async {
    if(busy)return;
    final remaining=invoices.take(20).toList();
    if(remaining.isEmpty){alert(context,'لا توجد فواتير مستحقة للمطابقة',error:true);return;}
    final inputs=[for(final _ in remaining)TextEditingController()];
    final reason=TextEditingController();
    String? failure;
    try {
      final proposal=await showDialog<Map<String,dynamic>>(context:context,
        builder:(context)=>StatefulBuilder(builder:(ctx,rebuild)=>AlertDialog(
          title:const Text('اقتراح مطابقة دفعة قديمة'),
          content:SizedBox(width:600,height:480,child:Column(children:[
            Text('الدفعة الأصلية: ${money(asInt(payment['amount_minor']))} '
              '— ${payment['method']}، ${payment['created_at']}'),
            const SizedBox(height:8),
            const Text('هذه العملية لا تحصل أموالًا مرة أخرى. أدخل توزيع '
              'الدفعة الأصلية بالكامل، وسيُطلب اعتماد مدير آخر.'),
            if(failure!=null) Padding(padding:const EdgeInsets.all(8),
              child:Text(failure!,style:TextStyle(
                color:Theme.of(ctx).colorScheme.error))),
            const SizedBox(height:8),
            Expanded(child:ListView.builder(itemCount:remaining.length,
              itemBuilder:(context,i)=>Padding(
                padding:const EdgeInsets.symmetric(vertical:5),
                child:TextField(controller:inputs[i],
                  keyboardType:const TextInputType.numberWithOptions(decimal:true),
                  decoration:InputDecoration(
                    border:const OutlineInputBorder(),
                    labelText:'${remaining[i]['number']}',
                    helperText:'متبقي الفاتورة: '
                      '${money(asInt(remaining[i]['remaining_minor']))}'))))),
            TextField(controller:reason,maxLines:2,
              decoration:const InputDecoration(
                labelText:'سبب المطابقة والمرجع المستندي (إلزامي)')),
          ])),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),
              child:const Text('إلغاء')),
            FilledButton(onPressed:(){
              try{
                if(reason.text.trim().length<12){
                  throw const FormatException('اكتب سببًا موثقًا من 12 حرفًا على الأقل');
                }
                final allocations=<Map<String,dynamic>>[];
                var total=0;
                for(var i=0;i<remaining.length;i++){
                  final raw=inputs[i].text.trim();
                  if(raw.isEmpty)continue;
                  final value=parseMoney(raw);
                  if(value<=0 ||
                      value>asInt(remaining[i]['remaining_minor'])){
                    throw const FormatException('يوجد مبلغ يتجاوز مستحق الفاتورة');
                  }
                  total+=value;
                  allocations.add({'invoice_id':remaining[i]['id'],
                    'amount_minor':value});
                }
                if(allocations.isEmpty ||
                    total!=asInt(payment['amount_minor'])){
                  throw const FormatException(
                    'مجموع مبالغ الفواتير لازم يساوي قيمة الدفعة القديمة بالكامل');
                }
                Navigator.pop(ctx,{
                  'branch_id':widget.branchId,'party_type':query['party_type'],
                  'party_id':widget.partyId,'payment_id':payment['id'],
                  'reason':reason.text.trim(),'allocations':allocations});
              }catch(e){rebuild(()=>failure=e.toString());}
            },child:const Text('إرسال للمراجعة')),
          ],
        )));
      if(proposal==null || !mounted)return;
      setState(()=>busy=true);
      try {
        await widget.api.post('debts/reconciliations',proposal);
        if(mounted){alert(context,'اتسجل طلب المطابقة، ويحتاج مديرًا آخر لاعتماده');_reload();}
      }catch(e){if(mounted)alert(context,'تعذر تقديم المطابقة: $e',error:true);}
      finally{if(mounted)setState(()=>busy=false);}
    }finally{
      for(final input in inputs){input.dispose();}
      reason.dispose();
    }
  }

  Future<void> _review(Map<String,dynamic> request,{required bool approve}) async {
    if(busy)return;
    final reason=TextEditingController();
    try {
      final reviewReason=await showDialog<String>(context:context,
        builder:(ctx)=>AlertDialog(
          title:Text(approve?'اعتماد مطابقة قائمة':'رفض طلب المطابقة'),
          content:Column(mainAxisSize:MainAxisSize.min,children:[
            Text('هذه ليست حركة نقدية جديدة. الطلب: ${request['id']}'),
            const SizedBox(height:8),
            Text('قيمة الدفعة: ${money(asInt(request['amount_minor']))}'),
            const SizedBox(height:8),
            TextField(controller:reason,maxLines:3,
              decoration:const InputDecoration(
                labelText:'سبب المراجعة (12 حرفًا على الأقل)')),
          ]),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),
              child:const Text('إلغاء')),
            FilledButton(onPressed:(){
              if(reason.text.trim().length<12){
                alert(ctx,'اكتب سببًا واضحًا للمراجعة',error:true);return;
              }
              Navigator.pop(ctx,reason.text.trim());
            },child:Text(approve?'تأكيد الاعتماد':'تأكيد الرفض')),
          ],
        ));
      if(reviewReason==null || !mounted)return;
      setState(()=>busy=true);
      try{
        await widget.api.post(
          'debts/reconciliations/${approve?'approve':'reject'}',{
            'reconciliation_id':request['id'],'reason':reviewReason});
        if(mounted){alert(context,approve?'تم اعتماد المطابقة':'تم رفض الطلب');_reload();}
      }catch(e){if(mounted)alert(context,'تعذرت مراجعة المطابقة: $e',error:true);}
      finally{if(mounted)setState(()=>busy=false);}
    }finally{reason.dispose();}
  }

  @override Widget build(BuildContext context)=>AlertDialog(
    title:const Text('مطابقة الدفعات القديمة — بموافقة مديرين'),
    content:SizedBox(width:760,height:550,child:FutureBuilder<Map<String,dynamic>>(
      future:future,builder:(ctx,snapshot){
        if(snapshot.hasError)return Column(mainAxisSize:MainAxisSize.min,children:[
          Text('تعذر تحميل المطابقة: ${snapshot.error}'),
          OutlinedButton(onPressed:_reload,child:const Text('إعادة المحاولة')),
        ]);
        if(!snapshot.hasData)return const Center(child:CircularProgressIndicator());
        final data=snapshot.data!;
        final payments=(data['payments'] as List<dynamic>)
          .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
        final requests=(data['requests'] as List<dynamic>)
          .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
        final invoices=(data['invoices'] as List<dynamic>)
          .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
        return ListView(children:[
          const Text('الدفعات غير الموزعة على فواتير',
            style:TextStyle(fontWeight:FontWeight.bold)),
          const SizedBox(height:6),
          if(payments.isEmpty)const Text('لا توجد دفعات قديمة بحاجة إلى مطابقة'),
          for(final payment in payments) Card(child:ListTile(
            title:Text('${money(asInt(payment['amount_minor']))} '
              '— ${payment['method']}'),
            subtitle:Text('${payment['created_at']} '
              '${payment['pending_request_id']!=null?'— قيد المراجعة':''}'),
            trailing:TextButton(
              onPressed:busy || payment['pending_request_id']!=null
                ?null:()=>_request(payment,invoices),
              child:const Text('إعداد المطابقة')),
          )),
          const Divider(),
          const Text('طلبات المطابقة وسجل اعتمادها',
            style:TextStyle(fontWeight:FontWeight.bold)),
          const SizedBox(height:6),
          if(requests.isEmpty)const Text('لا توجد طلبات مراجعة'),
          for(final request in requests) Card(child:Column(children:[
            ListTile(
              title:Text('${money(asInt(request['amount_minor']))} '
                '— ${request['status']}'),
              subtitle:Text('صاحب الطلب: ${request['requester_name']} '
                '— ${request['reason']}')),
            for(final line in (request['allocations'] as List<dynamic>))
              Padding(padding:const EdgeInsets.symmetric(
                horizontal:20,vertical:2),
                child:Align(alignment:Alignment.centerRight,
                  child:Text('${(line as Map)['invoice_number']} — '
                    '${money(asInt(line['amount_minor']))}'))),
            if(request['status']=='pending') Padding(
              padding:const EdgeInsets.all(8),
              child:Wrap(spacing:8,children:[
                OutlinedButton(onPressed:busy?null:
                  ()=>_review(request,approve:false),
                  child:const Text('رفض')),
                FilledButton(onPressed:busy?null:
                  ()=>_review(request,approve:true),
                  child:const Text('اعتماد من مدير آخر')),
              ])),
          ])),
        ]);
      },
    )),
    actions:[
      TextButton(onPressed:_reload,child:const Text('تحديث')),
      TextButton(onPressed:()=>Navigator.pop(context),
        child:const Text('إغلاق')),
    ],
  );
}
