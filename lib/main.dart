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
import 'package:url_launcher/url_launcher.dart';
import 'pdf_text_utils.dart';

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
// Reject corrupted purchase records or expense rows before trusting batch/global profit.
bool batchFinancialInputsAllowed(num grossKg,num netKg,num purchasePrice,num totalCost,List<num> expenses,{double tolerance=0.0001}) {
  if (!grossKg.isFinite || !netKg.isFinite || !purchasePrice.isFinite || !totalCost.isFinite ||
      grossKg <= 0 || netKg <= 0 || netKg > grossKg + tolerance || purchasePrice <= 0 || totalCost < 0) return false;
  if (totalCost != (grossKg * purchasePrice).round()) return false;
  for (final expense in expenses) {
    if (!expense.isFinite || expense <= 0) return false;
  }
  return true;
}
bool allocationRevenueShareAllowed(num saleTotal,num saleKg,num allocatedKg,{double tolerance=0.0001}) {
  if (!saleTotal.isFinite || !saleKg.isFinite || !allocatedKg.isFinite || saleTotal <= 0 || saleKg <= 0 || allocatedKg <= 0) return false;
  return allocatedKg <= saleKg + tolerance;
}
double allocationRevenueShare(num saleTotal,num saleKg,num allocatedKg) {
  if (!allocationRevenueShareAllowed(saleTotal,saleKg,allocatedKg)) return 0;
  return (saleTotal * (allocatedKg / saleKg)).toDouble();
}
bool saleAllocationsMatchInvoice(num saleKg,List<num> allocatedKgs,{double tolerance=0.0001}) {
  if (!saleKg.isFinite || saleKg <= 0) return false;
  var total=0.0;
  for (final kg in allocatedKgs) {
    if (!kg.isFinite || kg <= 0) return false;
    total+=kg;
  }
  return total.isFinite && (saleKg-total).abs() <= tolerance;}

double batchUnitCost(num purchaseCost,num expenses,num netKg) {
  if (!purchaseCost.isFinite || !expenses.isFinite || !netKg.isFinite ||
      purchaseCost < 0 || expenses < 0 || netKg <= 0) return 0;
  return (purchaseCost + expenses) / netKg;
}
// A batch profit may be shown as reliable only when its own financial inputs
// are valid and stock allocations reconcile globally and within this batch.
bool batchStatementIntegrityAllowed(num netKg, num purchaseCost, num batchExpenses,
    num soldKg, num revenue, num unallocatedKg, bool allocationsOk,
    {double tolerance=0.0001}) {
  if (!netKg.isFinite || !purchaseCost.isFinite || !batchExpenses.isFinite ||
      !soldKg.isFinite || !revenue.isFinite || !unallocatedKg.isFinite ||
      netKg <= 0 || purchaseCost < 0 || batchExpenses < 0 || soldKg < 0 ||
      revenue < 0 || unallocatedKg < 0 || !allocationsOk) return false;
  if (soldKg <= tolerance && revenue > tolerance) return false;
  if (soldKg > tolerance && revenue <= tolerance) return false;
  return soldKg <= netKg + tolerance && unallocatedKg <= tolerance;
}

double batchNetProfit(num revenue,num soldKg,num unitCost) {
  if (!revenue.isFinite || !soldKg.isFinite || !unitCost.isFinite ||
      revenue < 0 || soldKg < 0 || unitCost < 0) return 0;
  return (revenue - (soldKg * unitCost)).toDouble();
}
// Global profit is final only after at least one batch exists and all stock is sold with allocations reconciled.
bool globalProfitFinalAllowed(num batchCount,num remainingKg,num unallocatedKg,bool integrityOk,{double tolerance=0.0001}) {
  if (!batchCount.isFinite || !remainingKg.isFinite || !unallocatedKg.isFinite ||
      batchCount <= 0 || remainingKg < 0 || unallocatedKg < 0 || !integrityOk) return false;
  return remainingKg <= tolerance && unallocatedKg <= tolerance;
}

double globalNetProfit(num salesRevenue,num costOfSold,num generalExpenses) {
  if (!salesRevenue.isFinite || !costOfSold.isFinite || !generalExpenses.isFinite ||
      salesRevenue < 0 || costOfSold < 0 || generalExpenses < 0) return 0;
  return (salesRevenue - costOfSold - generalExpenses).toDouble();
}

double unallocatedSaleKg(num totalSold,num allocated,num migrationWarning) {
  if (!totalSold.isFinite || !allocated.isFinite ||
      totalSold < 0 || allocated < 0) return 0;
  // Recalculate from current sales and allocations. The migration warning is
  // historical and can become stale after invoices are deleted, so it must not
  // keep profit blocked after the underlying discrepancy has been resolved.
  return (totalSold-allocated).abs().toDouble();
}


bool saleFinancialEditAllowed(num total, num paid, String kind, bool hasCustomer) =>
    saleFinancialValuesAllowed(total, paid, kind, hasCustomer);

bool saleFinancialValuesAllowed(num total, num paid, String kind, bool hasCustomer) {
  if (!total.isFinite || !paid.isFinite || total <= 0 || paid < 0 || paid > total) return false;
  if (kind != 'نقدي' && kind != 'آجل') return false;
  if (kind == 'نقدي' && paid != total) return false;
  if (kind == 'آجل' && !hasCustomer) return false;
  return true;
}

bool customerCollectionLedgerIntegrityAllowed(List<num> invoiceTotals, List<num> invoicePaid, List<num> collectionAmounts) {
  if (invoiceTotals.length != invoicePaid.length) return false;
  var outstanding = 0.0;
  for (var i = 0; i < invoiceTotals.length; i++) {
    final total = invoiceTotals[i], paid = invoicePaid[i];
    if (!total.isFinite || !paid.isFinite || total <= 0 || paid < 0 || paid > total) return false;
    outstanding += total - paid;
  }
  var collected = 0.0;
  for (final amount in collectionAmounts) {
    if (!amount.isFinite || amount <= 0) return false;
    collected += amount;
  }
  return outstanding.isFinite && collected.isFinite && collected <= outstanding;
}

bool collectionAmountAllowed(num outstanding, num amount) {
  if (!outstanding.isFinite || !amount.isFinite || outstanding < 0 || amount <= 0) return false;
  return amount <= outstanding;
}

bool customerInvoiceEditCollectionCoverageAllowed(num totalOutstanding, num oldInvoiceOutstanding, num collected, num newInvoiceOutstanding, {double tolerance=0.0001}) {
  if (!totalOutstanding.isFinite || !oldInvoiceOutstanding.isFinite || !collected.isFinite || !newInvoiceOutstanding.isFinite ||
      totalOutstanding < 0 || oldInvoiceOutstanding < 0 || collected < 0 || newInvoiceOutstanding < 0 ||
      oldInvoiceOutstanding > totalOutstanding || collected > totalOutstanding + tolerance) return false;
  // Collections are pooled by customer. Editing an invoice is safe only if the
  // remaining customer debt still covers every receipt after replacing its old balance.
  final revisedOutstanding=totalOutstanding-oldInvoiceOutstanding+newInvoiceOutstanding;
  return revisedOutstanding + tolerance >= collected;
}

bool invoiceDeletionAllowed(num totalOutstanding, num targetOutstanding, num collected) {
  if (!totalOutstanding.isFinite || !targetOutstanding.isFinite || !collected.isFinite ||
      totalOutstanding < 0 || targetOutstanding < 0 || collected < 0 ||
      targetOutstanding > totalOutstanding) return false;
  // Pooled customer receipts must remain covered by the outstanding balance
  // after the invoice is removed; otherwise deletion would create orphaned receipts.
  return collected <= totalOutstanding - targetOutstanding;
}

bool saleDeletionAllocationIntegrityOk(num saleKg, num allocatedKg, bool rowsValid, bool batchReferencesValid, {double tolerance=0.0001}) {
  if (!saleKg.isFinite || !allocatedKg.isFinite || saleKg <= 0 || allocatedKg < 0 || !rowsValid || !batchReferencesValid) return false;
  return (saleKg-allocatedKg).abs() <= tolerance;
}
bool saleAllocationMismatch(num saleKg,num allocatedKg,{double tolerance=0.0001}) {
  if (!saleKg.isFinite || !allocatedKg.isFinite || saleKg < 0 || allocatedKg < 0) return true;
  return (saleKg-allocatedKg).abs()>tolerance;
}
bool batchAllocationOverage(num allocatedKg,num netKg,{double tolerance=0.0001}) {
  if (!allocatedKg.isFinite || !netKg.isFinite || allocatedKg < 0 || netKg < 0) return true;
  return allocatedKg>netKg+tolerance;
}
bool allocationRowValid(num kg) => kg.isFinite && kg > 0;
bool batchExpenseFinancialEditAllowed(num allocatedKg,{double tolerance=0.0001}) {
  if (!allocatedKg.isFinite || allocatedKg < 0) return false;
  return allocatedKg <= tolerance;
}

// Protect historical batch cost and yield once sales are attached; notes remain editable.
bool batchFinancialEditAllowed(num allocatedKg, num oldGross, num oldPrice, num oldNet, num newGross, num newPrice, num newNet, {double tolerance=0.0001}) {
  if (!allocatedKg.isFinite || allocatedKg < 0 || !oldGross.isFinite || !oldPrice.isFinite || !oldNet.isFinite || !newGross.isFinite || !newPrice.isFinite || !newNet.isFinite) return false;
  if (allocatedKg <= tolerance) return true;
  return oldGross == newGross && oldPrice == newPrice && oldNet == newNet;}

String money(num value) => '${NumberFormat('#,##0', 'en').format(value)} ر.ي';
String dateLabel(String value) => DateFormat('yyyy/MM/dd HH:mm').format(DateTime.parse(value));

String normalizeWhatsAppNumber(String raw) {
  var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (digits.startsWith('967')) return digits;
  if (digits.startsWith('0')) digits = digits.substring(1);
  return '967$digits';
}
String normalizeYemeniSmsNumber(String raw) {
  var phone = raw.replaceAll(RegExp(r'[^0-9+]'), '');
  if (phone.startsWith('00967')) return '+967' + phone.substring(5);
  if (phone.startsWith('967')) return '+' + phone;
  if (phone.startsWith('0')) return '+967' + phone.substring(1);
  if (!phone.startsWith('+') && phone.length == 9) return '+967' + phone;
  return phone;
}

String reservationArrivalMessage(String customerName, num kg) =>
    'مرحباً ' + customerName + '، نبلغك من تونة بلس أن الكمية المحجوزة (' + kg.toStringAsFixed(3) + ' كجم) قد وصلت. يمكنك التواصل معنا لتأكيد الاستلام. شكراً لك.\\n\\n📲 مراسلة تونــه بلــس عبر واتساب. https://wa.me/967733099270';


