import 'package:flutter/material.dart';
import '../services/api.dart';
import 'login.dart';
import 'dashboard.dart';
import 'pos.dart';
import 'products.dart';
import 'purchases.dart';
import 'parties.dart';
import 'expenses.dart';
import 'reports.dart';
import 'debts.dart';
import 'preparation.dart';
import 'returns.dart';
import 'users.dart';
import 'shifts.dart';
import 'warehouses.dart';
import 'stock_counts.dart';

class ShellScreen extends StatefulWidget {
  final ApiClient api;
  final Map<String,dynamic> session;
  const ShellScreen({super.key,required this.api,required this.session});
  @override State<ShellScreen> createState()=>_ShellScreenState();
}
class _ShellScreenState extends State<ShellScreen> {
  int selected=0;
  String get role => widget.session['role']?.toString() ?? 'viewer';
  late String branchId;
  List<Map<String,dynamic>> branches=[];
  final pageTitles=['الرئيسية','نقطة البيع','الأصناف والمخزون','المشتريات','العملاء','الموردون','الديون والتحصيل','التجهيز','المرتجعات','المصروفات','التقارير','المستخدمون','الورديات','المخازن الداخلية','الجرد المعتمد'];
  final pageIcons=[Icons.dashboard_outlined,Icons.point_of_sale_outlined,Icons.inventory_2_outlined,
    Icons.shopping_cart_outlined,Icons.groups_outlined,Icons.local_shipping_outlined,
    Icons.account_balance_wallet_outlined,Icons.blender_outlined,Icons.assignment_return_outlined,
    Icons.receipt_long_outlined,Icons.bar_chart_outlined,Icons.manage_accounts_outlined,Icons.access_time_outlined,Icons.warehouse_outlined,Icons.fact_check_outlined];
  @override void initState(){super.initState();selected=switch(role){'cashier'=>1,'stock'=>2,'purchasing'=>3,'viewer'=>10,_=>0};branchId=widget.session['branch_id']?.toString() ?? '';_loadBranches();}
  Future<void> _loadBranches() async {
    try {
      final all=await widget.api.list('branches');
      if(!mounted)return;
      setState(() {branches=all;if(branchId.isEmpty && all.isNotEmpty)branchId=all.first['id'].toString();});
    }catch(_){/* The dashboard will show a detailed connection error. */}
  }
  Future<void> _logout() async {
    try {await widget.api.post('auth/logout',{},idempotent:false);} catch (_) {
      // Clear local session even when the branch server is unreachable.
    }
    widget.api.token=null;
    if(!mounted)return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder:(_)=>const LoginScreen()),(_)=>false);
  }
  bool _visible(int index)=>switch(role) {
    'cashier'=>[1,2,4,6,10,12].contains(index),
    'stock'=>[2,7,10,13,14].contains(index),
    'purchasing'=>[2,3,5,6,8,10].contains(index),
    'viewer'=>index==10,
    'manager'=>index!=11,
    _=>true,
  };
  Widget _page()=>switch(selected) {
    0=>DashboardPage(api:widget.api,branchId:branchId),
    1=>PosPage(api:widget.api,branchId:branchId),
    2=>ProductsPage(api:widget.api,branchId:branchId,role:role),
    3=>PurchasesPage(api:widget.api,branchId:branchId),
    4=>PartyPage(api:widget.api,customer:true),
    5=>PartyPage(api:widget.api,customer:false),
    6=>DebtsPage(api:widget.api,branchId:branchId),
    7=>PreparationPage(api:widget.api,branchId:branchId),
    8=>ReturnsPage(api:widget.api,branchId:branchId),
    9=>ExpensesPage(api:widget.api,branchId:branchId),
    10=>ReportsPage(api:widget.api,branchId:branchId),
    11=>UsersPage(api:widget.api,branchId:branchId),
    12=>ShiftsPage(api:widget.api,branchId:branchId),
    13=>WarehousesPage(api:widget.api,branchId:branchId,role:role),
    14=>StockCountsPage(api:widget.api,branchId:branchId,role:role),
    _=>DashboardPage(api:widget.api,branchId:branchId),
  };
  @override Widget build(BuildContext context)=>LayoutBuilder(builder:(context,box){
    final wide=box.maxWidth>=900;
    return Scaffold(
      appBar:AppBar(title:Text('كاشير  /  ${pageTitles[selected]}'),
        actions:[if(branches.length>1) SizedBox(width:210,child:DropdownButtonHideUnderline(child:DropdownButton<String>(
          value:branches.any((b)=>b['id']==branchId)?branchId:null,
          isExpanded:true,items:branches.map((b)=>DropdownMenuItem<String>(value:b['id'].toString(),
            child:Text(b['name']?.toString() ?? 'فرع'))).toList(),
          onChanged:(value){if(value!=null)setState(()=>branchId=value);}))),
          IconButton(onPressed:_logout,tooltip:'تسجيل الخروج',icon:const Icon(Icons.logout))]),
      drawer:wide && [for(var i=0;i<pageTitles.length;i++)if(_visible(i))i].length>=2?null:Drawer(child:SafeArea(child:ListView(children:[
        const ListTile(title:Text('القائمة',style:TextStyle(fontWeight:FontWeight.bold))),
        for(var i=0;i<pageTitles.length;i++)if(_visible(i))ListTile(
          leading:Icon(pageIcons[i]),title:Text(pageTitles[i]),selected:selected==i,
          onTap:(){setState(()=>selected=i);Navigator.of(context).pop();}),
      ]))),
      body:Row(children:[
        if(wide && [for(var i=0;i<pageTitles.length;i++)if(_visible(i))i].length>=2) NavigationRail(
          extended:box.maxWidth>=1150,scrollable:true,selectedIndex:[for(var i=0;i<pageTitles.length;i++)if(_visible(i))i].indexOf(selected),
          onDestinationSelected:(i)=>setState(()=>selected=[for(var j=0;j<pageTitles.length;j++)if(_visible(j))j][i]),
          destinations:[for(var i=0;i<pageTitles.length;i++)if(_visible(i)) NavigationRailDestination(
            icon:Icon(pageIcons[i]),label:Text(pageTitles[i]))]),
        Expanded(child:Padding(padding:EdgeInsets.all(wide?24:12),
          child:KeyedSubtree(key:ValueKey('$selected:$branchId'),child:_page()))),
      ]),
      bottomNavigationBar:wide || [for(var i=0;i<4;i++)if(_visible(i))i].length<2?null:NavigationBar(selectedIndex:[for(var i=0;i<4;i++)if(_visible(i))i].contains(selected)?[for(var i=0;i<4;i++)if(_visible(i))i].indexOf(selected):0,
        onDestinationSelected:(i)=>setState(()=>selected=[for(var j=0;j<4;j++)if(_visible(j))j][i]),destinations:[
        for(var i=0;i<4;i++)if(_visible(i)) NavigationDestination(icon:Icon(pageIcons[i]),label:pageTitles[i]),
      ]),
    );
  });
}
