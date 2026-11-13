import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class CartLine {
  final Map<String,dynamic> product;
  final Map<String,dynamic>? unit;
  int qtyMilli;
  int unitCount;
  CartLine(this.product,{this.qtyMilli=1000,this.unit,this.unitCount=1});
  int get price=>asInt(unit?['sell_price_minor'] ?? product['sell_price_minor']);
  int get net=>unit==null ? (price*qtyMilli+500)~/1000 : price*unitCount;
  int get tax=>(net*asInt(product['tax_rate_bp'])+5000)~/10000;
  Map<String,dynamic> toSaleLine()=>unit==null
    ? {'product_id':product['id'],'qty_milli':qtyMilli}
    : {'product_id':product['id'],'unit_id':unit!['id'],'unit_count':unitCount};
}
class PosPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const PosPage({super.key,required this.api,required this.branchId});
  @override State<PosPage> createState()=>_PosState();
}
class _PosState extends State<PosPage> {
  final search=TextEditingController();
  final cash=TextEditingController(),card=TextEditingController(),wallet=TextEditingController(),bank=TextEditingController();
  late Future<List<Map<String,dynamic>>> products,customers;
  final cart=<CartLine>[];
  String? customerId;
  bool posting=false;
  @override void initState(){super.initState();products=widget.api.list('products');customers=widget.api.list('customers');}
  @override void dispose(){for(final c in [search,cash,card,wallet,bank]){c.dispose();}super.dispose();}
  void _search(String q)=>setState(()=>products=widget.api.list('products',{'q':q}));
  Future<void> _scanBarcode(String code) async {
    final cleaned=code.trim();
    if(cleaned.isEmpty)return;
    try {
      final results=await widget.api.list('products',{'q':cleaned});
      if(!mounted)return;
      final matching=results.where((p)=>
        p['sku']==cleaned || p['barcode']==cleaned || p['matched_unit_id']!=null).toList();
      if(matching.length!=1)return;
      final product=matching.single;
      if(product['matched_unit_id']!=null) {
        await _addUnit(product,preferredUnitId:product['matched_unit_id'].toString());
      } else {
        _add(product);
      }
      if(mounted){search.clear();_search('');}
    }catch(e) {if(mounted)alert(context,'لم يتم التعرف على الباركود: '+e.toString(),error:true);}
  }
  void _add(Map<String,dynamic> p){setState(() {
    final index=cart.indexWhere((x)=>x.product['id']==p['id'] && x.unit==null);
    if(index<0)cart.add(CartLine(p));else cart[index].qtyMilli+=1000;
  });}
  void _pushUnit(Map<String,dynamic> product,Map<String,dynamic> unit) {
    setState(() {
      final index=cart.indexWhere((x)=>x.product['id']==product['id'] &&
        x.unit?['id']==unit['id']);
      if(index<0)cart.add(CartLine(product,unit:unit));
      else cart[index].unitCount++;
    });
  }
  Future<void> _addUnit(Map<String,dynamic> product,{String? preferredUnitId}) async {
    try {
      final units=await widget.api.list('units',{'product_id':product['id'].toString()});
      if(!mounted)return;
      if(units.isEmpty){alert(context,'أضف وحدات البيع للصنف من شاشة المخزون أولًا',error:true);return;}
      if(preferredUnitId!=null) {
        final matches=units.where((u)=>u['id']==preferredUnitId).toList();
        if(matches.length==1) {
          _pushUnit(product,matches.single);
          return;
        }
      }
      final unit=await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>AlertDialog(
        title:Text('اختر وحدة بيع: '+product['name_ar'].toString()),
        content:SizedBox(width:450,child:SingleChildScrollView(child:Column(
          mainAxisSize:MainAxisSize.min,children:[
            for(final entry in units)
              ListTile(title:Text(entry['unit_name'].toString()),
                subtitle:Text('تعادل '+quantity(asInt(entry['factor_milli']))+
                  ' '+product['base_unit'].toString()),
                trailing:Text(money(asInt(entry['sell_price_minor']))),
                onTap:()=>Navigator.pop(ctx,entry)),
          ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء'))],
      ));
      if(unit==null || !mounted)return;
      _pushUnit(product,unit);
    }catch(e){if(mounted)alert(context,'تعذر تحميل وحدات الصنف: '+e.toString(),error:true);}
  }

  int get total=>cart.fold<int>(0,(n,x)=>n+x.net+x.tax);
  Future<void> _changeQty(CartLine item) async {
    final controller=TextEditingController(text:item.unit==null
      ?quantity(item.qtyMilli):item.unitCount.toString());
    final q=await showDialog<int>(context:context,builder:(ctx)=>AlertDialog(title:Text('${item.product['name_ar']}'),
      content:TextField(controller:controller,autofocus:true,keyboardType:const TextInputType.numberWithOptions(decimal:true),
        decoration:InputDecoration(labelText:item.unit==null
          ?'الكمية بوحدة الأساس (مثال: 0.350)':'عدد الوحدات الصحيحة')),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
        FilledButton(onPressed:(){try {
          final v=item.unit==null?parseQty(controller.text):int.parse(controller.text);
          if(v<=0 || (item.unit!=null && v>100000))throw const FormatException();
          Navigator.pop(ctx,v);
        }catch(_){alert(ctx,'كمية غير صالحة',error:true);}},child:const Text('حفظ'))]));
    controller.dispose();
    if(q!=null && mounted)setState((){
      if(item.unit==null)item.qtyMilli=q;else item.unitCount=q;
    });
  }
  Future<void> _submit() async {
    if(cart.isEmpty)return;
    setState(()=>posting=true);
    try {
      final payments=<Map<String,dynamic>>[];
      for(final p in [('cash',cash),('card',card),('wallet',wallet),('bank',bank)]) {
        final text=p.$2.text.trim();
        if(text.isNotEmpty){final amount=parseMoney(text);if(amount>0)payments.add({'method':p.$1,'amount_minor':amount});}
      }
      final result=await widget.api.post('sales',{'branch_id':widget.branchId,
        'customer_id':customerId,'lines':[for(final c in cart)c.toSaleLine()],
        'payments':payments});
      if(!mounted)return;
      alert(context,'تم حفظ الفاتورة ${result['number']} — ${money(asInt(result['total_minor']))}');
      setState(() {cart.clear();for(final c in [cash,card,wallet,bank]){c.clear();} customerId=null;});
    }catch(e){alert(context,'تعذر حفظ الفاتورة: $e',error:true);}
    finally{if(mounted)setState(()=>posting=false);}
  }
  @override Widget build(BuildContext context)=>LayoutBuilder(builder:(context,layout){
    final wide=layout.maxWidth>=900;
    final productsView=Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      TextField(controller:search,onChanged:_search,onSubmitted:_scanBarcode,
        decoration:const InputDecoration(
        prefixIcon:Icon(Icons.search),hintText:'اسم المنتج، SKU، أو الباركود')),
      const SizedBox(height:12),Expanded(child:AsyncPanel<List<Map<String,dynamic>>>(future:products,
        onRetry:()=>_search(search.text),builder:(list)=>list.isEmpty?const EmptyState('لا توجد أصناف مطابقة'):
        ListView.builder(itemCount:list.length,itemBuilder:(context,i){final p=list[i];return Card(child:ListTile(
          title:Text(p['name_ar']?.toString()??''),subtitle:Text('${p['sku']} • ${p['base_unit']}'),
          trailing:Row(mainAxisSize:MainAxisSize.min,children:[
            Text(money(asInt(p['sell_price_minor'])),style:const TextStyle(fontWeight:FontWeight.bold)),
            IconButton(onPressed:()=>_addUnit(p),tooltip:'بيع بالكرتونة أو الوحدة',
              icon:const Icon(Icons.all_inbox_outlined)),
            IconButton(onPressed:()=>_add(p),tooltip:'إضافة بوحدة الأساس',
              icon:const Icon(Icons.add_circle_outline))]),onTap:()=>p['matched_unit_id']==null?_add(p):
            _addUnit(p,preferredUnitId:p['matched_unit_id'].toString())));}))),
    ]);
    final basket=Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Row(children:[const Expanded(child:Text('الفاتورة الحالية',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold))),
        Text('${cart.length} صنف')]),
      const SizedBox(height:8),
      Expanded(child:cart.isEmpty?const EmptyState('اختر صنفًا أو امسح الباركود',icon:Icons.shopping_basket_outlined):
        ListView.builder(itemCount:cart.length,itemBuilder:(context,i){
          final c=cart[i];return Card(child:ListTile(dense:true,title:Text(c.product['name_ar'].toString()),
            subtitle:Text(c.unit==null
              ? quantity(c.qtyMilli)+' × '+money(c.price)
              : c.unitCount.toString()+' × '+c.unit!['unit_name'].toString()+' × '+money(c.price)),
            trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(money(c.net+c.tax)),
              IconButton(onPressed:()=>_changeQty(c),icon:const Icon(Icons.edit_outlined)),
              IconButton(onPressed:()=>setState(()=>cart.removeAt(i)),icon:const Icon(Icons.close))])));})),
      const Divider(),
      Text('الإجمالي شامل الضريبة: ${money(total)}',style:Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight:FontWeight.bold)),
      const SizedBox(height:8),
      AsyncPanel<List<Map<String,dynamic>>>(future:customers,onRetry:()=>setState(()=>customers=widget.api.list('customers')),
        builder:(list)=>DropdownButtonFormField<String>(value:customerId,decoration:const InputDecoration(labelText:'العميل (مطلوب للبيع الآجل)'),
          items:[const DropdownMenuItem<String>(value:null,child:Text('عميل نقدي')),
            ...list.map((x)=>DropdownMenuItem<String>(value:x['id'].toString(),child:Text(x['name'].toString())))],
          onChanged:(v)=>setState(()=>customerId=v))),
      const SizedBox(height:8),
      Wrap(spacing:8,runSpacing:8,children:[
        SizedBox(width:130,child:TextField(controller:cash,keyboardType:TextInputType.number,
          decoration:const InputDecoration(labelText:'نقدي (ج.م)'))),
        SizedBox(width:130,child:TextField(controller:card,keyboardType:TextInputType.number,
          decoration:const InputDecoration(labelText:'بطاقة'))),
        SizedBox(width:130,child:TextField(controller:wallet,keyboardType:TextInputType.number,
          decoration:const InputDecoration(labelText:'محفظة'))),
        SizedBox(width:130,child:TextField(controller:bank,keyboardType:TextInputType.number,
          decoration:const InputDecoration(labelText:'تحويل'))),
      ]),
      const SizedBox(height:8),Row(children:[
        TextButton(onPressed:()=>setState(()=>cash.text='${total ~/ 100}.${(total % 100).toString().padLeft(2,'0')}'),child:const Text('سداد نقدي كامل')),
        const Spacer(),FilledButton.icon(onPressed:posting||cart.isEmpty?null:_submit,
          icon:const Icon(Icons.check_circle_outline),label:Text(posting?'جارٍ الحفظ...':'اعتماد الفاتورة')),
      ]),
      const Text('أي مبلغ متبقٍ يُسجل آجلًا على العميل المختار. لا يتم اعتماد فاتورة غير محفوظة.',
        style:TextStyle(fontSize:11)),
    ]);
    return Column(children:[SectionTitle('نقطة البيع',subtitle:'بيع بالباركود والوزن والدفع المختلط مع تحديث المخزون والحسابات.'),
      Expanded(child:wide?Row(children:[Expanded(flex:4,child:productsView),const SizedBox(width:16),
        Expanded(flex:6,child:basket)]):Column(children:[Expanded(flex:3,child:productsView),
          const SizedBox(height:10),Expanded(flex:5,child:basket)]))]);
  });
}
