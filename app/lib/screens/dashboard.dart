import 'package:flutter/material.dart';
import '../services/api.dart';
import '../models/formats.dart';
import '../widgets/common.dart';

class DashboardPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const DashboardPage({super.key,required this.api,required this.branchId});
  @override State<DashboardPage> createState()=>_DashboardState();
}
class _DashboardState extends State<DashboardPage> {
  late Future<Map<String,dynamic>> future;
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(()=>future=widget.api.get('dashboard',{'branch_id':widget.branchId}));
  @override Widget build(BuildContext context)=>AsyncPanel<Map<String,dynamic>>(
    future:future,onRetry:_reload,builder:(d)=>SingleChildScrollView(child:Column(
      crossAxisAlignment:CrossAxisAlignment.start,children:[
      SectionTitle('لوحة الإدارة',subtitle:'ملخص حسابات الفرع، بالمبالغ الحقيقية المسجلة في قاعدة البيانات.',
        action:IconButton(onPressed:_reload,icon:const Icon(Icons.refresh))),
      LayoutBuilder(builder:(context,size){
        final columns=size.maxWidth>1000?4:size.maxWidth>560?2:1;
        final cards=[
          ('صافي المبيعات','sales_minor',Icons.trending_up),
          ('مجمل الربح','gross_profit_minor',Icons.show_chart),
          ('المصروفات','expenses_minor',Icons.money_off),
          ('الربح التشغيلي التقديري','estimated_operating_profit_minor',Icons.savings_outlined),
          ('قيمة المخزون','stock_value_minor',Icons.inventory_2),
          ('النقدية المحسوبة','cash_minor',Icons.account_balance_wallet_outlined),
          ('ديون العملاء','customer_receivables_minor',Icons.person_outline),
          ('مستحقات الموردين','supplier_payables_minor',Icons.local_shipping_outlined),
        ];
        return GridView.builder(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),
          gridDelegate:SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:columns,
            childAspectRatio:columns==1?3.3:1.9,crossAxisSpacing:12,mainAxisSpacing:12),
          itemCount:cards.length,itemBuilder:(context,i){
            final item=cards[i];
            return StatCard(title:item.$1,value:money(asInt(d[item.$2])),icon:item.$3);
          });
      }),
      const SizedBox(height:16),Card(child:ListTile(
        leading:const Icon(Icons.sync),title:const Text('طابور المزامنة المركزية'),
        subtitle:const Text('السجلات محفوظة محليًا، لكن ربط خادم المزامنة السحابية لم يُنفذ بعد.'),
        trailing:Text('${d['pending_sync']} عملية'))),
      const Card(child:ListTile(leading:Icon(Icons.info_outline),
        title:Text('ملاحظة محاسبية'),
        subtitle:Text('صافي الربح هنا تقديري وفق الحركات المسجلة؛ لا يعادل النقدية، ولا يمثل إقرارًا ضريبيًا رسميًا.'))),
    ])));
}
