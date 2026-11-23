import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

const gold = Color(0xFFD7AF59);
const dark = Color(0xFF101114);
const panel = Color(0xFF202024);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar');
  await DB.instance.database;
  runApp(const TunaApp());
}
String money(num value) => '${NumberFormat('#,##0', 'en').format(value)} ر.ي';
String dateLabel(String value) => DateFormat('yyyy/MM/dd HH:mm').format(DateTime.parse(value));

class TunaApp extends StatelessWidget {
  const TunaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'تونة بلس',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: dark,
        colorScheme: ColorScheme.fromSeed(seedColor: gold, brightness: Brightness.dark),
        appBarTheme: const AppBarTheme(backgroundColor: dark, foregroundColor: gold, centerTitle: true),
        cardTheme: const CardThemeData(color: panel),
      ),
      home: const AppShell(),
    );
  }
}

class DB {
  DB._();
  static final DB instance = DB._();
  Database? _database;
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await openDatabase(p.join(await getDatabasesPath(), 'tuna_plus.db'), version: 4,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) { await db.execute('CREATE TABLE private_batches(id INTEGER PRIMARY KEY AUTOINCREMENT,gross_kg REAL NOT NULL,purchase_price INTEGER NOT NULL,total_cost INTEGER NOT NULL,net_kg REAL NOT NULL,created TEXT NOT NULL,note TEXT)'); }
        if (oldVersion < 3) { await db.execute('CREATE TABLE expenses(id INTEGER PRIMARY KEY AUTOINCREMENT,amount INTEGER NOT NULL,note TEXT NOT NULL,created TEXT NOT NULL)'); }
        if (oldVersion < 4) { await db.execute('CREATE TABLE reservations(id INTEGER PRIMARY KEY AUTOINCREMENT,customer_name TEXT NOT NULL,phone TEXT,kg REAL NOT NULL,price INTEGER NOT NULL,total INTEGER NOT NULL,deposit INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,note TEXT,created TEXT NOT NULL)'); }
      },
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE customers(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,phone TEXT,note TEXT)');
        await db.execute('CREATE TABLE sales(id INTEGER PRIMARY KEY AUTOINCREMENT,invoice TEXT UNIQUE,customer_id INTEGER,kg REAL,price INTEGER,total INTEGER,paid INTEGER,kind TEXT,note TEXT,created TEXT)');
        await db.execute('CREATE TABLE collections(id INTEGER PRIMARY KEY AUTOINCREMENT,customer_id INTEGER,amount INTEGER,note TEXT,created TEXT)');
        await db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT)');
        await db.execute('CREATE TABLE private_batches(id INTEGER PRIMARY KEY AUTOINCREMENT,gross_kg REAL NOT NULL,purchase_price INTEGER NOT NULL,total_cost INTEGER NOT NULL,net_kg REAL NOT NULL,created TEXT NOT NULL,note TEXT)');
        await db.execute('CREATE TABLE expenses(id INTEGER PRIMARY KEY AUTOINCREMENT,amount INTEGER NOT NULL,note TEXT NOT NULL,created TEXT NOT NULL)');
        await db.execute('CREATE TABLE reservations(id INTEGER PRIMARY KEY AUTOINCREMENT,customer_name TEXT NOT NULL,phone TEXT,kg REAL NOT NULL,price INTEGER NOT NULL,total INTEGER NOT NULL,deposit INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,note TEXT,created TEXT NOT NULL)');
        await db.insert('settings', {'key':'shop','value':'تونة بلس'});
        await db.insert('settings', {'key':'price','value':'6500'});
        await db.insert('settings', {'key':'bank','value':'254127488'});
        await db.insert('settings', {'key':'owner','value':'محمد صالح بن صالح علي الخلاقي'});
        await db.insert('settings', {'key':'address','value':'فوه المتضررين بجانب مسجد هائل خلف البريد'});
      });
    return _database!;
  }
  Future<List<Map<String,Object?>>> customers() async => (await database).query('customers', orderBy: 'name');
  Future<List<Map<String,Object?>>> sales() async => (await database).query('sales', orderBy: 'created DESC');
  Future<int> addCustomer(String name, String phone, String note) async {
    if (name.trim().isEmpty) throw Exception('اسم العميل مطلوب');
    return (await database).insert('customers', {'name':name.trim(),'phone':phone.trim(),'note':note.trim()});
  }
  Future<int> addSale(int? customerId, double kg, int price, int paid, String type, String note) async {
    if (!kg.isFinite || kg <= 0 || price <= 0 || paid < 0) throw Exception('تحقق من الوزن والسعر والمدفوع');
    if (type != 'نقدي' && type != 'آجل') throw Exception('نوع البيع غير صحيح');
    if (type == 'آجل' && customerId == null) throw Exception('البيع الآجل يتطلب اختيار عميل لتسجيل الدين في كشف حسابه');
    final total = (kg * price).round();
    if (total <= 0) throw Exception('قيمة الفاتورة غير صحيحة');
    if (paid > total) throw Exception('المدفوع لا يتجاوز الإجمالي');
    if (type == 'نقدي' && paid != total) throw Exception('البيع النقدي يجب أن يكون مدفوعاً بالكامل');
    return (await database).insert('sales', {
      'invoice':'TP-${DateTime.now().microsecondsSinceEpoch}','customer_id':customerId,
      'kg':kg,'price':price,'total':total,'paid':paid,'kind':type,'note':note.trim(),
      'created':DateTime.now().toIso8601String()
    });
  }
  Future<int> collect(int customerId, int amount, String note) async {
    if (amount <= 0) throw Exception('أدخل مبلغ تحصيل صحيح');
    final db = await database;
    final saleDue = (await db.rawQuery('SELECT COALESCE(SUM(total-paid),0) AS v FROM sales WHERE customer_id=?',[customerId])).first['v'] as num;
    final collected = (await db.rawQuery('SELECT COALESCE(SUM(amount),0) AS v FROM collections WHERE customer_id=?',[customerId])).first['v'] as num;
    if (amount > saleDue - collected) throw Exception('المبلغ أكبر من الرصيد المستحق');
    return db.insert('collections', {'customer_id':customerId,'amount':amount,'note':note,'created':DateTime.now().toIso8601String()});
  }
  Future<Map<String,num>> totals() async {
    final db = await database;
    final s = (await db.rawQuery('SELECT COALESCE(SUM(total),0) total,COALESCE(SUM(paid),0) paid,COALESCE(SUM(kg),0) weight FROM sales')).first;
    final c = (await db.rawQuery('SELECT COALESCE(SUM(amount),0) total FROM collections')).first['total'] as num;
    final due = (await db.rawQuery('SELECT COALESCE(SUM(total-paid),0) total FROM sales')).first['total'] as num;
    final purchases = (await db.rawQuery('SELECT COALESCE(SUM(total_cost),0) cost,COALESCE(SUM(net_kg),0) net FROM private_batches')).first;
    final expenseTotal = (await db.rawQuery('SELECT COALESCE(SUM(amount),0) amount FROM expenses')).first['amount'] as num;
    final netKg = purchases['net'] as num;
    final costPerKg = netKg > 0 ? (purchases['cost'] as num) / netKg : 0;
    final costOfSold = (s['weight'] as num) * costPerKg;
    final netProfit = (s['total'] as num) - costOfSold - expenseTotal;
    return {'sales':s['total'] as num,'paid':s['paid'] as num,'weight':s['weight'] as num,'collections':c,'debt':due-c,'purchaseCost':purchases['cost'] as num,'costPerKg':costPerKg,'costOfSold':costOfSold,'expenses':expenseTotal,'netProfit':netProfit};
  }
  Future<List<Map<String,Object?>>> reservations() async => (await database).query('reservations',orderBy:'created DESC');
  Future<int> addReservation(String name,String phone,double kg,int price,int deposit,String note) async {
    if(name.trim().isEmpty || kg<=0 || price<=0 || deposit<0) throw Exception('تحقق من اسم العميل والوزن والسعر والعربون');
    final total=(kg*price).round();
    if(deposit>total) throw Exception('العربون لا يمكن أن يتجاوز إجمالي الحجز');
    return (await database).insert('reservations',{'customer_name':name.trim(),'phone':phone.trim(),'kg':kg,'price':price,'total':total,'deposit':deposit,'status':'بانتظار وصول الكمية','note':note.trim(),'created':DateTime.now().toIso8601String()});
  }
  Future<void> updateReservationStatus(int id,String status) async => (await database).update('reservations',{'status':status},where:'id=?',whereArgs:[id]);
  Future<void> deleteReservation(int id) async => (await database).delete('reservations',where:'id=?',whereArgs:[id]);
  Future<Map<String,num>> customerTotals(int id) async {
    final db = await database;
    final s = (await db.rawQuery('SELECT COALESCE(SUM(total),0) total,COALESCE(SUM(paid),0) paid FROM sales WHERE customer_id=?',[id])).first;
    final c = (await db.rawQuery('SELECT COALESCE(SUM(amount),0) total FROM collections WHERE customer_id=?',[id])).first['total'] as num;
    final total = s['total'] as num, paid = s['paid'] as num;
    return {'sales':total,'paid':paid+c,'debt':total-paid-c};
  }
  Future<List<Map<String,Object?>>> salesForCustomer(int id) async => (await database).query('sales', where:'customer_id=?', whereArgs:[id], orderBy:'created DESC');
  Future<Map<String,Object?>?> customerById(int? id) async { if (id == null) return null; final rows = await (await database).query('customers', where:'id=?', whereArgs:[id], limit:1); return rows.isEmpty ? null : rows.first; }
  Future<List<Map<String,Object?>>> collectionsForCustomer(int id) async => (await database).query('collections', where:'customer_id=?', whereArgs:[id], orderBy:'created DESC');
  Future<String> setting(String key, String fallback) async {
    final result = await (await database).query('settings', where:'key=?', whereArgs:[key]);
    return result.isEmpty ? fallback : result.first['value'] as String;
  }
  Future<void> setSetting(String key, String value) async => (await database).insert('settings', {'key':key,'value':value}, conflictAlgorithm: ConflictAlgorithm.replace);
  Future<List<Map<String,Object?>>> privateBatches() async => (await database).query('private_batches', orderBy: 'created DESC');
  Future<List<Map<String,Object?>>> expenses() async => (await database).query('expenses', orderBy: 'created DESC');
  Future<int> addExpense(int amount, String note) async {
    if (amount <= 0) throw Exception('أدخل مبلغ مصروف صحيح');
    if (note.trim().isEmpty) throw Exception('اكتب بيان المصروف حتى يسهل مراجعته');
    return (await database).insert('expenses', {'amount':amount,'note':note.trim(),'created':DateTime.now().toIso8601String()});
  }
  Future<int> addPrivateBatch(double grossKg, int purchasePrice, double netKg, String note) async {
    if (grossKg <= 0 || purchasePrice <= 0 || netKg <= 0 || netKg > grossKg) throw Exception('تحقق من الوزن الإجمالي والصافي وسعر الشراء');
    return (await database).insert('private_batches', {'gross_kg':grossKg,'purchase_price':purchasePrice,'total_cost':(grossKg*purchasePrice).round(),'net_kg':netKg,'created':DateTime.now().toIso8601String(),'note':note.trim()});
  }
  Future<void> deleteSale(int id) async {
    final db = await database;
    final sale = (await db.query('sales',where:'id=?',whereArgs:[id])).first;
    final cid = sale['customer_id'];
    if (cid != null) {
      final remaining = (await db.rawQuery('SELECT COALESCE(SUM(total-paid),0) v FROM sales WHERE customer_id=?',[cid])).first['v'] as num;
      final collected = (await db.rawQuery('SELECT COALESCE(SUM(amount),0) v FROM collections WHERE customer_id=?',[cid])).first['v'] as num;
      final saleOutstanding = (sale['total'] as num) - (sale['paid'] as num);
      if (collected > remaining - saleOutstanding) throw Exception('لا يمكن حذف الفاتورة؛ توجد تحصيلات لا يمكن ربطها بعد الحذف.');
    }
    await db.delete('sales',where:'id=?',whereArgs:[id]);
  }
}
void showMessage(BuildContext context, String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(text)));

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override State<AppShell> createState() => _AppShellState();
}
class _AppShellState extends State<AppShell> {
  int selected = 0, revision = 0;
  void refreshAll() => setState(() => revision++);
  @override
  Widget build(BuildContext context) {
    final pages = [
      Dashboard(key:ValueKey(revision),onTab:(v)=>setState(()=>selected=v)),
      InvoicePage(key:ValueKey('invoice$revision')),
      CustomersPage(key:ValueKey('customers$revision')),
      ReportsPage(key:ValueKey('reports$revision')),
    ];
    return Scaffold(
      appBar: AppBar(title:Text(const ['الرئيسية','الفواتير','العملاء','التقارير'][selected]),actions:[
        IconButton(icon:const Icon(Icons.settings),onPressed:()async{await Navigator.push(context,MaterialPageRoute(builder:(_)=>const SettingsPage()));if(mounted)refreshAll();})
      ]),
      body:pages[selected],
      bottomNavigationBar:NavigationBar(selectedIndex:selected,onDestinationSelected:(v)=>setState(()=>selected=v),backgroundColor:panel,indicatorColor:gold.withValues(alpha:0.18),destinations:const [
        NavigationDestination(icon:Icon(Icons.home),label:'الرئيسية'),
        NavigationDestination(icon:Icon(Icons.receipt_long),label:'فواتير'),
        NavigationDestination(icon:Icon(Icons.people),label:'عملاء'),
        NavigationDestination(icon:Icon(Icons.bar_chart),label:'تقارير'),
      ]),
    );
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key,required this.onTab});
  final ValueChanged<int> onTab;
  @override State<Dashboard> createState()=>_DashboardState();
}
class _DashboardState extends State<Dashboard> {
  late Future<Map<String,num>> data;
  @override void initState(){super.initState();data=DB.instance.totals();}
  Widget metric(String label,String value,IconData icon)=>Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(icon,color:gold),Text(label),Text(value,style:const TextStyle(color:gold,fontWeight:FontWeight.bold))])));
  @override Widget build(BuildContext context) => FutureBuilder<Map<String,num>>(future:data,builder:(context,s)=>ListView(padding:const EdgeInsets.all(14),children:[
    const Icon(Icons.set_meal,color:gold,size:60),const Text('تونة بلس',textAlign:TextAlign.center,style:TextStyle(color:gold,fontSize:26,fontWeight:FontWeight.bold)),const Text('إدارة مبيعات التونة بالكيلو',textAlign:TextAlign.center),const SizedBox(height:12),
    if(s.hasError)Text('تعذر تحميل البيانات: ${s.error}'),
    GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:2,childAspectRatio:1.45,children:[
      metric('إجمالي المبيعات',money(s.data?['sales']??0),Icons.point_of_sale),
      metric('مدفوع الفواتير',money(s.data?['paid']??0),Icons.payments),
      metric('الرصيد المستحق',money(s.data?['debt']??0),Icons.account_balance),
      metric('الوزن المباع','${(s.data?['weight']??0).toStringAsFixed(3)} كجم',Icons.scale),
      metric('صافي الأرباح التقديري',money(s.data?['netProfit']??0),Icons.trending_up),
    ]),
    const SizedBox(height:12),
    FilledButton.icon(onPressed:()=>newSale(context).then((_)=>setState(()=>data=DB.instance.totals())),icon:const Icon(Icons.add),label:const Text('بيع جديد')),
    OutlinedButton.icon(onPressed:()=>newCustomer(context).then((_)=>setState(()=>data=DB.instance.totals())),icon:const Icon(Icons.person_add),label:const Text('إضافة عميل')),
    OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const ReservationsPage())),icon:const Icon(Icons.event_available),label:const Text('حجوزات الكمية القادمة')),
    ListTile(title:const Text('الفواتير'),trailing:const Icon(Icons.chevron_left),onTap:()=>widget.onTab(1)),
    ListTile(title:const Text('العملاء وكشف الحساب'),trailing:const Icon(Icons.chevron_left),onTap:()=>widget.onTab(2)),
    ListTile(title:const Text('التقارير'),trailing:const Icon(Icons.chevron_left),onTap:()=>widget.onTab(3)),
  ]));
}

