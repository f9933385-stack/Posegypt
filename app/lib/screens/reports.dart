import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class ReportsPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const ReportsPage({super.key,required this.api,required this.branchId});
  @override State<ReportsPage> createState()=>_ReportsState();
}
class _ReportsState extends State<ReportsPage> {
  late Future<List<Map<String,dynamic>>> documents;
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(()=>documents=widget.api.list('documents',{'branch_id':widget.branchId}));
  Future<void> _details(Map<String,dynamic> doc) async {
    try {
      final full=await widget.api.get('documents/${doc['id']}');
      if(!mounted)return;
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:Text('${full['number']}'),
        content:SizedBox(width:530,child:SingleChildScrollView(child:Column(
          mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('النوع: ${full['kind']}'),Text('التاريخ: ${full['created_at']}'),
          Text('الإجمالي: ${money(asInt(full['total_minor']))}'),
          const Divider(),
          for(final l in (full['lines'] as List))ListTile(
            title:Text('${l['name_ar']}'),subtitle:Text('كمية ${quantity(asInt(l['qty_milli']))}'),
            trailing:Text(money(asInt(l['unit_price_minor'])))),
          const Divider(),const Text('الفاتورة داخلية وليست مستندًا ضريبيًا إلكترونيًا معتمدًا.',
            style:TextStyle(fontSize:11)),
        ]))),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق'))]));
    }catch(e){if(mounted)alert(context,'تعذر عرض المستند: $e',error:true);}
  }
  @override Widget build(BuildContext context)=>Column(children:[
    SectionTitle('الفواتير والتقارير',subtitle:'مستندات معتمدة وغير قابلة للحذف من شاشة المستخدم.',
      action:IconButton(onPressed:_reload,icon:const Icon(Icons.refresh))),
    Expanded(child:AsyncPanel<List<Map<String,dynamic>>>(future:documents,onRetry:_reload,
      builder:(list)=>list.isEmpty?const EmptyState('لا توجد فواتير بعد'):
        ListView.builder(itemCount:list.length,itemBuilder:(context,i){final d=list[i];return Card(child:ListTile(
          leading:Icon(d['kind']=='sale'?Icons.point_of_sale:Icons.receipt_outlined),
          title:Text(d['number'].toString()),subtitle:Text('${d['kind']} • ${d['created_at']}'),
          trailing:Text(money(asInt(d['total_minor'])),style:const TextStyle(fontWeight:FontWeight.bold)),
          onTap:()=>_details(d)));}))),
  ]);
}
