import 'package:flutter/material.dart';
import '../services/api.dart';
import '../widgets/common.dart';

class UsersPage extends StatefulWidget {
  final ApiClient api;
  final String branchId;
  const UsersPage({super.key,required this.api,required this.branchId});
  @override State<UsersPage> createState()=>_UsersState();
}
class _UsersState extends State<UsersPage> {
  late Future<List<Map<String,dynamic>>> users;
  @override void initState(){super.initState();_reload();}
  void _reload()=>setState(()=>users=widget.api.list('users'));
  Future<void> _create() async {
    final user=TextEditingController(),pass=TextEditingController();
    String role='cashier';
    final result=await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>StatefulBuilder(
      builder:(ctx,setDialog)=>AlertDialog(title:const Text('إضافة مستخدم'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:user,decoration:const InputDecoration(labelText:'اسم الدخول')),
          const SizedBox(height:12),TextField(controller:pass,obscureText:true,
            decoration:const InputDecoration(labelText:'كلمة مرور قوية (12 حرفًا على الأقل)')),
          const SizedBox(height:12),DropdownButtonFormField<String>(value:role,
            decoration:const InputDecoration(labelText:'الدور'),
            items:const [DropdownMenuItem(value:'cashier',child:Text('كاشير')),
              DropdownMenuItem(value:'manager',child:Text('مدير')),
              DropdownMenuItem(value:'stock',child:Text('مخزن')),
              DropdownMenuItem(value:'purchasing',child:Text('مشتريات')),
              DropdownMenuItem(value:'viewer',child:Text('عرض فقط'))],
            onChanged:(v)=>setDialog(()=>role=v??role)),
        ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,{'branch_id':widget.branchId,
            'username':user.text.trim(),'password':pass.text,'role':role}),child:const Text('حفظ'))])));
    user.dispose();pass.dispose();
    if(result==null)return;
    try{await widget.api.post('users',result);if(mounted){alert(context,'تمت إضافة الحساب');_reload();}}
    catch(e){if(mounted)alert(context,'فشل إنشاء الحساب: $e',error:true);}
  }
  @override Widget build(BuildContext context)=>Column(children:[
    SectionTitle('المستخدمون والصلاحيات',subtitle:'إنشاء حسابات منفصلة وأدوار محددة لكل فرع.',
      action:FilledButton.icon(onPressed:_create,icon:const Icon(Icons.person_add_alt),label:const Text('مستخدم جديد'))),
    Expanded(child:AsyncPanel<List<Map<String,dynamic>>>(future:users,onRetry:_reload,
      builder:(list)=>ListView.builder(itemCount:list.length,itemBuilder:(context,i){
        final u=list[i];return Card(child:ListTile(leading:const Icon(Icons.person_outline),
          title:Text(u['username'].toString()),subtitle:Text(u['role'].toString()),
          trailing:Text(u['active']==1?'نشط':'موقوف'))); }))),
  ]);
}
