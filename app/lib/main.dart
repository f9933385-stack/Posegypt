import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'screens/login.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KasherApp());
}

class KasherApp extends StatelessWidget {
  const KasherApp({super.key});
  @override Widget build(BuildContext context) {
    final light=ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:const Color(0xFF127F73)),
      scaffoldBackgroundColor:const Color(0xFFF5F7F9),
      inputDecorationTheme:InputDecorationTheme(border:OutlineInputBorder(borderRadius:BorderRadius.circular(12)),
        contentPadding:const EdgeInsets.symmetric(horizontal:14,vertical:12)),
      cardTheme:CardThemeData(elevation:0,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16),
        side:const BorderSide(color:Color(0xFFE7ECEF)))));
    return MaterialApp(
      title:'كاشير | إدارة السوبرماركت',debugShowCheckedModeBanner:false,
      locale:const Locale('ar'),supportedLocales:const [Locale('ar'),Locale('en')],
      localizationsDelegates:const [GlobalMaterialLocalizations.delegate,GlobalWidgetsLocalizations.delegate,GlobalCupertinoLocalizations.delegate],
      builder:(context,child)=>Directionality(textDirection:TextDirection.rtl,child:child!),
      theme:light,darkTheme:ThemeData.from(colorScheme:ColorScheme.fromSeed(seedColor:const Color(0xFF127F73),brightness:Brightness.dark),useMaterial3:true),
      home:const LoginScreen());
  }
}