Future<void> newCustomer(BuildContext context) async {
  final name=TextEditingController(),phone=TextEditingController(),note=TextEditingController();
  Future<void> chooseContact(BuildContext dialogContext,StateSetter setDialog) async {
    try {
      final allowed=await FlutterContacts.requestPermission();
      if(!allowed){if(dialogContext.mounted)showMessage(dialogContext,'يرجى السماح بالوصول إلى جهات الاتصال');return;}
      final contacts=await FlutterContacts.getContacts(withProperties:true);
      if(!dialogContext.mounted)return;
      final selected=await showDialog<Contact>(context:dialogContext,builder:(pickContext)=>AlertDialog(
        title:const Text('اختر من جهات الاتصال'),
        content:SizedBox(width:double.maxFinite,height:420,child:contacts.isEmpty?const Center(child:Text('لا توجد جهات اتصال')):ListView.builder(
          itemCount:contacts.length,itemBuilder:(context,index){final contact=contacts[index];final number=contact.phones.isEmpty?'':contact.phones.first.number;return ListTile(
            leading:const Icon(Icons.person,color:gold),title:Text(contact.displayName),subtitle:Text(number.isEmpty?'لا يوجد رقم هاتف':number),
            onTap:()=>Navigator.pop(pickContext,contact));})),
        actions:[TextButton(onPressed:()=>Navigator.pop(pickContext),child:const Text('إغلاق'))]));
      if(selected!=null){setDialog(()=>name.text=selected.displayName);if(selected.phones.isNotEmpty)setDialog(()=>phone.text=selected.phones.first.number);}
    } catch(e){if(dialogContext.mounted)showMessage(dialogContext,'تعذر قراءة جهات الاتصال: $e');}
  }
  await showDialog<void>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setDialog)=>AlertDialog(title:const Text('إضافة عميل'),content:Column(mainAxisSize:MainAxisSize.min,children:[
    OutlinedButton.icon(onPressed:()=>chooseContact(ctx,setDialog),icon:const Icon(Icons.contacts),label:const Text('اختيار من جهات الاتصال')),
    TextField(controller:name,decoration:const InputDecoration(labelText:'اسم العميل')),
    TextField(controller:phone,decoration:const InputDecoration(labelText:'الهاتف')),
    TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات')),
  ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await DB.instance.addCustomer(name.text,phone.text,note.text);if(ctx.mounted)Navigator.pop(ctx);}catch(e){showMessage(ctx,e.toString());}},child:const Text('حفظ'))])));
}

