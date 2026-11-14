import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class PartyPage extends StatefulWidget {
  final ApiClient api;
  final bool customer;
  const PartyPage({super.key,required this.api,required this.customer});
  @override State<PartyPage> createState()=>_PartyState();
}
class _PartyState extends State<PartyPage> {
  late Future<List<Map<String,dynamic>>> future;
  String get endpoint=>widget.customer?'customers':'suppliers';
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(()=>future=widget.api.list(endpoint));
  Future<void> _new() async {
    final name=TextEditingController(),phone=TextEditingController(),credit=TextEditingController(text:'0');
    final result=await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>AlertDialog(
      title:Text(widget.customer?'عميل جديد':'مورد جديد'),content:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:name,decoration:const InputDecoration(labelText:'الاسم')),
        const SizedBox(height:8),TextField(controller:phone,decoration:const InputDecoration(labelText:'الهاتف (اختياري)')),
        if(widget.customer) ...[const SizedBox(height:8),TextField(controller:credit,
          decoration:const InputDecoration(labelText:'حد الائتمان بالجنيه'))],
      ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
        FilledButton(onPressed:(){try{Navigator.pop(ctx,{'name':name.text,'phone':phone.text,
          if(widget.customer)'credit_limit_minor':parseMoney(credit.text)});}
          catch(_){alert(ctx,'خطأ في الحد الائتماني',error:true);}},child:const Text('حفظ'))]));
    name.dispose();phone.dispose();credit.dispose();
    if(result==null)return;
    try{await widget.api.post(endpoint,result);if(mounted){alert(context,'تم الحفظ');_reload();}}
    catch(e){if(mounted)alert(context,'لم يتم الحفظ: $e',error:true);}
  }
  @override Widget build(BuildContext context)=>Column(children:[
    SectionTitle(widget.customer?'العملاء':'الموردون',
      subtitle:widget.customer?'حد ائتماني لكل عميل وسجل موحّد للحسابات.':'الموردون وفواتير الشراء والمديونيات.',
      action:FilledButton.icon(onPressed:_new,icon:const Icon(Icons.add),label:const Text('إضافة'))),
    Expanded(child:AsyncPanel<List<Map<String,dynamic>>>(future:future,onRetry:_reload,
      builder:(list)=>list.isEmpty?const EmptyState('لا توجد بيانات بعد'):
        ListView.builder(itemCount:list.length,itemBuilder:(context,i){final p=list[i];return Card(child:ListTile(
          leading:CircleAvatar(child:Icon(widget.customer?Icons.person_outline:Icons.local_shipping_outlined)),
          title:Text(p['name'].toString()),subtitle:Text(p['phone']?.toString() ?? '—'),
          trailing:widget.customer?Text('الحد: ${money(asInt(p['credit_limit_minor']))}'):null));}))),
  ]);
}
