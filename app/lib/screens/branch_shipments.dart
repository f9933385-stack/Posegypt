import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

/// Two-phase branch transfer on a shared local branch database.
/// This is not cloud sync for independently hosted stores.
class BranchShipmentsPage extends StatefulWidget {
  final ApiClient api;
  final String branchId, role;
  const BranchShipmentsPage({super.key,required this.api,
    required this.branchId,required this.role});
  @override State<BranchShipmentsPage> createState()=>_BranchShipmentsState();
}

class _BranchShipmentsState extends State<BranchShipmentsPage> {
  late Future<List<Map<String,dynamic>>> shipments;
  bool busy=false;
  bool get canManage=>widget.role=='owner'||widget.role=='manager';
  @override void initState(){super.initState();_refresh();}
  void _refresh()=>setState(()=>shipments=widget.api.list('branch-shipments',
    {'branch_id':widget.branchId}));

  Future<void> _dispatch() async {
    if(widget.role!='owner')return;
    try {
      final branches=await widget.api.list('branches');
      final products=await widget.api.list('products');
      if(!mounted)return;
      if(branches.length<2 || products.isEmpty){
        alert(context,'يلزم وجود فرعين وصنف واحد على الأقل',error:true);return;
      }
      var source=branches.any((x)=>x['id']==widget.branchId)
        ?widget.branchId:branches.first['id'].toString();
      var dest=branches.firstWhere((x)=>x['id']!=source)['id'].toString();
      final first=await showDialog<List<String>>(context:context,builder:(ctx)=>
        StatefulBuilder(builder:(ctx,change)=>AlertDialog(
          title:const Text('اختيار فرعي الإرسال والاستلام'),
          content:SizedBox(width:500,child:Column(mainAxisSize:MainAxisSize.min,children:[
            DropdownButtonFormField<String>(isExpanded:true,
              initialValue:source,
              decoration:const InputDecoration(labelText:'الفرع المرسل'),
              items:branches.map((x)=>DropdownMenuItem<String>(
                value:x['id'].toString(),child:Text(x['name'].toString()))).toList(),
              onChanged:(v)=>change((){
                if(v!=null){
                  source=v;
                  if(source==dest)dest=branches.firstWhere((x)=>x['id']!=source)['id'].toString();
                }
              })),
            const SizedBox(height:14),
            DropdownButtonFormField<String>(isExpanded:true,
              key:ValueKey(source),
              initialValue:dest,
              decoration:const InputDecoration(labelText:'الفرع المستلم'),
              items:branches.where((x)=>x['id']!=source).map((x)=>
                DropdownMenuItem<String>(
                  value:x['id'].toString(),child:Text(x['name'].toString()))).toList(),
              onChanged:(v)=>change((){if(v!=null)dest=v;})),
          ])),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
            FilledButton(onPressed:()=>Navigator.pop(ctx,[source,dest]),
              child:const Text('التالي')),
          ],
        )));
      if(first==null)return;
      final from=await widget.api.list('warehouses',{'branch_id':first[0]});
      final to=await widget.api.list('warehouses',{'branch_id':first[1]});
      if(!mounted)return;
      if(from.isEmpty || to.isEmpty) {
        alert(context,'الفرع المختار ليس لديه مخزن متاح',error:true);return;
      }
      String origin=from.first['id'].toString();
      String destination=to.first['id'].toString();
      String product=products.first['id'].toString();
      final qty=TextEditingController();
      try {
        final request=await showDialog<Map<String,dynamic>>(context:context,
          builder:(ctx)=>StatefulBuilder(builder:(ctx,change)=>AlertDialog(
          title:const Text('إرسال شحنة بين الفرعين'),
          content:SizedBox(width:520,child:SingleChildScrollView(child:Column(
            mainAxisSize:MainAxisSize.min,children:[
              const Text('الشحنة تُخصم من المصدر وتظل بالطريق حتى يعتمد موظف آخر استلامها.'),
              const SizedBox(height:14),
              DropdownButtonFormField<String>(initialValue:origin,isExpanded:true,
                decoration:const InputDecoration(labelText:'مخزن الإرسال'),
                items:from.map((x)=>DropdownMenuItem<String>(
                  value:x['id'].toString(),child:Text(x['name'].toString()))).toList(),
                onChanged:(v)=>change((){if(v!=null)origin=v;})),
              const SizedBox(height:12),
              DropdownButtonFormField<String>(initialValue:destination,isExpanded:true,
                decoration:const InputDecoration(labelText:'مخزن الاستلام'),
                items:to.map((x)=>DropdownMenuItem<String>(
                  value:x['id'].toString(),child:Text(x['name'].toString()))).toList(),
                onChanged:(v)=>change((){if(v!=null)destination=v;})),
              const SizedBox(height:12),
              DropdownButtonFormField<String>(initialValue:product,isExpanded:true,
                decoration:const InputDecoration(labelText:'الصنف'),
                items:products.map((x)=>DropdownMenuItem<String>(
                  value:x['id'].toString(),child:Text(x['name_ar'].toString()))).toList(),
                onChanged:(v)=>change((){if(v!=null)product=v;})),
              const SizedBox(height:12),
              TextField(controller:qty,keyboardType:TextInputType.number,
                decoration:const InputDecoration(labelText:'كمية الإرسال بوحدة الصنف الأساسية')),
            ]))),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
            FilledButton(onPressed:(){
              try {
                final q=parseQty(qty.text);
                if(q<=0)throw const FormatException();
                Navigator.pop(ctx,{'source_branch_id':first[0],
                  'destination_branch_id':first[1],
                  'source_warehouse_id':origin,
                  'destination_warehouse_id':destination,
                  'product_id':product,'qty_milli':q});
              }catch(_){alert(ctx,'كمية الإرسال غير صالحة',error:true);}
            },child:const Text('تأكيد الإرسال')),
          ],
        )));
        if(request==null)return;
        setState(()=>busy=true);
        await widget.api.post('branch-shipments/dispatch',request);
        if(mounted){alert(context,'تم إرسال الشحنة وتسجيل قيمتها بالطريق');_refresh();}
      }finally{qty.dispose();}
    }catch(e){if(mounted)alert(context,'تعذر إرسال الشحنة: '+e.toString(),error:true);}
    finally{if(mounted)setState(()=>busy=false);}
  }

  Future<void> _receive(Map<String,dynamic> shipment) async {
    final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('اعتماد استلام شحنة'),
      content:Text('هل وصلت كمية '+quantity(asInt(shipment['qty_milli']))+
        ' من '+shipment['product_name'].toString()+
        '؟ الاستلام يضيف المخزون للفرع المستلم ويُقفل الشحنة.'),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('اعتماد الاستلام')),
      ],
    ));
    if(confirmed!=true)return;
    setState(()=>busy=true);
    try {
      await widget.api.post('branch-shipments/receive',{'shipment_id':shipment['id']});
      if(mounted){alert(context,'تم الاستلام وتحديث مخزون الفرع');_refresh();}
    }catch(e){if(mounted)alert(context,'تعذر الاستلام: '+e.toString(),error:true);}
    finally{if(mounted)setState(()=>busy=false);}
  }

  Future<void> _cancel(Map<String,dynamic> shipment) async {
    final reason=TextEditingController();
    try {
      final accepted=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('إلغاء شحنة بالطريق'),
        content:SizedBox(width:430,child:Column(mainAxisSize:MainAxisSize.min,children:[
          const Text('يرجع المخزون وقيمته المحاسبية للفرع المرسل. لا يمكن إلغاء شحنة مستلمة.'),
          const SizedBox(height:12),
          TextField(controller:reason,maxLength:200,
            decoration:const InputDecoration(labelText:'سبب إلغاء الشحنة')),
        ])),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('رجوع')),
          FilledButton(onPressed:(){
            if(reason.text.trim().isNotEmpty)Navigator.pop(ctx,true);
          },child:const Text('تأكيد الإلغاء')),
        ],
      ));
      if(accepted!=true)return;
      setState(()=>busy=true);
      await widget.api.post('branch-shipments/cancel',{
        'shipment_id':shipment['id'],'reason':reason.text.trim()});
      if(mounted){alert(context,'تم إلغاء الشحنة وإرجاع المخزون');_refresh();}
    }catch(e){if(mounted)alert(context,'تعذر إلغاء الشحنة: '+e.toString(),error:true);}
    finally {reason.dispose();if(mounted)setState(()=>busy=false);}
  }

  Future<void> _details(Map<String,dynamic> shipment) async {
    try {
      final detail=await widget.api.get('branch-shipments/'+shipment['id'].toString());
      if(!mounted)return;
      final lots=(detail['lots'] as List).cast<Map<String,dynamic>>();
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('تفاصيل الشحنة'),
        content:SizedBox(width:450,child:Column(mainAxisSize:MainAxisSize.min,children:[
          Text('الكمية: '+quantity(asInt(shipment['qty_milli']))),
          Text('القيمة بالطريق: '+money(asInt(shipment['cost_minor']))),
          Text('الحالة: '+shipment['status'].toString()),
          const SizedBox(height:10),
          for(final lot in lots)ListTile(
            title:Text('تشغيلة: '+lot['lot_no'].toString()),
            subtitle:Text('صلاحية: '+lot['expires_on'].toString()),
            trailing:Text(quantity(asInt(lot['qty_milli'])))),
        ])),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),
          child:const Text('إغلاق'))],
      ));
    }catch(e){if(mounted)alert(context,'تعذر تحميل الشحنة: '+e.toString(),error:true);}
  }

  @override Widget build(BuildContext context)=>Column(children:[
    SectionTitle('تحويلات البضاعة بين الفروع',
      subtitle:'الإرسال والاستلام مستقلان؛ الكميات بالطريق لا تُباع قبل استلامها.',
      action:widget.role=='owner'
        ?FilledButton.icon(onPressed:busy?null:_dispatch,
          icon:const Icon(Icons.local_shipping_outlined),
          label:const Text('إرسال شحنة')):null),
    Expanded(child:AsyncPanel<List<Map<String,dynamic>>>(future:shipments,
      onRetry:_refresh,builder:(list)=>ListView(children:[
      if(list.isEmpty)const EmptyState('لا توجد شحنات مرتبطة بهذا الفرع'),
      for(final item in list)Card(child:ListTile(
        leading:Icon(item['status']=='received'?Icons.check_circle_outline:
          item['status']=='cancelled'?Icons.cancel_outlined:Icons.local_shipping_outlined),
        title:Text(item['product_name'].toString()+' • '+
          quantity(asInt(item['qty_milli']))),
        subtitle:Text(item['source_name'].toString()+' ← '+
          item['destination_name'].toString()+' • '+item['status'].toString()),
        onTap:()=>_details(item),
        trailing:Row(mainAxisSize:MainAxisSize.min,children:[
          if(canManage && item['status']=='in_transit' &&
              item['destination_branch_id']==widget.branchId)
            IconButton(onPressed:busy?null:()=>_receive(item),
              tooltip:'اعتماد الاستلام',icon:const Icon(Icons.inventory_2_outlined)),
          if(canManage && item['status']=='in_transit' &&
              item['source_branch_id']==widget.branchId)
            IconButton(onPressed:busy?null:()=>_cancel(item),
              tooltip:'إلغاء الشحنة قبل الاستلام',icon:const Icon(Icons.undo)),
        ]),
      )),
    ]))),
  ]);
}