Future<void> newSale(BuildContext context) async {
  final clients=await DB.instance.customers();if(!context.mounted)return;
  int? customerId=clients.isEmpty?null:clients.first['id'] as int;
  final kgCtrl=TextEditingController(),priceCtrl=TextEditingController(text:await DB.instance.setting('price','6500')),paidCtrl=TextEditingController(),noteCtrl=TextEditingController();
  String type='نقدي';
  await showDialog<void>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setDialog)=>AlertDialog(title:const Text('بيع تونة'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
    DropdownButtonFormField<int>(initialValue:customerId,decoration:const InputDecoration(labelText:'العميل (اختياري)'),items:clients.map((c)=>DropdownMenuItem<int>(value:c['id'] as int,child:Text(c['name'] as String))).toList(),onChanged:(v)=>setDialog(()=>customerId=v)),
    TextField(controller:kgCtrl,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الوزن بالكيلو')),
    TextField(controller:priceCtrl,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'سعر الكيلو')),
    TextField(controller:paidCtrl,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المدفوع')),
    DropdownButtonFormField<String>(initialValue:type,decoration:const InputDecoration(labelText:'نوع البيع'),items:['نقدي','آجل'].map((x)=>DropdownMenuItem<String>(value:x,child:Text(x))).toList(),onChanged:(v)=>setDialog(()=>type=v??'نقدي')),
    TextField(controller:noteCtrl,decoration:const InputDecoration(labelText:'ملاحظات')),
  ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{
    final weight=double.parse(kgCtrl.text),price=int.parse(priceCtrl.text),total=(weight*price).round();
    final paid=paidCtrl.text.trim().isEmpty?(type=='نقدي'?total:0):int.parse(paidCtrl.text);
    await DB.instance.addSale(customerId,weight,price,paid,type,noteCtrl.text);await DB.instance.setSetting('price',price.toString());
    if(ctx.mounted)Navigator.pop(ctx);if(context.mounted)showMessage(context,'تم حفظ البيع بنجاح');
  }catch(e){showMessage(ctx,e.toString().replaceFirst('Exception: ',''));}},child:const Text('حفظ البيع'))])));
}

