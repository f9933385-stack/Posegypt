import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';
import 'debt_reconciliations.dart';

class DebtsPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  final String role;
  const DebtsPage({super.key,required this.api,required this.branchId,
    required this.role});
  @override State<DebtsPage> createState()=>_DebtsState();
}
class _DebtsState extends State<DebtsPage> {
  bool customer=true,saving=false;
  String? partyId;
  String method='cash';
  String? invoiceId;
  List<Map<String,dynamic>> splitAllocations=[];
  Future<Map<String,dynamic>>? invoiceInfo;
  final amount=TextEditingController();
  late Future<List<Map<String,dynamic>>> parties;
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(()=>parties=widget.api.list(
    customer?'customers':'suppliers',{'branch_id':widget.branchId}));
  void _loadInvoices() {
    final id=partyId;
    setState((){
      invoiceId=null;
      splitAllocations=[];
      invoiceInfo=id==null?null:widget.api.get('debts/invoices',{
        'branch_id':widget.branchId,'party_id':id,
        'party_type':customer?'customer':'supplier'});
    });
  }
  @override void dispose(){amount.dispose();super.dispose();}
  Future<void> _submit() async {
    if(partyId==null){alert(context,'اختر العميل أو المورد',error:true);return;}
    setState(()=>saving=true);
    try {
      final result=await widget.api.post(customer?'customers/receipts':'suppliers/payments',{
        'branch_id':widget.branchId,(customer?'customer_id':'supplier_id'):partyId,
        'amount_minor':parseMoney(amount.text),'method':method,
        if(invoiceId!=null) 'invoice_id':invoiceId,
        if(splitAllocations.isNotEmpty) 'allocations':splitAllocations});
      if(!mounted)return;
      alert(context,'تم تسجيل الحركة. الرصيد المتبقي: ${money(asInt(result['remaining_minor']))}');
      amount.clear();_reload();_loadInvoices();
    }catch(e){alert(context,'تعذر تسجيل الحركة: $e',error:true);}
    finally{if(mounted)setState(()=>saving=false);}
  }
  Future<void> _splitPayment(List<Map<String,dynamic>> invoices) async {
    final selectable=invoices.take(20).toList();
    final controllers=[
      for(final _ in selectable) TextEditingController(),
    ];
    String? validationError;
    try {
      final result=await showDialog<List<Map<String,dynamic>>>(
        context:context,builder:(ctx)=>StatefulBuilder(
        builder:(ctx,update)=>AlertDialog(
          title:const Text('توزيع دفعة على فواتير متعددة'),
          content:SizedBox(width:580,height:440,
            child:Column(children:[
              const Text('أدخل المبلغ بالجنيه أمام كل فاتورة ترغب في سداد جزء منها. '
                'اترك الباقي فارغًا. الحد الأقصى 20 فاتورة.'),
              if(validationError!=null) ...[
                const SizedBox(height:8),
                Text(validationError!,style:TextStyle(
                  color:Theme.of(ctx).colorScheme.error)),
              ],
              const SizedBox(height:8),
              Expanded(child:ListView.builder(itemCount:selectable.length,
                itemBuilder:(ctx,i) {
                  final item=selectable[i];
                  return Padding(padding:const EdgeInsets.only(bottom:10),
                    child:TextField(
                      controller:controllers[i],
                      keyboardType:const TextInputType.numberWithOptions(decimal:true),
                      decoration:InputDecoration(
                        border:const OutlineInputBorder(),
                        labelText:'فاتورة ${item['number']}',
                        helperText:'المتبقي: ${money(asInt(item['remaining_minor']))}',
                      )));
                })),
            ])),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
            FilledButton(onPressed:(){
              try {
                final chosen=<Map<String,dynamic>>[];
                for(var i=0;i<selectable.length;i++) {
                  if(controllers[i].text.trim().isEmpty) continue;
                  final minor=parseMoney(controllers[i].text);
                  if(minor<=0 || minor>asInt(selectable[i]['remaining_minor'])) {
                    throw const FormatException('أحد المبالغ يتجاوز رصيد الفاتورة أو يساوي صفرًا');
                  }
                  chosen.add({
                    'invoice_id':selectable[i]['id'].toString(),
                    'amount_minor':minor,
                  });
                }
                if(chosen.length<2) {
                  throw const FormatException('اختر فاتورتين على الأقل، أو استخدم خيار الفاتورة الواحدة');
                }
                Navigator.pop(ctx,chosen);
              }catch(e){update(()=>validationError=e.toString());}
            },child:const Text('تطبيق التوزيع')),
          ],
        )));
      if(result==null || !mounted) return;
      final total=result.fold<int>(0,(sum,row)=>sum+asInt(row['amount_minor']));
      setState((){
        invoiceId=null;
        splitAllocations=result;
        amount.text='${total~/100}.${(total%100).toString().padLeft(2,'0')}';
      });
    }finally{
      for(final controller in controllers){controller.dispose();}
    }
  }
  Future<void> _reconcileLegacy() async {
    if(partyId==null)return;
    await showDialog<void>(context:context,builder:(_)=>
      DebtReconciliationDialog(api:widget.api,branchId:widget.branchId,
        partyId:partyId!,customer:customer));
    if(mounted){_reload();_loadInvoices();}
  }
  Future<void> _statement() async {
    if(partyId==null) return;
    try {
      final statement=await widget.api.get('debts/statement',{
        'branch_id':widget.branchId,'party_id':partyId!,
        'party_type':customer?'customer':'supplier'});
      if(!mounted)return;
      final entries=statement['entries'] as List<dynamic>;
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:Text('كشف حساب: ${statement['party_name']}'),
        content:SizedBox(width:620,height:420,child:Column(children:[
          Text('الرصيد الحالي: ${money(asInt(statement['balance_minor']))}',
            style:const TextStyle(fontWeight:FontWeight.bold)),
          const SizedBox(height:12),
          Expanded(child:entries.isEmpty
            ? const Center(child:Text('لا توجد حركات مسجلة في هذا الفرع'))
            : ListView.builder(itemCount:entries.length,itemBuilder:(context,i){
              final entry=entries[i] as Map<String,dynamic>;
              final change=asInt(entry['change_minor']);
              return ListTile(
                title:Text('${entry['reference_type']} • ${entry['created_at']}'),
                subtitle:Text('التغير في الدين: ${change>0?'+':''}${money(change)}'),
                trailing:Text('الرصيد: ${money(asInt(entry['balance_after_minor']))}'));
            })),
          const SizedBox(height:8),
          Text('الرصيد قبل الحركات الظاهرة: ${money(asInt(statement['opening_minor']))}',
            style:Theme.of(ctx).textTheme.bodySmall),
        ])),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),
          child:const Text('إغلاق'))]));
    }catch(e){
      if(mounted)alert(context,'تعذر عرض كشف الحساب: $e',error:true);
    }
  }
  @override Widget build(BuildContext context)=>SingleChildScrollView(child:Column(
    crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const SectionTitle('التحصيلات وسداد الموردين',subtitle:'تسويات الديون تؤثر على الحساب النقدي والمديونية فقط، وليس الربح.'),
      SegmentedButton<bool>(segments:const [ButtonSegment(value:true,label:Text('تحصيل من عميل')),
        ButtonSegment(value:false,label:Text('سداد لمورد'))],selected:{customer},onSelectionChanged:(value){
          setState(() {customer=value.first;partyId=null;invoiceId=null;
            splitAllocations=[];invoiceInfo=null;});_reload();}),
      const SizedBox(height:12),AsyncPanel<List<Map<String,dynamic>>>(future:parties,onRetry:_reload,
        builder:(list)=>DropdownButtonFormField<String>(value:partyId,
          decoration:InputDecoration(labelText:customer?'العميل':'المورد'),
          items:list.map((p)=>DropdownMenuItem<String>(value:p['id'].toString(),
            child:Text('${p['name']}${p['balance_minor']!=null?' — ${money(asInt(p['balance_minor']))}':''}'))).toList(),
          onChanged:(p){setState(()=>partyId=p);_loadInvoices();})),
      const SizedBox(height:8),Align(alignment:Alignment.centerRight,
        child:OutlinedButton.icon(onPressed:partyId==null?null:_statement,
          icon:const Icon(Icons.receipt_long),
          label:const Text('كشف حساب الفرع'))),
      if(invoiceInfo!=null) ...[
        const SizedBox(height:12),
        AsyncPanel<Map<String,dynamic>>(future:invoiceInfo!,onRetry:_loadInvoices,
          builder:(data){
            final legacy=asInt(data['unallocated_settlements_minor']);
            final invoices=(data['invoices'] as List<dynamic>)
              .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
            return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
              if(legacy>0) ...[
                Text('يوجد تحصيل/سداد قديم بقيمة ${money(legacy)} بدون توزيع على الفواتير؛ '
                  'يلزم مطابقته أولًا قبل ربط دفعات جديدة بفواتير محددة.',
                  style:TextStyle(color:Theme.of(context).colorScheme.error)),
                if(widget.role=='owner' || widget.role=='manager') ...[
                  const SizedBox(height:8),
                  OutlinedButton.icon(onPressed:saving?null:_reconcileLegacy,
                    icon:const Icon(Icons.fact_check_outlined),
                    label:const Text('مطابقة الدفعات القديمة ومراجعتها')),
                ],
              ],
              DropdownButtonFormField<String>(
                value:invoiceId,
                decoration:const InputDecoration(labelText:'تخصيص السداد لفاتورة (اختياري)'),
                isExpanded:true,
                items:[
                  const DropdownMenuItem<String>(value:'',child:Text('بدون تخصيص — تحصيل على إجمالي الحساب')),
                  if(data['allocation_available']==true)
                    for(final item in invoices) DropdownMenuItem<String>(
                      value:item['id'].toString(),
                      child:Text('${item['number']} • المتبقي: ${money(asInt(item['remaining_minor']))}',
                        overflow:TextOverflow.ellipsis)),
                ],
                onChanged:(v)=>setState((){
                  invoiceId=v==null || v.isEmpty?null:v;
                  splitAllocations=[];
                })),
              if(data['allocation_available']==true && invoices.length>=2) ...[
                const SizedBox(height:8),
                OutlinedButton.icon(
                  onPressed:saving?null:()=>_splitPayment(invoices),
                  icon:const Icon(Icons.call_split),
                  label:const Text('توزيع المبلغ على عدة فواتير')),
              ],
              if(splitAllocations.isNotEmpty) Padding(
                padding:const EdgeInsets.only(top:8),
                child:Text('تم اختيار ${splitAllocations.length} فواتير. '
                  'مجموع المبالغ سيطابق قيمة السداد المدخلة.')),
              if(data['has_more']==true)
                const Text('هناك فواتير أخرى غير ظاهرة، استخدم كشف الحساب للمراجعة.'),
            ]);
          }),
      ],
      const SizedBox(height:12),TextField(controller:amount,keyboardType:TextInputType.number,
        decoration:const InputDecoration(labelText:'القيمة بالجنيه')),
      const SizedBox(height:12),DropdownButtonFormField<String>(value:method,
        decoration:const InputDecoration(labelText:'وسيلة الدفع'),
        items:const [DropdownMenuItem(value:'cash',child:Text('نقدي')),
          DropdownMenuItem(value:'card',child:Text('بطاقة')),
          DropdownMenuItem(value:'wallet',child:Text('محفظة')),
          DropdownMenuItem(value:'bank',child:Text('تحويل'))],
        onChanged:(v)=>setState(()=>method=v??method)),
      const SizedBox(height:20),FilledButton.icon(onPressed:saving?null:_submit,
        icon:const Icon(Icons.save),label:Text(saving?'جارٍ التسجيل':'اعتماد الحركة')),
    ]));
}
