import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart' as permissions;
import 'package:pdf_text_shaper/pdf_text_shaper.dart';

const gold = Color(0xFFD7AF59);
const dark = Color(0xFF101114);
const panel = Color(0xFF202024);

// Session-only contact cache to avoid repeatedly querying and sorting the full address book.
List<Contact>? _contactCache;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar');
  await DB.instance.database;
  runApp(const TunaApp());
}
String money(num value) => '${NumberFormat('#,##0', 'en').format(value)} ر.ي';
String dateLabel(String value) => DateFormat('yyyy/MM/dd HH:mm').format(DateTime.parse(value));

// HarfBuzz shapes Arabic from Unicode using the bundled Noto Naskh font.
// The font is loaded locally: invoices and reports work without internet access.
Future<ShapedFont> loadArabicPdfFont() async {
  final data = await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf');
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return ShapedFont.fromBytes(bytes, name: 'Noto Naskh Arabic');
}

pw.Widget pdfText(
  String value,
  ShapedFont font, {
  double fontSize = 11,
  pdf.PdfColor? color,
  ShapedTextAlign align = ShapedTextAlign.end,
}) => ShapedText(
  // Normalize unsupported decorative bullets before shaping text with the Arabic font.
  value.replaceAll('•', '-'),
  style: ShapedTextStyle(
    font: font,
    fontSize: fontSize,
    color: color ?? pdf.PdfColors.black,
    direction: ShapedTextDirection.auto,
    align: align,
    preserveUnicodeText: true,
  ),
);

