import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class FinancialBalancePage extends StatefulWidget {
  const FinancialBalancePage({super.key});

  @override
  State<FinancialBalancePage> createState() => _FinancialBalancePageState();
}

class _FinancialBalancePageState extends State<FinancialBalancePage> {
  DateTimeRange? _range;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    // Por defecto: últimos 6 meses aprox.
    _range = DateTimeRange(
      start: DateTime(now.year, now.month - 5, 1),
      end: DateTime(now.year, now.month, now.day, 23, 59, 59),
    );
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final current =
        _range ??
        DateTimeRange(
          start: DateTime(now.year, now.month, 1),
          end: DateTime(now.year, now.month, now.day, 23, 59, 59),
        );

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5),
      initialDateRange: current,
      helpText: 'Seleccionar período',
    );

    if (picked == null) return;

    setState(() {
      _range = DateTimeRange(
        start: DateTime(
          picked.start.year,
          picked.start.month,
          picked.start.day,
        ),
        end: DateTime(
          picked.end.year,
          picked.end.month,
          picked.end.day,
          23,
          59,
          59,
        ),
      );
    });
  }

  void _quickMonths(int monthsBack) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month - (monthsBack - 1), 1);
    final end = DateTime(now.year, now.month, now.day, 23, 59, 59);
    setState(() {
      _range = DateTimeRange(start: start, end: end);
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('No hay sesión iniciada.')),
      );
    }

    final range = _range!;
    final fmt = DateFormat('dd/MM/yyyy');
    final title =
        'Periodo: ${fmt.format(range.start)} - ${fmt.format(range.end)}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Balance financiero'),
        actions: [
          IconButton(
            tooltip: 'Elegir período',
            onPressed: _pickRange,
            icon: const Icon(Icons.calendar_month),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('appointments')
            .where(
              'startAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(range.start),
            )
            .where(
              'startAt',
              isLessThanOrEqualTo: Timestamp.fromDate(range.end),
            )
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }

          final docs = snap.data?.docs ?? [];

          // Solo: turnos CONCRETADOS y COBRADOS
          final paidAppts = docs
              .map((d) => _Appt.fromDoc(d))
              .where((a) => a.isPaidAndConcreted)
              .toList();

          paidAppts.sort((a, b) => b.start.compareTo(a.start));

          final buckets = <String, _MonthBucket>{};
          double paidTotal = 0;

          for (final a in paidAppts) {
            final key = _monthKey(a.start);
            final b = buckets.putIfAbsent(
              key,
              () => _MonthBucket(monthKey: key),
            );
            b.paidCount += 1;
            b.paidAmount += a.paidAmount;
            paidTotal += a.paidAmount;
          }

          final monthKeys = buckets.keys.toList()
            ..sort((a, b) => b.compareTo(a));

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(title, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => _quickMonths(1),
                    child: const Text('1 mes'),
                  ),
                  OutlinedButton(
                    onPressed: () => _quickMonths(3),
                    child: const Text('3 meses'),
                  ),
                  OutlinedButton(
                    onPressed: () => _quickMonths(6),
                    child: const Text('6 meses'),
                  ),
                  OutlinedButton(
                    onPressed: () => _quickMonths(12),
                    child: const Text('12 meses'),
                  ),
                  TextButton.icon(
                    onPressed: _pickRange,
                    icon: const Icon(Icons.tune),
                    label: const Text('Filtrar'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SummaryCard(paidCount: paidAppts.length, paidAmount: paidTotal),
              const SizedBox(height: 16),
              if (monthKeys.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: Text('No hay turnos cobrados en el período.'),
                  ),
                )
              else
                ...monthKeys.map((k) => _MonthCard(bucket: buckets[k]!)),
            ],
          );
        },
      ),
    );
  }

  static String _monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  static String _monthTitle(String monthKey) {
    final parts = monthKey.split('-');
    final y = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    final date = DateTime(y, m, 1);
    return DateFormat('MMMM yyyy', 'es').format(date);
  }
}

class _SummaryCard extends StatelessWidget {
  final int paidCount;
  final double paidAmount;

  const _SummaryCard({required this.paidCount, required this.paidAmount});

  @override
  Widget build(BuildContext context) {
    final money = NumberFormat.currency(
      locale: 'es_PY',
      symbol: '₲',
      decimalDigits: 0,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Resumen del período',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _row('Turnos cobrados', paidCount.toString()),
            _row('Cobrado (Concretado)', money.format(paidAmount)),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _MonthCard extends StatelessWidget {
  final _MonthBucket bucket;

  const _MonthCard({required this.bucket});

  @override
  Widget build(BuildContext context) {
    final money = NumberFormat.currency(
      locale: 'es_PY',
      symbol: '₲',
      decimalDigits: 0,
    );

    return Card(
      child: ListTile(
        title: Text(_FinancialBalancePageState._monthTitle(bucket.monthKey)),
        subtitle: Text('Turnos cobrados: ${bucket.paidCount}'),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              money.format(bucket.paidAmount),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            const Text('Cobrado', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _MonthBucket {
  final String monthKey;
  int paidCount = 0;
  double paidAmount = 0;

  _MonthBucket({required this.monthKey});
}

class _Appt {
  final DateTime start;
  final DateTime end;
  final String status;
  final double paidAmount;
  final DateTime? paidAt;

  _Appt({
    required this.start,
    required this.end,
    required this.status,
    required this.paidAmount,
    required this.paidAt,
  });

  bool get isPaidAndConcreted {
    final s = status.toLowerCase().trim();
    final isConcreted = (s == 'concretado' || s == 'completed' || s == 'done');
    final isPaid = (paidAt != null) || (paidAmount > 0);
    return isConcreted && isPaid;
  }

  static double _toDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    if (v is String) {
      final n = num.tryParse(v.replaceAll(',', '.'));
      return (n ?? 0).toDouble();
    }
    return 0;
  }

  factory _Appt.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();

    final startTs = d['startAt'] as Timestamp?;
    final dur = (d['durationMinutes'] as num?)?.toInt() ?? 60;

    final start = startTs?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
    final end = start.add(Duration(minutes: dur));

    final status = (d['status'] ?? '').toString();

    final paidAtTs = d['paidAt'] as Timestamp?;
    final paidAt = paidAtTs?.toDate();

    // Campo principal (según tu estructura): amountPaid
    // Fallbacks por compatibilidad: amount / price
    final paidAmount = _toDouble(d['amountPaid'] ?? d['amount'] ?? d['price']);

    return _Appt(
      start: start,
      end: end,
      status: status,
      paidAmount: paidAmount,
      paidAt: paidAt,
    );
  }
}
