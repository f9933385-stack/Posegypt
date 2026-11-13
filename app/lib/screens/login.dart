import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api.dart';
import '../services/network_policy.dart';
import 'shell.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override State<LoginScreen> createState()=>_LoginScreenState();
}
class _LoginScreenState extends State<LoginScreen> {
  final form=GlobalKey<FormState>();
  final host=TextEditingController(text:'http://127.0.0.1:8787');
  final tenant=TextEditingController();
  final username=TextEditingController(text:'admin');
  final password=TextEditingController();
  bool loading=false;
  @override void initState(){super.initState();_restore();}
  Future<void> _restore() async {
    final p=await SharedPreferences.getInstance();
    if(!mounted)return;
    setState(() {host.text=p.getString('host') ?? host.text;tenant.text=p.getString('tenant') ?? '';});
  }
  Future<void> _login() async {
    if(!form.currentState!.validate())return;
    setState(()=>loading=true);
    try {
      final api=ApiClient(host.text.trim());
      final response=await api.post('auth/login',{'tenant_id':tenant.text.trim(),
        'username':username.text.trim(),'password':password.text},idempotent:false);
      api.token=response['token'] as String;
      final p=await SharedPreferences.getInstance();
      await p.setString('host',host.text.trim());await p.setString('tenant',tenant.text.trim());
      if(!mounted)return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder:(_)=>ShellScreen(api:api,session:response)));
    }catch(e){if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('تعذّر الدخول: $e')));}
    finally{if(mounted)setState(()=>loading=false);}
  }
  @override void dispose(){host.dispose();tenant.dispose();username.dispose();password.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>Scaffold(
    body:Center(child:SingleChildScrollView(padding:const EdgeInsets.all(20),child:ConstrainedBox(
      constraints:const BoxConstraints(maxWidth:450),child:Card(child:Padding(padding:const EdgeInsets.all(28),
      child:Form(key:form,child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        CircleAvatar(radius:32,backgroundColor:Theme.of(context).colorScheme.primaryContainer,
          child:Icon(Icons.point_of_sale,size:34,color:Theme.of(context).colorScheme.primary)),
        const SizedBox(height:16),
        Text('كاشير',textAlign:TextAlign.center,style:Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight:FontWeight.bold)),
        const Text('إدارة سوبرماركت بسيطة ودقيقة',textAlign:TextAlign.center),
        const SizedBox(height:28),
        TextFormField(controller:host,textDirection:TextDirection.ltr,decoration:const InputDecoration(labelText:'عنوان خادم الفرع',prefixIcon:Icon(Icons.dns)),
          validator:(s){try {validateBranchEndpoint(s ?? '');return null;} on FormatException catch(e){return e.message;}}),
        const SizedBox(height:12),
        TextFormField(controller:tenant,textDirection:TextDirection.ltr,decoration:const InputDecoration(labelText:'معرف المنشأة Tenant ID',prefixIcon:Icon(Icons.store)),
          validator:(s)=>(s??'').isEmpty?'مطلوب':null),
        const SizedBox(height:12),
        TextFormField(controller:username,decoration:const InputDecoration(labelText:'اسم المستخدم',prefixIcon:Icon(Icons.person)),
          validator:(s)=>(s??'').isEmpty?'مطلوب':null),
        const SizedBox(height:12),
        TextFormField(controller:password,obscureText:true,decoration:const InputDecoration(labelText:'كلمة المرور',prefixIcon:Icon(Icons.lock)),
          onFieldSubmitted:(_)=>_login(),validator:(s)=>(s??'').isEmpty?'مطلوب':null),
        const SizedBox(height:22),
        FilledButton.icon(onPressed:loading?null:_login,icon:loading?const SizedBox(width:18,height:18,
          child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.login),label:const Text('تسجيل الدخول')),
        const SizedBox(height:12),const Text('يعمل داخل الفرع دون إنترنت خارجي، بشرط اتصال الأجهزة بالخادم المحلي.',
          textAlign:TextAlign.center,style:TextStyle(fontSize:12)),
      ]))))))));
}