pw.Widget pdfCell(String value, ShapedFont font, {bool header = false}) =>
    pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pdfText(
        value,
        font,
        fontSize: header ? 8.5 : 9,
        color: header ? pdf.PdfColors.white : pdf.PdfColors.black,
        align: ShapedTextAlign.center,
      ),
    );

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
    final db = await database;
    final total = (kg * price).round();
    if (total <= 0) throw Exception('قيمة الفاتورة غير صحيحة');
    if (paid > total) throw Exception('المدفوع لا يتجاوز الإجمالي');
    if (type == 'نقدي' && paid != total) throw Exception('البيع النقدي يجب أن يكون مدفوعاً بالكامل');
    // Run stock validation and sale insertion in one transaction to prevent two
    // simultaneous sales from overselling the same remaining inventory.
    return db.transaction((txn) async {
      final available = (await txn.rawQuery('SELECT COALESCE(SUM(net_kg),0) net FROM private_batches')).first['net'] as num;
      final sold = (await txn.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sales')).first['kg'] as num;
      if (available - sold + 0.0001 < kg) throw Exception('الوزن المطلوب يتجاوز المخزون الصافي المتاح (${(available-sold).toStringAsFixed(3)} كجم).');
      return txn.insert('sales', {
        'invoice':'TP-${DateTime.now().microsecondsSinceEpoch}','customer_id':customerId,
        'kg':kg,'price':price,'total':total,'paid':paid,'kind':type,'note':note.trim(),
        'created':DateTime.now().toIso8601String()
      });
    });
  }
  Future<int> collect(int customerId, int amount, String note) async {
    if (amount <= 0) throw Exception('أدخل مبلغ تحصيل صحيح');
    final db = await database;
    return db.transaction((txn) async {
      final saleDue = (await txn.rawQuery('SELECT COALESCE(SUM(total-paid),0) AS v FROM sales WHERE customer_id=?',[customerId])).first['v'] as num;
      final collected = (await txn.rawQuery('SELECT COALESCE(SUM(amount),0) AS v FROM collections WHERE customer_id=?',[customerId])).first['v'] as num;
      if (amount > saleDue - collected) throw Exception('المبلغ أكبر من الرصيد المستحق');
      return txn.insert('collections', {'customer_id':customerId,'amount':amount,'note':note,'created':DateTime.now().toIso8601String()});
    });
  }
  Future<Map<String,num>> totals() async {
    final db=await database;
    final s=(await db.rawQuery('SELECT COALESCE(SUM(total),0) total,COALESCE(SUM(paid),0) paid,COALESCE(SUM(kg),0) weight FROM sales')).first;
    final c=(await db.rawQuery('SELECT COALESCE(SUM(amount),0) total FROM collections')).first['total'] as num;
    final due=(await db.rawQuery('SELECT COALESCE(SUM(total-paid),0) total FROM sales')).first['total'] as num;
    final batches=await db.query('private_batches',orderBy:'created ASC,id ASC');
    final sales=await db.query('sales',orderBy:'created ASC,id ASC');
    final expenseTotal=(await db.rawQuery('SELECT COALESCE(SUM(amount),0) amount FROM expenses')).first['amount'] as num;
    final stockNetKg=batches.fold<num>(0,(sum,b)=>sum+(b['net_kg'] as num));
    final purchaseCost=batches.fold<num>(0,(sum,b)=>sum+(b['total_cost'] as num));
    final soldKg=s['weight'] as num;
    var remainingByBatch=batches.map((b)=>(b['net_kg'] as num).toDouble()).toList();
    var costOfSold=0.0,inventoryCost=0.0,unallocatedSoldKg=0.0;
    final unitCosts=batches.map((b){
      final net=(b['net_kg'] as num).toDouble();
      return net>0?(b['total_cost'] as num).toDouble()/net:0.0;
    }).toList();
    for(final sale in sales){
      var qty=(sale['kg'] as num).toDouble();
      for(int i=0;i<remainingByBatch.length&&qty>0.000001;i++){
        final available=remainingByBatch[i]>0?remainingByBatch[i]:0.0;
        final take=qty<available?qty:available;
        if(take<=0)continue;
        costOfSold+=take*unitCosts[i];
        remainingByBatch[i]-=take;
        qty-=take;
      }
      // Track historic sold weight that cannot be assigned to available stock.
      if(qty>0.000001)unallocatedSoldKg+=qty;
    }
    for(int i=0;i<remainingByBatch.length;i++){
      inventoryCost+=remainingByBatch[i]>0?remainingByBatch[i]*unitCosts[i]:0;
    }
    final remainingKg=remainingByBatch.fold<double>(0,(sum,v)=>sum+(v>0?v:0));
    final costPerNetKg=stockNetKg>0?purchaseCost/stockNetKg:0.0;
    final expensesAllocated=stockNetKg>0?expenseTotal*(soldKg/stockNetKg).clamp(0,1):0.0;
    final netProfit=(s['total'] as num)-costOfSold-expensesAllocated;
    final finalProfit=stockNetKg>0&&remainingKg<=0.0001;
    return {'sales':s['total'] as num,'paid':s['paid'] as num,'weight':soldKg,'collections':c,'debt':due-c,'purchaseCost':purchaseCost,'costPerKg':costPerNetKg,'costOfSold':costOfSold,'inventoryCost':inventoryCost,'stockNetKg':stockNetKg,'remainingKg':remainingKg,'expenses':expenseTotal,'expensesAllocated':expensesAllocated,'netProfit':unallocatedSoldKg>0.0001?0:netProfit,'unallocatedSoldKg':unallocatedSoldKg,'profitReliable':unallocatedSoldKg<=0.0001?1:0,'profitFinal':finalProfit&&unallocatedSoldKg<=0.0001?1:0};
  }
  Future<List<Map<String,Object?>>> reservations() async => (await database).query('reservations',orderBy:'created DESC');
  Future<int> addReservation(String name,String phone,double kg,int price,int deposit,String note) async {
    if(name.trim().isEmpty || !kg.isFinite || kg<=0 || price<=0 || deposit<0) throw Exception('تحقق من اسم العميل والوزن والسعر والعربون');
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
    if (!grossKg.isFinite || grossKg <= 0 || purchasePrice <= 0 || !netKg.isFinite || netKg <= 0 || netKg > grossKg) throw Exception('تحقق من الوزن الإجمالي والصافي وسعر الشراء');
    return (await database).insert('private_batches', {'gross_kg':grossKg,'purchase_price':purchasePrice,'total_cost':(grossKg*purchasePrice).round(),'net_kg':netKg,'created':DateTime.now().toIso8601String(),'note':note.trim()});
  }
  // FIFO batch statement: calculates allocation of historical sales without modifying saved data.
  Future<Map<String,Object?>> privateBatchStatement(int batchId) async {
    final db=await database;
    final batches=await db.query('private_batches',orderBy:'created ASC,id ASC');
    final sales=await db.query('sales',orderBy:'created ASC,id ASC');
    final expenseRows=await db.query('expenses');
    final batchIndex=batches.indexWhere((b)=>(b['id'] as int)==batchId);
    if(batchIndex<0) throw Exception('عملية الشراء غير موجودة');
    final batch=batches[batchIndex];
    final netKg=(batch['net_kg'] as num).toDouble();
    final totalCost=(batch['total_cost'] as num).toDouble();
    final unitCost=netKg>0?totalCost/netKg:0.0;
    final remainingByBatch=batches.map((b)=>(b['net_kg'] as num).toDouble()).toList();
    double soldKg=0,revenue=0,unallocatedSoldKg=0;
    final allocatedSales=<Map<String,Object?>>[];
    for(final sale in sales){
      double saleRemaining=(sale['kg'] as num).toDouble();
      final saleKg=(sale['kg'] as num).toDouble();
      final saleTotal=(sale['total'] as num).toDouble();
      for(int bi=0;bi<remainingByBatch.length && saleRemaining>0.000001;bi++){
        final available=remainingByBatch[bi]>0?remainingByBatch[bi]:0.0;
        final take=saleRemaining<available?saleRemaining:available;
        if(take<=0)continue;
        if(bi==batchIndex){
          soldKg+=take;
          final allocatedRevenue=saleKg>0?saleTotal*(take/saleKg):0.0;
          revenue+=allocatedRevenue;
          allocatedSales.add({'invoice':sale['invoice'],'created':sale['created'],'kg':take,'revenue':allocatedRevenue,'unitPrice':sale['price']});
        }
        remainingByBatch[bi]-=take;
        saleRemaining-=take;
      }
      if(saleRemaining>0.000001)unallocatedSoldKg+=saleRemaining;
    }
    final totalNetStock=batches.fold<num>(0,(sum,b)=>sum+(b['net_kg'] as num));
    final expenses=expenseRows.fold<num>(0,(sum,e)=>sum+(e['amount'] as num));
    final expenseShare=totalNetStock>0?expenses*(soldKg/totalNetStock):0.0;
    final costOfSold=soldKg*unitCost;
    final remainingKg=(netKg-soldKg).clamp(0.0,netKg);
    final profitReliable=unallocatedSoldKg<=0.0001;
    // Do not display a profit figure that could be misleading when any historical
    // sale cannot be allocated to purchase stock.
    final safeProfit=profitReliable?revenue-costOfSold-expenseShare:0.0;
    return {'batch':batch,'netKg':netKg,'cost':totalCost,'unitCost':unitCost,'soldKg':soldKg,'remainingKg':remainingKg,'revenue':revenue,'costOfSold':costOfSold,'expenseShare':expenseShare,'profit':safeProfit,'profitReliable':profitReliable,'expenseTotal':expenses,'unallocatedSoldKg':unallocatedSoldKg,'allocations':allocatedSales};
  }
  Future<void> updatePrivateBatch(int id,double grossKg,int purchasePrice,double netKg,String note) async {
    if(!grossKg.isFinite || grossKg<=0 || purchasePrice<=0 || !netKg.isFinite || netKg<=0 || netKg>grossKg) throw Exception('تحقق من الوزن الإجمالي والصافي وسعر الشراء');
    final db=await database;
    // Validate and update within one transaction so stock cannot change between check and write.
    await db.transaction((txn) async {
      final oldRows=await txn.query('private_batches',where:'id=?',whereArgs:[id],limit:1);
      if(oldRows.isEmpty) throw Exception('عملية الشراء غير موجودة');
      final sold=(await txn.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sales')).first['kg'] as num;
      final stock=(await txn.rawQuery('SELECT COALESCE(SUM(net_kg),0) kg FROM private_batches')).first['kg'] as num;
      final old=oldRows.first;
      final resultingNet=stock-(old['net_kg'] as num)+netKg;
      if(resultingNet+0.0001<sold) throw Exception('لا يمكن تعديل الشراء: المخزون الصافي الناتج أقل من الوزن المباع.');
      await txn.update('private_batches',{'gross_kg':grossKg,'purchase_price':purchasePrice,'total_cost':(grossKg*purchasePrice).round(),'net_kg':netKg,'note':note.trim()},where:'id=?',whereArgs:[id]);
    });
  }
  Future<void> deletePrivateBatch(int id) async {
    final db=await database;
    // Protect stock validation and removal as one atomic operation.
    await db.transaction((txn) async {
      final oldRows=await txn.query('private_batches',where:'id=?',whereArgs:[id],limit:1);
      if(oldRows.isEmpty) throw Exception('عملية الشراء غير موجودة');
      final sold=(await txn.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sales')).first['kg'] as num;
      final stock=(await txn.rawQuery('SELECT COALESCE(SUM(net_kg),0) kg FROM private_batches')).first['kg' ] as num;
      final old=oldRows.first;
      if(stock-(old['net_kg'] as num)+0.0001<sold) throw Exception('لا يمكن حذف الشراء لأنه سيجعل المخزون أقل من الوزن المباع.');
      await txn.delete('private_batches',where:'id=?',whereArgs:[id]);
    });
  }
  Future<void> deleteSale(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows=await txn.query('sales',where:'id=?',whereArgs:[id],limit:1);
      if(rows.isEmpty) throw Exception('الفاتورة غير موجودة');
      final sale=rows.first;
      final cid=sale['customer_id'];
      if(cid!=null){
        final remaining=(await txn.rawQuery('SELECT COALESCE(SUM(total-paid),0) v FROM sales WHERE customer_id=?',[cid])).first['v'] as num;
        final collected=(await txn.rawQuery('SELECT COALESCE(SUM(amount),0) v FROM collections WHERE customer_id=?',[cid])).first['v'] as num;
        final saleOutstanding=(sale['total'] as num)-(sale['paid'] as num);
        if(collected>remaining-saleOutstanding) throw Exception('لا يمكن حذف الفاتورة؛ توجد تحصيلات لا يمكن ربطها بعد الحذف.');
      }
      await txn.delete('sales',where:'id=?',whereArgs:[id]);
    });
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
      body:SafeArea(top:false,child:pages[selected]),
      bottomNavigationBar:SafeArea(top:false,child:NavigationBar(selectedIndex:selected,onDestinationSelected:(v)=>setState(()=>selected=v),backgroundColor:panel,indicatorColor:gold.withValues(alpha:0.18),destinations:const [
        NavigationDestination(icon:Icon(Icons.home),label:'الرئيسية'),
        NavigationDestination(icon:Icon(Icons.receipt_long),label:'فواتير'),
        NavigationDestination(icon:Icon(Icons.people),label:'عملاء'),
        NavigationDestination(icon:Icon(Icons.bar_chart),label:'تقارير'),
      ])),
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
      metric((s.data?['profitReliable']??1)<=0?'الربح غير محسوب (نقص مخزون)':((s.data?['profitFinal']??0)>0?'صافي الربح النهائي':'الربح من المبيعات (غير نهائي)'),money(s.data?['netProfit']??0),Icons.trending_up),
    ]),
    if((s.data?['unallocatedSoldKg']??0)>0.0001)Card(color:Colors.orange.withValues(alpha:0.12),child:Padding(padding:const EdgeInsets.all(12),child:Text('تنبيه محاسبي: يوجد وزن مبيعات غير موزع على المخزون مقدار ${(s.data?['unallocatedSoldKg']??0).toStringAsFixed(3)} كجم. لا تعتمد الربح قبل مراجعة عمليات الشراء والمبيعات.',style:const TextStyle(color:Colors.orange,fontWeight:FontWeight.bold)))),
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
  bool selectingContact=false;
  Future<void> chooseContact(BuildContext dialogContext,StateSetter setDialog) async {
    if(selectingContact)return;
    selectingContact=true;
    // Keep the user informed while the native permission prompt or contact query is running.
    bool loadingDialogOpen=false;
    try {
      // Use the contacts plugin's own permission request before querying its native API.
      // This keeps the permission flow aligned with the exact plugin that reads the address book.
      var contactPermission=await permissions.Permission.contacts.status;
      final pluginPermissionGranted=contactPermission.isGranted
          ? true
          : await FlutterContacts.requestPermission(readonly:true);
      if(!contactPermission.isGranted && pluginPermissionGranted) {
        contactPermission=await permissions.Permission.contacts.status;
      }
      if(!pluginPermissionGranted || !contactPermission.isGranted){
        if(dialogContext.mounted){
          if(contactPermission.isPermanentlyDenied){
            await showDialog<void>(context:dialogContext,builder:(permissionContext)=>AlertDialog(
              title:const Text('إذن جهات الاتصال مطلوب'),
              content:const Text('تم رفض الإذن نهائياً. افتح إعدادات التطبيق واسمح بالوصول إلى جهات الاتصال، ثم أعد المحاولة.'),
              actions:[TextButton(onPressed:()=>Navigator.pop(permissionContext),child:const Text('لاحقاً')),FilledButton(onPressed:()async{Navigator.pop(permissionContext);await permissions.openAppSettings();},child:const Text('فتح الإعدادات'))],
            ));
          }else{
            showMessage(dialogContext,'لم يتم منح إذن جهات الاتصال. يمكنك المحاولة مرة أخرى.');
          }
        }
        return;
      }
      if(!dialogContext.mounted)return;
      loadingDialogOpen=true;
      showDialog<void>(context:dialogContext,barrierDismissible:false,builder:(loadingContext)=>const AlertDialog(
        content:Row(mainAxisSize:MainAxisSize.min,children:[CircularProgressIndicator(),SizedBox(width:16),Flexible(child:Text('جارٍ تحميل جهات الاتصال...'))]),
      ));
      final contacts=_contactCache ?? await FlutterContacts.getContacts(withProperties:true);
      if(dialogContext.mounted&&loadingDialogOpen){Navigator.of(dialogContext,rootNavigator:true).pop();loadingDialogOpen=false;}
      if(!dialogContext.mounted)return;
      if(_contactCache==null){
        contacts.sort((a,b)=>a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
        _contactCache=contacts;
      }
      final searchController=TextEditingController();
      final selected=await showDialog<Contact>(
        context:dialogContext,
        builder:(pickContext)=>StatefulBuilder(builder:(pickContext,refreshPicker){
          final query=searchController.text.trim().toLowerCase();
          final filtered=contacts.where((contact){
            final numbers=contact.phones.map((p)=>p.number).join(' ');
            return contact.displayName.toLowerCase().contains(query)||numbers.toLowerCase().contains(query);
          }).toList();
          return AlertDialog(
            title:const Text('اختر من جهات الاتصال'),
            content:SizedBox(width:double.maxFinite,height:MediaQuery.of(pickContext).size.height*0.65,child:Column(children:[
              TextField(controller:searchController,decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'بحث بالاسم أو رقم الهاتف'),onChanged:(_)=>refreshPicker((){})),
              const SizedBox(height:6),
              Expanded(child:filtered.isEmpty?const Center(child:Text('لا توجد نتائج')):ListView.builder(
                itemCount:filtered.length,
                itemBuilder:(context,index){
                  final contact=filtered[index];
                  final displayPhone=contact.phones.isEmpty?'':contact.phones.first.number;
                  return ListTile(leading:const Icon(Icons.person,color:gold),title:Text(contact.displayName.isEmpty?'بدون اسم':contact.displayName),subtitle:Text(displayPhone.isEmpty?'لا يوجد رقم هاتف':displayPhone),onTap:()=>Navigator.pop(pickContext,contact));
                })),
            ])),
            actions:[TextButton(onPressed:()=>Navigator.pop(pickContext),child:const Text('إغلاق'))],
          );
        }),
      );
      searchController.dispose();
      if(selected!=null){
        setDialog(()=>name.text=selected.displayName);
        if(selected.phones.isNotEmpty){
          String? chosen=selected.phones.first.number;
          if(selected.phones.length>1 && dialogContext.mounted){
            chosen=await showDialog<String>(
              context:dialogContext,
              builder:(phoneContext)=>AlertDialog(
                title:const Text('اختر رقم الهاتف'),
                content:SizedBox(height:MediaQuery.of(phoneContext).size.height*0.45,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:selected.phones.map((p)=>ListTile(title:Text(p.number),subtitle:Text(p.label.name),onTap:()=>Navigator.pop(phoneContext,p.number))).toList()))),
                actions:[TextButton(onPressed:()=>Navigator.pop(phoneContext),child:const Text('إلغاء'))],
              ),
            );
          }
          if(chosen!=null)setDialog(()=>phone.text=chosen!);
        }
      }
    } catch(e){
      if(dialogContext.mounted&&loadingDialogOpen){Navigator.of(dialogContext,rootNavigator:true).pop();loadingDialogOpen=false;}
      if(dialogContext.mounted)showMessage(dialogContext,'تعذر فتح جهات الاتصال: $e');
    } finally {
      selectingContact=false;
      if(dialogContext.mounted)setDialog((){});
    }
  }
  await showDialog<void>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setDialog)=>AlertDialog(title:const Text('إضافة عميل'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
    SizedBox(width:double.maxFinite,child:OutlinedButton.icon(onPressed:selectingContact?null:()=>chooseContact(ctx,setDialog),icon:selectingContact?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.contacts),label:Text(selectingContact?'جارٍ فتح جهات الاتصال...':'اختيار من جهات الاتصال'))),
    TextField(controller:name,decoration:const InputDecoration(labelText:'اسم العميل')),
    TextField(controller:phone,decoration:const InputDecoration(labelText:'الهاتف'),keyboardType:TextInputType.phone),
    TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات')),
  ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await DB.instance.addCustomer(name.text,phone.text,note.text);if(ctx.mounted)Navigator.pop(ctx);}catch(e){showMessage(ctx,e.toString());}},child:const Text('حفظ'))])));
}

