import 'package:flutter/material.dart';
import '../models/formats.dart';

void alert(BuildContext context,String message,{bool error=false}) {
  if(!context.mounted)return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(message),
    backgroundColor:error?Theme.of(context).colorScheme.error:null));
}

class SectionTitle extends StatelessWidget {
  final String title,subtitle;
  final Widget? action;
  const SectionTitle(this.title,{super.key,this.subtitle='',this.action});
  @override Widget build(BuildContext context)=>Padding(padding:const EdgeInsets.only(bottom:16),
    child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(title,style:Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight:FontWeight.bold)),
      if(subtitle.isNotEmpty) Text(subtitle,style:Theme.of(context).textTheme.bodySmall),
    ])),if(action!=null)action!]));
}

class StatCard extends StatelessWidget {
  final String title,value;
  final IconData icon;
  final Color? color;
  const StatCard({super.key,required this.title,required this.value,required this.icon,this.color});
  @override Widget build(BuildContext context)=>Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(
    crossAxisAlignment:CrossAxisAlignment.start,children:[
      CircleAvatar(backgroundColor:(color ?? Theme.of(context).colorScheme.primary).withValues(alpha:0.10),
        child:Icon(icon,color:color ?? Theme.of(context).colorScheme.primary)),
      const SizedBox(height:15),Text(value,style:Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight:FontWeight.bold)),
      Text(title,style:Theme.of(context).textTheme.bodySmall),
    ])));
}

class AsyncPanel<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(T) builder;
  final VoidCallback onRetry;
  const AsyncPanel({super.key,required this.future,required this.builder,required this.onRetry});
  @override Widget build(BuildContext context)=>FutureBuilder<T>(future:future,builder:(context,snapshot){
    if(snapshot.hasError)return Center(child:Column(mainAxisSize:MainAxisSize.min,children:[
      Icon(Icons.error_outline,color:Theme.of(context).colorScheme.error,size:38),
      const SizedBox(height:8),Text('تعذر تحميل البيانات: ${apiError(snapshot.error ?? 'خطأ غير معروف')}'),
      TextButton.icon(onPressed:onRetry,icon:const Icon(Icons.refresh),label:const Text('إعادة المحاولة')),
    ]));
    if(!snapshot.hasData)return const Center(child:Padding(padding:EdgeInsets.all(50),child:CircularProgressIndicator()));
    return builder(snapshot.data as T);
  });
}

Widget moneyText(Object? value,{TextStyle? style}) => Text(money(asInt(value)),style:style,textDirection:TextDirection.ltr);

class EmptyState extends StatelessWidget {
  final String message;
  final IconData icon;
  const EmptyState(this.message,{super.key,this.icon=Icons.inbox_outlined});
  @override Widget build(BuildContext context)=>Padding(padding:const EdgeInsets.all(40),child:Center(child:Column(mainAxisSize:MainAxisSize.min,children:[
    Icon(icon,size:52,color:Theme.of(context).colorScheme.outline),
    const SizedBox(height:12),Text(message,textAlign:TextAlign.center),
  ])));
}