// Arabic shaping font plus a cached Latin fallback for invoice IDs and symbols.
ShapedFont? _latinPdfFallback;
Future<ShapedFont> loadArabicPdfFont() async {
  if (_latinPdfFallback == null) {
    final latinData = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    final latinBytes = latinData.buffer.asUint8List(latinData.offsetInBytes, latinData.lengthInBytes);
    _latinPdfFallback = ShapedFont.fromBytes(latinBytes, name: 'Noto Sans Latin');
  }
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
  sanitizePdfText(value),
  style: ShapedTextStyle(
    font: font,
    fallbackFonts: _latinPdfFallback == null ? const [] : [_latinPdfFallback!],
    fontSize: fontSize,
    color: color ?? pdf.PdfColors.black,
    direction: ShapedTextDirection.auto,
    align: align,
    // Render only HarfBuzz-shaped vector glyphs; the invisible Unicode layer
    // triggered unsupported glyph errors during PDF creation on some text.
    preserveUnicodeText: false,
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

class TunaApp extends StatefulWidget {
  const TunaApp({super.key});
  @override State<TunaApp> createState() => _TunaAppState();
}
class _TunaAppState extends State<TunaApp> {
  bool isDark = true;
  @override
  void initState() {
    super.initState();
    _loadTheme();
  }
  Future<void> _loadTheme() async {
    final saved = await DB.instance.setting('theme_mode', 'dark');
    if (mounted) setState(() => isDark = saved != 'light');
  }
  Future<void> _toggleTheme() async {
    final next = !isDark;
    setState(() => isDark = next);
    await DB.instance.setSetting('theme_mode', next ? 'dark' : 'light');
  }
  @override
  Widget build(BuildContext context) {
    final brightness = isDark ? Brightness.dark : Brightness.light;
    final bg = isDark ? dark : const Color(0xFFF5F5F2);
    final card = isDark ? panel : Colors.white;
    final foreground = isDark ? Colors.white : const Color(0xFF242424);
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
        brightness: brightness,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(seedColor: gold, brightness: brightness),
        appBarTheme: AppBarTheme(backgroundColor: bg, foregroundColor: gold, centerTitle: true),
        cardTheme: CardThemeData(color: card),
        textTheme: ThemeData(brightness: brightness).textTheme.apply(bodyColor: foreground, displayColor: foreground),
        navigationBarTheme: NavigationBarThemeData(backgroundColor: card),
      ),
      home: AppShell(isDark: isDark, onToggleTheme: _toggleTheme),
    );
  }
}