class ReservationsPage extends StatefulWidget {
  const ReservationsPage({super.key});
  @override State<ReservationsPage> createState()=>_ReservationsPageState();
}
class _ReservationsPageState extends State<ReservationsPage> {
  late Future<List<Map<String,Object?>>> future;
  @override void initState(){super.initState();future=DB.instance.reservations();}
  void reload()=>setState(()=>future=DB.instance.reservations());
  Future<void> add() async {
    final name=TextEditingController(),phone=TextEditingController(),kg=TextEditingController(),price=TextEditingController(text:'6500'),deposit=TextEditingController(text:'0'),note=TextEditingController();
    await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:const Text('حجز كمية قادمة'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:name,decoration:const InputDecoration(labelText:'اسم العميل')),
      TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم الهاتف')),
      TextField(controller:kg,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الوزن المطلوب بالكيلو')),
      TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'سعر الكيلو المتفق عليه')),
      TextField(controller:deposit,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'العربون (اختياري)')),
      TextField(controller:note,maxLines:2,decoration:const InputDecoration(labelText:'ملاحظات')),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{
      await DB.instance.addReservation(name.text,phone.text,double.parse(kg.text),int.parse(price.text),int.tryParse(deposit.text)??0,note.text);
      if(ctx.mounted)Navigator.pop(ctx);if(mounted)reload();
    }catch(e){showMessage(ctx,e.toString().replaceFirst('Exception: ',''));}},child:const Text('حفظ الحجز'))]));
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('حجوزات الكمية القادمة')),floatingActionButton:FloatingActionButton.extended(onPressed:add,icon:const Icon(Icons.add),label:const Text('حجز جديد')),body:FutureBuilder<List<Map<String,Object?>>>(future:future,builder:(context,s){
    if(s.hasError)return Center(child:Text('خطأ: ${s.error}'));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    if(s.data!.isEmpty)return const Center(child:Text('لا توجد حجوزات حتى الآن'));
    return ListView(padding:const EdgeInsets.all(12),children:s.data!.map((r)=>Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(r['customer_name'] as String,style:const TextStyle(color:gold,fontWeight:FontWeight.bold,fontSize:17)),
      Text('الهاتف: ${r['phone']??'—'}'),
      Text('الكمية: ${(r['kg'] as num).toStringAsFixed(3)} كجم • سعر الكيلو: ${money(r['price'] as num)}'),
      Text('الإجمالي: ${money(r['total'] as num)} • العربون: ${money(r['deposit'] as num)}'),
      Text('الحالة: ${r['status']}'),
      if((r['note'] as String? ?? '').isNotEmpty)Text('ملاحظات: ${r['note']}'),
      Row(children:[
        Expanded(child:DropdownButton<String>(isExpanded:true,value:r['status'] as String,items:['بانتظار وصول الكمية','مؤكد','تم التسليم','ملغي'].map((v)=>DropdownMenuItem(value:v,child:Text(v,overflow:TextOverflow.ellipsis))).toList(),onChanged:(v)async{if(v!=null){await DB.instance.updateReservationStatus(r['id'] as int,v);reload();}})),
        IconButton(tooltip:'حذف الحجز',onPressed:()async{await DB.instance.deleteReservation(r['id'] as int);reload();},icon:const Icon(Icons.delete_outline,color:Colors.red))
      ])
    ])))).toList());
  }));
}

