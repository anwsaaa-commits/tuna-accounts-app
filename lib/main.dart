import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

const gold = Color(0xFFD7AF59);
const bg = Color(0xFF101114);
const panel = Color(0xFF202024);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar');
  await DB.instance.database;
  runApp(const TunaApp());
}
String money(num n) => '${NumberFormat('#,##0','en').format(n)} ر.ي';
String fmtDate(String s) => DateFormat('yyyy/MM/dd HH:mm').format(DateTime.parse(s));

class TunaApp extends StatelessWidget {
  const TunaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'تونة بلس', debugShowCheckedModeBanner: false,
    locale: const Locale('ar'),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: ThemeData(
      useMaterial3: true, brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(seedColor: gold, brightness: Brightness.dark),
      appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: gold, centerTitle: true),
      cardTheme: CardThemeData(color: panel),
    ),
    home: const Directionality(textDirection: TextDirection.rtl, child: AppShell()),
  );
}

class DB {
  DB._();
  static final DB instance = DB._();
  Database? _db;
  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await openDatabase(path.join(await getDatabasesPath(), 'tuna_plus.db'),
      version: 1, onCreate: (db, version) async {
        await db.execute('CREATE TABLE customers(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,phone TEXT,note TEXT)');
        await db.execute('CREATE TABLE sales(id INTEGER PRIMARY KEY AUTOINCREMENT,invoice TEXT UNIQUE,customer_id INTEGER,kg REAL,price INTEGER,total INTEGER,paid INTEGER,kind TEXT,note TEXT,created TEXT)');
        await db.execute('CREATE TABLE collections(id INTEGER PRIMARY KEY AUTOINCREMENT,customer_id INTEGER,amount INTEGER,note TEXT,created TEXT)');
        await db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT)');
        await db.insert('settings', {'key':'shop','value':'تونة بلس'});
        await db.insert('settings', {'key':'price','value':'6500'});
      });
    return _db!;
  }
  Future<List<Map<String,Object?>>> customers() async => (await database).query('customers',orderBy:'name');
  Future<List<Map<String,Object?>>> sales() async => (await database).query('sales',orderBy:'created DESC');
  Future<int> addCustomer(String name,String phone,String note) async {
    if(name.trim().isEmpty) throw Exception('اسم العميل مطلوب');
    return (await database).insert('customers',{'name':name.trim(),'phone':phone,'note':note});
  }
  Future<int> addSale(int? cid,double kg,int price,int paid,String kind,String note) async {
    if(kg<=0||price<=0||paid<0) throw Exception('تحقق من الوزن والسعر والمدفوع');
    final total=(kg*price).round();
    if(paid>total) throw Exception('المدفوع لا يتجاوز الإجمالي');
    if(kind=='نقدي'&&paid!=total) throw Exception('البيع النقدي يجب أن يكون مدفوعاً بالكامل');
    return (await database).insert('sales',{'invoice':'TP-${DateTime.now().microsecondsSinceEpoch}','customer_id':cid,'kg':kg,'price':price,'total':total,'paid':paid,'kind':kind,'note':note,'created':DateTime.now().toIso8601String()});
  }
  Future<int> collect(int cid,int amount,String note) async {
    if(amount<=0) throw Exception('أدخل مبلغ تحصيل صحيح');
    final db=await database;
    final s=(await db.rawQuery('SELECT COALESCE(SUM(total-paid),0) v FROM sales WHERE customer_id=?',[cid])).first['v'] as num;
    final c=(await db.rawQuery('SELECT COALESCE(SUM(amount),0) v FROM collections WHERE customer_id=?',[cid])).first['v'] as num;
    if(amount>s.toInt()-c.toInt()) throw Exception('المبلغ أكبر من الرصيد المستحق');
    return db.insert('collections',{'customer_id':cid,'amount':amount,'note':note,'created':DateTime.now().toIso8601String()});
  }
  Future<Map<String,num>> totals() async {
    final db=await database;
    final s=(await db.rawQuery('SELECT COALESCE(SUM(total),0) total,COALESCE(SUM(paid),0) paid,COALESCE(SUM(kg),0) weight FROM sales')).first;
    final collected=(await db.rawQuery('SELECT COALESCE(SUM(amount),0) total FROM collections')).first['total'] as num;
    final debt=(await db.rawQuery('SELECT COALESCE(SUM(total-paid),0) total FROM sales')).first['total'] as num;
    return {'sales':(s['total'] as num),'paid':(s['paid'] as num),'weight':(s['weight'] as num),'collections':collected,'debt':debt-collected};
  }
  Future<Map<String,num>> customerTotals(int id) async {
    final db=await database;
    final s=(await db.rawQuery('SELECT COALESCE(SUM(total),0) total,COALESCE(SUM(paid),0) paid FROM sales WHERE customer_id=?',[id])).first;
    final c=(await db.rawQuery('SELECT COALESCE(SUM(amount),0) total FROM collections WHERE customer_id=?',[id])).first['total'] as num;
    return {'sales':s['total'] as num,'paid':(s['paid'] as num)+c,'debt':(s['total'] as num)-(s['paid'] as num)-c};
  }
  Future<List<Map<String,Object?>>> customerSales(int id) async => (await database).query('sales',where:'customer_id=?',whereArgs:[id],orderBy:'created DESC');
  Future<List<Map<String,Object?>>> customerCollections(int id) async => (await database).query('collections',where:'customer_id=?',whereArgs:[id],orderBy:'created DESC');
  Future<String> setting(String key,String fallback) async {
    final rows=await (await database).query('settings',where:'key=?',whereArgs:[key]);
    return rows.isEmpty?fallback:rows.first['value'] as String;
  }
  Future<void> setSetting(String key,String value) async => (await database).insert('settings',{'key':key,'value':value},conflictAlgorithm:ConflictAlgorithm.replace);
  Future<void> deleteSale(int id) async {
    final db=await database;
    final sale=(await db.query('sales',where:'id=?',whereArgs:[id])).first;
    final cid=sale['customer_id'];
    if(cid!=null){
      final outstanding=(await db.rawQuery('SELECT COALESCE(SUM(total-paid),0) v FROM sales WHERE customer_id=?',[cid])).first['v'] as num;
      final collected=(await db.rawQuery('SELECT COALESCE(SUM(amount),0) v FROM collections WHERE customer_id=?',[cid])).first['v'] as num;
      if(collected>outstanding-(sale['total'] as num)+(sale['paid'] as num)) throw Exception('لا يمكن حذف فاتورة لأن هناك تحصيلات مرتبطة. راجع كشف الحساب أولاً.');
    }
    await db.delete('sales',where:'id=?',whereArgs:[id]);
  }
}

