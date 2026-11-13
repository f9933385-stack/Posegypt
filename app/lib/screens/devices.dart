import 'package:flutter/material.dart';
import '../services/api.dart';
import '../widgets/common.dart';

/// Manager issues short-lived pairing codes. Never displays persistent secrets.
class DevicesPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const DevicesPage({super.key,required this.api,required this.branchId});
  @override State<DevicesPage> createState()=>_DevicesState();
}

class _DevicesState extends State<DevicesPage> {
  late Future<List<Map<String,dynamic>>> devices;
  bool busy=false;
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(()=>devices=widget.api.list('devices',
    {'branch_id':widget.branchId}));

  Future<void> _issue() async {
    setState(()=>busy=true);
    try {
      final result=await widget.api.post('devices/pairings',
        {'branch_id':widget.branchId},idempotent:false);
      if(!mounted)return;
      final code=result['pairing_code'] as String;
      final expires=result['expires_at'] as String;
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('رمز إقران مؤقت لجهاز جديد'),
        content:SizedBox(width:450,child:Column(mainAxisSize:MainAxisSize.min,children:[
          const Text('اكتب الرمز على الجهاز الجديد داخل شاشة تسجيل الدخول. يُستخدم مرة واحدة خلال 10 دقائق. لا تشاركه خارج المتجر.'),
          const SizedBox(height:14),
          SelectableText(code,textDirection:TextDirection.ltr,
            style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),
          const SizedBox(height:12),
          Text('تنتهي الصلاحية (UTC): '+expires),
        ])),
        actions:[FilledButton(onPressed:()=>Navigator.pop(ctx),
          child:const Text('إغلاق'))],
      ));
      if(mounted)_reload();
    }catch(e){if(mounted)alert(context,'تعذر إنشاء رمز الإقران: $e',error:true);}
    finally{if(mounted)setState(()=>busy=false);}
  }

  Future<void> _revoke(Map<String,dynamic> device) async {
    final reason=TextEditingController();
    try {
      final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('إلغاء صلاحية جهاز'),
        content:SizedBox(width:440,child:Column(mainAxisSize:MainAxisSize.min,children:[
          Text('الجهاز: '+device['name'].toString()),
          const SizedBox(height:10),
          const Text('سيُمنع تسجيل الدخول بهذا الجهاز وستُحذف جلساته الحالية من الخادم فورًا.'),
          const SizedBox(height:12),
          TextField(controller:reason,maxLength:200,
            decoration:const InputDecoration(labelText:'سبب إلغاء الجهاز')),
        ])),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx,false),
            child:const Text('رجوع')),
          FilledButton(onPressed:(){
            if(reason.text.trim().isEmpty){alert(ctx,'اكتب السبب',error:true);return;}
            Navigator.pop(ctx,true);
          },child:const Text('إلغاء صلاحية الجهاز')),
        ],
      ));
      if(confirmed!=true)return;
      setState(()=>busy=true);
      await widget.api.post('devices/revoke',{'device_id':device['id'],
        'reason':reason.text.trim()},idempotent:false);
      if(mounted){alert(context,'تم إلغاء صلاحية الجهاز وجلساته');_reload();}
    }catch(e){if(mounted)alert(context,'فشل إلغاء الجهاز: $e',error:true);}
    finally{reason.dispose();if(mounted)setState(()=>busy=false);}
  }

  @override Widget build(BuildContext context)=>Column(children:[
    SectionTitle('أجهزة الكاشير المصرّح لها',
      subtitle:'ربط الأجهزة برمز مؤقت وإيقاف الأجهزة المفقودة أو غير المصرّح بها.',
      action:FilledButton.icon(onPressed:busy?null:_issue,
        icon:const Icon(Icons.add_link),label:const Text('رمز إقران جديد'))),
    Expanded(child:AsyncPanel<List<Map<String,dynamic>>>(
      future:devices,onRetry:_reload,builder:(list)=>ListView(children:[
        if(list.isEmpty)const EmptyState('لا توجد أجهزة مسجلة بهذا الفرع'),
        for(final item in list)Card(child:ListTile(
          leading:Icon(item['active']==1?Icons.devices:Icons.phonelink_off_outlined),
          title:Text(item['name'].toString()),
          subtitle:Text('أضيف: '+item['created_at'].toString()+
            (item['revoked_at']==null?'':'\nأوقف: '+item['revoked_at'].toString())),
          isThreeLine:item['revoked_at']!=null,
          trailing:item['active']==1
            ?IconButton(onPressed:busy?null:()=>_revoke(item),
              tooltip:'إلغاء صلاحية الجهاز',icon:const Icon(Icons.block))
            :const Text('موقوف'),
        )),
      ]))),
  ]);
}