class InvoicePage extends StatefulWidget{const InvoicePage({super.key});@override State<InvoicePage> createState()=>_InvoicePageState();}
class _InvoicePageState extends State<InvoicePage>{
  late Future<List<Map<String,Object?>>> future;@override void initState(){super.initState();future=DB.instance.sales();}
  void openInvoice(Map<String,Object?> sale)=>Navigator.push(context,MaterialPageRoute(builder:(_)=>InvoicePreview(sale:sale)));
  @override Widget build(BuildContext context)=>FutureBuilder<List<Map<String,Object?>>>(
    future:future,builder:(context,s)=>ListView(padding:const EdgeInsets.all(12),children:[
      FilledButton.icon(onPressed:()=>newSale(context).then((_)=>setState(()=>future=DB.instance.sales())),icon:const Icon(Icons.add),label:const Text('بيع جديد')),
      const SizedBox(height:8),
      if(s.hasError)Text('خطأ: ${s.error}') else if(!s.hasData)const Center(child:CircularProgressIndicator()) else if(s.data!.isEmpty)const Padding(padding:EdgeInsets.all(20),child:Text('لا توجد فواتير')) else ...s.data!.map((v)=>Card(child:ListTile(
        onTap:()=>openInvoice(v),
        title:Text('${v['invoice']} • ${money(v['total'] as num)}'),
        subtitle:Text('${v['kg']} كجم | ${v['kind']} | ${dateLabel(v['created'] as String)}\nمدفوع: ${money(v['paid'] as num)}'),
        leading:const Icon(Icons.receipt,color:gold),
        trailing:Wrap(children:[
          IconButton(tooltip:'عرض الفاتورة',icon:const Icon(Icons.visibility,color:gold),onPressed:()=>openInvoice(v)),
          IconButton(icon:const Icon(Icons.delete,color:Colors.red),onPressed:()async{try{await DB.instance.deleteSale(v['id'] as int);setState(()=>future=DB.instance.sales());}catch(e){showMessage(context,e.toString());}})
        ])
      ))),
    ]));
}

class InvoicePreview extends StatefulWidget{const InvoicePreview({super.key,required this.sale});final Map<String,Object?> sale;@override State<InvoicePreview> createState()=>_InvoicePreviewState();}
class _InvoicePreviewState extends State<InvoicePreview>{
  Map<String,Object?>? client;Map<String,String> storeInfo={};late Future<void> loaded;
  @override void initState(){super.initState();loaded=load();}
  Future<void> load()async{client=await DB.instance.customerById(widget.sale['customer_id'] as int?);storeInfo={'shop':await DB.instance.setting('shop','تونة بلس'),'phone':await DB.instance.setting('phone','777521058'),'bank':await DB.instance.setting('bank','254127488'),'owner':await DB.instance.setting('owner','محمد صالح بن صالح علي الخلاقي'),'address':await DB.instance.setting('address','فوه المتضررين بجانب مسجد هائل خلف البريد')};if(mounted)setState((){});}
  String val(String key,String fallback)=>widget.sale[key]?.toString()??fallback;
  Future<pw.Document> createInvoiceDocument()async{
    final shop=await DB.instance.setting('shop','تونة بلس');
    final phone=await DB.instance.setting('phone','777521058');
    final bank=await DB.instance.setting('bank','254127488');
    final owner=await DB.instance.setting('owner','محمد صالح بن صالح علي الخلاقي');
    final address=await DB.instance.setting('address','فوه المتضررين بجانب مسجد هائل خلف البريد');
    final sale=widget.sale;final total=sale['total'] as num;final paid=sale['paid'] as num;final due=total-paid;
    final arabicFont=await PdfGoogleFonts.amiriRegular();
    final arabicBold=await PdfGoogleFonts.amiriBold();
    final normal=pw.TextStyle(font:arabicFont,fontSize:11);
    final bold=pw.TextStyle(font:arabicBold,fontSize:14);
    final doc=pw.Document();
    doc.addPage(pw.Page(pageFormat:pdf.PdfPageFormat.a4,build:(_)=>pw.Directionality(textDirection:pw.TextDirection.rtl,child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.stretch,children:[
      pw.Container(padding:const pw.EdgeInsets.all(16),decoration:pw.BoxDecoration(color:pdf.PdfColor.fromHex('#161616')),child:pw.Column(children:[
        pw.Text(shop,style:pw.TextStyle(font:arabicBold,color:pdf.PdfColor.fromHex('#D7AF59'),fontSize:24)),
        pw.Text('فاتورة مبيعات • تونة بلس',style:pw.TextStyle(font:arabicFont,color:pdf.PdfColor.fromHex('#D7AF59'),fontSize:12))
      ])),
      pw.SizedBox(height:18),
      pw.Text('رقم الفاتورة: ${sale['invoice']}',style:bold,textAlign:pw.TextAlign.right),
      pw.Text('التاريخ: ${(sale['created'] as String).substring(0,16).replaceFirst('T',' ')}',style:normal,textAlign:pw.TextAlign.right),
      pw.Text('العميل: ${client?['name']??'عميل نقدي'}',style:normal,textAlign:pw.TextAlign.right),
      pw.SizedBox(height:14),
      pw.TableHelper.fromTextArray(data:[['الوزن (كجم)','سعر الكيلو','الإجمالي'],[sale['kg'].toString(),money(sale['price'] as num),money(total)]],headerStyle:pw.TextStyle(font:arabicBold,fontSize:11),cellStyle:normal),
      pw.SizedBox(height:16),
      pw.Text('الإجمالي: ${money(total)}',style:bold,textAlign:pw.TextAlign.right),
      pw.Text('المدفوع: ${money(paid)}',style:normal,textAlign:pw.TextAlign.right),
      pw.Text('المتبقي: ${money(due)}',style:bold,textAlign:pw.TextAlign.right),
      if((sale['note'] as String? ?? '').isNotEmpty)pw.Padding(padding:const pw.EdgeInsets.only(top:10),child:pw.Text('ملاحظات: ${sale['note']}',style:normal,textAlign:pw.TextAlign.right)),
      pw.SizedBox(height:22),pw.Divider(),
      pw.Text('بيانات التحويل البنكي',style:bold,textAlign:pw.TextAlign.right),
      pw.Text('بنك العميقي: $bank',style:normal,textAlign:pw.TextAlign.right),
      pw.Text(owner,style:normal,textAlign:pw.TextAlign.right),
      pw.Text('رقم الهاتف: $phone',style:normal,textAlign:pw.TextAlign.right),
      pw.Text('العنوان: $address',style:normal,textAlign:pw.TextAlign.right),
      pw.SizedBox(height:18),pw.Center(child:pw.Text('شكراً لثقتكم • تونة بلس',style:bold))
    ]))));
    return doc;
  }
  Future<void> printInvoice() async { final doc=await createInvoiceDocument(); await Printing.layoutPdf(onLayout:(_)=>doc.save()); }
  Future<void> shareInvoice() async { final doc=await createInvoiceDocument(); await Printing.sharePdf(bytes:await doc.save(),filename:'TunaPlus-${widget.sale['invoice']}.pdf'); }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('فاتورة العميل')),body:FutureBuilder<void>(future:loaded,builder:(context,s)=>ListView(padding:const EdgeInsets.all(16),children:[
    Card(child:Padding(padding:const EdgeInsets.all(20),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const Center(child:Icon(Icons.set_meal,color:gold,size:46)),
      Center(child:Text('تونة بلس',style:Theme.of(context).textTheme.headlineMedium?.copyWith(color:gold,fontWeight:FontWeight.bold))),
      const Center(child:Text('فاتورة مبيعات',style:TextStyle(fontSize:18))),
      const SizedBox(height:14),const Divider(),
      _invoiceRow('رقم الفاتورة',val('invoice','—')),
      _invoiceRow('التاريخ',dateLabel(val('created',DateTime.now().toIso8601String()))),
      _invoiceRow('العميل',client?['name']?.toString()??'عميل نقدي'),
      _invoiceRow('الوزن', '${val('kg','0')} كجم'),
      _invoiceRow('سعر الكيلو',money(widget.sale['price'] as num)),
      const Divider(),
      _invoiceRow('الإجمالي',money(widget.sale['total'] as num),strong:true),
      _invoiceRow('المدفوع',money(widget.sale['paid'] as num)),
      _invoiceRow('المتبقي',money((widget.sale['total'] as num)-(widget.sale['paid'] as num)),strong:true),
      if((widget.sale['note'] as String? ?? '').isNotEmpty)...[const SizedBox(height:8),Text('ملاحظات: ${widget.sale['note']}')],
      const Divider(),
      const Text('بيانات التحويل البنكي',style:TextStyle(color:gold,fontWeight:FontWeight.bold)),
      Text('بنك العميقي: ${storeInfo['bank']??'254127488'}'),
      Text(storeInfo['owner']??'محمد صالح بن صالح علي الخلاقي'),
      Text('جوال: ${storeInfo['phone']??'777521058'}'),
      Text(storeInfo['address']??'فوه المتضررين بجانب مسجد هائل خلف البريد'),
      const SizedBox(height:12),const Center(child:Text('شكراً لثقتكم • تونة بلس',style:TextStyle(color:gold))),
    ]))),
    FilledButton.icon(onPressed:printInvoice,icon:const Icon(Icons.picture_as_pdf),label:const Text('طباعة / حفظ الفاتورة PDF')),
    OutlinedButton.icon(onPressed:shareInvoice,icon:const Icon(Icons.share),label:const Text('مشاركة الفاتورة للعميل')),
  ])));
}
Widget _invoiceRow(String label,String value,{bool strong=false})=>Padding(padding:const EdgeInsets.symmetric(vertical:5),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text(label,style:strong?const TextStyle(fontWeight:FontWeight.bold,color:gold):null),Flexible(child:Text(value,textAlign:TextAlign.end,style:strong?const TextStyle(fontWeight:FontWeight.bold,color:gold):null))]));
class CustomersPage extends StatefulWidget{const CustomersPage({super.key});@override State<CustomersPage> createState()=>_CustomersPageState();}
class _CustomersPageState extends State<CustomersPage>{
  late Future<List<Map<String,Object?>>> future;@override void initState(){super.initState();future=DB.instance.customers();}
  @override Widget build(BuildContext context)=>FutureBuilder<List<Map<String,Object?>>>(future:future,builder:(context,s)=>Column(children:[
    Padding(padding:const EdgeInsets.all(10),child:FilledButton.icon(onPressed:()=>newCustomer(context).then((_)=>setState(()=>future=DB.instance.customers())),icon:const Icon(Icons.person_add),label:const Text('عميل جديد'))),
    Expanded(child:ListView(children:[if(s.hasError)Text('خطأ: ${s.error}') else if(!s.hasData)const Center(child:CircularProgressIndicator()) else ...s.data!.map((c)=>Card(child:ListTile(title:Text(c['name'] as String),subtitle:Text(c['phone'] as String? ?? ''),leading:const Icon(Icons.person,color:gold),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>CustomerLedger(client:c))))))]))
  ]));
}