Future<void> newSale(BuildContext context) async {
  final clients=await DB.instance.customers();if(!context.mounted)return;
  int? customerId; // Cash sales are not assigned to a customer by default.
  final kgCtrl=TextEditingController(),priceCtrl=TextEditingController(text:await DB.instance.setting('price','6500')),paidCtrl=TextEditingController(),noteCtrl=TextEditingController();
  String type='نقدي';
  await showDialog<void>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setDialog)=>AlertDialog(title:const Text('بيع تونة'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
    DropdownButtonFormField<int>(initialValue:customerId,decoration:const InputDecoration(labelText:'العميل (اختياري — اتركه فارغًا للبيع النقدي)'),items:[const DropdownMenuItem<int>(value:null,child:Text('بيع نقدي بدون تسجيل عميل')), ...clients.map((c)=>DropdownMenuItem<int>(value:c['id'] as int,child:Text(c['name'] as String)))],onChanged:(v)=>setDialog(()=>customerId=v)),
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
    final active=s.data!.where((r)=>r['status']!='تم التسليم'&&r['status']!='ملغي');
    final activeKg=active.fold<num>(0,(sum,r)=>sum+(r['kg'] as num));
    final activeCount=active.length;
    if(s.data!.isEmpty)return const Center(child:Text('لا توجد حجوزات حتى الآن'));
    return ListView(padding:const EdgeInsets.all(12),children:[
      Card(
        color: gold.withValues(alpha: 0.12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('إجمالي الكميات المحجوزة القادمة', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('${activeKg.toStringAsFixed(3)} كجم', style: const TextStyle(fontSize: 22, color: gold, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              Column(
                children: [
                  const Text('الحجوزات النشطة'),
                  Text('$activeCount', style: const TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 18)),
                ],
              ),
            ],
          ),
        ),
      ),
      ...s.data!.map((r)=>Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(r['customer_name'] as String,style:const TextStyle(color:gold,fontWeight:FontWeight.bold,fontSize:17)),
        Text('الهاتف: ${r['phone']??'—'}'),
        Text('الكمية: ${(r['kg'] as num).toStringAsFixed(3)} كجم - سعر الكيلو: ${money(r['price'] as num)}'),
        Text('الإجمالي: ${money(r['total'] as num)} - العربون: ${money(r['deposit'] as num)}'),
        Text('الحالة: ${r['status']}'),
        if((r['note'] as String? ?? '').isNotEmpty)Text('ملاحظات: ${r['note']}'),
        Row(children:[
          Expanded(child:DropdownButton<String>(isExpanded:true,value:r['status'] as String,items:['بانتظار وصول الكمية','مؤكد','تم التسليم','ملغي'].map((v)=>DropdownMenuItem(value:v,child:Text(v,overflow:TextOverflow.ellipsis))).toList(),onChanged:(v)async{if(v!=null){await DB.instance.updateReservationStatus(r['id'] as int,v);reload();}})),
          IconButton(tooltip:'حذف الحجز',onPressed:()async{await DB.instance.deleteReservation(r['id'] as int);reload();},icon:const Icon(Icons.delete_outline,color:Colors.red))
        ])
      ])))).toList(),
    ]);
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
  Map<String,Object?>? client;Map<String,String> storeInfo={};late Future<void> loaded;bool pdfBusy=false;
  @override void initState(){super.initState();loaded=load();}
  Future<void> load()async{client=await DB.instance.customerById(widget.sale['customer_id'] as int?);storeInfo={'shop':await DB.instance.setting('shop','تونة بلس'),'phone':await DB.instance.setting('phone','777521058'),'bank':await DB.instance.setting('bank','254127488'),'owner':await DB.instance.setting('owner','محمد صالح بن صالح علي الخلاقي'),'address':await DB.instance.setting('address','فوه المتضررين بجانب مسجد هائل خلف البريد')};if(mounted)setState((){});}
  String val(String key,String fallback)=>widget.sale[key]?.toString()??fallback;
  Future<Uint8List> createInvoicePdf() async {
    final font = await loadArabicPdfFont();
    try {
      final shop = await DB.instance.setting('shop', 'تونة بلس');
      final phone = await DB.instance.setting('phone', '777521058');
      final bank = await DB.instance.setting('bank', '254127488');
      final owner = await DB.instance.setting('owner', 'محمد صالح بن صالح علي الخلاقي');
      final address = await DB.instance.setting('address', 'فوه المتضررين بجانب مسجد هائل خلف البريد');
      final sale = widget.sale;
      final total = sale['total'] as num;
      final paid = sale['paid'] as num;
      final due = total - paid;
      final doc = pw.Document();

      doc.addPage(pw.Page(
        pageFormat: pdf.PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (_) => pw.Directionality(
          textDirection: pw.TextDirection.rtl,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Container(
                padding: const pw.EdgeInsets.all(16),
                decoration: pw.BoxDecoration(color: pdf.PdfColor.fromHex('#161616')),
                child: pw.Column(children: [
                  pdfText(shop, font, fontSize: 24, color: pdf.PdfColor.fromHex('#D7AF59'), align: ShapedTextAlign.center),
                  pdfText('فاتورة مبيعات • تونة بلس', font, fontSize: 13, color: pdf.PdfColor.fromHex('#D7AF59'), align: ShapedTextAlign.center),
                ]),
              ),
              pw.SizedBox(height: 18),
              pdfText('رقم الفاتورة: ${sale['invoice']}', font, fontSize: 12),
              pdfText('التاريخ: ${(sale['created'] as String).substring(0,16).replaceFirst('T',' ')}', font),
              pdfText('العميل: ${client?['name'] ?? 'عميل نقدي'}', font),
              pw.SizedBox(height: 14),
              pw.Table(
                border: pw.TableBorder.all(color: pdf.PdfColor.fromHex('#C8B58C'), width: 0.6),
                children: [
                  pw.TableRow(
                    decoration: pw.BoxDecoration(color: pdf.PdfColor.fromHex('#2C2924')),
                    children: [
                      pdfCell('الوزن (كجم)', font, header: true),
                      pdfCell('سعر الكيلو', font, header: true),
                      pdfCell('الإجمالي', font, header: true),
                    ],
                  ),
                  pw.TableRow(children: [
                    pdfCell(sale['kg'].toString(), font),
                    pdfCell(money(sale['price'] as num), font),
                    pdfCell(money(total), font),
                  ]),
                ],
              ),
              pw.SizedBox(height: 16),
              pdfText('الإجمالي: ${money(total)}', font, fontSize: 14),
              pdfText('المدفوع: ${money(paid)}', font),
              pdfText('المتبقي: ${money(due)}', font, fontSize: 13),
              if ((sale['note'] as String? ?? '').isNotEmpty)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 10),
                  child: pdfText('ملاحظات: ${sale['note']}', font),
                ),
              pw.SizedBox(height: 22),
              pw.Divider(),
              pdfText('بيانات التحويل البنكي', font, fontSize: 14, color: pdf.PdfColor.fromHex('#9A742B')),
              pdfText('بنك العميقي: $bank', font),
              pdfText(owner, font),
              pdfText('رقم الهاتف: $phone', font),
              pdfText('العنوان: $address', font),
              pw.SizedBox(height: 18),
              pdfText('شكراً لثقتكم • تونة بلس', font, fontSize: 13, align: ShapedTextAlign.center),
            ],
          ),
        ),
      ));
      return await doc.save();
    } finally {
      font.dispose();
    }
  }

  Future<void> printInvoice() async {
    if(pdfBusy)return;
    setState(()=>pdfBusy=true);
    try {
      final bytes = await createInvoicePdf();
      final printed = await Printing.layoutPdf(onLayout: (_) async => bytes);
      if(mounted && !printed) showMessage(context,'لم يتم فتح الطباعة. تحقق من وجود تطبيق طباعة PDF على الهاتف.');
    } catch(e) {
      if(mounted) showMessage(context,'تعذر إنشاء PDF: ${e.toString().replaceFirst('Exception: ','')}');
    } finally {
      if(mounted)setState(()=>pdfBusy=false);
    }
  }

  Future<void> shareInvoice() async {
    if(pdfBusy)return;
    setState(()=>pdfBusy=true);
    try {
      final bytes = await createInvoicePdf();
      await Printing.sharePdf(bytes: bytes, filename: 'TunaPlus-${widget.sale['invoice']}.pdf');
    } catch(e) {
      if(mounted) showMessage(context,'تعذر مشاركة PDF: ${e.toString().replaceFirst('Exception: ','')}');
    } finally {
      if(mounted)setState(()=>pdfBusy=false);
    }
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('فاتورة العميل')),body:SafeArea(child:FutureBuilder<void>(future:loaded,builder:(context,s)=>ListView(padding:const EdgeInsets.fromLTRB(16,16,16,32),children:[
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
    FilledButton.icon(style:FilledButton.styleFrom(minimumSize:const Size.fromHeight(52),padding:const EdgeInsets.symmetric(horizontal:18,vertical:14)),onPressed:pdfBusy?null:printInvoice,icon:pdfBusy?const SizedBox(width:20,height:20,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.picture_as_pdf),label:Text(pdfBusy?'جارٍ تجهيز PDF...':'طباعة / حفظ الفاتورة PDF')),
    OutlinedButton.icon(style:OutlinedButton.styleFrom(minimumSize:const Size.fromHeight(52),padding:const EdgeInsets.symmetric(horizontal:18,vertical:14),side:const BorderSide(color:gold,width:1.4)),onPressed:pdfBusy?null:shareInvoice,icon:const Icon(Icons.share),label:const Text('مشاركة الفاتورة للعميل')),
  ]))));
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
  Future<void> exportPdf(BuildContext context) async {
    try {
    final totals = await DB.instance.totals();
    final rows = await DB.instance.sales();
    final font = await loadArabicPdfFont();
    try {
      final number = (num? value) => NumberFormat('#,##0.##', 'en').format(value ?? 0);
      final tableRows = <pw.TableRow>[
        pw.TableRow(
          decoration: pw.BoxDecoration(color: pdf.PdfColor.fromHex('#2C2924')),
          children: [
            pdfCell('رقم الفاتورة', font, header: true),
            pdfCell('التاريخ', font, header: true),
            pdfCell('الوزن كجم', font, header: true),
            pdfCell('السعر/كجم', font, header: true),
            pdfCell('الإجمالي', font, header: true),
            pdfCell('المدفوع', font, header: true),
          ],
        ),
        ...rows.map((row) => pw.TableRow(children: [
          pdfCell(row['invoice']?.toString() ?? '—', font),
          pdfCell((row['created'] as String).substring(0, 10), font),
          pdfCell(number(row['kg'] as num), font),
          pdfCell(number(row['price'] as num), font),
          pdfCell(number(row['total'] as num), font),
          pdfCell(number(row['paid'] as num), font),
        ])),
      ];

      final doc = pw.Document();
      doc.addPage(pw.MultiPage(
        pageFormat: pdf.PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (ctx) => pw.Container(
          alignment: pw.Alignment.centerRight,
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pdfText('تونة بلس • تقرير الحسابات', font, fontSize: 18, color: pdf.PdfColor.fromHex('#B78B34')),
        ),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.only(top: 8),
          child: pdfText('صفحة ${ctx.pageNumber} من ${ctx.pagesCount}', font, fontSize: 9, align: ShapedTextAlign.center),
        ),
        build: (ctx) => [
          pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Container(
                  padding: const pw.EdgeInsets.all(12),
                  decoration: pw.BoxDecoration(
                    color: pdf.PdfColor.fromHex('#F4E8CF'),
                    borderRadius: pw.BorderRadius.circular(8),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                    children: [
                      pdfText('ملخص مالي', font, fontSize: 16, color: pdf.PdfColor.fromHex('#27221A')),
                      pw.SizedBox(height: 8),
                      pdfText('إجمالي المبيعات: ${number(totals['sales'])} ر.ي', font),
                      pdfText('المدفوع في الفواتير: ${number(totals['paid'])} ر.ي', font),
                      pdfText('التحصيلات اللاحقة: ${number(totals['collections'])} ر.ي', font),
                      pdfText('الديون المتبقية: ${number(totals['debt'])} ر.ي', font),
                      pdfText('الوزن المباع: ${number(totals['weight'])} كجم', font),
                      pdfText('الربح من المبيعات بعد المصروفات: ${number(totals['netProfit'])} ر.ي • ${(totals['profitFinal'] ?? 0) > 0 ? 'نهائي' : 'غير نهائي بسبب وجود مخزون'}', font, fontSize: 12),
                      pdfText('المخزون الصافي المتبقي: ${number(totals['remainingKg'])} كجم', font),
                      pdfText('قيمة تكلفة المخزون المتبقي: ${number(totals['inventoryCost'])} ر.ي', font),
                      pdfText('إجمالي المصروفات المسجلة: ${number(totals['expenses'])} ر.ي', font),
                      pdfText('المصروفات المحملة على المبيعات: ${number(totals['expensesAllocated'])} ر.ي', font),
                      if ((totals['unallocatedSoldKg'] ?? 0) > 0.0001)
                        pdfText('تنبيه: وزن مبيعات غير موزع على المخزون: ${number(totals['unallocatedSoldKg']!)} كجم؛ الربح غير محسوب لوجود نقص.', font, fontSize: 11, color: pdf.PdfColor.fromHex('#B3261E')),
                    ],
                  ),
                ),
                pw.SizedBox(height: 14),
                pdfText('تفاصيل الفواتير', font, fontSize: 15),
                pw.SizedBox(height: 8),
                pw.Table(
                  border: pw.TableBorder.all(color: pdf.PdfColor.fromHex('#D6C6A5'), width: 0.4),
                  columnWidths: {
                    0: const pw.FlexColumnWidth(1.6),
                    1: const pw.FlexColumnWidth(1.2),
                    2: const pw.FlexColumnWidth(0.8),
                    3: const pw.FlexColumnWidth(1.0),
                    4: const pw.FlexColumnWidth(1.1),
                    5: const pw.FlexColumnWidth(1.1),
                  },
                  children: tableRows,
                ),
              ],
            ),
          ),
        ],
      ));
      await Printing.layoutPdf(onLayout: (_) async => await doc.save());
    } finally {
      font.dispose();
    }
    } catch(e) {
      showMessage(context,'تعذر إنشاء تقرير PDF: ${e.toString().replaceFirst('Exception: ','')}');
    }
  }
  @override Widget build(BuildContext context) {
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
          'netProfit': (totals['profitReliable']??1)<=0 ? 'الربح غير موثوق (نقص مخزون)' : ((totals['profitFinal']??0)>0 ? 'صافي الربح النهائي' : 'الربح من المبيعات (غير نهائي)'),
          'remainingKg':'المخزون الصافي المتبقي',
          'inventoryCost':'تكلفة المخزون المتبقي',
          'expenses':'إجمالي المصروفات',
          'expensesAllocated':'مصروفات محسوبة على المباع',
          'unallocatedSoldKg':'وزن مبيعات غير موزع (مراجعة المخزون)',
        };
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            ...labels.entries.map((entry) => Card(
              child: ListTile(
                title: Text(entry.value),
                trailing: Text(entry.key=='weight'||entry.key=='remainingKg'||entry.key=='unallocatedSoldKg'
                    ? '${totals[entry.key]!.toStringAsFixed(3)} كجم'
                    : money(totals[entry.key]!)),
              ),
            )),
            FilledButton.icon(
              onPressed: () => exportPdf(context),
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
    final gross = TextEditingController();
    final price = TextEditingController();
    final net = TextEditingController();
    final note = TextEditingController();
    final grossFocus = FocusNode();
    final priceFocus = FocusNode();
    final netFocus = FocusNode();
    final noteFocus = FocusNode();

    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          final media = MediaQuery.of(ctx);
          final availableHeight = media.size.height - media.viewInsets.bottom - 40;
          return Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: availableHeight > 160 ? availableHeight : media.size.height * 0.7,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'تسجيل شراء تونة (خاص)',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: gold, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: gross,
                      focusNode: grossFocus,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => FocusScope.of(ctx).requestFocus(priceFocus),
                      decoration: const InputDecoration(
                        labelText: 'الوزن الإجمالي عند الشراء (كجم)',
                        prefixIcon: Icon(Icons.scale),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: price,
                      focusNode: priceFocus,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => FocusScope.of(ctx).requestFocus(netFocus),
                      decoration: const InputDecoration(
                        labelText: 'تكلفة شراء الكيلو (ريال)',
                        prefixIcon: Icon(Icons.payments),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: net,
                      focusNode: netFocus,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => FocusScope.of(ctx).requestFocus(noteFocus),
                      decoration: const InputDecoration(
                        labelText: 'الوزن الصافي بعد التقطيع (كجم)',
                        prefixIcon: Icon(Icons.inventory_2),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: note,
                      focusNode: noteFocus,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => FocusScope.of(ctx).unfocus(),
                      decoration: const InputDecoration(
                        labelText: 'ملاحظة (اختياري)',
                        prefixIcon: Icon(Icons.notes),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'هذه البيانات خاصة ولا تظهر في فواتير العملاء أو كشوفهم.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('إلغاء'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.save),
                            onPressed: () async {
                              try {
                                await DB.instance.addPrivateBatch(
                                  double.parse(gross.text.trim()),
                                  int.parse(price.text.trim()),
                                  double.parse(net.text.trim()),
                                  note.text,
                                );
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (mounted) setState(reloadEntries);
                              } catch (e) {
                                showMessage(ctx, e.toString().replaceFirst('Exception: ', ''));
                              }
                            },
                            label: const Text('حفظ الشراء'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } finally {
      gross.dispose();
      price.dispose();
      net.dispose();
      note.dispose();
      grossFocus.dispose();
      priceFocus.dispose();
      netFocus.dispose();
      noteFocus.dispose();
    }
  }
  Future<void> editEntry(Map<String,Object?> row)async{
    final gross=TextEditingController(text:(row['gross_kg'] as num).toString());
    final price=TextEditingController(text:(row['purchase_price'] as num).toString());
    final net=TextEditingController(text:(row['net_kg'] as num).toString());
    final note=TextEditingController(text:row['note'] as String? ?? '');
    await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:const Text('تعديل عملية شراء'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:gross,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الوزن الإجمالي (كجم)')),
      TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'سعر شراء الكيلو')),
      TextField(controller:net,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الوزن الصافي (كجم)')),
      TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظة')),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await DB.instance.updatePrivateBatch(row['id'] as int,double.parse(gross.text),int.parse(price.text),double.parse(net.text),note.text);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState(reloadEntries);}catch(e){showMessage(ctx,e.toString().replaceFirst('Exception: ',''));}},child:const Text('حفظ التعديل'))]));
  }
  Future<void> addExpense() async {
    final amount=TextEditingController(),note=TextEditingController();
    try {
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('تسجيل مصروف خاص'),
        content:SizedBox(width:double.maxFinite,height:MediaQuery.of(ctx).size.height*0.38,
          child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
            TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'مبلغ المصروف (ريال)',prefixIcon:Icon(Icons.payments))),
            TextField(controller:note,maxLines:3,decoration:const InputDecoration(labelText:'بيان المصروف / ملاحظات',prefixIcon:Icon(Icons.notes))),
            const SizedBox(height:8),
            const Text('المصروفات خاصة ولا تظهر في فواتير العملاء أو كشوفهم.')
          ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
          FilledButton.icon(icon:const Icon(Icons.save),onPressed:()async{
            final value=int.tryParse(amount.text.trim());
            if(value==null||value<=0){showMessage(ctx,'أدخل مبلغًا صحيحًا أكبر من صفر');return;}
            if(note.text.trim().isEmpty){showMessage(ctx,'اكتب بيان المصروف لتسهيل المراجعة');return;}
            try{await DB.instance.addExpense(value,note.text);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState(reloadEntries);}
            catch(e){showMessage(ctx,e.toString().replaceFirst('Exception: ',''));}
          },label:const Text('حفظ المصروف'))]
      ));
    } finally {
      amount.dispose();note.dispose();
    }
  }
  Future<void> showBatchStatement(Map<String,Object?> purchase) async {
    try {
      final report=await DB.instance.privateBatchStatement(purchase['id'] as int);
      if(!mounted)return;
      final batch=report['batch'] as Map<String,Object?>;
      final allocations=report['allocations'] as List<Map<String,Object?>>;
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('كشف شراء مستقل'),
        content:SizedBox(width:double.maxFinite,height:MediaQuery.of(ctx).size.height*0.68,child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Text('تاريخ الشراء: ${dateLabel(batch['created'] as String)}'),
          if((batch['note'] as String? ?? '').isNotEmpty)Text('ملاحظة: ${batch['note']}'),
          const Divider(),
          Text('الوزن الإجمالي: ${(batch['gross_kg'] as num).toStringAsFixed(2)} كجم'),
          Text('الوزن الصافي: ${(report['netKg'] as num).toStringAsFixed(2)} كجم'),
          Text('تكلفة الشراء: ${money(report['cost'] as num)}'),
          Text('تكلفة الكيلو الصافي: ${money(report['unitCost'] as num)}'),
          const Divider(),
          Text('الوزن المباع من هذه الشحنة: ${(report['soldKg'] as num).toStringAsFixed(3)} كجم'),
          Text('المتبقي: ${(report['remainingKg'] as num).toStringAsFixed(3)} كجم'),
          Text('إيرادات المبيعات الموزعة: ${money(report['revenue'] as num)}'),
          Text('تكلفة وزن المباع: ${money(report['costOfSold'] as num)}'),
          Text('حصة المصروفات العامة: ${money(report['expenseShare'] as num)}'),
          Text((report['profitReliable'] as bool? ?? false)?'الربح الصافي التقريبي: ${money(report['profit'] as num)}':'الربح غير محسوب لوجود نقص في توزيع المخزون',style:TextStyle(color:(report['profitReliable'] as bool? ?? false)?gold:Colors.orange,fontWeight:FontWeight.bold)),
          const SizedBox(height:10),
          const Text('تفصيل المبيعات الموزعة على الشحنة',style:TextStyle(fontWeight:FontWeight.bold)),
          if(allocations.isEmpty)const Text('لم تُوزع مبيعات على هذه الشحنة بعد.'),
          ...allocations.map((s)=>Card(child:ListTile(
            dense:true,title:Text('${s['invoice']??'فاتورة'} • ${(s['kg'] as num).toStringAsFixed(3)} كجم'),
            subtitle:Text('${dateLabel(s['created'] as String)}\nالإيراد: ${money(s['revenue'] as num)}'),
            isThreeLine:true,
          ))),
          if((report['unallocatedSoldKg'] as num)>0.0001)Text('تنبيه: يوجد وزن مبيعات غير موزع على الشحنات بمقدار ${(report['unallocatedSoldKg'] as num).toStringAsFixed(3)} كجم؛ يلزم مراجعة المخزون قبل اعتماد الربح.',style:const TextStyle(color:Colors.orange,fontWeight:FontWeight.bold)),
            const Text('التوزيع حسابي بطريقة FIFO (الأقدم شراءً أولاً). المصروفات العامة موزعة حسب الوزن المباع من إجمالي الوزن الصافي المشتراة، وليس ربطاً دائماً محفوظاً بين الفواتير والشحنات.',style:TextStyle(fontSize:12)),
        ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق'))],
      ));
    }catch(e){if(mounted)showMessage(context,e.toString().replaceFirst('Exception: ',''));}
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
      ...rows.map((r){final g=r['gross_kg'] as num,n=r['net_kg'] as num,pc=r['purchase_price'] as num,tc=r['total_cost'] as num;return Card(child:ListTile(title:Text('${dateLabel(r['created'] as String)}'),subtitle:Text('إجمالي: ${g.toStringAsFixed(2)} كجم • صافي: ${n.toStringAsFixed(2)} كجم • فاقد: ${(g-n).toStringAsFixed(2)} كجم\nشراء الكيلو: ${money(pc)} • الإجمالي: ${money(tc)}'),isThreeLine:true,trailing:PopupMenuButton<String>(onSelected:(action)async{if(action=='statement'){await showBatchStatement(r);}else if(action=='edit'){await editEntry(r);}else if(action=='delete'){try{await DB.instance.deletePrivateBatch(r['id'] as int);if(mounted)setState(reloadEntries);}catch(e){if(mounted)showMessage(context,e.toString().replaceFirst('Exception: ',''));}}},itemBuilder:(_)=>const [PopupMenuItem(value:'statement',child:Text('كشف الشحنة والربح')),PopupMenuItem(value:'edit',child:Text('تعديل عملية الشراء')),PopupMenuItem(value:'delete',child:Text('حذف عملية الشراء'))],child:const Icon(Icons.more_vert))));})
    ]);
  }));
}
class SettingsPage extends StatefulWidget{const SettingsPage({super.key});@override State<SettingsPage> createState()=>_SettingsPageState();}
class _SettingsPageState extends State<SettingsPage>{
  final store=TextEditingController(),phone=TextEditingController(),price=TextEditingController(),bank=TextEditingController(),owner=TextEditingController(),address=TextEditingController();
  @override void initState(){super.initState();load();}
  Future<void> load()async{store.text=await DB.instance.setting('shop','تونة بلس');phone.text=await DB.instance.setting('phone','777521058');price.text=await DB.instance.setting('price','6500');bank.text=await DB.instance.setting('bank','254127488');owner.text=await DB.instance.setting('owner','محمد صالح بن صالح علي الخلاقي');address.text=await DB.instance.setting('address','فوه المتضررين بجانب مسجد هائل خلف البريد');}
  Future<void> save()async{await DB.instance.setSetting('shop',store.text);await DB.instance.setSetting('phone',phone.text);await DB.instance.setSetting('price',price.text);await DB.instance.setSetting('bank',bank.text);await DB.instance.setSetting('owner',owner.text);await DB.instance.setSetting('address',address.text);if(mounted){showMessage(context,'تم حفظ الإعدادات');Navigator.pop(context);}}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('إعدادات المتجر')),body:SafeArea(child:ListView(padding:const EdgeInsets.fromLTRB(16,16,16,48),children:[
    TextField(controller:store,decoration:const InputDecoration(labelText:'اسم المتجر')),
    TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم التواصل')),
    TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'سعر الكيلو الافتراضي (قابل للتغيير عند كل بيع)')),
    const SizedBox(height:14),const Text('بيانات الفواتير',style:TextStyle(color:gold,fontSize:18,fontWeight:FontWeight.bold)),
    TextField(controller:bank,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'رقم الحساب البنكي')),
    TextField(controller:owner,decoration:const InputDecoration(labelText:'اسم صاحب الحساب')),
    TextField(controller:address,maxLines:2,decoration:const InputDecoration(labelText:'عنوان المتجر')),
    const SizedBox(height:20),OutlinedButton.icon(style:OutlinedButton.styleFrom(minimumSize:const Size.fromHeight(52),padding:const EdgeInsets.symmetric(horizontal:12,vertical:14)),onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const PrivateCostPage())),icon:const Icon(Icons.lock),label:const Text('حسابات الشراء الخاصة (لا تظهر للزبائن)')),const SizedBox(height:12),FilledButton(style:FilledButton.styleFrom(minimumSize:const Size.fromHeight(52)),onPressed:save,child:const Text('حفظ'))
  ])));
}