class DB {
  DB._();
  // Prevent accidental duplicate submissions while an identical ledger write is in flight.
  final Set<String> _pendingWriteKeys = {};
  Future<int> _guardedWrite(String key, Future<int> Function() operation) async {
    if (!_pendingWriteKeys.add(key)) throw Exception('العملية قيد الحفظ بالفعل؛ انتظر حتى يكتمل الحفظ.');
    try { return await operation(); } finally { _pendingWriteKeys.remove(key); }
  }
  static final DB instance = DB._();
  Database? _database;
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await openDatabase(p.join(await getDatabasesPath(), 'tuna_plus.db'), version: 6,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) { await db.execute('CREATE TABLE private_batches(id INTEGER PRIMARY KEY AUTOINCREMENT,gross_kg REAL NOT NULL,purchase_price INTEGER NOT NULL,total_cost INTEGER NOT NULL,net_kg REAL NOT NULL,created TEXT NOT NULL,note TEXT)'); }
        if (oldVersion < 3) { await db.execute('CREATE TABLE expenses(id INTEGER PRIMARY KEY AUTOINCREMENT,amount INTEGER NOT NULL,note TEXT NOT NULL,created TEXT NOT NULL)'); }
        if (oldVersion < 4) { await db.execute('CREATE TABLE reservations(id INTEGER PRIMARY KEY AUTOINCREMENT,customer_name TEXT NOT NULL,phone TEXT,kg REAL NOT NULL,price INTEGER NOT NULL,total INTEGER NOT NULL,deposit INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,note TEXT,created TEXT NOT NULL)'); }
        if (oldVersion < 5) { await db.execute('CREATE TABLE batch_expenses(id INTEGER PRIMARY KEY AUTOINCREMENT,batch_id INTEGER NOT NULL,amount INTEGER NOT NULL,note TEXT NOT NULL,created TEXT NOT NULL,FOREIGN KEY(batch_id) REFERENCES private_batches(id))'); await db.execute('CREATE TABLE sale_batch_allocations(sale_id INTEGER NOT NULL,batch_id INTEGER NOT NULL,kg REAL NOT NULL,PRIMARY KEY(sale_id,batch_id),FOREIGN KEY(sale_id) REFERENCES sales(id),FOREIGN KEY(batch_id) REFERENCES private_batches(id))'); }
        if (oldVersion < 6) {
          final batches = await db.query('private_batches', orderBy: 'created ASC,id ASC');
          final oldSales = await db.query('sales', orderBy: 'created ASC,id ASC');
          final remaining = batches.map((b) => (b['net_kg'] as num).toDouble()).toList();
          var migrationUnallocatedKg=0.0;
          for (final sale in oldSales) {
            var qty = (sale['kg'] as num).toDouble();
            for (var i=0; i<batches.length && qty>0.000001; i++) {
              final available = remaining[i] > 0 ? remaining[i] : 0.0;
              final take = qty < available ? qty : available;
              if (take <= 0) continue;
              await db.insert('sale_batch_allocations', {'sale_id':sale['id'],'batch_id':batches[i]['id'],'kg':take});
              remaining[i] -= take; qty -= take;
            }
            if(qty>0.000001)migrationUnallocatedKg+=qty;
          }
          await db.insert('settings',{'key':'legacy_unallocated_sales_kg','value':migrationUnallocatedKg.toString()},conflictAlgorithm:ConflictAlgorithm.replace);
        }
      },
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE customers(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,phone TEXT,note TEXT)');
        await db.execute('CREATE TABLE sales(id INTEGER PRIMARY KEY AUTOINCREMENT,invoice TEXT UNIQUE,customer_id INTEGER,kg REAL,price INTEGER,total INTEGER,paid INTEGER,kind TEXT,note TEXT,created TEXT)');
        await db.execute('CREATE TABLE collections(id INTEGER PRIMARY KEY AUTOINCREMENT,customer_id INTEGER,amount INTEGER,note TEXT,created TEXT)');
        await db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT)');
        await db.execute('CREATE TABLE private_batches(id INTEGER PRIMARY KEY AUTOINCREMENT,gross_kg REAL NOT NULL,purchase_price INTEGER NOT NULL,total_cost INTEGER NOT NULL,net_kg REAL NOT NULL,created TEXT NOT NULL,note TEXT)');
        await db.execute('CREATE TABLE expenses(id INTEGER PRIMARY KEY AUTOINCREMENT,amount INTEGER NOT NULL,note TEXT NOT NULL,created TEXT NOT NULL)');
        await db.execute('CREATE TABLE reservations(id INTEGER PRIMARY KEY AUTOINCREMENT,customer_name TEXT NOT NULL,phone TEXT,kg REAL NOT NULL,price INTEGER NOT NULL,total INTEGER NOT NULL,deposit INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,note TEXT,created TEXT NOT NULL)');
        await db.execute('CREATE TABLE batch_expenses(id INTEGER PRIMARY KEY AUTOINCREMENT,batch_id INTEGER NOT NULL,amount INTEGER NOT NULL,note TEXT NOT NULL,created TEXT NOT NULL,FOREIGN KEY(batch_id) REFERENCES private_batches(id))');
        await db.execute('CREATE TABLE sale_batch_allocations(sale_id INTEGER NOT NULL,batch_id INTEGER NOT NULL,kg REAL NOT NULL,PRIMARY KEY(sale_id,batch_id),FOREIGN KEY(sale_id) REFERENCES sales(id),FOREIGN KEY(batch_id) REFERENCES private_batches(id))');
        await db.insert('settings', {'key':'shop','value':'تونة بلس'});
        await db.insert('settings', {'key':'price','value':'6500'});
        await db.insert('settings', {'key':'legacy_unallocated_sales_kg','value':'0'});
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
  Future<List<Map<String,Object?>>> batchStocks() async {
    final db=await database;
    final batches=await db.query('private_batches',orderBy:'created ASC,id ASC');
    final result=<Map<String,Object?>>[];
    for(final b in batches){
      final sold=(await db.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sale_batch_allocations WHERE batch_id=?',[b['id']])).first['kg'] as num;
      final net=b['net_kg'] as num;
      result.add({...b,'sold_kg':sold,'remaining_kg':net-sold});
    }
    return result;
  }
  Future<int> addSale(int? customerId, int batchId, double kg, int price, int paid, String type, String note) async {
    if (!kg.isFinite || kg <= 0 || price <= 0 || paid < 0) throw Exception('تحقق من الوزن والسعر والمدفوع');
    if (type != 'نقدي' && type != 'آجل') throw Exception('نوع البيع غير صحيح');
    if (type == 'آجل' && customerId == null) throw Exception('البيع الآجل يتطلب اختيار عميل لتسجيل الدين في كشف حسابه');
    final db = await database;
    final total = (kg * price).round();
    if (total <= 0) throw Exception('قيمة الفاتورة غير صحيحة');
    if (!saleFinancialValuesAllowed(total,paid,type,customerId!=null)) {
      if (paid > total) throw Exception('المدفوع لا يتجاوز الإجمالي');
      if (type == 'نقدي' && paid != total) throw Exception('البيع النقدي يجب أن يكون مدفوعاً بالكامل');
      if (type == 'آجل' && customerId == null) throw Exception('البيع الآجل يتطلب اختيار عميل لتسجيل الدين في كشف حسابه');
      throw Exception('قيم الفاتورة أو المدفوع غير صحيحة');
    }
    // Run stock validation and sale insertion in one transaction to prevent two
    // simultaneous sales from overselling the same remaining inventory.
    final saleGuardKey='sale:$batchId:$customerId:${kg.toStringAsFixed(6)}:$price:$paid:$type:${note.trim()}';
    return _guardedWrite(saleGuardKey, () => db.transaction((txn) async {
      final batchRows=await txn.query('private_batches',where:'id=?',whereArgs:[batchId],limit:1);
      if(batchRows.isEmpty) throw Exception('دفعة الشراء غير موجودة');
      final net=batchRows.first['net_kg'] as num;
      final allocated=(await txn.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sale_batch_allocations WHERE batch_id=?',[batchId])).first['kg'] as num;
      final available=net-allocated;
      if(available+0.0001<kg) throw Exception('الوزن يتجاوز المتبقي في هذه الدفعة (${available.toStringAsFixed(3)} كجم).');
      final saleId=await txn.insert('sales', {
        'invoice':'TP-${DateTime.now().microsecondsSinceEpoch}','customer_id':customerId,
        'kg':kg,'price':price,'total':total,'paid':paid,'kind':type,'note':note.trim(),
        'created':DateTime.now().toIso8601String()
      });
      await txn.insert('sale_batch_allocations',{'sale_id':saleId,'batch_id':batchId,'kg':kg});
      return saleId;
    }));
  }
  Future<int> collect(int customerId, int amount, String note) async {
    if (amount <= 0) throw Exception('أدخل مبلغ تحصيل صحيح');
    if (note.trim().isEmpty) throw Exception('اكتب بيان التحصيل لتسهيل المراجعة');
    final db = await database;
    return _guardedWrite('collection:$customerId', () => db.transaction((txn) async {
      final customer = await txn.query('customers',where:'id=?',whereArgs:[customerId],limit:1);
      if (customer.isEmpty) throw Exception('العميل غير موجود؛ لا يمكن تسجيل تحصيل');
      final customerSales = await txn.query('sales',where:'customer_id=?',whereArgs:[customerId]);
      final customerCollections = await txn.query('collections',where:'customer_id=?',whereArgs:[customerId]);
      final invoiceTotals = customerSales.map((row) => row['total'] as num).toList();
      final invoicePaid = customerSales.map((row) => row['paid'] as num).toList();
      final collectionAmounts = customerCollections.map((row) => row['amount'] as num).toList();
      if (!customerCollectionLedgerIntegrityAllowed(invoiceTotals,invoicePaid,collectionAmounts)) {
        throw Exception('تعذر تسجيل التحصيل؛ توجد بيانات فواتير أو تحصيلات غير سليمة في حساب العميل. راجع السجل أولاً.');
      }
      final saleDue = customerSales.fold<num>(0,(sum,row) => sum + ((row['total'] as num) - (row['paid'] as num)));
      final collected = customerCollections.fold<num>(0,(sum,row) => sum + (row['amount'] as num));
      final outstanding = saleDue-collected;
      if (!collectionAmountAllowed(outstanding,amount)) throw Exception('المبلغ أكبر من الرصيد المستحق');
      return txn.insert('collections', {'customer_id':customerId,'amount':amount,'note':note.trim(),'created':DateTime.now().toIso8601String()});
    }));
  }
  Future<Map<String,num>> totals() async {
    final db=await database;
    final salesTotals=(await db.rawQuery('SELECT COALESCE(SUM(total),0) total,COALESCE(SUM(paid),0) paid,COALESCE(SUM(kg),0) weight FROM sales')).first;
    final collections=(await db.rawQuery('SELECT COALESCE(SUM(amount),0) total FROM collections')).first['total'] as num;
    final due=(await db.rawQuery('SELECT COALESCE(SUM(total-paid),0) total FROM sales')).first['total'] as num;
    final batches=await db.query('private_batches',orderBy:'created ASC,id ASC');
    final sales=await db.query('sales');
    final saleAllocations=await db.query('sale_batch_allocations');
    final batchExpenses=await db.query('batch_expenses');
    final legacyExpenses=(await db.rawQuery('SELECT COALESCE(SUM(amount),0) amount FROM expenses')).first['amount'] as num;
    final netKg=batches.fold<num>(0,(sum,b)=>sum+(b['net_kg'] as num));
    final purchaseCost=batches.fold<num>(0,(sum,b)=>sum+(b['total_cost'] as num));
    final soldKg=salesTotals['weight'] as num;
    var costSold=0.0,stockCost=0.0,remainingKg=0.0,expenseTotal=legacyExpenses;
    var financialIntegrityOk=true;
    if(batchExpenses.any((e)=>!batches.any((b)=>b['id']==e['batch_id']))) financialIntegrityOk=false;
    // Reconcile the persisted migration warning against current sales and allocations.
    // Use the larger value to avoid double-counting historical migration gaps.
    final migratedGap=double.tryParse(await setting('legacy_unallocated_sales_kg','0'))??0.0;
    final allocatedSalesKg=saleAllocations.fold<num>(0,(sum,a)=>sum+(a['kg'] as num));
    var unallocatedKg=unallocatedSaleKg(soldKg,allocatedSalesKg,migratedGap);
    var allocationRowsValid=true;
    final allocatedBySale=<int,double>{};
    for(final a in saleAllocations) {
      if(!allocationRowValid(a['kg'] as num)) allocationRowsValid=false;
      final sid=a['sale_id'] as int;
      allocatedBySale[sid]=(allocatedBySale[sid]??0.0)+(a['kg'] as num).toDouble();
    }
    var allocationIntegrityOk=allocationRowsValid&&sales.every((sale)=>!saleAllocationMismatch(sale['kg'] as num,allocatedBySale[sale['id'] as int]??0));
    final allocatedByBatch=<int,double>{};
    for(final a in saleAllocations) {
      final bid=a['batch_id'] as int;
      allocatedByBatch[bid]=(allocatedByBatch[bid]??0.0)+(a['kg'] as num).toDouble();
    }
    for(final batch in batches) {
      if(batchAllocationOverage(allocatedByBatch[batch['id'] as int]??0,batch['net_kg'] as num)) allocationIntegrityOk=false;
    }
    for(final a in saleAllocations) {
      if(!sales.any((sale)=>sale['id']==a['sale_id']) || !batches.any((b)=>b['id']==a['batch_id'])) allocationIntegrityOk=false;
    }
    for(final sale in sales) {
      final allocated=allocatedBySale[sale['id'] as int]??0;
      if(saleAllocationMismatch(sale['kg'] as num,allocated)) allocationIntegrityOk=false;
    }
    for(final batch in batches){
      final id=batch['id'] as int, net=(batch['net_kg'] as num).toDouble(),baseCost=(batch['total_cost'] as num).toDouble();
      final batchExpenseRows=batchExpenses.where((e)=>e['batch_id']==id).toList();
      final exp=batchExpenseRows.fold<num>(0,(sum,e)=>sum+(e['amount'] as num)).toDouble();
      if(!batchFinancialInputsAllowed(batch['gross_kg'] as num,net,batch['purchase_price'] as num,baseCost,batchExpenseRows.map((e)=>e['amount'] as num).toList())) financialIntegrityOk=false;
      expenseTotal+=exp;
      final capital=baseCost+exp, unit=net>0?capital/net:0.0;
      final sold=saleAllocations.where((a)=>a['batch_id']==id).fold<num>(0,(sum,a)=>sum+(a['kg'] as num)).toDouble();
      final rem=(net-sold).clamp(0.0,net);
      if(batchAllocationOverage(sold,net)){allocationIntegrityOk=false;unallocatedKg=unallocatedKg>sold-net?unallocatedKg:sold-net;}
      costSold+=sold*unit; stockCost+=rem*unit; remainingKg+=rem;
    }
    // Legacy global expenses remain outside batch cost until the user assigns them;
    // they are shown in the total expenses but not distributed silently.
    final netProfit=globalNetProfit(salesTotals['total'] as num,costSold,legacyExpenses);
    final profitDataReliable=unallocatedKg<=0.0001&&allocationIntegrityOk&&financialIntegrityOk;
    final finalProfit=globalProfitFinalAllowed(batches.length,remainingKg,unallocatedKg,allocationIntegrityOk);
    return {'sales':salesTotals['total'] as num,'paid':salesTotals['paid'] as num,'weight':soldKg,'collections':collections,'debt':due-collections,'purchaseCost':purchaseCost,'costPerKg':netKg>0?purchaseCost/netKg:0.0,'costOfSold':costSold,'inventoryCost':stockCost,'stockNetKg':netKg,'remainingKg':remainingKg,'expenses':expenseTotal,'expensesAllocated':legacyExpenses,'netProfit':profitDataReliable?netProfit:0,'unallocatedSoldKg':unallocatedKg,'profitReliable':profitDataReliable?1:0,'profitFinal':finalProfit&&profitDataReliable?1:0,'allocationIntegrityOk':allocationIntegrityOk?1:0};
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
  Future<void> deleteCollection(int customerId, int collectionId) async {
    final key='collection-delete:$collectionId';
    if (!_pendingWriteKeys.add(key)) throw Exception('عملية حذف التحصيل قيد التنفيذ بالفعل؛ انتظر حتى تكتمل.');
    try {
      final db = await database;
      await db.transaction((txn) async {
        final rows = await txn.query('collections',where:'id=? AND customer_id=?',whereArgs:[collectionId,customerId],limit:1);
        if (rows.isEmpty) throw Exception('التحصيل غير موجود في حساب هذا العميل');
        final amount = rows.first['amount'] as num;
        if (!amount.isFinite || amount <= 0) throw Exception('بيانات التحصيل غير سليمة؛ لا يمكن حذفه');
        await txn.delete('collections',where:'id=? AND customer_id=?',whereArgs:[collectionId,customerId]);
      });
    } finally {
      _pendingWriteKeys.remove(key);
    }
  }
  Future<Map<String,num>> customerTotals(int id) async {
    final db = await database;
    // Validate the complete customer ledger before showing a balance; never
    // silently display a negative debt caused by broken/duplicate receipts.
    final customerSales = await db.query('sales',where:'customer_id=?',whereArgs:[id]);
    final customerCollections = await db.query('collections',where:'customer_id=?',whereArgs:[id]);
    final invoiceTotals = customerSales.map((row) => row['total'] as num).toList();
    final invoicePaid = customerSales.map((row) => row['paid'] as num).toList();
    final collectionAmounts = customerCollections.map((row) => row['amount'] as num).toList();
    if (!customerCollectionLedgerIntegrityAllowed(invoiceTotals,invoicePaid,collectionAmounts)) {
      throw Exception('كشف حساب العميل غير متوازن؛ راجع الفواتير والتحصيلات قبل اعتماد الرصيد.');
    }
    final total = customerSales.fold<num>(0,(sum,row) => sum+(row['total'] as num));
    final paid = customerSales.fold<num>(0,(sum,row) => sum+(row['paid'] as num));
    final collected = customerCollections.fold<num>(0,(sum,row) => sum+(row['amount'] as num));
    return {'sales':total,'paid':paid+collected,'debt':total-paid-collected};
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
    return _guardedWrite('general-expense:add', () => (database).then((db) => db.insert('expenses', {'amount':amount,'note':note.trim(),'created':DateTime.now().toIso8601String()})));
  }
  Future<int> updateExpense(int id, int amount, String note) async {
    if (amount <= 0) throw Exception('أدخل مبلغ مصروف صحيح');
    if (note.trim().isEmpty) throw Exception('اكتب بيان المصروف حتى يسهل مراجعته');
    return _guardedWrite('general-expense:$id', () async {
      final db = await database;
      return db.transaction((txn) async {
        final rows = await txn.query('expenses', where:'id=?', whereArgs:[id], limit:1);
        if (rows.isEmpty) throw Exception('المصروف غير موجود');
        return txn.update('expenses', {'amount':amount,'note':note.trim()}, where:'id=?', whereArgs:[id]);
      });
    });
  }
  Future<int> deleteExpense(int id) async =>
      _guardedWrite('general-expense:$id', () async {
        final db = await database;
        return db.transaction((txn) async {
          final rows = await txn.query('expenses', where:'id=?', whereArgs:[id], limit:1);
          if (rows.isEmpty) throw Exception('المصروف غير موجود');
          return txn.delete('expenses', where:'id=?', whereArgs:[id]);
        });
      });
  Future<int> updateBatchExpense(int expenseId,int amount,String note) async {
    if(amount<=0)throw Exception('أدخل مبلغ مصروف صحيح');
    if(note.trim().isEmpty)throw Exception('اكتب بيان المصروف');
    final db=await database;
    final initialRows=await db.query('batch_expenses',where:'id=?',whereArgs:[expenseId],limit:1);
    if(initialRows.isEmpty)throw Exception('المصروف غير موجود');
    final batchId=initialRows.first['batch_id'] as int;
    return _guardedWrite('batch-expense-batch:$batchId', () => db.transaction((txn)async{
      final rows=await txn.query('batch_expenses',where:'id=?',whereArgs:[expenseId],limit:1);
      if(rows.isEmpty)throw Exception('المصروف غير موجود');
      final old=rows.first;
      final sold=(await txn.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sale_batch_allocations WHERE batch_id=?',[batchId])).first['kg'] as num;
      if(amount!=(old['amount'] as num) && !batchExpenseFinancialEditAllowed(sold)) {
        throw Exception('لا يمكن تعديل مبلغ مصروف الدفعة بعد تسجيل مبيعات عليها؛ يمكنك تعديل البيان فقط.');
      }
      return txn.update('batch_expenses',{'amount':amount,'note':note.trim()},where:'id=?',whereArgs:[expenseId]);
    }));
  }
  Future<int> deleteBatchExpense(int expenseId) async {
    final db=await database;
    final initialRows=await db.query('batch_expenses',where:'id=?',whereArgs:[expenseId],limit:1);
    if(initialRows.isEmpty)return 0;
    final batchId=initialRows.first['batch_id'] as int;
    return _guardedWrite('batch-expense-batch:$batchId', () => db.transaction((txn)async{
      final rows=await txn.query('batch_expenses',where:'id=?',whereArgs:[expenseId],limit:1);
      if(rows.isEmpty)return 0;
      final sold=(await txn.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sale_batch_allocations WHERE batch_id=?',[batchId])).first['kg'] as num;
      if(!batchExpenseFinancialEditAllowed(sold))throw Exception('لا يمكن حذف مصروف الدفعة بعد تسجيل مبيعات عليها؛ حتى لا تتغير الأرباح السابقة.');
      return txn.delete('batch_expenses',where:'id=?',whereArgs:[expenseId]);
    }));
  }
  Future<int> addBatchExpense(int batchId,int amount,String note) async {
    if(amount<=0)throw Exception('أدخل مبلغ مصروف صحيح');
    if(note.trim().isEmpty)throw Exception('اكتب بيان المصروف');
    final db=await database;
    return _guardedWrite('batch-expense-batch:$batchId', () => db.transaction((txn)async{
      final batch=await txn.query('private_batches',where:'id=?',whereArgs:[batchId],limit:1);
      if(batch.isEmpty)throw Exception('دفعة الشراء غير موجودة');
      final sold=(await txn.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sale_batch_allocations WHERE batch_id=?',[batchId])).first['kg'] as num;
      if(!batchExpenseFinancialEditAllowed(sold))throw Exception('لا يمكن إضافة مصروف للدفعة بعد تسجيل مبيعات عليها؛ حتى لا تتغير الأرباح السابقة.');
      return txn.insert('batch_expenses',{'batch_id':batchId,'amount':amount,'note':note.trim(),'created':DateTime.now().toIso8601String()});
    }));
  }
  Future<int> addPrivateBatch(double grossKg, int purchasePrice, double netKg, String note, {int batchExpense=0, String expenseNote='مصاريف شراء'}) async {
    if (!grossKg.isFinite || grossKg <= 0 || purchasePrice <= 0 || !netKg.isFinite || netKg <= 0 || netKg > grossKg || batchExpense < 0) throw Exception('تحقق من الوزن الإجمالي والصافي وسعر الشراء والمصروف');
    final db=await database;
    final purchaseGuardKey='purchase:${grossKg.toStringAsFixed(6)}:$purchasePrice:${netKg.toStringAsFixed(6)}:${note.trim()}:$batchExpense:$expenseNote';
    return _guardedWrite(purchaseGuardKey, () => db.transaction((txn)async{
      final id=await txn.insert('private_batches', {'gross_kg':grossKg,'purchase_price':purchasePrice,'total_cost':(grossKg*purchasePrice).round(),'net_kg':netKg,'created':DateTime.now().toIso8601String(),'note':note.trim()});
      if(batchExpense>0) await txn.insert('batch_expenses',{'batch_id':id,'amount':batchExpense,'note':expenseNote.trim().isEmpty?'مصاريف شراء':expenseNote.trim(),'created':DateTime.now().toIso8601String()});
      return id;
    }));
  }
  // FIFO batch statement: calculates allocation of historical sales without modifying saved data.
  Future<Map<String,Object?>> privateBatchStatement(int batchId) async {
    final db=await database;
    final batchRows=await db.query('private_batches',where:'id=?',whereArgs:[batchId],limit:1);
    if(batchRows.isEmpty)throw Exception('عملية الشراء غير موجودة');
    final batch=batchRows.first;
    final netKg=(batch['net_kg'] as num).toDouble();
    final baseCost=(batch['total_cost'] as num).toDouble();
    final expenseRows=await db.query('batch_expenses',where:'batch_id=?',whereArgs:[batchId]);
    final expenseTotal=expenseRows.fold<num>(0,(sum,e)=>sum+(e['amount'] as num)).toDouble();
    final capital=baseCost+expenseTotal;
    final financialInputsOk=batchFinancialInputsAllowed(batch['gross_kg'] as num,netKg,batch['purchase_price'] as num,baseCost,expenseRows.map((e)=>e['amount'] as num).toList());
    final unitCost=batchUnitCost(baseCost,expenseTotal,netKg);
    final allocationRows=await db.query('sale_batch_allocations',where:'batch_id=?',whereArgs:[batchId]);
    final salesRows=await db.query('sales',orderBy:'created ASC,id ASC');
    double soldKg=0,revenue=0;
    var revenueShareIntegrityOk=true;
    final allocatedSales=<Map<String,Object?>>[];
    for(final allocation in allocationRows){
      final saleId=allocation['sale_id'];
      final saleRows=salesRows.where((sale)=>sale['id']==saleId);
      if(saleRows.isEmpty)continue;
      final sale=saleRows.first;
      final kg=(allocation['kg'] as num).toDouble();
      final saleKg=(sale['kg'] as num).toDouble();
      final saleTotal=(sale['total'] as num).toDouble();
      if(!allocationRevenueShareAllowed(saleTotal,saleKg,kg)){
        revenueShareIntegrityOk=false;
        continue;
      }
      final allocatedRevenue=allocationRevenueShare(saleTotal,saleKg,kg);
      soldKg+=kg;revenue+=allocatedRevenue;
      allocatedSales.add({'invoice':sale['invoice'],'created':sale['created'],'kg':kg,'revenue':allocatedRevenue,'unitPrice':sale['price']});
    }
    final remainingKg=(netKg-soldKg).clamp(0.0,netKg);
    final costOfSold=soldKg*unitCost;
    final migrationUnallocated=double.tryParse(await setting('legacy_unallocated_sales_kg','0'))??0.0;
    final allSalesKg=(await db.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sales')).first['kg'] as num;
    final allAllocatedKg=(await db.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sale_batch_allocations')).first['kg'] as num;
    final unallocatedSalesKg=unallocatedSaleKg(allSalesKg,allAllocatedKg,migrationUnallocated);
    final saleAllocatedTotals=<int,double>{};
    for(final a in await db.query('sale_batch_allocations')) {
      final sid=a['sale_id'] as int;
      saleAllocatedTotals[sid]=(saleAllocatedTotals[sid]??0.0)+(a['kg'] as num).toDouble();
    }
    final invoiceIntegrity=salesRows.every((sale) => !saleAllocationMismatch((sale['kg'] as num),saleAllocatedTotals[sale['id'] as int]??0));
    final allBatchRows=await db.query('private_batches');
    final batchAllocatedTotals=<int,double>{};
    for(final a in await db.query('sale_batch_allocations')) {
      final bid=a['batch_id'] as int;
      batchAllocatedTotals[bid]=(batchAllocatedTotals[bid]??0.0)+(a['kg'] as num).toDouble();
    }
    final batchIntegrity=allBatchRows.every((b)=>!batchAllocationOverage(batchAllocatedTotals[b['id'] as int]??0,b['net_kg'] as num));
    final allocationRowsAll=await db.query('sale_batch_allocations');
    final allocationReferencesOk=allocationRowsAll.every((a)=>allocationRowValid(a['kg'] as num)&&salesRows.any((sale)=>sale['id']==a['sale_id'])&&allBatchRows.any((b)=>b['id']==a['batch_id']));
    final allocationIntegrityOk=invoiceIntegrity&&batchIntegrity&&allocationReferencesOk;
    final profit=batchNetProfit(revenue,soldKg,unitCost);
    return {'batch':batch,'netKg':netKg,'cost':baseCost,'unitCost':unitCost,'batchExpenses':expenseTotal,'capital':capital,'soldKg':soldKg,'remainingKg':remainingKg,'revenue':revenue,'costOfSold':costOfSold,'expenseShare':expenseTotal*(soldKg/(netKg==0?1:netKg)),'profit':profit,'profitReliable':financialInputsOk&&revenueShareIntegrityOk&&batchStatementIntegrityAllowed(netKg,baseCost,expenseTotal,soldKg,revenue,unallocatedSalesKg,allocationIntegrityOk),'profitFinal':financialInputsOk&&revenueShareIntegrityOk&&batchStatementIntegrityAllowed(netKg,baseCost,expenseTotal,soldKg,revenue,unallocatedSalesKg,allocationIntegrityOk)&&remainingKg<=0.0001,'allocationIntegrityOk':allocationIntegrityOk,'expenseTotal':expenseTotal,'unallocatedSoldKg':unallocatedSalesKg,'allocations':allocatedSales,'expenseRows':expenseRows};
  }
  Future<void> updatePrivateBatch(int id,double grossKg,int purchasePrice,double netKg,String note) async {
    if(!grossKg.isFinite || grossKg<=0 || purchasePrice<=0 || !netKg.isFinite || netKg<=0 || netKg>grossKg) throw Exception('تحقق من الوزن الإجمالي والصافي وسعر الشراء');
    final db=await database;
    // Validate and update within one transaction so stock cannot change between check and write.
    await db.transaction((txn) async {
      final oldRows=await txn.query('private_batches',where:'id=?',whereArgs:[id],limit:1);
      if(oldRows.isEmpty) throw Exception('عملية الشراء غير موجودة');
      final old=oldRows.first;
      final soldForBatch=(await txn.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sale_batch_allocations WHERE batch_id=?',[id])).first['kg'] as num;
      if(netKg+0.0001<soldForBatch) throw Exception('لا يمكن تعديل الشراء: الصافي أقل من الوزن المباع من هذه الدفعة.');
      if(!batchFinancialEditAllowed(soldForBatch,old['gross_kg'] as num,old['purchase_price'] as num,old['net_kg'] as num,grossKg,purchasePrice,netKg)) throw Exception('لا يمكن تعديل الوزن أو سعر الشراء بعد تسجيل مبيعات على الدفعة؛ يمكنك تعديل الملاحظة فقط حتى لا تتغير الأرباح السابقة.');
      await txn.update('private_batches',{'gross_kg':grossKg,'purchase_price':purchasePrice,'total_cost':(grossKg*purchasePrice).round(),'net_kg':netKg,'note':note.trim()},where:'id=?',whereArgs:[id]);
    });
  }
  Future<void> deletePrivateBatch(int id) async {
    final db=await database;
    // Protect stock validation and removal as one atomic operation.
    await db.transaction((txn) async {
      final oldRows=await txn.query('private_batches',where:'id=?',whereArgs:[id],limit:1);
      if(oldRows.isEmpty) throw Exception('عملية الشراء غير موجودة');
      final allocated=(await txn.rawQuery('SELECT COALESCE(SUM(kg),0) kg FROM sale_batch_allocations WHERE batch_id=?',[id])).first['kg'] as num;
      if(allocated>0.0001) throw Exception('لا يمكن حذف دفعة مرتبطة بمبيعات. احذف أو عدّل الفواتير المرتبطة أولاً.');
      await txn.delete('batch_expenses',where:'batch_id=?',whereArgs:[id]);
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
        if(!invoiceDeletionAllowed(remaining,saleOutstanding,collected)) throw Exception('لا يمكن حذف الفاتورة؛ توجد تحصيلات لا يمكن ربطها بعد الحذف.');
      }
      final allocationRows=await txn.query('sale_batch_allocations',where:'sale_id=?',whereArgs:[id]);
      final allocatedKg=allocationRows.fold<num>(0,(sum,row)=>sum+(row['kg'] as num));
      final validRows=allocationRows.every((row)=>allocationRowValid(row['kg'] as num));
      final batchIds=allocationRows.map((row)=>row['batch_id'] as int).toSet();
      final existingBatches=await txn.query('private_batches',where:'id IN (${batchIds.isEmpty ? -1 : batchIds.join(',')})');
      final validBatchReferences=existingBatches.length==batchIds.length;
      if(!saleDeletionAllocationIntegrityOk(sale['kg'] as num,allocatedKg,validRows,validBatchReferences)) {
        throw Exception('لا يمكن حذف الفاتورة بسبب خلل في توزيع وزنها على دفعات المخزون؛ أصلح التوزيع أولاً حتى لا يتضرر المخزون.');
      }
      await txn.delete('sale_batch_allocations',where:'sale_id=?',whereArgs:[id]);
      await txn.delete('sales',where:'id=?',whereArgs:[id]);
    });
  }
}
void showMessage(BuildContext context, String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(text)));

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.isDark, required this.onToggleTheme});
  final bool isDark;
  final VoidCallback onToggleTheme;
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
    return WillPopScope(
      onWillPop: () async {
        if (selected != 0) {
          setState(() => selected = 0);
          return false;
        }
        return true;
      },
      child: Scaffold(
        appBar: AppBar(title:Text(const ['الرئيسية','الفواتير','العملاء','التقارير'][selected]),actions:[
          IconButton(tooltip:widget.isDark?'تفعيل الوضع النهاري':'تفعيل الوضع الليلي',icon:Icon(widget.isDark?Icons.light_mode:Icons.dark_mode),onPressed:widget.onToggleTheme),
          IconButton(icon:const Icon(Icons.settings),onPressed:()async{await Navigator.push(context,MaterialPageRoute(builder:(_)=>const SettingsPage()));if(mounted)refreshAll();})
        ]),
        body:SafeArea(top:false,child:pages[selected]),
        bottomNavigationBar:SafeArea(top:false,child:NavigationBar(selectedIndex:selected,onDestinationSelected:(v)=>setState(()=>selected=v),backgroundColor:widget.isDark?panel:Colors.white,indicatorColor:gold.withValues(alpha:0.18),destinations:const [
          NavigationDestination(icon:Icon(Icons.home),label:'الرئيسية'),
          NavigationDestination(icon:Icon(Icons.receipt_long),label:'فواتير'),
          NavigationDestination(icon:Icon(Icons.people),label:'عملاء'),
          NavigationDestination(icon:Icon(Icons.bar_chart),label:'تقارير'),
        ])),
      ),
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
  final clients=await DB.instance.customers();
  final batches=await DB.instance.batchStocks();
  if(!context.mounted)return;
  final availableBatches=batches.where((b)=>(b['remaining_kg'] as num)>0.0001).toList();
  if(availableBatches.isEmpty){showMessage(context,'لا يوجد مخزون متاح في أي دفعة. سجّل عملية شراء أولاً.');return;}
  int? customerId;
  int? batchId=availableBatches.first['id'] as int;
  final kgCtrl=TextEditingController(),priceCtrl=TextEditingController(text:await DB.instance.setting('price','6500')),paidCtrl=TextEditingController(),noteCtrl=TextEditingController();
  String type='نقدي';
  await showDialog<void>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setDialog)=>AlertDialog(title:const Text('بيع تونة'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
    DropdownButtonFormField<int>(initialValue:batchId,decoration:const InputDecoration(labelText:'دفعة الشراء — البيع منها فقط'),items:availableBatches.map((b)=>DropdownMenuItem<int>(value:b['id'] as int,child:Text('شراء رقم ${b['id']} • المتبقي ${(b['remaining_kg'] as num).toStringAsFixed(3)} كجم'))).toList(),onChanged:(v)=>setDialog(()=>batchId=v)),
    DropdownButtonFormField<int>(initialValue:customerId,decoration:const InputDecoration(labelText:'العميل (اختياري — اتركه فارغًا للبيع النقدي)'),items:[const DropdownMenuItem<int>(value:null,child:Text('بيع نقدي بدون تسجيل عميل')), ...clients.map((c)=>DropdownMenuItem<int>(value:c['id'] as int,child:Text(c['name'] as String)))],onChanged:(v)=>setDialog(()=>customerId=v)),
    TextField(controller:kgCtrl,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الوزن بالكيلو')),
    TextField(controller:priceCtrl,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'سعر الكيلو')),
    TextField(controller:paidCtrl,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المدفوع')),
    DropdownButtonFormField<String>(initialValue:type,decoration:const InputDecoration(labelText:'نوع البيع'),items:['نقدي','آجل'].map((x)=>DropdownMenuItem<String>(value:x,child:Text(x))).toList(),onChanged:(v)=>setDialog(()=>type=v??'نقدي')),
    TextField(controller:noteCtrl,decoration:const InputDecoration(labelText:'ملاحظات')),
  ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{
    if(batchId==null)throw Exception('اختر دفعة شراء');
    final weight=double.parse(kgCtrl.text),price=int.parse(priceCtrl.text),total=(weight*price).round();
    final paid=paidCtrl.text.trim().isEmpty?(type=='نقدي'?total:0):int.parse(paidCtrl.text);
    await DB.instance.addSale(customerId,batchId!,weight,price,paid,type,noteCtrl.text);await DB.instance.setSetting('price',price.toString());
    if(ctx.mounted)Navigator.pop(ctx);if(context.mounted)showMessage(context,'تم حفظ البيع وربطه بالدفعة المحددة');
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
  Future<void> notifyArrival(Map<String,Object?> reservation) async {
    final phone = (reservation['phone'] as String? ?? '').trim();
    if (phone.isEmpty) { showMessage(context, 'لا يوجد رقم هاتف لهذا الحجز'); return; }
    final customer = reservation['customer_name'] as String? ?? 'عميلنا العزيز';
    final number = normalizeWhatsAppNumber(phone);
    final message = reservationArrivalMessage(customer, reservation['kg'] as num);
    final uri = Uri.https('wa.me', '/$number', {'text': message});
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) showMessage(context, 'تعذر فتح واتساب');
    } catch (_) { if (mounted) showMessage(context, 'تعذر فتح واتساب'); }
  }
  Future<void> notifyArrivalSms(Map<String,Object?> reservation) async {
    final rawPhone=(reservation['phone'] as String? ?? '').trim();
    if(rawPhone.isEmpty){showMessage(context,'لا يوجد رقم هاتف لهذا الحجز');return;}
    final phone=normalizeYemeniSmsNumber(rawPhone);
    final customer=reservation['customer_name'] as String? ?? 'عميلنا العزيز';
    final kg=(reservation['kg'] as num).toStringAsFixed(3);
    final controller=TextEditingController(text:'السلام عليكم ' + customer + '، نود إشعارك بأن كمية التونة الطازجة التي حجزتها (' + kg + ' كجم) أصبحت متوفرة الآن. يسعدنا خدمتك في تونة بلس، وشكرًا لثقتك بنا.');
    final edited=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('رسالة SMS للعميل'),
      content:TextField(controller:controller,maxLines:5,decoration:const InputDecoration(labelText:'يمكنك تعديل الرسالة قبل فتح تطبيق الرسائل',border:OutlineInputBorder())),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,controller.text.trim()),child:const Text('فتح الرسائل'))]
    ));
    controller.dispose();
    if(edited==null||edited.isEmpty)return;
    final uri=Uri(scheme:'sms',path:phone,queryParameters:{'body':edited});
    try{final opened=await launchUrl(uri,mode:LaunchMode.externalApplication);if(!opened&&mounted)showMessage(context,'تعذر فتح تطبيق الرسائل');}
    catch(_){if(mounted)showMessage(context,'تعذر فتح تطبيق الرسائل');}
  }
  Future<void> add() async {
    final name=TextEditingController(),phone=TextEditingController(),kg=TextEditingController(),price=TextEditingController(text:'6500'),deposit=TextEditingController(text:'0'),note=TextEditingController();
    bool pickingContact=false;
    Future<void> chooseReservationContact(BuildContext dialogContext,StateSetter setDialog) async {
      if(pickingContact)return;
      pickingContact=true;
      bool loadingOpen=false;
      try {
        var permission=await permissions.Permission.contacts.status;
        final granted=permission.isGranted?true:await FlutterContacts.requestPermission(readonly:true);
        if(!permission.isGranted&&granted)permission=await permissions.Permission.contacts.status;
        if(!granted||!permission.isGranted){if(dialogContext.mounted)showMessage(dialogContext,'لم يتم منح إذن جهات الاتصال. يمكنك إدخال الاسم والرقم يدويًا.');return;}
        if(!dialogContext.mounted)return;
        loadingOpen=true;
        showDialog<void>(context:dialogContext,barrierDismissible:false,builder:(_)=>const AlertDialog(content:Row(mainAxisSize:MainAxisSize.min,children:[CircularProgressIndicator(),SizedBox(width:16),Flexible(child:Text('جارٍ تحميل جهات الاتصال...'))])));
        final contacts=_contactCache??await FlutterContacts.getContacts(withProperties:true);
        if(dialogContext.mounted&&loadingOpen){Navigator.of(dialogContext,rootNavigator:true).pop();loadingOpen=false;}
        if(!dialogContext.mounted)return;
        if(_contactCache==null){contacts.sort((a,b)=>a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));_contactCache=contacts;}
        final search=TextEditingController();
        final selected=await showDialog<Contact>(context:dialogContext,builder:(pickContext)=>StatefulBuilder(builder:(pickContext,refreshPicker){
          final q=search.text.trim().toLowerCase();
          final filtered=contacts.where((c)=>c.displayName.toLowerCase().contains(q)||c.phones.map((p)=>p.number).join(' ').contains(q)).toList();
          return AlertDialog(title:const Text('اختر جهة اتصال'),content:SizedBox(width:double.maxFinite,height:MediaQuery.of(pickContext).size.height*0.62,child:Column(children:[
            TextField(controller:search,decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'بحث بالاسم أو الهاتف'),onChanged:(_)=>refreshPicker((){})),
            const SizedBox(height:6),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child:Text('لا توجد نتائج'))
                  : ListView.builder(
                      itemCount:filtered.length,
                      itemBuilder:(_,i){
                        final c=filtered[i];
                        return ListTile(
                          title:Text(c.displayName.isEmpty?'بدون اسم':c.displayName),
                          subtitle:Text(c.phones.isEmpty?'لا يوجد رقم هاتف':c.phones.first.number),
                          leading:const Icon(Icons.person,color:gold),
                          onTap:()=>Navigator.pop(pickContext,c),
                        );
                      },
                    ),
            ),
          ])),
          );
        }));
        search.dispose();
        if(selected!=null){setDialog(()=>name.text=selected.displayName);if(selected.phones.isNotEmpty)setDialog(()=>phone.text=selected.phones.first.number);}
      }catch(e){if(dialogContext.mounted&&loadingOpen){Navigator.of(dialogContext,rootNavigator:true).pop();loadingOpen=false;}if(dialogContext.mounted)showMessage(dialogContext,'تعذر فتح جهات الاتصال: $e');}
      finally{pickingContact=false;if(dialogContext.mounted)setDialog((){});}
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialog) {
            return AlertDialog(
              title: const Text('حجز كمية قادمة'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.maxFinite,
                      child: OutlinedButton.icon(
                        onPressed: pickingContact
                            ? null
                            : () => chooseReservationContact(ctx, setDialog),
                        icon: pickingContact
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.contacts),
                        label: Text(
                          pickingContact
                              ? 'جارٍ فتح جهات الاتصال...'
                              : 'جلب العميل من جهات الاتصال',
                        ),
                      ),
                    ),
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(labelText: 'اسم العميل'),
                    ),
                    TextField(
                      controller: phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'رقم الهاتف'),
                    ),
                    TextField(
                      controller: kg,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'الوزن المطلوب بالكيلو'),
                    ),
                    TextField(
                      controller: price,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'سعر الكيلو المتفق عليه'),
                    ),
                    TextField(
                      controller: deposit,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'العربون (اختياري)'),
                    ),
                    TextField(
                      controller: note,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'ملاحظات'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: () async {
                    try {
                      await DB.instance.addReservation(
                        name.text,
                        phone.text,
                        double.parse(kg.text),
                        int.parse(price.text),
                        int.tryParse(deposit.text) ?? 0,
                        note.text,
                      );
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) reload();
                    } catch (e) {
                      showMessage(ctx, e.toString().replaceFirst('Exception: ', ''));
                    }
                  },
                  child: const Text('حفظ الحجز'),
                ),
              ],
            );
          },
        );
      },
    );
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
           IconButton(tooltip:'إشعار وصول عبر SMS',onPressed:()=>notifyArrivalSms(r),icon:const Icon(Icons.sms_outlined,color:Colors.lightBlue)),
          IconButton(tooltip:'إشعار وصول عبر واتساب',onPressed:()=>notifyArrival(r),icon:const Icon(Icons.notifications_active_outlined,color:Colors.green)),
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
          IconButton(icon:const Icon(Icons.delete,color:Colors.red),onPressed:()async{
          final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
            title:const Text('تأكيد حذف الفاتورة'),
            content:Text('هل تريد حذف الفاتورة ${v['invoice']}؟\nلا يمكن التراجع عن الحذف.'),
            actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),style:FilledButton.styleFrom(backgroundColor:Colors.red),child:const Text('حذف الفاتورة'))],
          ));
          if(confirmed!=true)return;
          try{await DB.instance.deleteSale(v['id'] as int);if(mounted)setState(()=>future=DB.instance.sales());}
          catch(e){if(mounted)showMessage(context,e.toString().replaceFirst('Exception: ',''));}
        })
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
      final logoData = await rootBundle.load('assets/tuna_plus_crown_icon.png');
      final logoBytes = logoData.buffer.asUint8List(logoData.offsetInBytes, logoData.lengthInBytes);
      final logo = pw.MemoryImage(logoBytes);
      final doc = pw.Document();

      doc.addPage(pw.Page(
        pageFormat: pdf.PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(26),
        build: (_) => pw.Directionality(
          textDirection: pw.TextDirection.rtl,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                decoration: pw.BoxDecoration(color: pdf.PdfColor.fromHex('#111111'), borderRadius: pw.BorderRadius.circular(12)),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Container(width: 82, height: 82, decoration: pw.BoxDecoration(color: pdf.PdfColor.fromHex('#FFFFFF'), borderRadius: pw.BorderRadius.circular(8)), padding: const pw.EdgeInsets.all(4), child: pw.Image(logo, fit: pw.BoxFit.contain)),
                    pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
                      pdfText(shop, font, fontSize: 25, color: pdf.PdfColor.fromHex('#D7AF59')),
                      pdfText('فاتورة مبيعات • ثمد طازج', font, fontSize: 12, color: pdf.PdfColor.fromHex('#F4E8CF')),
                      pdfText('TUNA PLUS', font, fontSize: 10, color: pdf.PdfColor.fromHex('#D7AF59')),
                    ])),
                  ],
                ),
              ),
              pw.SizedBox(height: 12),
              pw.Container(padding: const pw.EdgeInsets.all(12), decoration: pw.BoxDecoration(color: pdf.PdfColor.fromHex('#F7F3EA'), border: pw.Border.all(color: pdf.PdfColor.fromHex('#D8C69B'), width: 0.8), borderRadius: pw.BorderRadius.circular(8)), child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
                pdfText('رقم الفاتورة: ${sale['invoice']}', font, fontSize: 10),
                pdfText('التاريخ: ${(sale['created'] as String).substring(0,16).replaceFirst('T',' ')}', font, fontSize: 10),
                pdfText('العميل: ${client?['name'] ?? 'عميل نقدي'}', font, fontSize: 11),
              ])),
              pw.SizedBox(height: 14),
              pw.Table(border: pw.TableBorder.all(color: pdf.PdfColor.fromHex('#C8B58C'), width: 0.6), children: [
                pw.TableRow(decoration: pw.BoxDecoration(color: pdf.PdfColor.fromHex('#2C2924')), children: [
                  pdfCell('الوزن (كجم)', font, header: true), pdfCell('سعر الكيلو', font, header: true), pdfCell('الإجمالي', font, header: true),
                ]),
                pw.TableRow(children: [pdfCell(sale['kg'].toString(), font), pdfCell(money(sale['price'] as num), font), pdfCell(money(total), font)]),
              ]),
              pw.SizedBox(height: 14),
              pw.Container(padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 12), decoration: pw.BoxDecoration(color: pdf.PdfColor.fromHex('#171717'), borderRadius: pw.BorderRadius.circular(8)), child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
                pdfText('الإجمالي: ${money(total)}', font, fontSize: 15, color: pdf.PdfColor.fromHex('#D7AF59')),
                pdfText('المدفوع: ${money(paid)}', font, fontSize: 11, color: pdf.PdfColor.fromHex('#FFFFFF')),
                pdfText('المتبقي: ${money(due)}', font, fontSize: 13, color: pdf.PdfColor.fromHex('#F4E8CF')),
              ])),
              if ((sale['note'] as String? ?? '').isNotEmpty) pw.Container(margin: const pw.EdgeInsets.only(top: 10), padding: const pw.EdgeInsets.all(9), decoration: pw.BoxDecoration(border: pw.Border.all(color: pdf.PdfColor.fromHex('#D8C69B')), borderRadius: pw.BorderRadius.circular(6)), child: pdfText('ملاحظات: ${sale['note']}', font, fontSize: 10)),
              pw.SizedBox(height: 14),
              pw.Container(padding: const pw.EdgeInsets.all(12), decoration: pw.BoxDecoration(border: pw.Border.all(color: pdf.PdfColor.fromHex('#D8C69B')), borderRadius: pw.BorderRadius.circular(8)), child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
                pdfText('بيانات التحويل البنكي', font, fontSize: 13, color: pdf.PdfColor.fromHex('#9A742B')),
                pdfText('بنك العميقي', font, fontSize: 10),
                pw.Center(child: pw.Text(bank, textDirection: pw.TextDirection.ltr, style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold, color: pdf.PdfColor.fromHex('#9A742B')))),
                pdfText('اضغط مطولاً على الرقم لتحديده ونسخه', font, fontSize: 8, color: pdf.PdfColor.fromHex('#777777'), align: ShapedTextAlign.center),
                pdfText(owner, font, fontSize: 10), pdfText('رقم الهاتف: $phone', font, fontSize: 10), pdfText('العنوان: $address', font, fontSize: 9),
              ])),
              pw.SizedBox(height: 14),
              pw.Container(padding: const pw.EdgeInsets.symmetric(vertical: 8), decoration: pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: pdf.PdfColor.fromHex('#D7AF59'), width: 1.5))), child: pdfText('شكراً لثقتكم • تونة بلس', font, fontSize: 13, color: pdf.PdfColor.fromHex('#9A742B'), align: ShapedTextAlign.center)),
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
                      trailing: IconButton(
                        tooltip: 'حذف التحصيل',
                        icon: const Icon(Icons.delete_outline,color:Colors.red),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
                            title:const Text('تأكيد حذف التحصيل'),
                            content:Text('سيتم حذف تحصيل ${money(receipt['amount'] as num)} وإعادة المبلغ إلى الدين المستحق. هل تريد المتابعة؟'),
                            actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),style:FilledButton.styleFrom(backgroundColor:Colors.red),child:const Text('حذف'))],
                          ));
                          if(confirmed!=true) return;
                          try {
                            await DB.instance.deleteCollection(id,receipt['id'] as int);
                            if(mounted)setState(load);
                          } catch(e) {
                            if(mounted)showMessage(context,e.toString());
                          }
                        },
                      ),
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
                      pdfText('المصروفات العامة غير الموزعة على الشحنات: ${number(totals['expensesAllocated'])} ر.ي (تُخصم من الربح الإجمالي، ولا تدخل في ربح الشحنة الفردية)', font),
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
          'expensesAllocated':'مصروفات عامة غير موزعة على الشحنات (تُخصم من الربح الإجمالي)',
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
  Future<void> showGlobalInventory() async {
    final batches=await DB.instance.batchStocks();
    final totals=await DB.instance.totals();
    if(!mounted)return;
    final actualController=TextEditingController();
    double gross=0,net=0,sold=0,remaining=0,cost=0;
    for(final b in batches){
      gross+=(b['gross_kg'] as num).toDouble();
      net+=(b['net_kg'] as num).toDouble();
      sold+=(b['sold_kg'] as num).toDouble();
      remaining+=(b['remaining_kg'] as num).toDouble();
      cost+=(b['total_cost'] as num).toDouble();
    }
    await showDialog<void>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setDialog)=>AlertDialog(
      title:const Text('الجرد الشامل — عرض فقط'),
      content:SizedBox(width:double.maxFinite,height:MediaQuery.of(ctx).size.height*0.65,child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        const Text('تجميع لكل دفعات الشراء دون تغيير أرصدتها.',style:TextStyle(color:Colors.orange,fontSize:12)),
        const Divider(),
        Text('الوزن الإجمالي المشترى: ${gross.toStringAsFixed(3)} كجم'),
        Text('الوزن الصافي بعد التقطيع: ${net.toStringAsFixed(3)} كجم'),
        Text('الوزن المباع (حسب تخصيص الدفعات): ${sold.toStringAsFixed(3)} كجم'),
        Text('المخزون النظري المتبقي: ${remaining.toStringAsFixed(3)} كجم',style:const TextStyle(fontWeight:FontWeight.bold,color:gold)),
        Text('تكلفة الشراء الأساسية: ${money(cost)}'),
        Text('إجمالي إيرادات المبيعات: ${money(totals['sales']??0)}'),
        Text('تكلفة البضاعة المباعة (شاملة مصروف الدفعات): ${money(totals['costOfSold']??0)}'),
        Text('إجمالي المصروفات المسجلة: ${money(totals['expenses']??0)}'),
        Text('المصروفات العامة غير الموزعة على الشحنات: ${money(totals['expensesAllocated']??0)} (تُخصم من الربح الإجمالي)',style:const TextStyle(fontSize:12,color:Colors.orange)),
        Text('الربح المؤقت: ${money(totals['netProfit']??0)}'),
        const Divider(),
        TextField(controller:actualController,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الوزن الفعلي الذي قمت بوزنه (كجم)',border:OutlineInputBorder()),onChanged:(_)=>setDialog((){})),
        if(actualController.text.trim().isNotEmpty&&double.tryParse(actualController.text.trim())!=null)
          Text('فرق الجرد: ${(double.parse(actualController.text.trim())-remaining).toStringAsFixed(3)} كجم • ${double.parse(actualController.text.trim())>=remaining?'زيادة':'عجز'}',style:const TextStyle(fontWeight:FontWeight.bold)),
      ]))),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق'))],
    )));
    actualController.dispose();
  }
  Future<void> addEntry() async {
    final gross = TextEditingController();
    final price = TextEditingController();
    final net = TextEditingController();
    final purchaseExpense = TextEditingController(text:'0');
    final expenseNote = TextEditingController(text:'نقل/عمال/تجهيز');
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
                      controller: purchaseExpense,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'مصاريف هذه الدفعة (ريال) — تضاف لرأس المال', prefixIcon: Icon(Icons.money_off), border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: expenseNote,
                      decoration: const InputDecoration(labelText: 'بيان المصروفات (اختياري)', prefixIcon: Icon(Icons.notes), border: OutlineInputBorder()),
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
                                  batchExpense: int.tryParse(purchaseExpense.text.trim().isEmpty?'0':purchaseExpense.text.trim()) ?? -1,
                                  expenseNote: expenseNote.text,
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
      purchaseExpense.dispose();
      expenseNote.dispose();
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
  Future<void> addBatchExpenseDialog(int batchId) async {
    final amount=TextEditingController(),note=TextEditingController();
    try{
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('إضافة مصروف للدفعة'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المبلغ (ريال)')),
          TextField(controller:note,decoration:const InputDecoration(labelText:'بيان المصروف')),
        ]),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{
          final value=int.tryParse(amount.text.trim());
          if(value==null||value<=0){showMessage(ctx,'أدخل مبلغًا صحيحًا');return;}
          if(note.text.trim().isEmpty){showMessage(ctx,'اكتب بيان المصروف');return;}
          try{await DB.instance.addBatchExpense(batchId,value,note.text);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState(reloadEntries);}
          catch(e){showMessage(ctx,e.toString().replaceFirst('Exception: ',''));}
        },child:const Text('حفظ المصروف'))]
      ));
    }finally{amount.dispose();note.dispose();}
  }
  Future<void> editBatchExpenseDialog(Map<String,Object?> expense) async {
    final amount=TextEditingController(text:(expense['amount'] as num).toString());
    final note=TextEditingController(text:expense['note'] as String? ?? '');
    try{
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:const Text('تعديل مصروف الدفعة'),content:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المبلغ (ريال)')),
        TextField(controller:note,decoration:const InputDecoration(labelText:'بيان المصروف')),
      ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{
        final value=int.tryParse(amount.text.trim());
        if(value==null||value<=0){showMessage(ctx,'أدخل مبلغًا صحيحًا');return;}
        if(note.text.trim().isEmpty){showMessage(ctx,'اكتب بيان المصروف');return;}
        try{await DB.instance.updateBatchExpense(expense['id'] as int,value,note.text);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState(reloadEntries);}
        catch(e){showMessage(ctx,e.toString().replaceFirst('Exception: ',''));}
      },child:const Text('حفظ'))]));
    }finally{amount.dispose();note.dispose();}
  }
  Future<void> deleteBatchExpenseDialog(Map<String,Object?> expense) async {
    final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('حذف مصروف الدفعة'),content:Text('هل تريد حذف «${expense['note']}» بقيمة ${money(expense['amount'] as num)}؟'),actions:[
      TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),
      FilledButton(onPressed:()=>Navigator.pop(ctx,true),style:FilledButton.styleFrom(backgroundColor:Colors.red),child:const Text('حذف'))
    ]));
    if(confirmed==true){await DB.instance.deleteBatchExpense(expense['id'] as int);if(mounted)setState(reloadEntries);}
  }
  Future<void> editExpense(Map<String,Object?> row) async {
    final amount=TextEditingController(text:(row['amount'] as num).toString());
    final note=TextEditingController(text:row['note'] as String? ?? '');
    try{
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('تعديل المصروف'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'مبلغ المصروف (ريال)',prefixIcon:Icon(Icons.payments))),
          TextField(controller:note,maxLines:3,decoration:const InputDecoration(labelText:'بيان المصروف',prefixIcon:Icon(Icons.notes))),
        ]),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton.icon(icon:const Icon(Icons.save),label:const Text('حفظ التعديل'),onPressed:()async{
          final value=int.tryParse(amount.text.trim());
          if(value==null||value<=0){showMessage(ctx,'أدخل مبلغًا صحيحًا أكبر من صفر');return;}
          if(note.text.trim().isEmpty){showMessage(ctx,'اكتب بيان المصروف لتسهيل المراجعة');return;}
          try{await DB.instance.updateExpense(row['id'] as int,value,note.text);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState(reloadEntries);}
          catch(e){showMessage(ctx,e.toString().replaceFirst('Exception: ',''));}
        })]
      ));
    }finally{amount.dispose();note.dispose();}
  }
  Future<void> deleteExpense(Map<String,Object?> row) async {
    final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('حذف المصروف'),
      content:Text('هل تريد حذف المصروف «' + (row['note'] as String) + '» بقيمة ' + money(row['amount'] as num) + '؟ سيتم تحديث إجمالي المصروفات والربح تلقائيًا.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),style:FilledButton.styleFrom(backgroundColor:Colors.red),child:const Text('حذف'))]
    ));
    if(confirmed!=true)return;
    try{await DB.instance.deleteExpense(row['id'] as int);if(mounted)setState(reloadEntries);}
    catch(e){if(mounted)showMessage(context,e.toString().replaceFirst('Exception: ',''));}
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
  Future<void> exportBatchPdf(Map<String,Object?> purchase) async {
    try{
      final report=await DB.instance.privateBatchStatement(purchase['id'] as int);
      final batch=report['batch'] as Map<String,Object?>;
      final allocations=report['allocations'] as List<Map<String,Object?>>;
      final expenseRows=report['expenseRows'] as List<Map<String,Object?>>;
      final font=await loadArabicPdfFont();
      try{
        final number=(Object? value)=>NumberFormat('#,##0.##','en').format(value is num?value:0);
        final doc=pw.Document();
        doc.addPage(pw.MultiPage(
          pageFormat:pdf.PdfPageFormat.a4,
          margin:const pw.EdgeInsets.all(28),
          header:(ctx)=>pw.Container(alignment:pw.Alignment.centerRight,child:pdfText('تونة بلس • كشف دفعة شراء',font,fontSize:18,color:pdf.PdfColor.fromHex('#B78B34'))),
          footer:(ctx)=>pw.Container(alignment:pw.Alignment.center,child:pdfText('صفحة ${ctx.pageNumber} من ${ctx.pagesCount}',font,fontSize:9,align:ShapedTextAlign.center)),
          build:(ctx)=>[
            pw.Directionality(textDirection:pw.TextDirection.rtl,child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.stretch,children:[
              pdfText('دفعة شراء رقم ${batch['id']}',font,fontSize:15),
              pdfText('تاريخ الشراء: ${(batch['created'] as String).substring(0,10)}',font),
              pdfText('الوزن الإجمالي: ${number(batch['gross_kg'])} كجم • الصافي: ${number(report['netKg'])} كجم',font),
              pdfText('تكلفة الشراء الأساسية: ${number(report['cost'])} ر.ي',font),
              pdfText('مصاريف الدفعة: ${number(report['batchExpenses'])} ر.ي',font),
              pdfText('رأس المال: ${number(report['capital'])} ر.ي',font,fontSize:12),
              pdfText('تكلفة الكيلو الصافي: ${number(report['unitCost'])} ر.ي',font),
              pdfText('المباع: ${number(report['soldKg'])} كجم • المتبقي: ${number(report['remainingKg'])} كجم',font),
              pdfText('الإيراد: ${number(report['revenue'])} ر.ي • تكلفة المباع: ${number(report['costOfSold'])} ر.ي',font),
              pdfText('الربح ${(report['profitFinal'] as bool)?'النهائي':'المؤقت'}: ${number(report['profit'])} ر.ي',font,fontSize:12),
              pw.SizedBox(height:12),
              pdfText('تفاصيل المصروفات',font,fontSize:14),
              if(expenseRows.isEmpty)pdfText('لا توجد مصروفات للدفعة.',font),
              if(expenseRows.isNotEmpty)pw.Table(border:pw.TableBorder.all(color:pdf.PdfColor.fromHex('#D6C6A5'),width:0.4),children:[
                pw.TableRow(decoration:pw.BoxDecoration(color:pdf.PdfColor.fromHex('#2C2924')),children:[pdfCell('التاريخ',font,header:true),pdfCell('البيان',font,header:true),pdfCell('المبلغ',font,header:true)]),
                ...expenseRows.map((expense)=>pw.TableRow(children:[
                  pdfCell((expense['created'] as String).substring(0,10),font),
                  pdfCell(expense['note']?.toString()??'—',font),
                  pdfCell(number(expense['amount'])+' ر.ي',font),
                ]))
              ]),
              pw.SizedBox(height:8),
              pdfText('تفاصيل المبيعات',font,fontSize:14),
              pw.Table(border:pw.TableBorder.all(color:pdf.PdfColor.fromHex('#D6C6A5'),width:0.4),children:[
                pw.TableRow(decoration:pw.BoxDecoration(color:pdf.PdfColor.fromHex('#2C2924')),children:[pdfCell('الفاتورة',font,header:true),pdfCell('التاريخ',font,header:true),pdfCell('الوزن',font,header:true),pdfCell('الإيراد',font,header:true)]),
                ...allocations.map((sale)=>pw.TableRow(children:[
                  pdfCell(sale['invoice']?.toString()??'—',font),
                  pdfCell((sale['created'] as String).substring(0,10),font),
                  pdfCell(number(sale['kg'])+' كجم',font),
                  pdfCell(number(sale['revenue'])+' ر.ي',font),
                ]))
              ]),
              if(allocations.isEmpty)pdfText('لا توجد مبيعات مسجلة لهذه الدفعة.',font),
              if((batch['note'] as String? ?? '').isNotEmpty)pdfText('ملاحظة: ${batch['note']}',font),
            ]))
          ],
        ));
        await Printing.layoutPdf(onLayout:(_)async=>await doc.save());
      }finally{font.dispose();}
    }catch(e){if(mounted)showMessage(context,'تعذر تصدير كشف الدفعة: ${e.toString().replaceFirst('Exception: ','')}');}
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
          Text('مصاريف الدفعة: ${money(report['batchExpenses'] as num)}'),
          Text('رأس المال الإجمالي للدفعة: ${money(report['capital'] as num)}',style:const TextStyle(fontWeight:FontWeight.bold)),
          Text('تكلفة الكيلو الصافي: ${money(report['unitCost'] as num)}'),
          const Divider(),
          Text('الوزن المباع من هذه الشحنة: ${(report['soldKg'] as num).toStringAsFixed(3)} كجم'),
          Text('المتبقي: ${(report['remainingKg'] as num).toStringAsFixed(3)} كجم'),
          Text('إيرادات المبيعات الموزعة: ${money(report['revenue'] as num)}'),
          Text('تكلفة وزن المباع: ${money(report['costOfSold'] as num)}'),
          Text('مصاريف الدفعة المحملة على الوزن المباع: ${money(report['expenseShare'] as num)}'),
          Text((report['profitReliable'] as bool? ?? false)?((report['profitFinal'] as bool? ?? false)?'الربح النهائي بعد تصفية الدفعة: ${money(report['profit'] as num)}':'الربح المؤقت للدفعة: ${money(report['profit'] as num)}'):'الربح غير محسوب لوجود خلل في توزيع المخزون',style:TextStyle(color:(report['profitReliable'] as bool? ?? false)?gold:Colors.orange,fontWeight:FontWeight.bold)),
          const SizedBox(height:10),
          const Text('مصروفات هذه الدفعة',style:TextStyle(fontWeight:FontWeight.bold)),
          if((report['expenseRows'] as List).isEmpty)const Text('لا توجد مصروفات مسجلة لهذه الدفعة.'),
          ...((report['expenseRows'] as List<Map<String,Object?>>).map((expense)=>Card(child:ListTile(
            dense:true,title:Text(money(expense['amount'] as num)),subtitle:Text('${expense['note']} • ${dateLabel(expense['created'] as String)}'),
            trailing:PopupMenuButton<String>(onSelected:(action){if(action=='edit'){editBatchExpenseDialog(expense);}else if(action=='delete'){deleteBatchExpenseDialog(expense);}},itemBuilder:(_)=>const [PopupMenuItem(value:'edit',child:Text('تعديل')),PopupMenuItem(value:'delete',child:Text('حذف'))]),
          )))),
          const SizedBox(height:8),
          const Text('تفصيل المبيعات الموزعة على الشحنة',style:TextStyle(fontWeight:FontWeight.bold)),
          if(allocations.isEmpty)const Text('لم تُوزع مبيعات على هذه الشحنة بعد.'),
          ...allocations.map((s)=>Card(child:ListTile(
            dense:true,title:Text('${s['invoice']??'فاتورة'} • ${(s['kg'] as num).toStringAsFixed(3)} كجم'),
            subtitle:Text('${dateLabel(s['created'] as String)}\nالإيراد: ${money(s['revenue'] as num)}'),
            isThreeLine:true,
          ))),
          if((report['unallocatedSoldKg'] as num)>0.0001)Text('تنبيه: يوجد وزن مبيعات غير موزع على الشحنات بمقدار ${(report['unallocatedSoldKg'] as num).toStringAsFixed(3)} كجم؛ يلزم مراجعة المخزون قبل اعتماد الربح.',style:const TextStyle(color:Colors.orange,fontWeight:FontWeight.bold)),
            const Text('كل فاتورة مرتبطة بالدفعة التي اخترتها عند البيع. مصروفات الدفعة تدخل في رأس مالها وتكلفتها، ولا يتم خلطها مع الدفعات الأخرى.',style:TextStyle(fontSize:12)),
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
    return ListView(padding:const EdgeInsets.fromLTRB(12,12,12,128),children:[
      const Text('بيانات سرية لصاحب المتجر فقط',textAlign:TextAlign.center,style:TextStyle(color:gold,fontWeight:FontWeight.bold)),
      GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:2,childAspectRatio:1.5,children:[
        Card(child:ListTile(title:const Text('إجمالي الشراء'),subtitle:Text('${gross.toStringAsFixed(2)} كجم'))),
        Card(child:ListTile(title:const Text('الوزن الصافي'),subtitle:Text('${net.toStringAsFixed(2)} كجم'))),
        Card(child:ListTile(title:const Text('إجمالي رأس المال'),subtitle:Text(money(costs)))),
        Card(child:ListTile(title:const Text('الفاقد'),subtitle:Text('${loss.toStringAsFixed(2)} كجم'))),
      ]),
      Card(child:ListTile(title:const Text('التكلفة الحقيقية للكيلو الصافي'),subtitle:Text(money(eff),style:const TextStyle(color:gold,fontWeight:FontWeight.bold)))),
      Card(child:ListTile(title:const Text('فرق المبيعات المسجلة والمشتريات المسجلة (تقريبي)'),subtitle:FutureBuilder<Map<String,num>>(future:DB.instance.totals(),builder:(context,t){if(!t.hasData)return const Text('...');return Text(money(t.data!['sales']!-costs-(t.data!['expenses']??0)));}))),
      FilledButton.icon(onPressed:addEntry,icon:const Icon(Icons.add),label:const Text('إضافة عملية شراء')),
      const SizedBox(height:8),      OutlinedButton.icon(onPressed:showGlobalInventory,icon:const Icon(Icons.inventory),label:const Text('الجرد الشامل ومقارنة الوزن الفعلي')),
      const SizedBox(height:8),
      FutureBuilder<List<Map<String,Object?>>>(future:expenseEntries,builder:(context,e){
        if(!e.hasData)return const Card(child:ListTile(title:Text('إجمالي المصروفات'),subtitle:Text('جارٍ التحميل...')));
        final expenseTotal=e.data!.fold<num>(0,(sum,row)=>sum+(row['amount'] as num));
        return Column(children:[
          Card(child:ListTile(title:const Text('إجمالي المصروفات العامة القديمة (غير مربوطة بدفعة)'),subtitle:Text(money(expenseTotal),style:const TextStyle(color:gold,fontWeight:FontWeight.bold)))),
          const Padding(padding:EdgeInsets.only(bottom:6),child:Text('مصاريف الشحنات الجديدة تُسجل داخل الدفعة وتظهر في كشفها المستقل.',style:TextStyle(fontSize:12,color:Colors.orange))),
          FilledButton.tonalIcon(onPressed:addExpense,icon:const Icon(Icons.add),label:const Text('إضافة مصروف')),
          if(e.data!.isNotEmpty)const Align(alignment:Alignment.centerRight,child:Text('سجل المصروفات',style:TextStyle(fontWeight:FontWeight.bold))),
            ...e.data!.map((row) {
              return Card(
                child: ListTile(
                  title: Text(money(row['amount'] as num)),
                  subtitle: Text('${row['note']}\n${dateLabel(row['created'] as String)}'),
                  isThreeLine: true,
                  leading: const Icon(Icons.money_off, color: gold),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      if (action == 'edit') {
                        editExpense(row);
                      } else if (action == 'delete') {
                        deleteExpense(row);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('تعديل المصروف')),
                      PopupMenuItem(value: 'delete', child: Text('حذف المصروف')),
                    ],
                    child: const Icon(Icons.more_vert),
                  ),
                ),
              );
            }),
        ]);
      }),
      const Divider(),const Text('سجل المشتريات',style:TextStyle(fontWeight:FontWeight.bold)),
      if(rows.isEmpty)const Padding(padding:EdgeInsets.all(18),child:Text('لم تسجل مشتريات بعد',textAlign:TextAlign.center)),
      ...rows.map((r){final g=r['gross_kg'] as num,n=r['net_kg'] as num,pc=r['purchase_price'] as num,tc=r['total_cost'] as num;return Card(child:ListTile(title:Text('${dateLabel(r['created'] as String)}'),subtitle:Text('إجمالي: ${g.toStringAsFixed(2)} كجم • صافي: ${n.toStringAsFixed(2)} كجم • فاقد: ${(g-n).toStringAsFixed(2)} كجم\nشراء الكيلو: ${money(pc)} • الإجمالي: ${money(tc)}'),isThreeLine:true,trailing:PopupMenuButton<String>(onSelected:(action)async{if(action=='statement'){await showBatchStatement(r);}else if(action=='pdf'){await exportBatchPdf(r);}else if(action=='expense'){await addBatchExpenseDialog(r['id'] as int);}else if(action=='edit'){await editEntry(r);}else if(action=='delete'){try{await DB.instance.deletePrivateBatch(r['id'] as int);if(mounted)setState(reloadEntries);}catch(e){if(mounted)showMessage(context,e.toString().replaceFirst('Exception: ',''));}}},itemBuilder:(_)=>const [PopupMenuItem(value:'statement',child:Text('كشف الشحنة والربح')),PopupMenuItem(value:'pdf',child:Text('تصدير كشف الدفعة PDF')),PopupMenuItem(value:'expense',child:Text('إضافة مصروف للدفعة')),PopupMenuItem(value:'edit',child:Text('تعديل عملية الشراء')),PopupMenuItem(value:'delete',child:Text('حذف عملية الشراء'))],child:const Icon(Icons.more_vert))));})
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