class CustomerLedger extends StatefulWidget{const CustomerLedger({super.key,required this.client});final Map<String,Object?> client;@override State<CustomerLedger> createState()=>_CustomerLedgerState();}
class _CustomerLedgerState extends State<CustomerLedger>{
  late Future<Map<String,num>> balance;late Future<List<Map<String,Object?>>> invoices,receipts;int get id=>widget.client['id'] as int;
  void load(){balance=DB.instance.customerTotals(id);invoices=DB.instance.salesForCustomer(id);receipts=DB.instance.collectionsForCustomer(id);}
  @override void initState(){super.initState();load();}
  Future<void> receivePayment()async{
    final amount=TextEditingController(),note=TextEditingController();
    await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:const Text('تحصيل من العميل'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المبلغ')),TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات'))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await DB.instance.collect(id,int.parse(amount.text),note.text);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState(load);}catch(e){showMessage(ctx,e.toString());}},child:const Text('حفظ'))]));
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.client['name'] as String)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: receivePayment,
        icon: const Icon(Icons.payments),
        label: const Text('تحصيل'),
      ),
      body: FutureBuilder<Map<String, num>>(
        future: balance,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('خطأ: ${snapshot.error}'));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final totals = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: ListTile(
                  title: Text('المبيعات: ${money(totals['sales']!)}'),
                  subtitle: Text('المستلم: ${money(totals['paid']!)}'),
                  trailing: Text(
                    'المتبقي: ${money(totals['debt']!)}',
                    style: const TextStyle(color: gold, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              if ((widget.client['note'] as String? ?? '').isNotEmpty)
                Text('ملاحظات العميل: ${widget.client['note']}'),
              const Text('الفواتير', style: TextStyle(fontWeight: FontWeight.bold)),
              FutureBuilder<List<Map<String, Object?>>>(
                future: invoices,
                builder: (context, invoiceSnapshot) {
                  if (!invoiceSnapshot.hasData) return const SizedBox.shrink();
                  return Column(
                    children: invoiceSnapshot.data!.map((invoice) => Card(child:ListTile(
                      onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>InvoicePreview(sale:invoice))),
                      leading:const Icon(Icons.receipt_long,color:gold),
                      title: Text('${invoice['invoice']} • ${money(invoice['total'] as num)}'),
                      subtitle: Text(dateLabel(invoice['created'] as String)),
                      trailing:const Icon(Icons.chevron_left),
                    ))).toList(),
                  );
                },
              ),
              const Text('التحصيلات', style: TextStyle(fontWeight: FontWeight.bold)),
              FutureBuilder<List<Map<String, Object?>>>(
                future: receipts,
                builder: (context, receiptSnapshot) {
                  if (!receiptSnapshot.hasData) return const SizedBox.shrink();
                  return Column(
                    children: receiptSnapshot.data!.map((receipt) => ListTile(
                      title: Text(money(receipt['amount'] as num)),
                      subtitle: Text(receipt['note'] as String? ?? ''),
                    )).toList(),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
class ReportsPage extends StatelessWidget{
  const ReportsPage({super.key});
  Future<void> exportPdf()async{
    final t=await DB.instance.totals(),rows=await DB.instance.sales(),doc=pw.Document();
    final arabicFont=await PdfGoogleFonts.amiriRegular();
    final arabicBold=await PdfGoogleFonts.amiriBold();
    final normal=pw.TextStyle(font:arabicFont,fontSize:10);
    final bold=pw.TextStyle(font:arabicBold,fontSize:14);
    doc.addPage(pw.Page(build:(_)=>pw.Directionality(textDirection:pw.TextDirection.rtl,child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.stretch,children:[
      pw.Text('تقرير مبيعات تونة بلس',style:bold,textAlign:pw.TextAlign.right),
      pw.SizedBox(height:10),
      pw.Text('إجمالي المبيعات: ${money(t['sales']!)}',style:normal),
      pw.Text('المدفوع: ${money(t['paid']!)}',style:normal),
      pw.Text('التحصيلات: ${money(t['collections']!)}',style:normal),
      pw.Text('الرصيد المستحق: ${money(t['debt']!)}',style:normal),
      pw.Text('الوزن المباع: ${t['weight']!.toStringAsFixed(3)} كجم',style:normal),
      pw.Text('صافي الأرباح التقديري: ${money(t['netProfit']??0)}',style:bold),
      pw.SizedBox(height:12),
      pw.TableHelper.fromTextArray(data:[['رقم الفاتورة','التاريخ','الوزن','الإجمالي','المدفوع'],...rows.map((r)=>[r['invoice'],(r['created'] as String).substring(0,10),r['kg'],r['total'],r['paid']])],headerStyle:pw.TextStyle(font:arabicBold,fontSize:9),cellStyle:pw.TextStyle(font:arabicFont,fontSize:9))
    ]))));
    await Printing.layoutPdf(onLayout:(_)=>doc.save());
  }
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, num>>(
      future: DB.instance.totals(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('خطأ: ${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final totals = snapshot.data!;
        final labels = <String, String>{
          'sales': 'إجمالي المبيعات',
          'paid': 'مدفوع الفواتير',
          'collections': 'التحصيلات',
          'debt': 'الديون القائمة',
          'weight': 'الوزن المباع',
          'netProfit': 'صافي الأرباح التقديري',
        };
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            ...labels.entries.map((entry) => Card(
              child: ListTile(
                title: Text(entry.value),
                trailing: Text(entry.key == 'weight'
                    ? '${totals[entry.key]!.toStringAsFixed(3)} كجم'
                    : money(totals[entry.key]!)),
              ),
            )),
            FilledButton.icon(
              onPressed: exportPdf,
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('تصدير تقرير PDF'),
            ),
          ],
        );
      },
    );
  }
}
class PrivateCostPage extends StatefulWidget { const PrivateCostPage({super.key}); @override State<PrivateCostPage> createState()=>_PrivateCostPageState(); }
class _PrivateCostPageState extends State<PrivateCostPage> {
  late Future<List<Map<String,Object?>>> entries;
  late Future<List<Map<String,Object?>>> expenseEntries;
  @override void initState(){super.initState();entries=DB.instance.privateBatches();expenseEntries=DB.instance.expenses();}
  void reloadEntries(){entries=DB.instance.privateBatches();expenseEntries=DB.instance.expenses();}
  Future<void> addEntry() async {
    final gross=TextEditingController(),price=TextEditingController(),net=TextEditingController(),note=TextEditingController();
    await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:const Text('تسجيل شراء تونة (خاص)'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:gross,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الوزن الإجمالي عند الشراء (كجم)')),
      TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'تكلفة شراء الكيلو (ريال)')),
      TextField(controller:net,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الوزن الصافي بعد التقطيع (كجم)')),
      TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظة (اختياري)')),
      const SizedBox(height:8),const Text('هذه البيانات خاصة ولا تظهر في فواتير العملاء أو كشوفهم.')
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await DB.instance.addPrivateBatch(double.parse(gross.text),int.parse(price.text),double.parse(net.text),note.text);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState(reloadEntries);}catch(e){showMessage(ctx,e.toString().replaceFirst('Exception: ',''));}},child:const Text('حفظ'))]));
  }
  Future<void> addExpense() async {
    final amount=TextEditingController(),note=TextEditingController();
    await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:const Text('تسجيل مصروف خاص'),content:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'مبلغ المصروف (ريال)')),
      TextField(controller:note,maxLines:2,decoration:const InputDecoration(labelText:'بيان المصروف / ملاحظات')),
      const SizedBox(height:8),const Text('المصروفات خاصة ولا تظهر في فواتير العملاء أو كشوفهم.')
    ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await DB.instance.addExpense(int.parse(amount.text),note.text);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState(reloadEntries);}catch(e){showMessage(ctx,e.toString().replaceFirst('Exception: ',''));}},child:const Text('حفظ المصروف'))]));
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('حسابات الشراء والمصروفات الخاصة')),body:FutureBuilder<List<Map<String,Object?>>>(future:entries,builder:(context,s){
    if(s.hasError)return Center(child:Text('خطأ: ${s.error}'));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final rows=s.data!;
    final gross=rows.fold<num>(0,(a,r)=>a+(r['gross_kg'] as num));
    final net=rows.fold<num>(0,(a,r)=>a+(r['net_kg'] as num));
    final costs=rows.fold<num>(0,(a,r)=>a+(r['total_cost'] as num));
    final loss=gross-net;final eff=net==0?0:costs/net;
    return ListView(padding:const EdgeInsets.all(12),children:[
      const Text('بيانات سرية لصاحب المتجر فقط',textAlign:TextAlign.center,style:TextStyle(color:gold,fontWeight:FontWeight.bold)),
      GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:2,childAspectRatio:1.5,children:[
        Card(child:ListTile(title:const Text('إجمالي الشراء'),subtitle:Text('${gross.toStringAsFixed(2)} كجم'))),
        Card(child:ListTile(title:const Text('الوزن الصافي'),subtitle:Text('${net.toStringAsFixed(2)} كجم'))),
        Card(child:ListTile(title:const Text('إجمالي رأس المال'),subtitle:Text(money(costs)))),
        Card(child:ListTile(title:const Text('الفاقد'),subtitle:Text('${loss.toStringAsFixed(2)} كجم'))),
      ]),
      Card(child:ListTile(title:const Text('التكلفة الحقيقية للكيلو الصافي'),subtitle:Text(money(eff),style:const TextStyle(color:gold,fontWeight:FontWeight.bold)))),
      Card(child:ListTile(title:const Text('فرق المبيعات المسجلة والمشتريات المسجلة (تقريبي)'),subtitle:FutureBuilder<Map<String,num>>(future:DB.instance.totals(),builder:(context,t)=>FutureBuilder<List<Map<String,Object?>>>(future:expenseEntries,builder:(context,e){if(!t.hasData||!e.hasData)return const Text('...');final expenseTotal=e.data!.fold<num>(0,(sum,row)=>sum+(row['amount'] as num));return Text(money(t.data!['sales']!-costs-expenseTotal));})))),
      FilledButton.icon(onPressed:addEntry,icon:const Icon(Icons.add),label:const Text('إضافة عملية شراء')),
      const SizedBox(height:8),
      FutureBuilder<List<Map<String,Object?>>>(future:expenseEntries,builder:(context,e){
        if(!e.hasData)return const Card(child:ListTile(title:Text('إجمالي المصروفات'),subtitle:Text('جارٍ التحميل...')));
        final expenseTotal=e.data!.fold<num>(0,(sum,row)=>sum+(row['amount'] as num));
        return Column(children:[
          Card(child:ListTile(title:const Text('إجمالي المصروفات الخاصة'),subtitle:Text(money(expenseTotal),style:const TextStyle(color:gold,fontWeight:FontWeight.bold)))),
          FilledButton.tonalIcon(onPressed:addExpense,icon:const Icon(Icons.add),label:const Text('إضافة مصروف')),
          if(e.data!.isNotEmpty)const Align(alignment:Alignment.centerRight,child:Text('سجل المصروفات',style:TextStyle(fontWeight:FontWeight.bold))),
          ...e.data!.map((row)=>Card(child:ListTile(title:Text(money(row['amount'] as num)),subtitle:Text('${row['note']}\\n${dateLabel(row['created'] as String)}'),isThreeLine:true,leading:const Icon(Icons.money_off,color:gold))))
        ]);
      }),
      const Divider(),const Text('سجل المشتريات',style:TextStyle(fontWeight:FontWeight.bold)),
      if(rows.isEmpty)const Padding(padding:EdgeInsets.all(18),child:Text('لم تسجل مشتريات بعد',textAlign:TextAlign.center)),
      ...rows.map((r){final g=r['gross_kg'] as num,n=r['net_kg'] as num,pc=r['purchase_price'] as num,tc=r['total_cost'] as num;return Card(child:ListTile(title:Text('${dateLabel(r['created'] as String)}'),subtitle:Text('إجمالي: ${g.toStringAsFixed(2)} كجم • صافي: ${n.toStringAsFixed(2)} كجم • فاقد: ${(g-n).toStringAsFixed(2)} كجم\nشراء الكيلو: ${money(pc)} • الإجمالي: ${money(tc)}'),isThreeLine:true,trailing:Text(money(n==0?0:tc/n))));})
    ]);
  }));
}
class SettingsPage extends StatefulWidget{const SettingsPage({super.key});@override State<SettingsPage> createState()=>_SettingsPageState();}
class _SettingsPageState extends State<SettingsPage>{
  final store=TextEditingController(),phone=TextEditingController(),price=TextEditingController(),bank=TextEditingController(),owner=TextEditingController(),address=TextEditingController();
  @override void initState(){super.initState();load();}
  Future<void> load()async{store.text=await DB.instance.setting('shop','تونة بلس');phone.text=await DB.instance.setting('phone','777521058');price.text=await DB.instance.setting('price','6500');bank.text=await DB.instance.setting('bank','254127488');owner.text=await DB.instance.setting('owner','محمد صالح بن صالح علي الخلاقي');address.text=await DB.instance.setting('address','فوه المتضررين بجانب مسجد هائل خلف البريد');}
  Future<void> save()async{await DB.instance.setSetting('shop',store.text);await DB.instance.setSetting('phone',phone.text);await DB.instance.setSetting('price',price.text);await DB.instance.setSetting('bank',bank.text);await DB.instance.setSetting('owner',owner.text);await DB.instance.setSetting('address',address.text);if(mounted){showMessage(context,'تم حفظ الإعدادات');Navigator.pop(context);}}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('إعدادات المتجر')),body:ListView(padding:const EdgeInsets.all(16),children:[
    TextField(controller:store,decoration:const InputDecoration(labelText:'اسم المتجر')),
    TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم التواصل')),
    TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'سعر الكيلو الافتراضي (قابل للتغيير عند كل بيع)')),
    const SizedBox(height:14),const Text('بيانات الفواتير',style:TextStyle(color:gold,fontSize:18,fontWeight:FontWeight.bold)),
    TextField(controller:bank,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'رقم الحساب البنكي')),
    TextField(controller:owner,decoration:const InputDecoration(labelText:'اسم صاحب الحساب')),
    TextField(controller:address,maxLines:2,decoration:const InputDecoration(labelText:'عنوان المتجر')),
    const SizedBox(height:20),OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const PrivateCostPage())),icon:const Icon(Icons.lock),label:const Text('حسابات الشراء الخاصة (لا تظهر للزبائن)')),const SizedBox(height:12),FilledButton(onPressed:save,child:const Text('حفظ'))
  ]));
}
