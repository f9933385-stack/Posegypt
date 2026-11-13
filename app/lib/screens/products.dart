import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class ProductsPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  final String role;
  const ProductsPage({super.key,required this.api,required this.branchId,
    this.role='viewer'});
  @override State<ProductsPage> createState()=>_ProductsState();
}
class _ProductsState extends State<ProductsPage> {
  late Future<List<Map<String,dynamic>>> products,stock;
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(() {
    products=widget.api.list('products');stock=widget.api.list('stock',{'branch_id':widget.branchId});
  });
  Future<void> _createProduct() async {
    final sku=TextEditingController(),barcode=TextEditingController(),name=TextEditingController(),
      price=TextEditingController(),unit=TextEditingController(text:'قطعة'),reorder=TextEditingController(text:'0');
    final trackExpiry=ValueNotifier<bool>(false);
    final result=await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('إضافة صنف جديد'),content:SizedBox(width:480,child:SingleChildScrollView(child:Column(
        mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:name,decoration:const InputDecoration(labelText:'اسم الصنف بالعربية')),
          const SizedBox(height:10),TextField(controller:sku,decoration:const InputDecoration(labelText:'SKU')),
          const SizedBox(height:10),TextField(controller:barcode,decoration:const InputDecoration(labelText:'الباركود (اختياري)')),
          const SizedBox(height:10),TextField(controller:price,keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'سعر البيع بالجنيه')),
          const SizedBox(height:10),TextField(controller:unit,decoration:const InputDecoration(labelText:'وحدة الأساس')),
          const SizedBox(height:10),TextField(controller:reorder,keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'حد إعادة الطلب')),
          ValueListenableBuilder<bool>(valueListenable:trackExpiry,
            builder:(context,checked,_)=>CheckboxListTile(
              title:const Text('تتبّع التشغيلات وتواريخ الصلاحية'),
              subtitle:const Text('يلزم رقم التشغيلة وتاريخ الانتهاء في كل شراء.'),
              value:checked,onChanged:(value)=>trackExpiry.value=value??false)),
        ]))),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
        FilledButton(onPressed:(){try {Navigator.pop(ctx,{'sku':sku.text,'barcode':barcode.text,
          'name_ar':name.text,'base_unit':unit.text,'sell_price_minor':parseMoney(price.text),
          'reorder_qty_milli':parseQty(reorder.text),
          'track_expiry':trackExpiry.value});}catch(_){alert(ctx,'تأكد من صحة السعر والكمية',error:true);}},
          child:const Text('إضافة'))]));
    for(final c in [sku,barcode,name,price,unit,reorder]){c.dispose();}
    trackExpiry.dispose();
    if(result==null)return;
    try {await widget.api.post('products',result);if(mounted){alert(context,'تمت إضافة الصنف');_reload();}}
    catch(e){if(mounted)alert(context,'تعذر الإضافة: $e',error:true);}
  }
  Future<void> _managePromotions(Map<String,dynamic> product) async {
    if(!['owner','manager'].contains(widget.role)) {
      alert(context,'العروض يحددها المدير فقط',error:true);
      return;
    }
    try {
      final offers=await widget.api.list('promotions',
        {'product_id':product['id'].toString()});
      final units=await widget.api.list('units',
        {'product_id':product['id'].toString()});
      if(!mounted)return;
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:Text('العروض المجدولة: '+product['name_ar'].toString()),
        content:SizedBox(width:560,height:360,child:offers.isEmpty
          ?const Center(child:Text('لا توجد عروض لهذا الصنف'))
          :ListView(children:[
            for(final offer in offers)ListTile(
              title:Text(offer['title'].toString()+' • '+
                money(asInt(offer['promo_price_minor']))),
              subtitle:Text(offer['starts_at'].toString()+' ← '+offer['ends_at'].toString()+
                (offer['unit_id']!=null?' • وحدة بديلة':'')),
              trailing:offer['active']==1
                ?TextButton(onPressed:() async {
                  Navigator.pop(ctx);
                  await _stopPromotion(offer);
                },child:const Text('إيقاف العرض'))
                :const Text('متوقف'),
            ),
          ])),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق')),
          FilledButton(onPressed:(){
            Navigator.pop(ctx);
            _createPromotion(product,units);
          },child:const Text('إضافة عرض جديد')),
        ],
      ));
    }catch(e){if(mounted)alert(context,'تعذر تحميل العروض: '+e.toString(),error:true);}
  }

  Future<void> _stopPromotion(Map<String,dynamic> offer) async {
    final reason=TextEditingController();
    try {
      final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('إيقاف العرض'),
        content:TextField(controller:reason,
          decoration:const InputDecoration(labelText:'سبب الإيقاف')),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx,false),
            child:const Text('إلغاء')),
          FilledButton(onPressed:(){
            if(reason.text.trim().isNotEmpty)Navigator.pop(ctx,true);
          },child:const Text('إيقاف')),
        ],
      ));
      if(confirmed!=true)return;
      await widget.api.post('promotions/stop',
        {'promotion_id':offer['id'],'reason':reason.text.trim()});
      if(mounted){alert(context,'تم إيقاف العرض');_reload();}
    }catch(e){if(mounted)alert(context,'تعذر إيقاف العرض: '+e.toString(),error:true);}
    finally{reason.dispose();}
  }

  Future<void> _createPromotion(Map<String,dynamic> product,
      List<Map<String,dynamic>> units) async {
    final title=TextEditingController(),price=TextEditingController();
    final now=DateTime.now().toUtc();
    final start=TextEditingController(
      text:now.toIso8601String().substring(0,19)+'Z');
    final end=TextEditingController(
      text:now.add(const Duration(days:7)).toIso8601String().substring(0,19)+'Z');
    String? unitId;
    try {
      final result=await showDialog<Map<String,dynamic>>(context:context,
        builder:(ctx)=>StatefulBuilder(builder:(ctx,setForm)=>AlertDialog(
          title:const Text('إضافة عرض سعر محدد المدة'),
          content:SizedBox(width:480,child:SingleChildScrollView(child:Column(
            mainAxisSize:MainAxisSize.min,children:[
              const Text('الخصم يطبقه الخادم تلقائيًا، ولا يمكن تداخل عرضين لنفس وحدة البيع.'),
              const SizedBox(height:12),
              TextField(controller:title,
                decoration:const InputDecoration(labelText:'اسم العرض')),
              const SizedBox(height:12),
              DropdownButtonFormField<String>(
                isExpanded:true,
                decoration:const InputDecoration(labelText:'وحدة البيع'),
                initialValue:unitId,
                items:[
                  const DropdownMenuItem<String>(value:null,child:Text('وحدة الأساس')),
                  for(final u in units)DropdownMenuItem<String>(
                    value:u['id'].toString(),child:Text(u['unit_name'].toString())),
                ],
                onChanged:(v)=>setForm(()=>unitId=v),
              ),
              const SizedBox(height:12),
              TextField(controller:price,keyboardType:TextInputType.number,
                decoration:const InputDecoration(labelText:'السعر الترويجي بالجنيه')),
              const SizedBox(height:12),
              TextField(controller:start,textDirection:TextDirection.ltr,
                decoration:const InputDecoration(labelText:'البداية UTC YYYY-MM-DDTHH:MM:SSZ')),
              const SizedBox(height:12),
              TextField(controller:end,textDirection:TextDirection.ltr,
                decoration:const InputDecoration(labelText:'النهاية UTC YYYY-MM-DDTHH:MM:SSZ')),
            ]))),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
            FilledButton(onPressed:(){
              try {
                final amount=parseMoney(price.text);
                if(amount<=0 || title.text.trim().isEmpty)throw const FormatException();
                Navigator.pop(ctx,{'product_id':product['id'],
                  if(unitId!=null)'unit_id':unitId,
                  'title':title.text.trim(),'promo_price_minor':amount,
                  'starts_at':start.text.trim(),'ends_at':end.text.trim()});
              }catch(_){alert(ctx,'تحقق من اسم العرض والسعر والتواريخ',error:true);}
            },child:const Text('حفظ العرض')),
          ],
        )));
      if(result==null)return;
      await widget.api.post('promotions',result);
      if(mounted){alert(context,'تم إنشاء العرض وسيسري في موعده');_reload();}
    }catch(e){if(mounted)alert(context,'تعذر إنشاء العرض: '+e.toString(),error:true);}
    finally {
      for(final c in [title,price,start,end]){c.dispose();}
    }
  }

  Future<void> _createUnit(Map<String,dynamic> product) async {
    final name=TextEditingController(),factor=TextEditingController(text:'12'),
      price=TextEditingController(),barcode=TextEditingController();
    final input=await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>AlertDialog(
      title:Text('إضافة وحدة بيع: '+product['name_ar'].toString()),
      content:SizedBox(width:460,child:SingleChildScrollView(child:Column(
        mainAxisSize:MainAxisSize.min,children:[
          const Text('مثال: كرتونة = 12 قطعة. المخزون يبقى بوحدة الأساس، وسعر الكرتونة مستقل.'),
          const SizedBox(height:12),
          TextField(controller:name,decoration:const InputDecoration(labelText:'اسم الوحدة (كرتونة/علبة)')),
          const SizedBox(height:10),
          TextField(controller:factor,keyboardType:TextInputType.number,
            decoration:InputDecoration(labelText:'كم '+product['base_unit'].toString()+' داخل الوحدة؟')),
          const SizedBox(height:10),
          TextField(controller:price,keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'سعر بيع الوحدة بالجنيه')),
          const SizedBox(height:10),
          TextField(controller:barcode,decoration:const InputDecoration(labelText:'باركود الوحدة (اختياري)')),
        ]))),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
        FilledButton(onPressed:(){
          try {
            final multiplier=parseQty(factor.text);
            if(multiplier<=0 || name.text.trim().isEmpty)throw const FormatException('Invalid unit');
            Navigator.pop(ctx,{'product_id':product['id'],'unit_name':name.text.trim(),
              'factor_milli':multiplier,'sell_price_minor':parseMoney(price.text),
              'barcode':barcode.text.trim()});
          }catch(_){alert(ctx,'تأكد من اسم الوحدة ومعامل التحويل وسعرها',error:true);}
        },child:const Text('إضافة')),
      ],
    ));
    for(final c in [name,factor,price,barcode]){c.dispose();}
    if(input==null)return;
    try {
      await widget.api.post('units',input);
      if(mounted) alert(context,'تم إضافة وحدة البيع بنجاح');
    }catch(e){if(mounted)alert(context,'تعذر إضافة الوحدة: $e',error:true);}
  }

  Future<void> _changeLotQuarantine(BuildContext lotDialogContext,
      Map<String,dynamic> lot,bool block) async {
    final reason=TextEditingController();
    try {
      final submitted=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
        title:Text(block?'حجر تشغيلة':'رفع الحجر عن تشغيلة'),
        content:SizedBox(width:430,child:Column(mainAxisSize:MainAxisSize.min,children:[
          Text('التشغيلة: '+lot['lot_no'].toString()),
          const SizedBox(height:12),
          TextField(controller:reason,maxLength:200,
            decoration:const InputDecoration(labelText:'سبب القرار (مطلوب للتدقيق)')),
        ])),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
          FilledButton(onPressed:(){
            if(reason.text.trim().isNotEmpty)Navigator.pop(ctx,reason.text.trim());
          },child:Text(block?'اعتماد الحجز':'اعتماد رفع الحجز')),
        ],
      ));
      if(submitted==null)return;
      await widget.api.post('lots/quarantine',{
        'branch_id':widget.branchId,
        'warehouse_id':lot['warehouse_id'],
        'batch_id':lot['id'],
        'quarantined':block,
        'reason':submitted,
      });
      if(lotDialogContext.mounted)Navigator.pop(lotDialogContext);
      if(mounted)alert(context,block?'تم حجز التشغيلة ومنع بيعها':'تم رفع الحجر بعد الاعتماد');
    }catch(e){
      if(mounted)alert(context,'تعذر تعديل حالة التشغيلة: '+e.toString(),error:true);
    }finally{reason.dispose();}
  }

  Future<void> _showLots(Map<String,dynamic> product) async {
    try {
      final lots=await widget.api.list('lots',{
        'branch_id':widget.branchId,'product_id':product['id'].toString()});
      if(!mounted)return;
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:Text('تشغيلات وتواريخ صلاحية: '+product['name_ar'].toString()),
        content:SizedBox(width:520,height:330,child:lots.isEmpty
          ?const Center(child:Text('لا توجد تشغيلات مسجلة لهذا الصنف'))
          :ListView.builder(itemCount:lots.length,itemBuilder:(ctx,i){
            final lot=lots[i],expired=lot['expired']==true;
            final quarantined=lot['quarantined']==true;
            final mayBlock=['owner','manager','stock'].contains(widget.role);
            final mayRelease=['owner','manager'].contains(widget.role);
            return ListTile(
              leading:Icon(expired || quarantined?Icons.warning_amber:Icons.event_available,
                color:expired || quarantined?Colors.red:null),
              title:Text('التشغيلة: '+lot['lot_no'].toString()),
              subtitle:Text('ينتهي: '+lot['expires_on'].toString()+
                (quarantined?' • محجوزة للبيع':'')),
              trailing:Row(mainAxisSize:MainAxisSize.min,children:[
                Column(mainAxisSize:MainAxisSize.min,children:[
                  Text(quantity(asInt(lot['qty_milli']))),
                  Text(expired?'منتهية':quarantined?'محجوزة':'صالحة للبيع',
                    style:TextStyle(color:expired||quarantined?Colors.red:Colors.green,fontSize:11)),
                ]),
                if((quarantined && mayRelease) || (!quarantined && mayBlock))
                  IconButton(onPressed:()=>_changeLotQuarantine(ctx,lot,!quarantined),
                    tooltip:quarantined?'رفع الحجر':'حجر التشغيلة',
                    icon:Icon(quarantined?Icons.lock_open:Icons.lock_outline)),
              ]));
          })),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق'))],
      ));
    }catch(e){if(mounted)alert(context,'تعذر تحميل التشغيلات: '+e.toString(),error:true);}
  }

  Future<void> _adjust(Map<String,dynamic> product) async {
    final tracked=product['track_expiry']==1;
    List<Map<String,dynamic>> lots=<Map<String,dynamic>>[];
    if(tracked){
      try {
        lots=await widget.api.list('lots',{
          'branch_id':widget.branchId,'product_id':product['id'].toString()});
      }catch(e){
        if(mounted)alert(context,'تعذر تحميل التشغيلات: '+e.toString(),error:true);
        return;
      }
    }
    if(!mounted)return;
    final qty=TextEditingController(),cost=TextEditingController(text:'0'),
      reason=TextEditingController(),lotNo=TextEditingController(),
      expiry=TextEditingController();
    String? selectedBatch;
    final result=await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>AlertDialog(
      title:Text('تسوية مخزون: '+product['name_ar'].toString()),
      content:SizedBox(width:480,child:SingleChildScrollView(child:Column(
        mainAxisSize:MainAxisSize.min,children:[
        const Text('للزيادة أدخل كمية موجبة وتكلفتها؛ وللنقص أدخل كمية سالبة.'),
        const SizedBox(height:10),
        TextField(controller:qty,decoration:const InputDecoration(labelText:'التغير في الكمية (+ أو -)')),
        const SizedBox(height:10),
        TextField(controller:cost,decoration:const InputDecoration(labelText:'تكلفة الكمية المضافة بالجنيه')),
        const SizedBox(height:10),
        TextField(controller:reason,decoration:const InputDecoration(labelText:'سبب التسوية')),
        if(tracked)...[
          const SizedBox(height:14),
          const Text('للزيادة: رقم التشغيلة وتاريخ انتهاء صالح. للنقص: اختر التشغيلة الحالية.'),
          const SizedBox(height:8),
          TextField(controller:lotNo,decoration:const InputDecoration(labelText:'رقم التشغيلة للزيادة')),
          const SizedBox(height:8),
          TextField(controller:expiry,decoration:const InputDecoration(labelText:'تاريخ الانتهاء YYYY-MM-DD')),
          const SizedBox(height:8),
          DropdownButtonFormField<String>(isExpanded:true,
            decoration:const InputDecoration(labelText:'التشغيلة المسحوب منها عند النقص'),
            items:lots.where((x)=>asInt(x['qty_milli'])>0)
              .map((lot)=>DropdownMenuItem<String>(
                value:lot['id'].toString(),
                child:Text(lot['lot_no'].toString()+' • '+lot['expires_on'].toString())))
              .toList(),
            onChanged:(value)=>selectedBatch=value),
        ],
      ]))),actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
        FilledButton(onPressed:(){try {
          final q=qty.text.startsWith('-')
            ?-parseQty(qty.text.substring(1)):parseQty(qty.text);
          if(q==0) throw const FormatException('Zero quantity');
          if(tracked && q>0 && (lotNo.text.trim().isEmpty || expiry.text.trim().isEmpty)) {
            throw const FormatException('Lot and expiry required');
          }
          if(tracked && q<0 && selectedBatch==null) {
            throw const FormatException('Select a lot');
          }
          Navigator.pop(ctx,{'product_id':product['id'],'branch_id':widget.branchId,
            'qty_change_milli':q,'added_cost_minor':parseMoney(cost.text),
            'reason':reason.text,
            if(tracked && q>0)'lot_no':lotNo.text.trim(),
            if(tracked && q>0)'expires_on':expiry.text.trim(),
            if(tracked && q<0)'batch_id':selectedBatch});
        }catch(_){alert(ctx,'تحقق من الكمية وبيانات التشغيلة',error:true);}},
          child:const Text('اعتماد')),
      ],
    ));
    for(final c in [qty,cost,reason,lotNo,expiry]){c.dispose();}
    if(result==null)return;
    try {
      await widget.api.post('inventory/adjustments',result);
      if(mounted){alert(context,'تم تحديث المخزون');_reload();}
    }catch(e){if(mounted)alert(context,'فشلت التسوية: '+e.toString(),error:true);}
  }

  @override Widget build(BuildContext context)=>Column(children:[
    SectionTitle('الأصناف والمخزون',subtitle:'الأصناف الحقيقية في قاعدة البيانات وحركات المخزون المعتمدة.',
      action:FilledButton.icon(onPressed:_createProduct,icon:const Icon(Icons.add),label:const Text('صنف جديد'))),
    Expanded(child:AsyncPanel<List<Map<String,dynamic>>>(future:products,onRetry:_reload,
      builder:(list)=>AsyncPanel<List<Map<String,dynamic>>>(future:stock,onRetry:_reload,builder:(balances){
        if(list.isEmpty)return const EmptyState('ابدأ بإضافة المنتجات، ثم سجّل المشتريات لإدخال مخزونها.');
        return ListView.builder(itemCount:list.length,itemBuilder:(context,i){final p=list[i];
          final available=balances.where((b)=>b['product_id']==p['id']).fold<int>(0,(sum,b)=>sum+asInt(b['qty_milli']));
          final low=available<asInt(p['reorder_qty_milli']);
          return Card(child:ListTile(leading:CircleAvatar(child:Icon(low?Icons.warning_amber:Icons.inventory_2_outlined)),
            title:Text(p['name_ar'].toString()),subtitle:Text('${p['sku']} • ${p['base_unit']} • رصيد ${quantity(available)}'),
            trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(money(asInt(p['sell_price_minor']))),
              if(p['track_expiry']==1)IconButton(onPressed:()=>_showLots(p),
                tooltip:'عرض التشغيلات والصلاحية',icon:const Icon(Icons.event_note)),
              if(['owner','manager'].contains(widget.role))
                IconButton(onPressed:()=>_managePromotions(p),tooltip:'العروض المجدولة',
                  icon:const Icon(Icons.local_offer_outlined)),
              IconButton(onPressed:()=>_createUnit(p),tooltip:'إضافة وحدة بيع (كرتونة/علبة)',
                icon:const Icon(Icons.all_inbox_outlined)),
              IconButton(onPressed:()=>_adjust(p),tooltip:'تسوية المخزون',icon:const Icon(Icons.tune))])));});
      }))),
  ]);
}