void toast(BuildContext context,String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(text)));

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override State<AppShell> createState()=>_AppShellState();
}
class _AppShellState extends State<AppShell>{
  int tab=0, refresh=0;
  void reload()=>setState(()=>refresh++);
  @override Widget build(BuildContext context){
    final screens=[Dashboard(key:ValueKey(refresh),onRefresh:reload,onTab:(v)=>setState(()=>tab=v)),InvoicePage(key:ValueKey('invoices$refresh'),onRefresh:reload),CustomerPage(key:ValueKey('customers$refresh'),onRefresh:reload),ReportPage(key:ValueKey('report$refresh'))];
    return Scaffold(appBar:AppBar(title:Text(['تونة بلس','الفواتير','العملاء','التقارير'][tab]),actions:[IconButton(icon:const Icon(Icons.settings),onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const SettingsPage())).then((_)=>reload()))]),body:screens[tab],bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v),backgroundColor:panel,indicatorColor:gold.withValues(alpha:.2),destinations:const[NavigationDestination(icon:Icon(Icons.home),label:'الرئيسية'),NavigationDestination(icon:Icon(Icons.receipt_long),label:'فواتير'),NavigationDestination(icon:Icon(Icons.people),label:'عملاء'),NavigationDestination(icon:Icon(Icons.bar_chart),label:'تقارير')]));
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key,required this.onRefresh,required this.onTab});
  final VoidCallback onRefresh; final ValueChanged<int> onTab;
  @override State<Dashboard> createState()=>_DashboardState();
}
class _DashboardState extends State<Dashboard>{
  late Future<Map<String,num>> future;
  @override void initState(){super.initState();future=DB.instance.totals();}
  Widget metric(String title,String value,IconData icon)=>Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(icon,color:gold),Text(title),Text(value,style:const TextStyle(color:gold,fontWeight:FontWeight.bold))])));
  @override Widget build(BuildContext context)=>FutureBuilder(future:future,builder:(context,s)=>RefreshIndicator(onRefresh:()async{setState(()=>future=DB.instance.totals());},child:ListView(padding:const EdgeInsets.all(14),children:[const Icon(Icons.set_meal,color:gold,size:60),const Text('تونة بلس',textAlign:TextAlign.center,style:TextStyle(color:gold,fontSize:26,fontWeight:FontWeight.bold)),const Text('إدارة مبيعات التونة بالكيلو',textAlign:TextAlign.center),const SizedBox(height:12),GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:2,childAspectRatio:1.45,children:[metric('المبيعات',money(s.data?['sales']??0:0),Icons.point_of_sale),metric('المدفوع من الفواتير',money(s.data?['paid']??0:0),Icons.payments),metric('الديون المتبقية',money(s.data?['debt']??0:0),Icons.account_balance),metric('الوزن', '${(s.data?['weight']??0).toStringAsFixed(3)} كجم", Icons.scale)]),const SizedBox(height:12),FilledButton.icon(onPressed:()=>createSale(context).then((_)=>setState(()=>future=DB.instance.totals())),icon:const Icon(Icons.add),label:const Text('بيع جديد')),OutlinedButton.icon(onPressed:()=>createCustomer(context).then((_)=>setState(()=>future=DB.instance.totals())),icon:const Icon(Icons.person_add),label:const Text('إضافة عميل')),ListTile(title:const Text('الفواتير'),trailing:const Icon(Icons.chevron_left),onTap:()=>widget.onTab(1)),ListTile(title:const Text('العملاء وكشف الحساب'),trailing:const Icon(Icons.chevron_left),onTap:()=>widget.onTab(2)),ListTile(title:const Text('التقارير'),trailing:const Icon(Icons.chevron_left),onTap:()=>widget.onTab(3))])));
}

Future<void> createCustomer(BuildContext context)async{
  final name=TextEditingController(),phone=TextEditingController(),note=TextEditingController();
  await showDialog(context:context,builder:(ctx)=>AlertDialog(title:const Text('إضافة عميل'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:name,decoration:const InputDecoration(labelText:'اسم العميل')),TextField(controller:phone,decoration:const InputDecoration(labelText:'الهاتف')),TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات'))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await DB.instance.addCustomer(name.text,phone.text,note.text);if(ctx.mounted)Navigator.pop(ctx);}catch(e){toast(ctx,e.toString());}},child:const Text('حفظ'))]));
}
Future<void> createSale(BuildContext context)async{
  final clients=await DB.instance.customers();if(!context.mounted)return;
  int? selected=clients.isEmpty?null:clients.first['id'] as int;
  final weight=TextEditingController(),price=TextEditingController(text:await DB.instance.setting('price','6500')),paid=TextEditingController(),note=TextEditingController();String kind='نقدي';
  await showDialog(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,set)=>AlertDialog(title:const Text('بيع تونة'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[DropdownButtonFormField<int>(value:selected,decoration:const InputDecoration(labelText:'العميل (اختياري)'),items:clients.map((e)=>DropdownMenuItem<int>(value:e['id'] as int,child:Text(e['name'] as String))).toList(),onChanged:(v)=>set(()=>selected=v)),TextField(controller:weight,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الوزن بالكيلو')),TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'سعر الكيلو')),TextField(controller:paid,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المدفوع')),DropdownButtonFormField<String>(value:kind,decoration:const InputDecoration(labelText:'نوع البيع'),items:['نقدي','آجل'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>set(()=>kind=v??'نقدي')),TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات')),Text('الإجمالي: ${money(((double.tryParse(weight.text)??0)*(int.tryParse(price.text)??0)).round())}') ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{final kg=double.parse(weight.text),p=int.parse(price.text);final total=(kg*p).round();final cash=paid.text.trim().isEmpty?(kind=='نقدي'?total:0):int.parse(paid.text);await DB.instance.addSale(selected,kg,p,cash,kind,note.text);await DB.instance.setSetting('price',p.toString());if(ctx.mounted)Navigator.pop(ctx);if(context.mounted)toast(context,'تم حفظ البيع');}catch(e){toast(ctx,e.toString().replaceFirst('Exception: ',''));}},child:const Text('حفظ البيع'))])));
}

class InvoicePage extends StatefulWidget{const InvoicePage({super.key,required this.onRefresh});final VoidCallback onRefresh;@override State<InvoicePage> createState()=>_InvoicePageState();}
class _InvoicePageState extends State<InvoicePage>{late Future<List<Map<String,Object?>>> future;@override void initState(){super.initState();future=DB.instance.sales();}@override Widget build(BuildContext context)=>FutureBuilder(future:future,builder:(context,s)=>RefreshIndicator(onRefresh:()async{setState(()=>future=DB.instance.sales());},child:ListView(padding:const EdgeInsets.all(12),children:[FilledButton.icon(onPressed:()=>createSale(context).then((_)=>setState(()=>future=DB.instance.sales())),icon:const Icon(Icons.add),label:const Text('بيع جديد')),if(!s.hasData)const Center(child:CircularProgressIndicator())else if(s.data!.isEmpty)const Padding(padding:EdgeInsets.all(20),child:Text('لا توجد فواتير'))else ...s.data!.map((v)=>Card(child:ListTile(title:Text('${v['invoice']} • ${money(v['total'] as num)}'),subtitle:Text('${v['kg']} كجم | ${v['kind']} | ${fmtDate(v['created'] as String)}\nمدفوع: ${money(v['paid'] as num)}'),leading:const Icon(Icons.receipt,color:gold),trailing:IconButton(icon:const Icon(Icons.delete,color:Colors.red),onPressed:()async{try{await DB.instance.deleteSale(v['id'] as int);setState(()=>future=DB.instance.sales());}catch(e){toast(context,e.toString());}}))))])));}
}

class CustomerPage extends StatefulWidget{const CustomerPage({super.key,required this.onRefresh});final VoidCallback onRefresh;@override State<CustomerPage> createState()=>_CustomerPageState();}
class _CustomerPageState extends State<CustomerPage>{late Future<List<Map<String,Object?>>> future;@override void initState(){super.initState();future=DB.instance.customers();}@override Widget build(BuildContext context)=>FutureBuilder(future:future,builder:(context,s)=>Column(children:[Padding(padding:const EdgeInsets.all(10),child:FilledButton.icon(onPressed:()=>createCustomer(context).then((_)=>setState(()=>future=DB.instance.customers())),icon:const Icon(Icons.person_add),label:const Text('عميل جديد'))),Expanded(child:ListView(children:[if(!s.hasData)const Center(child:CircularProgressIndicator())else ...s.data!.map((c)=>Card(child:ListTile(title:Text(c['name'] as String),subtitle:Text(c['phone'] as String? ??''),leading:const Icon(Icons.person,color:gold),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>Ledger(client:c))))))]))]);}
}
class Ledger extends StatefulWidget{const Ledger({super.key,required this.client});final Map<String,Object?> client;@override State<Ledger> createState()=>_LedgerState();}
class _LedgerState extends State<Ledger>{late Future<Map<String,num>> totals;late Future<List<Map<String,Object?>>> sales,collections;int get cid=>widget.client['id'] as int;void load(){totals=DB.instance.customerTotals(cid);sales=DB.instance.customerSales(cid);collections=DB.instance.customerCollections(cid);}@override void initState(){super.initState();load();}Future<void> collect()async{final amount=TextEditingController(),note=TextEditingController();await showDialog(context:context,builder:(ctx)=>AlertDialog(title:const Text('تحصيل من العميل'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المبلغ')),TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات'))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await DB.instance.collect(cid,int.parse(amount.text),note.text);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState(load);}catch(e){toast(ctx,e.toString());}},child:const Text('حفظ'))]));}@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text(widget.client['name'] as String)),floatingActionButton:FloatingActionButton.extended(onPressed:collect,icon:const Icon(Icons.payments),label:const Text('تحصيل')),body:FutureBuilder(future:totals,builder:(ctx,s){if(!s.hasData)return const Center(child:CircularProgressIndicator());final t=s.data!;return ListView(padding:const EdgeInsets.all(12),children:[Card(child:ListTile(title:Text('المبيعات: ${money(t['sales']!)}'),subtitle:Text('المستلم: ${money(t['paid']!)}'),trailing:Text('الباقي: ${money(t['debt']!)}',style:const TextStyle(color:gold,fontWeight:FontWeight.bold)))),if((widget.client['note'] as String? ?? '').isNotEmpty)Text('ملاحظات: ${widget.client['note']}'),const Text('فواتير العميل'),FutureBuilder(future:sales,builder:(ctx,ss)=>Column(children:[if(ss.hasData)for(final v in ss.data!)ListTile(title:Text('${v['invoice']} • ${money(v['total'] as num)}'),subtitle:Text(fmtDate(v['created'] as String)))])),const Text('التحصيلات'),FutureBuilder(future:collections,builder:(ctx,cc)=>Column(children:[if(cc.hasData)for(final v in cc.data!)ListTile(title:Text(money(v['amount'] as num)),subtitle:Text(v['note'] as String? ?? ''))]))]);})));}}
class ReportPage extends StatelessWidget{const ReportPage({super.key});Future<void> pdf()async{final t=await DB.instance.totals(),rows=await DB.instance.sales();final doc=pw.Document();doc.addPage(pw.Page(build:(_)=>pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Text('TUNA PLUS - Sales Summary',style:pw.TextStyle(fontSize:20,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:10),pw.Text('Sales: ${money(t['sales']!)}'),pw.Text('Paid: ${money(t['paid']!)}'),pw.Text('Collections: ${money(t['collections']!)}'),pw.Text('Debt: ${money(t['debt']!)}'),pw.Text('Weight: ${t['weight']!.toStringAsFixed(3)} kg'),pw.SizedBox(height:12),pw.Table.fromTextArray(data:[['Invoice','Date','Weight','Total','Paid'],...rows.map((r)=>[r['invoice'],(r['created'] as String).substring(0,10),r['kg'],r['total'],r['paid']])])])));await Printing.layoutPdf(onLayout:(_)=>doc.save());}@override Widget build(BuildContext context)=>FutureBuilder(future:DB.instance.totals(),builder:(context,s)=>ListView(padding:const EdgeInsets.all(12),children:[if(s.hasData)...['sales','paid','collections','debt','weight'].map((k)=>Card(child:ListTile(title:Text({'sales':'إجمالي المبيعات','paid':'المدفوع','collections':'التحصيلات','debt':'الديون القائمة','weight':'الوزن المباع'}[k]!),trailing:Text(k=='weight'?`${s.data![k]!.toStringAsFixed(3)} كجم`:money(s.data![k]!))))),FilledButton.icon(onPressed:pdf,icon:const Icon(Icons.picture_as_pdf),label:const Text('تصدير التقرير PDF'))]));}
}
class SettingsPage extends StatefulWidget{const SettingsPage({super.key});@override State<SettingsPage> createState()=>_SettingsPageState();}
class _SettingsPageState extends State<SettingsPage>{final shop=TextEditingController(),phone=TextEditingController(),price=TextEditingController();@override void initState(){super.initState();load();}Future<void> load()async{shop.text=await DB.instance.setting('shop','تونة بلس');phone.text=await DB.instance.setting('phone','');price.text=await DB.instance.setting('price','6500');}Future<void> save()async{await DB.instance.setSetting('shop',shop.text);await DB.instance.setSetting('phone',phone.text);await DB.instance.setSetting('price',price.text);if(mounted){toast(context,'تم حفظ الإعدادات');Navigator.pop(context);}}@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('إعدادات المتجر')),body:ListView(padding:const EdgeInsets.all(16),children:[TextField(controller:shop,decoration:const InputDecoration(labelText:'اسم المتجر')),TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم التواصل')),TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'سعر الكيلو الافتراضي')),const SizedBox(height:20),FilledButton(onPressed:save,child:const Text('حفظ'))]));}
