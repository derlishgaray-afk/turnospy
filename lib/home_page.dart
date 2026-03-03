import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:web/web.dart' as web;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:url_launcher/url_launcher.dart';

import 'admin_users_page.dart';
import 'settings_page.dart';
import 'financial_balance_page.dart';
import 'user_guide_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

enum _Filter { all, libre, confirmado, concretado, cancelado }

enum _HomeMenuAction { guide, signOut }

class _TimeSeg {
  final DateTime start;
  final DateTime end;
  const _TimeSeg(this.start, this.end);
}

class _HomePageState extends State<HomePage> {
  DateTime _selectedDay = DateTime.now();

  // ===== Calendario: contorno rojo para días SIN turnos disponibles (solo visual) =====
  // Se calcula para los próximos 6 meses (incluyendo el mes actual).
  final Set<DateTime> _unavailableDays = <DateTime>{};
  bool _loadingUnavailableDays = false;
  DateTime? _unavailableCacheStart;
  DateTime? _unavailableCacheEnd;

  DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<void> _ensureUnavailableDaysLoaded({required String uid}) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final end = DateTime(
      now.year,
      now.month + 6,
      1,
    ).subtract(const Duration(days: 1));

    final needReload =
        _unavailableCacheStart == null ||
        _unavailableCacheEnd == null ||
        start.isBefore(_unavailableCacheStart!) ||
        end.isAfter(_unavailableCacheEnd!);

    if (!needReload) return;

    await _loadUnavailableDays(uid: uid, start: start, end: end);
  }

  Future<void> _loadUnavailableDays({
    required String uid,
    required DateTime start,
    required DateTime end,
  }) async {
    if (_loadingUnavailableDays) return;
    setState(() => _loadingUnavailableDays = true);

    try {
      // settings/{default} (tu estructura actual)
      final settingsSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('settings')
          .doc('default')
          .get();

      final settings = settingsSnap.data() ?? {};

      final workHoursRaw = settings['workHours'];
      final workHours = (workHoursRaw is Map)
          ? Map<String, dynamic>.from(workHoursRaw)
          : <String, dynamic>{};

      final slotMinutes =
          (settings['slotMinutesDefault'] as num?)?.toInt() ?? 60;
      final bufferMinutes = (settings['bufferMinutes'] as num?)?.toInt() ?? 0;
      final maxConcurrent =
          (settings['maxConcurrentAppointments'] as num?)?.toInt() ?? 1;

      final apptSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('appointments')
          .where('startAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .where(
            'startAt',
            isLessThanOrEqualTo: Timestamp.fromDate(
              DateTime(end.year, end.month, end.day, 23, 59, 59),
            ),
          )
          .get();

      final appts = apptSnap.docs.map((d) => _Appt.fromDoc(d)).toList();

      final Set<DateTime> unavailable = <DateTime>{};

      // Recorremos día por día y verificamos si existe al menos 1 slot libre
      DateTime day = _dayOnly(start);
      final endDay = _dayOnly(end);

      while (!day.isAfter(endDay)) {
        final dayKey = _dayKeyFromDate(day);

        final config = workHours[dayKey];
        if (config == null) {
          // Sin configuración para ese día => sin turnos disponibles.
          unavailable.add(day);
          day = day.add(const Duration(days: 1));
          continue;
        }

        // 'enabled' puede no existir en configuraciones antiguas; si no existe, asumimos true.
        final bool enabled = (config is Map && config.containsKey('enabled'))
            ? (config['enabled'] == true)
            : true;
        if (!enabled) {
          unavailable.add(day);
          day = day.add(const Duration(days: 1));
          continue;
        }

        final startStr = config['start'];
        final endStr = config['end'];
        if (startStr == null || endStr == null) {
          unavailable.add(day);
          day = day.add(const Duration(days: 1));
          continue;
        }

        final stepMinutes = slotMinutes + bufferMinutes;

        final segs = _segmentsForDay(
          day,
          startStr: startStr,
          endStr: endStr,
          breakStartStr: (config['breakStart'] ?? config['breakStartAt'])
              ?.toString(),
          breakEndStr: (config['breakEnd'] ?? config['breakEndAt'])?.toString(),
        );

        bool hasFree = false;

        for (final seg in segs) {
          DateTime cursor = seg.start;
          while (true) {
            final slotEnd = cursor.add(Duration(minutes: slotMinutes));
            if (slotEnd.isAfter(seg.end)) break;

            final used = appts
                .where((a) => a.status != 'canceled')
                .where((a) => _overlaps(cursor, slotEnd, a.start, a.end))
                .length;

            if (used < maxConcurrent) {
              hasFree = true;
              break;
            }

            final next = cursor.add(Duration(minutes: stepMinutes));
            if (!next.isBefore(seg.end)) break;
            cursor = next;
          }

          if (hasFree) break;
        }

        if (!hasFree) {
          unavailable.add(day);
        }

        day = day.add(const Duration(days: 1));
      }

      if (!mounted) return;

      setState(() {
        _unavailableDays
          ..clear()
          ..addAll(unavailable);
        _unavailableCacheStart = _dayOnly(start);
        _unavailableCacheEnd = _dayOnly(end);
      });
    } catch (_) {
      // Silencioso: es una mejora visual; no bloquea el uso.
    } finally {
      if (mounted) setState(() => _loadingUnavailableDays = false);
    }
  }

  _Filter _filter = _Filter.all;

  // Para resaltar el próximo slot libre (botón "Próximo")
  DateTime? _focusSlotStart;

  // ===== Helpers fecha/hora =====

  String _two(int n) => n.toString().padLeft(2, '0');
  String _fmtDate(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year}';
  String _fmtTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
  String _fmtDateTime(DateTime d) => '${_fmtDate(d)} ${_fmtTime(d)}';

  List<_TimeSeg> _segmentsForDay(
    DateTime day, {
    required String startStr,
    required String endStr,
    String? breakStartStr,
    String? breakEndStr,
  }) {
    final workStart = _atTime(day, startStr);
    final workEnd = _atTime(day, endStr);

    if (breakStartStr == null || breakEndStr == null) {
      return [_TimeSeg(workStart, workEnd)];
    }

    final bs = _atTime(day, breakStartStr);
    final be = _atTime(day, breakEndStr);

    // Si el descanso es inválido, ignorarlo (no bloquea la agenda).
    final isValid =
        bs.isAfter(workStart) && be.isBefore(workEnd) && bs.isBefore(be);

    if (!isValid) {
      return [_TimeSeg(workStart, workEnd)];
    }

    final segs = <_TimeSeg>[];
    if (bs.isAfter(workStart)) segs.add(_TimeSeg(workStart, bs));
    if (workEnd.isAfter(be)) segs.add(_TimeSeg(be, workEnd));
    return segs.isEmpty ? [_TimeSeg(workStart, workEnd)] : segs;
  }

  String _weekdayLabel(DateTime d) {
    const map = {
      1: 'Lunes',
      2: 'Martes',
      3: 'Miércoles',
      4: 'Jueves',
      5: 'Viernes',
      6: 'Sábado',
      7: 'Domingo',
    };
    return map[d.weekday] ?? '';
  }

  String _dayKeyFromDate(DateTime d) {
    switch (d.weekday) {
      case DateTime.monday:
        return 'mon';
      case DateTime.tuesday:
        return 'tue';
      case DateTime.wednesday:
        return 'wed';
      case DateTime.thursday:
        return 'thu';
      case DateTime.friday:
        return 'fri';
      case DateTime.saturday:
        return 'sat';
      case DateTime.sunday:
        return 'sun';
      default:
        return 'mon';
    }
  }

  DateTime _atTime(DateTime day, String hhmm) {
    final parts = hhmm.split(':');
    return DateTime(
      day.year,
      day.month,
      day.day,
      int.parse(parts[0]),
      int.parse(parts[1]),
    );
  }

  bool _overlaps(
    DateTime aStart,
    DateTime aEnd,
    DateTime bStart,
    DateTime bEnd,
  ) {
    return aStart.isBefore(bEnd) && bStart.isBefore(aEnd);
  }

  bool _isPastSlot(DateTime slotStart) => slotStart.isBefore(DateTime.now());

  void _goToday() => setState(() => _selectedDay = DateTime.now());
  void _prevDay() => setState(
    () => _selectedDay = _selectedDay.subtract(const Duration(days: 1)),
  );
  void _nextDay() =>
      setState(() => _selectedDay = _selectedDay.add(const Duration(days: 1)));

  Future<void> _pickDay() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Carga/actualiza cache (próximos 6 meses) para contornos rojos.
    await _ensureUnavailableDaysLoaded(uid: user.uid);
    if (!mounted) return;

    DateTime focusedDay = _dayOnly(_selectedDay);
    DateTime tempSelected = _dayOnly(_selectedDay);

    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Seleccionar fecha'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_loadingUnavailableDays)
                  const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: 8),
                TableCalendar(
                  locale: 'es_ES',
                  firstDay: DateTime(2000, 1, 1),
                  lastDay: DateTime(2100, 12, 31),
                  focusedDay: focusedDay,
                  availableGestures: AvailableGestures.horizontalSwipe,
                  headerStyle: const HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                  ),
                  selectedDayPredicate: (day) => isSameDay(day, tempSelected),
                  onDaySelected: (selectedDay, newFocusedDay) {
                    // Importante: sigue siendo seleccionable aunque tenga contorno rojo.
                    tempSelected = _dayOnly(selectedDay);
                    focusedDay = _dayOnly(newFocusedDay);
                    (context as Element).markNeedsBuild();
                  },
                  calendarBuilders: CalendarBuilders(
                    defaultBuilder: (context, day, _) =>
                        _calendarDayCell(day: day, isSelected: false),
                    todayBuilder: (context, day, _) =>
                        _calendarDayCell(day: day, isToday: true),
                    selectedBuilder: (context, day, _) =>
                        _calendarDayCell(day: day, isSelected: true),
                    outsideBuilder: (context, day, _) =>
                        _calendarDayCell(day: day, isOutside: true),
                    disabledBuilder: (context, day, _) =>
                        _calendarDayCell(day: day, isDisabled: true),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(tempSelected),
                  child: const Text('Aceptar'),
                ),
              ],
            ),
          ],
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedDay = _dayOnly(picked);
      });
    }
  }

  Widget _calendarDayCell({
    required DateTime day,
    bool isSelected = false,
    bool isToday = false,
    bool isOutside = false,
    bool isDisabled = false,
  }) {
    final d = _dayOnly(day);
    final bool isUnavailable = _unavailableDays.contains(d);

    // Nota: el día sigue siendo seleccionable; el contorno rojo es solo visual.
    final Decoration? decoration = isSelected
        ? BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            shape: BoxShape.circle,
            border: isUnavailable
                ? Border.all(color: Colors.red, width: 2)
                : null,
          )
        : isToday
        ? BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          )
        : isUnavailable
        ? BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.red, width: 2),
          )
        : null;

    final TextStyle baseStyle =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final Color textColor = isSelected
        ? Theme.of(context).colorScheme.onPrimary
        : isOutside
        ? Theme.of(context).disabledColor
        : baseStyle.color ?? Colors.black;

    return Center(
      child: Container(
        width: 36,
        height: 36,
        decoration: decoration,
        alignment: Alignment.center,
        child: Text('${day.day}', style: baseStyle.copyWith(color: textColor)),
      ),
    );
  }

  // ============================================================
  //               IR AL PRÓXIMO TURNO DISPONIBLE
  // ============================================================
  Future<void> _jumpToNextAvailableDay({required String uid}) async {
    // Helpers locales (para que no dependa de otras funciones)
    DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

    String dayKeyFromDate(DateTime d) {
      // DateTime.weekday: 1=lunes ... 7=domingo
      switch (d.weekday) {
        case DateTime.monday:
          return 'mon';
        case DateTime.tuesday:
          return 'tue';
        case DateTime.wednesday:
          return 'wed';
        case DateTime.thursday:
          return 'thu';
        case DateTime.friday:
          return 'fri';
        case DateTime.saturday:
          return 'sat';
        case DateTime.sunday:
          return 'sun';
        default:
          return 'mon';
      }
    }

    bool overlaps(
      DateTime aStart,
      DateTime aEnd,
      DateTime bStart,
      DateTime bEnd,
    ) {
      // solapamiento estricto
      return aStart.isBefore(bEnd) && aEnd.isAfter(bStart);
    }

    try {
      final now = DateTime.now();

      // Día base = el que está mostrando la pantalla ahora
      final baseDay = startOfDay(_selectedDay);
      final firstToCheck = baseDay.add(const Duration(days: 1));
      final rangeEnd = firstToCheck.add(const Duration(days: 31));

      // 1) Settings
      final settingsSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('settings')
          .doc('default')
          .get();

      final settings = settingsSnap.data() ?? <String, dynamic>{};

      final workHoursRaw = settings['workHours'];
      final workHours = (workHoursRaw is Map)
          ? Map<String, dynamic>.from(workHoursRaw)
          : <String, dynamic>{};

      final slotMinutes = (settings['slotMinutes'] as num?)?.toInt() ?? 60;
      final bufferMinutes = (settings['bufferMinutes'] as num?)?.toInt() ?? 0;
      final maxConcurrent = (settings['maxConcurrent'] as num?)?.toInt() ?? 1;

      final stepMinutes = slotMinutes + bufferMinutes;

      // 2) Appointments en rango (desde el día siguiente al actual)
      final apptSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('appointments')
          .where(
            'startAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(firstToCheck),
          )
          .where('startAt', isLessThanOrEqualTo: Timestamp.fromDate(rangeEnd))
          .get();

      // Normalizamos a lista con start/end
      final appts = apptSnap.docs
          .map((d) {
            final data = d.data();
            final ts = data['startAt'];
            final start = (ts is Timestamp) ? ts.toDate() : null;

            final dur =
                (data['durationMinutes'] as num?)?.toInt() ?? slotMinutes;
            final end = (start != null)
                ? start.add(Duration(minutes: dur))
                : null;

            final status = (data['status'] ?? '').toString();

            return {'start': start, 'end': end, 'status': status};
          })
          .where((a) => a['start'] != null && a['end'] != null)
          .toList();

      // 3) Buscar el próximo día que tenga AL MENOS 1 turno libre
      for (int i = 0; i < 31; i++) {
        final day = startOfDay(firstToCheck.add(Duration(days: i)));
        final dayKey = dayKeyFromDate(day);

        final cfgRaw = workHours[dayKey];

        // Si es null => cerrado (así lo guardas en settings_setup_page)
        if (cfgRaw == null) continue;

        final cfg = (cfgRaw is Map)
            ? Map<String, dynamic>.from(cfgRaw)
            : <String, dynamic>{};

        // Si algún día llegas a guardar enabled, lo respetamos. Si no existe, asumimos habilitado.
        final enabled = (cfg['enabled'] is bool)
            ? (cfg['enabled'] as bool)
            : true;
        if (!enabled) continue;

        final startStr = cfg['start']?.toString();
        final endStr = cfg['end']?.toString();
        if (startStr == null || endStr == null) continue;

        final segs = _segmentsForDay(
          day,
          startStr: startStr,
          endStr: endStr,
          breakStartStr: (cfg['breakStart'] ?? cfg['breakStartAt'])?.toString(),
          breakEndStr: (cfg['breakEnd'] ?? cfg['breakEndAt'])?.toString(),
        );

        for (final seg in segs) {
          DateTime cursor = seg.start;

          while (true) {
            final slotEnd = cursor.add(Duration(minutes: slotMinutes));
            if (slotEnd.isAfter(seg.end)) break;

            // Contar ocupados por solape (no cancelados)
            final used = appts
                .where((a) => a['status'] != 'canceled')
                .where(
                  (a) => overlaps(
                    cursor,
                    slotEnd,
                    a['start'] as DateTime,
                    a['end'] as DateTime,
                  ),
                )
                .length;

            // Evitar horarios pasados por seguridad.
            final slotIsFutureEnough = cursor.isAfter(now);

            if (used < maxConcurrent && slotIsFutureEnough) {
              if (!mounted) return;
              setState(() {
                _selectedDay = day;
              });
              return;
            }

            final next = cursor.add(Duration(minutes: stepMinutes));
            if (!next.isBefore(seg.end)) break;
            cursor = next;
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se encontró un día con turnos disponibles.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error buscando próximo día disponible: $e')),
      );
    }
  }

  // ===== Formato dinero =====
  NumberFormat _moneyFmt() => NumberFormat.decimalPattern('es');
  String _fmtMoney(num n) => _moneyFmt().format(n);

  int? _parseMoney(String input) {
    final cleaned = input.replaceAll(RegExp(r'[^\d]'), '');
    if (cleaned.isEmpty) return null;
    return int.tryParse(cleaned);
  }

  // ===== WhatsApp =====
  Future<void> _openWhatsApp({String? phone, required String message}) async {
    final text = Uri.encodeComponent(message);

    final uri = (phone != null && phone.trim().isNotEmpty)
        ? Uri.parse(
            'https://wa.me/${phone.trim().replaceAll(RegExp(r'[^\d]'), '')}?text=$text',
          )
        : Uri.parse('https://wa.me/?text=$text');

    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      final fallback = Uri.parse('whatsapp://send?text=$text');
      await launchUrl(fallback, mode: LaunchMode.externalApplication);
    }
  }

  Widget _buildFormDialog({
    required BuildContext context,
    required String title,
    required Widget body,
    required List<Widget> actions,
  }) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final viewInsets = media.viewInsets;
    final maxWidth = math.min(420.0, size.width - 40);
    final verticalInset = 24.0 * 2;
    final availableHeight = size.height - viewInsets.bottom - verticalInset;
    final dialogHeight = math.min(520.0, math.max(0.0, availableHeight));

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: dialogHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: body,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    actions[i],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===== CRUD Turnos =====
  Future<void> _createAppointment({
    required String uid,
    required DateTime startAt,
    required int defaultDurationMinutes,
    required String businessName,
  }) async {
    final nameCtrl = TextEditingController();
    final notesCtrl = TextEditingController();

    int duration = defaultDurationMinutes;

    final action = await showDialog<String?>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => _buildFormDialog(
          context: context,
          title: 'Crear turno',
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Inicio: ${_fmtDateTime(startAt)}'),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: duration,
                items: const [15, 30, 45, 60, 90, 120]
                    .map(
                      (m) => DropdownMenuItem(value: m, child: Text('$m min')),
                    )
                    .toList(),
                onChanged: (v) =>
                    setLocal(() => duration = v ?? defaultDurationMinutes),
                decoration: const InputDecoration(
                  labelText: 'Duración',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Cliente',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notas (opcional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('Guardar'),
            ),
            IconButton(
              tooltip: 'Compartir confirmacion',
              icon: const Icon(Icons.share),
              onPressed: () => Navigator.pop(context, 'save_whatsapp'),
            ),
          ],
        ),
      ),
    );

    if (action == null) return;

    final clientName = nameCtrl.text.trim();
    if (clientName.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Poné el nombre del cliente.')),
        );
      }
      return;
    }

    final appointmentsRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('appointments');
    final doc = appointmentsRef.doc();

    final saveFuture = doc.set({
      'startAt': Timestamp.fromDate(startAt),
      'durationMinutes': duration,
      'clientName': clientName,
      'notes': notesCtrl.text.trim(),
      'status': 'confirmed', // confirmed | completed | canceled
      'amountPaid': null,
      'currency': 'PYG',
      'paidAt': null,
      'canceledAt': null,
      'canceledByUid': null,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    if (action == 'save_whatsapp') {
      final msg = _buildWhatsappConfirmMessage(
        businessName: businessName,
        clientName: clientName,
        startAt: startAt,
        duration: duration,
        notes: notesCtrl.text.trim(),
      );
      // iOS web es estricto con popups fuera de gesto de usuario.
      if (kIsWeb) {
        await _openWhatsApp(message: msg);
        await saveFuture;
      } else {
        await saveFuture;
        await _openWhatsApp(message: msg);
      }
      await doc.update({'whatsappSentAt': FieldValue.serverTimestamp()});
    } else {
      await saveFuture;
    }
  }

  String _buildWhatsappConfirmMessage({
    required String businessName,
    required String clientName,
    required DateTime startAt,
    required int duration,
    required String notes,
  }) {
    final noteLine = notes.trim().isEmpty ? '' : '\n📝 Notas: ${notes.trim()}';
    return '✅ *$businessName* - Turno confirmado\n'
        '👤 Cliente: *$clientName*\n'
        '📅 Fecha: *${_weekdayLabel(startAt)} ${_fmtDate(startAt)}*\n'
        '🕒 Hora: *${_fmtTime(startAt)}* (Duración: $duration min)'
        '$noteLine\n'
        '\n¡Te esperamos!';
  }

  Future<void> _editAppointment({
    required String uid,
    required String businessName,
    required _Appt appt,
    required int maxConcurrent,
  }) async {
    final nameCtrl = TextEditingController(text: appt.clientName);
    final notesCtrl = TextEditingController(text: appt.notes);
    final amountCtrl = TextEditingController(
      text: (appt.amountPaid == null) ? '' : _fmtMoney(appt.amountPaid!),
    );

    int duration = appt.durationMinutes;
    String status = appt.status;
    DateTime startAt = appt.start;

    Future<bool> hasCapacityAt({
      required DateTime newStart,
      required int newDuration,
    }) async {
      final newEnd = newStart.add(Duration(minutes: newDuration));
      final dayStart = DateTime(newStart.year, newStart.month, newStart.day);
      final dayEnd = dayStart.add(const Duration(days: 1));

      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('appointments')
          .where(
            'startAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(dayStart),
          )
          .where('startAt', isLessThan: Timestamp.fromDate(dayEnd))
          .get();

      final used = snap.docs
          .where((d) => d.id != appt.id)
          .map((d) {
            final data = d.data();
            final ts = data['startAt'] as Timestamp?;
            final start = ts?.toDate();
            final dur = (data['durationMinutes'] as num?)?.toInt() ?? 60;
            final end = (start == null)
                ? null
                : start.add(Duration(minutes: dur));
            final st = (data['status'] ?? 'confirmed').toString();
            return (start: start, end: end, status: st);
          })
          .where((a) => a.start != null && a.end != null)
          .where((a) => a.status != 'canceled')
          .where((a) => _overlaps(newStart, newEnd, a.start!, a.end!))
          .length;

      return used < maxConcurrent;
    }

    Map<String, dynamic>? settingsCache;
    Future<Map<String, dynamic>?> loadSettings() async {
      if (settingsCache != null) return settingsCache;
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('settings')
          .doc('default')
          .get();
      final data = snap.data();
      if (data == null) return null;
      settingsCache = data;
      return settingsCache;
    }

    bool sameMinute(DateTime a, DateTime b) {
      return a.year == b.year &&
          a.month == b.month &&
          a.day == b.day &&
          a.hour == b.hour &&
          a.minute == b.minute;
    }

    Future<bool> isEnabledBySchedule({
      required DateTime newStart,
      required int newDuration,
    }) async {
      final settings = await loadSettings();
      if (settings == null) return false;

      final workHoursRaw = settings['workHours'];
      final workHours = (workHoursRaw is Map)
          ? Map<String, dynamic>.from(workHoursRaw)
          : <String, dynamic>{};

      final dayCfgRaw = workHours[_dayKeyFromDate(newStart)];
      if (dayCfgRaw == null) return false;

      final dayCfg = (dayCfgRaw is Map)
          ? Map<String, dynamic>.from(dayCfgRaw)
          : <String, dynamic>{};

      final enabled = (dayCfg['enabled'] is bool)
          ? (dayCfg['enabled'] as bool)
          : true;
      if (!enabled) return false;

      final startStr = dayCfg['start']?.toString() ?? '';
      final endStr = dayCfg['end']?.toString() ?? '';
      if (startStr.isEmpty || endStr.isEmpty) return false;

      final segs = _segmentsForDay(
        newStart,
        startStr: startStr,
        endStr: endStr,
        breakStartStr: (dayCfg['breakStart'] ?? dayCfg['breakStartAt'])
            ?.toString(),
        breakEndStr: (dayCfg['breakEnd'] ?? dayCfg['breakEndAt'])?.toString(),
      );

      final newEnd = newStart.add(Duration(minutes: newDuration));
      final insideSegment = segs.any(
        (seg) => !newStart.isBefore(seg.start) && !newEnd.isAfter(seg.end),
      );
      if (!insideSegment) return false;

      final slotMinutes =
          (settings['slotMinutesDefault'] as num?)?.toInt() ?? 60;
      final bufferMinutes = (settings['bufferMinutes'] as num?)?.toInt() ?? 0;
      final stepMinutes = slotMinutes + bufferMinutes;
      if (stepMinutes <= 0) return false;

      for (final seg in segs) {
        DateTime cursor = seg.start;
        while (true) {
          final cursorEnd = cursor.add(Duration(minutes: newDuration));
          if (cursorEnd.isAfter(seg.end)) break;
          if (sameMinute(cursor, newStart)) return true;

          final next = cursor.add(Duration(minutes: stepMinutes));
          if (!next.isBefore(seg.end)) break;
          cursor = next;
        }
      }

      return false;
    }

    Future<void> pickNewDateTime() async {
      final pickedDate = await showDatePicker(
        context: context,
        locale: const Locale('es', 'ES'),
        initialDate: startAt,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        cancelText: 'Cancelar',
        confirmText: 'Aceptar',
        helpText: 'Seleccionar fecha',
      );
      if (pickedDate == null) return;
      if (!mounted) return;

      final pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: startAt.hour, minute: startAt.minute),
        cancelText: 'Cancelar',
        confirmText: 'Aceptar',
        helpText: 'Seleccionar hora',
      );
      if (pickedTime == null) return;
      if (!mounted) return;

      final candidateStart = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );

      if (_isPastSlot(candidateStart)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se puede reagendar a un horario pasado.'),
          ),
        );
        return;
      }

      final enabledBySchedule = await isEnabledBySchedule(
        newStart: candidateStart,
        newDuration: duration,
      );
      if (!enabledBySchedule) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ese horario no esta habilitado.')),
        );
        return;
      }

      if (status != 'canceled') {
        final canSchedule = await hasCapacityAt(
          newStart: candidateStart,
          newDuration: duration,
        );
        if (!canSchedule) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ese horario no tiene cupo.')),
          );
          return;
        }
      }

      startAt = candidateStart;
    }

    final action = await showDialog<String?>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => _buildFormDialog(
          context: context,
          title: 'Editar turno',
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Inicio: ${_fmtDateTime(startAt)}')),
                  IconButton(
                    tooltip: 'Reagendar',
                    icon: const Icon(Icons.edit_calendar),
                    onPressed: () async {
                      await pickNewDateTime();
                      setLocal(() {});
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: duration,
                items: const [15, 30, 45, 60, 90, 120]
                    .map(
                      (m) => DropdownMenuItem(value: m, child: Text('$m min')),
                    )
                    .toList(),
                onChanged: (v) => setLocal(() => duration = v ?? duration),
                decoration: const InputDecoration(
                  labelText: 'Duración',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: status,
                items: const [
                  DropdownMenuItem(
                    value: 'confirmed',
                    child: Text('Confirmado'),
                  ),
                  DropdownMenuItem(
                    value: 'completed',
                    child: Text('Concretado'),
                  ),
                  DropdownMenuItem(value: 'canceled', child: Text('Cancelado')),
                ],
                onChanged: (v) => setLocal(() => status = v ?? status),
                decoration: const InputDecoration(
                  labelText: 'Estado',
                  border: OutlineInputBorder(),
                ),
              ),
              if (status == 'completed') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Monto cobrado (PYG)',
                    hintText: 'Ej: 150.000',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Cliente',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notas',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('Guardar'),
            ),
            IconButton(
              tooltip: 'Compartir confirmacion',
              icon: const Icon(Icons.share),
              onPressed: () => Navigator.pop(context, 'save_whatsapp'),
            ),
          ],
        ),
      ),
    );

    if (action == null) return;

    final bool sendWhatsapp = action == 'save_whatsapp';

    num? amountPaid;
    Timestamp? paidAt;

    if (status == 'completed') {
      final parsed = _parseMoney(amountCtrl.text.trim());
      if (parsed == null || parsed < 0) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Monto inválido.')));
        }
        return;
      }
      amountPaid = parsed;
      paidAt = Timestamp.now();
    } else {
      amountPaid = null;
      paidAt = null;
    }

    final isCancelingNow = (status == 'canceled' && appt.status != 'canceled');
    final cancelFields = isCancelingNow
        ? {
            'canceledAt': FieldValue.serverTimestamp(),
            'canceledByUid': FirebaseAuth.instance.currentUser?.uid,
          }
        : (status != 'canceled'
              ? {'canceledAt': null, 'canceledByUid': null}
              : <String, dynamic>{});

    final isRescheduling =
        startAt.millisecondsSinceEpoch != appt.start.millisecondsSinceEpoch;
    if (isRescheduling && _isPastSlot(startAt)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se puede reagendar a un horario pasado.'),
          ),
        );
      }
      return;
    }

    if (isRescheduling) {
      final enabledBySchedule = await isEnabledBySchedule(
        newStart: startAt,
        newDuration: duration,
      );
      if (!enabledBySchedule) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No se puede guardar: horario no habilitado.'),
            ),
          );
        }
        return;
      }
    }

    if (status != 'canceled') {
      final canSchedule = await hasCapacityAt(
        newStart: startAt,
        newDuration: duration,
      );
      if (!canSchedule) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No se puede guardar: horario sin cupo.'),
            ),
          );
        }
        return;
      }
    }

    final apptRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('appointments')
        .doc(appt.id);

    final saveFuture = apptRef.update({
      'startAt': Timestamp.fromDate(startAt),
      'durationMinutes': duration,
      'clientName': nameCtrl.text.trim(),
      'notes': notesCtrl.text.trim(),
      'status': status,
      'amountPaid': amountPaid,
      'currency': 'PYG',
      'paidAt': paidAt,
      'updatedAt': FieldValue.serverTimestamp(),
      ...cancelFields,
    });

    if (sendWhatsapp) {
      final msg = _buildWhatsappConfirmMessage(
        businessName: businessName,
        clientName: nameCtrl.text.trim().isEmpty
            ? appt.clientName
            : nameCtrl.text.trim(),
        startAt: startAt,
        duration: duration,
        notes: notesCtrl.text.trim(),
      );
      // iOS web es estricto con popups fuera de gesto de usuario.
      if (kIsWeb) {
        await _openWhatsApp(message: msg);
        await saveFuture;
      } else {
        await saveFuture;
        await _openWhatsApp(message: msg);
      }

      await apptRef.update({'whatsappSentAt': FieldValue.serverTimestamp()});
    } else {
      await saveFuture;
    }
  }

  // ===== Slot detail =====
  Future<void> _openSlotDetail({
    required String uid,
    required String businessName,
    required DateTime slotStart,
    required int slotMinutes,
    required int maxConcurrent,
    required List<_Appt> overlapsAll,
  }) async {
    final slotEnd = slotStart.add(Duration(minutes: slotMinutes));

    final overlapsActive = overlapsAll
        .where((a) => a.status != 'canceled')
        .toList();
    final canAdd =
        overlapsActive.length < maxConcurrent && !_isPastSlot(slotStart);

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Slot ${_fmtTime(slotStart)} - ${_fmtTime(slotEnd)}'),
        content: SizedBox(
          width: 520,
          child: overlapsAll.isEmpty
              ? const Text('No hay turnos en este horario.')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: overlapsAll.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final a = overlapsAll[i];
                    final statusTxt = a.status == 'canceled'
                        ? 'CANCELADO'
                        : (a.status == 'completed'
                              ? 'CONCRETADO'
                              : 'CONFIRMADO');

                    final money =
                        (a.status == 'completed' && a.amountPaid != null)
                        ? ' • Cobrado: ${_fmtMoney(a.amountPaid!)} ${a.currency}'
                        : '';

                    return ListTile(
                      title: Text(a.clientName),
                      subtitle: Text(
                        '${_fmtTime(a.start)} • ${a.durationMinutes}m • $statusTxt$money'
                        '${a.notes.isNotEmpty ? ' • ${a.notes}' : ''}',
                      ),
                      trailing: const Icon(Icons.edit),
                      onTap: () async {
                        Navigator.pop(context);
                        await _editAppointment(
                          uid: uid,
                          businessName: businessName,
                          appt: a,
                          maxConcurrent: maxConcurrent,
                        );
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
          FilledButton(
            onPressed: canAdd
                ? () async {
                    Navigator.pop(context);
                    await _createAppointment(
                      uid: uid,
                      startAt: slotStart,
                      defaultDurationMinutes: slotMinutes,
                      businessName: businessName,
                    );
                  }
                : null,
            child: Text(canAdd ? 'Agregar turno' : 'Sin cupo'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  //            DISPONIBLES (texto WhatsApp)
  // ============================================================
  String _buildAvailableTextForDay({
    required String businessName,
    required DateTime day,
    required String startStr,
    required String endStr,
    required List<DateTime> slots,
    required List<_Appt> appts,
    required int slotMinutes,
    required int maxConcurrent,
  }) {
    final lines = <String>[];

    final title = businessName.trim().isEmpty
        ? 'Turnos disponibles'
        : '$businessName - Turnos disponibles';

    lines.add('📌 *$title*');
    lines.add('📅 ${_weekdayLabel(day)} ${_fmtDate(day)}');
    lines.add('🕒 Horario: $startStr - $endStr');
    lines.add('');

    int count = 0;

    final today = _dayOnly(DateTime.now());
    final dayOnly = _dayOnly(day);

    for (final slotStart in slots) {
      if (dayOnly == today && _isPastSlot(slotStart)) continue;

      final slotEnd = slotStart.add(Duration(minutes: slotMinutes));
      final used = appts
          .where((a) => a.status != 'canceled')
          .where((a) => _overlaps(slotStart, slotEnd, a.start, a.end))
          .length;

      final remaining = maxConcurrent - used;
      if (remaining <= 0) continue;

      count++;
      final cupoTxt = remaining == 1 ? '1 cupo' : '$remaining cupos';
      lines.add('• ${_fmtTime(slotStart)} ($cupoTxt)');
    }

    if (count == 0) {
      lines.add('No hay horarios disponibles para esta fecha.');
    }

    lines.add('');
    lines.add('📲 Para reservar, respondé este mensaje.');

    return lines.join('\n');
  }

  // ============================================================
  //                    FLYER (PNG)
  // ============================================================
  Future<Uint8List> _captureWidgetToPngBytes(GlobalKey key) async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  Future<void> _downloadPngOnWeb(Uint8List bytes, String filename) async {
    final parts = JSArray<web.BlobPart>();
    parts.add(bytes.toJS);
    final blob = web.Blob(parts, web.BlobPropertyBag(type: 'image/png'));
    final url = web.URL.createObjectURL(blob);

    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..style.display = 'none'
      ..rel = 'noopener';

    web.window.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(url);
  }

  List<_AvailSlotLine> _computeAvailableLinesForDay({
    required DateTime day,
    required List<DateTime> slots,
    required List<_Appt> appts,
    required int slotMinutes,
    required int maxConcurrent,
  }) {
    final out = <_AvailSlotLine>[];
    final today = _dayOnly(DateTime.now());
    final dayOnly = _dayOnly(day);

    for (final slotStart in slots) {
      if (dayOnly == today && _isPastSlot(slotStart)) continue;

      final slotEnd = slotStart.add(Duration(minutes: slotMinutes));
      final used = appts
          .where((a) => a.status != 'canceled')
          .where((a) => _overlaps(slotStart, slotEnd, a.start, a.end))
          .length;
      final remaining = maxConcurrent - used;
      if (remaining <= 0) continue;

      out.add(_AvailSlotLine(time: _fmtTime(slotStart), cupos: remaining));
    }

    return out;
  }

  // Compact flyer:
  // - Header minimal (nombre + "Disponibles")
  // - Cada día: título + horas + chips pequeños en wrap

  // ============================================================
  //                    FLYER (PNG) - 9:16 vertical
  // ============================================================
  static const double _flyerW = 1080;

  _FlyerPalette _defaultFlyerPalette({required bool isDark}) {
    if (isDark) {
      return const _FlyerPalette(
        bgStart: Color(0xFF121216),
        bgEnd: Color(0xFF121216),
        useGradient: false,
        card: Color(0xFF1B1C24),
        titleText: Color(0xFFF2F3F7),
        bodyText: Color(0xFFD7D9E0),
        nameColor: Color(0xFF90CAF9),
        sloganColor: Color(0xFFB0B4BE),
        dayTitleColor: Color(0xFFFF8A80),
        timesColor: Color(0xFFE6E8EF),
        badgeBg: Color(0xFF1E3327),
        badgeText: Color(0xFF9FE3B4),
        iconBg: Color(0xFF2B2A3A),
        iconColor: Color(0xFFB39DDB),
      );
    }

    return const _FlyerPalette(
      bgStart: Color(0xFFF4F1F7),
      bgEnd: Color(0xFFF4F1F7),
      useGradient: false,
      card: Color(0xFFFFFFFF),
      titleText: Color(0xFF111111),
      bodyText: Color(0xFF333333),
      nameColor: Color(0xFF1565C0),
      sloganColor: Color(0xFF5A5A5A),
      dayTitleColor: Color(0xFF8B0000),
      timesColor: Color(0xFF1E1E1E),
      badgeBg: Color(0x1F16A34A),
      badgeText: Color(0xFF145A32),
      iconBg: Color(0x24673AB7),
      iconColor: Color(0xFF673AB7),
    );
  }

  _FlyerPalette _paletteFromSettings({
    required Map<String, dynamic>? settings,
    required _FlyerPalette fallback,
  }) {
    if (settings == null) return fallback;
    final raw = settings['flyerPalette'];
    if (raw is Map) {
      return _FlyerPalette.fromMap(
        Map<String, dynamic>.from(raw),
        fallback: fallback,
      );
    }
    return fallback;
  }

  int? _matchPresetIndex(
    _FlyerPalette palette,
    List<_FlyerPalettePreset> presets,
  ) {
    for (var i = 0; i < presets.length; i++) {
      if (palette.sameAs(presets[i].palette)) return i;
    }
    return null;
  }

  List<_FlyerPalettePreset> _flyerPresets() {
    return [
      _FlyerPalettePreset(
        name: 'Clásico',
        palette: _defaultFlyerPalette(isDark: false),
      ),
      _FlyerPalettePreset(
        name: 'Nocturno',
        palette: _defaultFlyerPalette(isDark: true),
      ),
      const _FlyerPalettePreset(
        name: 'Azul',
        palette: _FlyerPalette(
          bgStart: Color(0xFF0F172A),
          bgEnd: Color(0xFF1E3A8A),
          useGradient: true,
          card: Color(0xFF0B1220),
          titleText: Color(0xFFE2E8F0),
          bodyText: Color(0xFFCBD5E1),
          nameColor: Color(0xFF60A5FA),
          sloganColor: Color(0xFF93C5FD),
          dayTitleColor: Color(0xFF38BDF8),
          timesColor: Color(0xFFF8FAFC),
          badgeBg: Color(0xFF38BDF8),
          badgeText: Color(0xFF0B1220),
          iconBg: Color(0xFF1E293B),
          iconColor: Color(0xFF93C5FD),
        ),
      ),
      const _FlyerPalettePreset(
        name: 'Menta',
        palette: _FlyerPalette(
          bgStart: Color(0xFFECFDF3),
          bgEnd: Color(0xFFE0F2FE),
          useGradient: true,
          card: Color(0xFFFFFFFF),
          titleText: Color(0xFF0F172A),
          bodyText: Color(0xFF334155),
          nameColor: Color(0xFF0F766E),
          sloganColor: Color(0xFF0F766E),
          dayTitleColor: Color(0xFF047857),
          timesColor: Color(0xFF111827),
          badgeBg: Color(0xFFD1FAE5),
          badgeText: Color(0xFF065F46),
          iconBg: Color(0xFFCCFBF1),
          iconColor: Color(0xFF0F766E),
        ),
      ),
      const _FlyerPalettePreset(
        name: 'Cálido',
        palette: _FlyerPalette(
          bgStart: Color(0xFFFFF7ED),
          bgEnd: Color(0xFFFFEDD5),
          useGradient: true,
          card: Color(0xFFFFFFFF),
          titleText: Color(0xFF7C2D12),
          bodyText: Color(0xFF7C2D12),
          nameColor: Color(0xFFB45309),
          sloganColor: Color(0xFFB45309),
          dayTitleColor: Color(0xFF9A3412),
          timesColor: Color(0xFF7C2D12),
          badgeBg: Color(0xFFFDE68A),
          badgeText: Color(0xFF92400E),
          iconBg: Color(0xFFFED7AA),
          iconColor: Color(0xFFB45309),
        ),
      ),
    ];
  }

  // Diseñado para capturar en PNG vertical (9:16) y que se vea bien al compartir.
  // - Resalta el nombre del negocio.
  // - "Turnos disponibles" más chico.
  // - Cada día en una tarjeta compacta con horas en una o dos líneas.
  Widget _flyerWidgetCompact({
    required String businessName,
    required String subtitle,
    required String serviceDescription,
    required String slogan,
    required List<_FlyerDayBlock> days,
    required bool isDark,
    _FlyerPalette? palette,
  }) {
    final name = businessName.trim().isEmpty
        ? 'Mi negocio'
        : businessName.trim();
    final desc = serviceDescription.trim();
    final sg = slogan.trim();

    final theme = palette ?? _defaultFlyerPalette(isDark: isDark);
    final bgStart = theme.bgStart;
    final bgEnd = theme.bgEnd;
    final useGradient = theme.useGradient;
    final card = theme.card;
    final titleText = theme.titleText;
    final bodyText = theme.bodyText;
    final nameColor = theme.nameColor;
    final sloganColor = theme.sloganColor;
    final dayTitleColor = theme.dayTitleColor;
    final timesColor = theme.timesColor;
    final badgeBg = theme.badgeBg;
    final badgeText = theme.badgeText;
    final iconBg = theme.iconBg;
    final iconColor = theme.iconColor;
    final isDarkBg = bgStart.computeLuminance() < 0.4;
    final cardBorder = titleText.withValues(alpha: isDarkBg ? 0.10 : 0.08);
    final badgeBorder = badgeText.withValues(alpha: 0.35);
    final cardShadow = Colors.black.withValues(alpha: isDarkBg ? 0.35 : 0.08);

    String timesLine(List<_AvailSlotLine> lines) {
      // Solo mostramos la hora (sin “(1)” ni “Hs”)
      return lines.map((e) => e.time).join(' - ');
    }

    final daysCount = math.min(days.length, 7);
    const cardGap = 16.0;

    // Altura de tarjeta según cantidad de días (como antes).
    final cardH = (days.length <= 4)
        ? 210.0
        : (days.length <= 6)
        ? 185.0
        : 165.0;

    // Altura del PNG: cortar espacio vacío cuando hay pocos días.
    final daysHeight = daysCount > 0
        ? (daysCount * cardH) + ((daysCount - 1) * cardGap)
        : 0.0;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: useGradient ? null : bgStart,
          gradient: useGradient
              ? LinearGradient(
                  colors: [bgStart, bgEnd],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
        ),
        child: SizedBox(
          width: _flyerW,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(56, 54, 56, 44),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header compacto: icono + nombre + badge
                Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: iconBg,
                      ),
                      child: Icon(
                        Icons.event_available,
                        size: 30,
                        color: iconColor,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 44,
                              fontWeight: FontWeight.w900,
                              height: 1.05,
                              color: nameColor,
                            ),
                          ),
                          if (sg.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              sg,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 22,
                                fontStyle: FontStyle.italic,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                                color: sloganColor,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: badgeBg,
                        border: Border.all(color: badgeBorder),
                      ),
                      child: Text(
                        'DISPONIBLES',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                          color: badgeText,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 22),

                // Título (más discreto)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 18,
                        offset: const Offset(0, 10),
                        color: cardShadow,
                      ),
                    ],
                  ),
                  child: Text(
                    'Turnos disponibles',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                      color: titleText,
                    ),
                  ),
                ),

                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    desc,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                      color: bodyText,
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                // Bloques de días (sin scroll; recorta altura al contenido)
                SizedBox(
                  height: daysHeight,
                  child: days.isEmpty
                      ? Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: isDarkBg
                                ? const Color(0xFF3A2C1B)
                                : Colors.orange.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: isDarkBg
                                  ? const Color(0xFF8D5A2B)
                                  : Colors.orange.withValues(alpha: 0.22),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              'No hay horarios disponibles en este rango.',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: isDarkBg
                                    ? const Color(0xFFF7D7A7)
                                    : const Color(0xFF5A3A15),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : Column(
                          children: [
                            for (int i = 0; i < daysCount; i++) ...[
                              Container(
                                width: double.infinity,
                                height: cardH,
                                padding: const EdgeInsets.fromLTRB(
                                  22,
                                  18,
                                  22,
                                  18,
                                ),
                                decoration: BoxDecoration(
                                  color: card,
                                  borderRadius: BorderRadius.circular(22),
                                  boxShadow: [
                                    BoxShadow(
                                      blurRadius: 14,
                                      offset: const Offset(0, 8),
                                      color: cardShadow,
                                    ),
                                  ],
                                  border: Border.all(color: cardBorder),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      days[i].title
                                          .replaceAll('📅 ', '')
                                          .toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w900,
                                        color: dayTitleColor,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          timesLine(days[i].lines).isEmpty
                                              ? 'Sin cupos'
                                              : timesLine(days[i].lines),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 28,
                                            fontWeight: FontWeight.w800,
                                            height: 1.10,
                                            color: timesColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (i < daysCount - 1)
                                const SizedBox(height: cardGap),
                            ],
                          ],
                        ),
                ),

                const SizedBox(height: 8),
                Text(
                  '📲 Para reservar: escribinos por WhatsApp / mensaje directo.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: isDarkBg
                        ? Colors.white.withValues(alpha: 0.6)
                        : Colors.black.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openFlyerPreviewAndExportPng({
    required String businessName,
    required String subtitle,
    required String serviceDescription,
    required String slogan,
    required List<_FlyerDayBlock> days,
    required String filename,
    required DocumentReference settingsRef,
    Map<String, dynamic>? settings,
  }) async {
    final key = GlobalKey();
    final isDarkTheme = Theme.of(context).brightness == Brightness.dark;
    final presets = _flyerPresets();
    final initialPresetIndex = isDarkTheme ? 1 : 0;
    final fallbackPalette = presets[initialPresetIndex].palette;
    _FlyerPalette palette = _paletteFromSettings(
      settings: settings,
      fallback: fallbackPalette,
    );
    int? presetIndex = _matchPresetIndex(palette, presets);

    final backgroundOptions = <Color>[
      const Color(0xFF121216),
      const Color(0xFF0F172A),
      const Color(0xFF1E293B),
      const Color(0xFFF4F1F7),
      const Color(0xFFF8FAFC),
      const Color(0xFFFFFFFF),
      const Color(0xFFE2E8F0),
      const Color(0xFFE0F2FE),
      const Color(0xFFECFDF3),
      const Color(0xFFFFF7ED),
      const Color(0xFFFFEDD5),
      const Color(0xFF111827),
    ];

    final accentOptions = <Color>[
      const Color(0xFF1565C0),
      const Color(0xFF0EA5E9),
      const Color(0xFF38BDF8),
      const Color(0xFF22C55E),
      const Color(0xFF16A34A),
      const Color(0xFF0F766E),
      const Color(0xFFB45309),
      const Color(0xFF9A3412),
      const Color(0xFF8B5CF6),
      const Color(0xFFEC4899),
      const Color(0xFFEF4444),
      const Color(0xFF111827),
    ];

    final textOptions = <Color>[
      const Color(0xFF111111),
      const Color(0xFF1E1E1E),
      const Color(0xFF333333),
      const Color(0xFF5A5A5A),
      const Color(0xFFD7D9E0),
      const Color(0xFFF2F3F7),
      const Color(0xFFFFFFFF),
      const Color(0xFFCBD5E1),
    ];

    bool exporting = false;
    String? exportError;

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) {
          void updatePalette(_FlyerPalette Function(_FlyerPalette) updater) {
            setLocal(() {
              palette = updater(palette);
              presetIndex = null;
            });
          }

          Future<void> handleExport() async {
            if (exporting) return;
            setLocal(() {
              exporting = true;
              exportError = null;
            });

            try {
              final bytes = await _captureWidgetToPngBytes(key);

              if (kIsWeb) {
                await _downloadPngOnWeb(bytes, filename);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('PNG descargado. Ahora podés compartirlo.'),
                  ),
                );
              } else {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'PNG generado. En móvil la descarga está disponible en la versión web.',
                    ),
                  ),
                );
              }

              try {
                await settingsRef.update({
                  'flyerPalette': palette.toMap(),
                  'flyerPaletteUpdatedAt': FieldValue.serverTimestamp(),
                });
              } catch (_) {
                // Si falla, no bloqueamos la exportación.
              }

              if (!context.mounted) return;
              if (Navigator.of(context).canPop()) {
                Navigator.pop(context);
              }
            } catch (_) {
              setLocal(() {
                exporting = false;
                exportError = 'No se pudo generar el PNG. Probá nuevamente.';
              });
            }
          }

          Widget colorRow({
            required String label,
            required Color value,
            required List<Color> options,
            required ValueChanged<Color> onChanged,
          }) {
            final theme = Theme.of(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in options)
                      InkWell(
                        onTap: () => onChanged(c),
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: value == c
                                  ? theme.colorScheme.primary
                                  : Colors.black.withValues(alpha: 0.18),
                              width: value == c ? 2 : 1,
                            ),
                          ),
                          child: value == c
                              ? Icon(
                                  Icons.check,
                                  size: 14,
                                  color: c.computeLuminance() > 0.5
                                      ? Colors.black
                                      : Colors.white,
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
              ],
            );
          }

          return AlertDialog(
            title: const Text('Vista previa del flyer'),
            content: SizedBox(
              width: 900,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.vertical,
                        child: RepaintBoundary(
                          key: key,
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: _flyerWidgetCompact(
                              businessName: businessName,
                              subtitle: subtitle,
                              serviceDescription: serviceDescription,
                              slogan: slogan,
                              days: days,
                              isDark: isDarkTheme,
                              palette: palette,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Personalizar',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (int i = 0; i < presets.length; i++)
                          ChoiceChip(
                            label: Text(presets[i].name),
                            selected: presetIndex == i,
                            onSelected: exporting
                                ? null
                                : (_) => setLocal(() {
                                    palette = presets[i].palette;
                                    presetIndex = i;
                                  }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Fondo con degradado'),
                      value: palette.useGradient,
                      onChanged: exporting
                          ? null
                          : (v) => updatePalette(
                              (p) => p.copyWith(useGradient: v),
                            ),
                    ),
                    colorRow(
                      label: 'Fondo inicio',
                      value: palette.bgStart,
                      options: backgroundOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) => updatePalette((p) => p.copyWith(bgStart: c)),
                    ),
                    if (palette.useGradient) ...[
                      const SizedBox(height: 12),
                      colorRow(
                        label: 'Fondo fin',
                        value: palette.bgEnd,
                        options: backgroundOptions,
                        onChanged: exporting
                            ? (_) {}
                            : (c) => updatePalette((p) => p.copyWith(bgEnd: c)),
                      ),
                    ],
                    const Divider(height: 28),
                    colorRow(
                      label: 'Tarjeta',
                      value: palette.card,
                      options: backgroundOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) => updatePalette((p) => p.copyWith(card: c)),
                    ),
                    const SizedBox(height: 12),
                    colorRow(
                      label: 'Nombre',
                      value: palette.nameColor,
                      options: accentOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) =>
                                updatePalette((p) => p.copyWith(nameColor: c)),
                    ),
                    const SizedBox(height: 12),
                    colorRow(
                      label: 'Título',
                      value: palette.titleText,
                      options: textOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) =>
                                updatePalette((p) => p.copyWith(titleText: c)),
                    ),
                    const SizedBox(height: 12),
                    colorRow(
                      label: 'Texto',
                      value: palette.bodyText,
                      options: textOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) =>
                                updatePalette((p) => p.copyWith(bodyText: c)),
                    ),
                    const SizedBox(height: 12),
                    colorRow(
                      label: 'Día',
                      value: palette.dayTitleColor,
                      options: accentOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) => updatePalette(
                              (p) => p.copyWith(dayTitleColor: c),
                            ),
                    ),
                    const SizedBox(height: 12),
                    colorRow(
                      label: 'Horas',
                      value: palette.timesColor,
                      options: textOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) =>
                                updatePalette((p) => p.copyWith(timesColor: c)),
                    ),
                    const Divider(height: 28),
                    colorRow(
                      label: 'Badge',
                      value: palette.badgeBg,
                      options: accentOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) => updatePalette((p) => p.copyWith(badgeBg: c)),
                    ),
                    const SizedBox(height: 12),
                    colorRow(
                      label: 'Badge texto',
                      value: palette.badgeText,
                      options: textOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) =>
                                updatePalette((p) => p.copyWith(badgeText: c)),
                    ),
                    const SizedBox(height: 12),
                    colorRow(
                      label: 'Icono fondo',
                      value: palette.iconBg,
                      options: backgroundOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) => updatePalette((p) => p.copyWith(iconBg: c)),
                    ),
                    const SizedBox(height: 12),
                    colorRow(
                      label: 'Icono color',
                      value: palette.iconColor,
                      options: accentOptions,
                      onChanged: exporting
                          ? (_) {}
                          : (c) =>
                                updatePalette((p) => p.copyWith(iconColor: c)),
                    ),
                    if (exportError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        exportError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: exporting ? null : () => Navigator.pop(context),
                child: const Text('Cerrar'),
              ),
              FilledButton(
                onPressed: exporting ? null : handleExport,
                child: exporting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(kIsWeb ? 'Descargar PNG' : 'Compartir'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _exportFlyerDayPng({
    required String businessName,
    required String serviceDescription,
    required String slogan,
    required DateTime day,
    required String startStr,
    required String endStr,
    required List<DateTime> slots,
    required List<_Appt> appts,
    required int slotMinutes,
    required int maxConcurrent,
    required DocumentReference settingsRef,
    required Map<String, dynamic> settings,
  }) async {
    final today = _dayOnly(DateTime.now());
    final sel = _dayOnly(day);
    if (sel.isBefore(today)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('El PNG solo se genera para fechas futuras (o hoy).'),
          ),
        );
      }
      return;
    }

    final lines = _computeAvailableLinesForDay(
      day: day,
      slots: slots,
      appts: appts,
      slotMinutes: slotMinutes,
      maxConcurrent: maxConcurrent,
    );

    final blocks = <_FlyerDayBlock>[
      _FlyerDayBlock(
        title: '📅 ${_weekdayLabel(day)} ${_fmtDate(day)}',
        hoursLine: '🕒 $startStr - $endStr',
        lines: lines,
      ),
    ];

    await _openFlyerPreviewAndExportPng(
      businessName: businessName,
      subtitle: 'Horarios disponibles (día)',
      serviceDescription: serviceDescription,
      slogan: slogan,
      days: blocks,
      filename: 'turnos_${day.year}${_two(day.month)}${_two(day.day)}.png',
      settingsRef: settingsRef,
      settings: settings,
    );
  }

  Future<void> _exportFlyerWeekPng({
    required String uid,
    required String businessName,
    required String serviceDescription,
    required String slogan,
    required Map<String, dynamic> settings,
    required DateTime anchorDay,
    required DocumentReference settingsRef,
  }) async {
    final today = _dayOnly(DateTime.now());
    final anchor = _dayOnly(anchorDay);
    final startDay = anchor.isBefore(today) ? today : anchor;
    final endDayExclusive = startDay.add(const Duration(days: 7));

    final slotMinutes = (settings['slotMinutesDefault'] ?? 30) as int;
    final bufferMinutes = (settings['bufferMinutes'] ?? 0) as int;
    final maxConcurrent = (settings['maxConcurrentAppointments'] ?? 1) as int;
    final workHours = (settings['workHours'] ?? {}) as Map<String, dynamic>;

    final query = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('appointments')
        .where('startAt', isGreaterThanOrEqualTo: Timestamp.fromDate(startDay))
        .where('startAt', isLessThan: Timestamp.fromDate(endDayExclusive))
        .get();

    final apptsRange = query.docs.map((d) {
      final data = d.data();
      final startAt = (data['startAt'] as Timestamp).toDate();
      final duration = (data['durationMinutes'] ?? slotMinutes) as int;
      final endAt = startAt.add(Duration(minutes: duration));
      return _Appt(
        id: d.id,
        start: startAt,
        end: endAt,
        durationMinutes: duration,
        clientName: (data['clientName'] ?? '').toString(),
        clientPhone: (data['clientPhone'] ?? '').toString(),
        notes: (data['notes'] ?? '').toString(),
        status: (data['status'] ?? 'confirmed').toString(),
        amountPaid: data['amountPaid'] as num?,
        currency: (data['currency'] ?? 'PYG').toString(),
      );
    }).toList();

    final blocks = <_FlyerDayBlock>[];

    for (int i = 0; i < 7; i++) {
      final day = startDay.add(Duration(days: i));
      final dayKey = _dayKeyFromDate(day);
      final dayWork = workHours[dayKey];
      if (dayWork == null) continue;

      final startStr = (dayWork['start'] ?? '').toString();
      final endStr = (dayWork['end'] ?? '').toString();
      if (startStr.isEmpty || endStr.isEmpty) continue;

      final stepMinutes = slotMinutes + bufferMinutes;
      final List<DateTime> slots = [];
      final segs = _segmentsForDay(
        day,
        startStr: startStr,
        endStr: endStr,
        breakStartStr: (dayWork['breakStart'] ?? dayWork['breakStartAt'])
            ?.toString(),
        breakEndStr: (dayWork['breakEnd'] ?? dayWork['breakEndAt'])?.toString(),
      );

      for (final seg in segs) {
        DateTime cursor = seg.start;
        while (true) {
          final slotEnd = cursor.add(Duration(minutes: slotMinutes));
          if (slotEnd.isAfter(seg.end)) break;
          slots.add(cursor);
          final next = cursor.add(Duration(minutes: stepMinutes));
          if (!next.isBefore(seg.end)) break;
          cursor = next;
        }
      }

      final apptsDay = apptsRange
          .where((a) => _dayOnly(a.start) == _dayOnly(day))
          .toList();

      final lines = _computeAvailableLinesForDay(
        day: day,
        slots: slots,
        appts: apptsDay,
        slotMinutes: slotMinutes,
        maxConcurrent: maxConcurrent,
      );

      if (lines.isEmpty) continue;

      blocks.add(
        _FlyerDayBlock(
          title: '📅 ${_weekdayLabel(day)} ${_fmtDate(day)}',
          hoursLine: '🕒 $startStr - $endStr',
          lines: lines,
        ),
      );
    }

    await _openFlyerPreviewAndExportPng(
      businessName: businessName,
      subtitle: 'Horarios disponibles (próximos 7 días)',
      serviceDescription: serviceDescription,
      slogan: slogan,
      days: blocks,
      filename:
          'turnos_semana_${startDay.year}${_two(startDay.month)}${_two(startDay.day)}.png',
      settingsRef: settingsRef,
      settings: settings,
    );
  }

  // ============================================================
  //            Totales / resumen pill
  // ============================================================
  _Totals _computeTotals(List<_Appt> appts) {
    int confirmed = 0;
    int completed = 0;
    int canceled = 0;
    num totalPaid = 0;

    for (final a in appts) {
      if (a.status == 'confirmed') confirmed++;
      if (a.status == 'completed') {
        completed++;
        totalPaid += (a.amountPaid ?? 0);
      }
      if (a.status == 'canceled') canceled++;
    }

    return _Totals(
      confirmed: confirmed,
      completed: completed,
      canceled: canceled,
      totalPaid: totalPaid,
    );
  }

  // ============================================================
  //                 UI Helpers
  // ============================================================
  Widget _headerRow(
    String businessName,
    int slot,
    int buffer,
    int maxConcurrent,
  ) {
    return Row(
      children: [
        Expanded(
          child: Text(
            businessName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '${slot}m • buf ${buffer}m • x$maxConcurrent',
          style: TextStyle(
            fontSize: 12,
            color: Colors.black.withValues(alpha: 0.65),
          ),
        ),
      ],
    );
  }

  Widget _filtersRow() {
    ChoiceChip chip(String label, _Filter value) {
      return ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: _filter == value,
        onSelected: (_) => setState(() => _filter = value),
        visualDensity: VisualDensity.compact,
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip('Todos', _Filter.all),
        chip('Libre', _Filter.libre),
        chip('Confirmado', _Filter.confirmado),
        chip('Concretado', _Filter.concretado),
        chip('Cancelado', _Filter.cancelado),
      ],
    );
  }

  Widget _summaryPill({
    required int confirmed,
    required int completed,
    required int canceled,
    required num totalPaid,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.attach_money, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Hoy: $confirmed conf. • $completed conc. • $canceled canc.',
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Cobrado: ${_fmtMoney(totalPaid)}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ============================================================
  //                     BUILD
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    final settingsRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('settings')
        .doc('default');

    final dayStart = _dayOnly(_selectedDay);
    final dayEnd = dayStart.add(const Duration(days: 1));

    final apptQuery = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('appointments')
        .where('startAt', isGreaterThanOrEqualTo: Timestamp.fromDate(dayStart))
        .where('startAt', isLessThan: Timestamp.fromDate(dayEnd))
        .orderBy('startAt');

    return Scaffold(
      appBar: AppBar(
        title: const Text('TurnosPY'),
        actions: [
          PopupMenuButton<_HomeMenuAction>(
            tooltip: 'Sesion',
            icon: const Icon(Icons.more_vert),
            onSelected: (action) async {
              if (action == _HomeMenuAction.guide) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const UserGuidePage()),
                );
                return;
              }

              if (action != _HomeMenuAction.signOut) return;

              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Cerrar sesion'),
                  content: const Text('Seguro que queres cerrar sesion?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancelar'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Cerrar sesion'),
                    ),
                  ],
                ),
              );

              if (ok == true) {
                await FirebaseAuth.instance.signOut();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem<_HomeMenuAction>(
                value: _HomeMenuAction.guide,
                child: Text('Guia de uso'),
              ),
              PopupMenuItem<_HomeMenuAction>(
                value: _HomeMenuAction.signOut,
                child: Text('Cerrar sesion'),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Configuración',
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              );
            },
          ),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .snapshots(),
            builder: (context, adminSnap) {
              final isAdmin =
                  adminSnap.hasData &&
                  adminSnap.data!.data()?['isAdmin'] == true;
              if (!isAdmin) return const SizedBox.shrink();
              return IconButton(
                tooltip: 'Panel admin',
                icon: const Icon(Icons.admin_panel_settings_outlined),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AdminUsersPage()),
                  );
                },
              );
            },
          ),
          IconButton(
            tooltip: 'Balance financiero',
            icon: const Icon(Icons.bar_chart),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FinancialBalancePage()),
              );
            },
          ),
          IconButton(
            tooltip: 'Anterior',
            icon: const Icon(Icons.chevron_left),
            onPressed: _prevDay,
          ),
          IconButton(
            tooltip: 'Hoy',
            icon: const Icon(Icons.today),
            onPressed: _goToday,
          ),
          IconButton(
            tooltip: 'Siguiente',
            icon: const Icon(Icons.chevron_right),
            onPressed: _nextDay,
          ),
          IconButton(
            tooltip: 'Elegir día',
            icon: const Icon(Icons.calendar_month),
            onPressed: _pickDay,
          ),
          IconButton(
            tooltip: 'Próximo libre',
            icon: const Icon(Icons.skip_next),
            onPressed: () => _jumpToNextAvailableDay(uid: user.uid),
          ),
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Cerrar sesión'),
                  content: const Text('¿Seguro que querés cerrar sesión?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancelar'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Cerrar sesión'),
                    ),
                  ],
                ),
              );

              if (ok == true) {
                await FirebaseAuth.instance.signOut();
              }
            },
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: StreamBuilder<DocumentSnapshot>(
              stream: settingsRef.snapshots(),
              builder: (context, settingsSnap) {
                if (settingsSnap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (settingsSnap.hasError) {
                  return Text(
                    'Error leyendo configuración: ${settingsSnap.error}',
                  );
                }
                if (!settingsSnap.hasData || !settingsSnap.data!.exists) {
                  return const Text(
                    'No existe settings/default. Volvé a configurar el negocio.',
                  );
                }

                final settings =
                    settingsSnap.data!.data() as Map<String, dynamic>;
                final businessName = (settings['businessName'] ?? 'Mi negocio')
                    .toString();
                final serviceDescription =
                    (settings['serviceDescription'] ?? '').toString();
                final slogan = (settings['slogan'] ?? '').toString();
                final slotMinutes =
                    (settings['slotMinutesDefault'] ?? 30) as int;
                final bufferMinutes = (settings['bufferMinutes'] ?? 0) as int;
                final maxConcurrent =
                    (settings['maxConcurrentAppointments'] ?? 1) as int;
                final workHours =
                    (settings['workHours'] ?? {}) as Map<String, dynamic>;

                final dayKey = _dayKeyFromDate(_selectedDay);
                final dayWork = workHours[dayKey];

                Widget closedView() {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _headerRow(
                        businessName,
                        slotMinutes,
                        bufferMinutes,
                        maxConcurrent,
                      ),
                      const SizedBox(height: 10),
                      _filtersRow(),
                      const SizedBox(height: 10),
                      Text(
                        '📅 ${_weekdayLabel(_selectedDay)} ${_fmtDate(_selectedDay)}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text('Hoy el negocio está cerrado.'),
                    ],
                  );
                }

                if (dayWork == null) return closedView();

                final startStr = (dayWork['start'] ?? '').toString();
                final endStr = (dayWork['end'] ?? '').toString();
                if (startStr.isEmpty || endStr.isEmpty) return closedView();

                final stepMinutes = slotMinutes + bufferMinutes;
                final List<DateTime> slots = [];
                final segs = _segmentsForDay(
                  _selectedDay,
                  startStr: startStr,
                  endStr: endStr,
                  breakStartStr:
                      (dayWork['breakStart'] ?? dayWork['breakStartAt'])
                          ?.toString(),
                  breakEndStr: (dayWork['breakEnd'] ?? dayWork['breakEndAt'])
                      ?.toString(),
                );

                for (final seg in segs) {
                  DateTime cursor = seg.start;
                  while (true) {
                    final slotEnd = cursor.add(Duration(minutes: slotMinutes));
                    if (slotEnd.isAfter(seg.end)) break;
                    slots.add(cursor);
                    final next = cursor.add(Duration(minutes: stepMinutes));
                    if (!next.isBefore(seg.end)) break;
                    cursor = next;
                  }
                }

                return StreamBuilder<QuerySnapshot>(
                  stream: apptQuery.snapshots(),
                  builder: (context, apptSnap) {
                    if (apptSnap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (apptSnap.hasError) {
                      return Text('Error leyendo turnos: ${apptSnap.error}');
                    }

                    final docs = apptSnap.data?.docs ?? [];
                    final appts = docs.map((d) {
                      final data = d.data() as Map<String, dynamic>;
                      final startAt = (data['startAt'] as Timestamp).toDate();
                      final duration =
                          (data['durationMinutes'] ?? slotMinutes) as int;
                      final endAt = startAt.add(Duration(minutes: duration));
                      return _Appt(
                        id: d.id,
                        start: startAt,
                        end: endAt,
                        durationMinutes: duration,
                        clientName: (data['clientName'] ?? '').toString(),
                        clientPhone: (data['clientPhone'] ?? '').toString(),
                        notes: (data['notes'] ?? '').toString(),
                        status: (data['status'] ?? 'confirmed').toString(),
                        amountPaid: data['amountPaid'] as num?,
                        currency: (data['currency'] ?? 'PYG').toString(),
                      );
                    }).toList();

                    final totals = _computeTotals(appts);

                    Future<void> openShareMenu() async {
                      final choice = await showModalBottomSheet<String>(
                        context: context,
                        showDragHandle: true,
                        builder: (_) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                leading: const Icon(Icons.image),
                                title: Text(
                                  kIsWeb
                                      ? 'PNG descargable - día (solo futuro)'
                                      : 'Flyer (imagen) - día (solo futuro)',
                                ),
                                onTap: () => Navigator.pop(context, 'png_day'),
                              ),
                              ListTile(
                                leading: const Icon(Icons.image_outlined),
                                title: Text(
                                  kIsWeb
                                      ? 'PNG descargable - próximos 7 días'
                                      : 'Flyer (imagen) - próximos 7 días',
                                ),
                                onTap: () => Navigator.pop(context, 'png_week'),
                              ),
                              const Divider(height: 1),
                              const SizedBox(height: 6),
                              ListTile(
                                leading: const Icon(Icons.message),
                                title: const Text(
                                  'Texto WhatsApp - día (solo disponibles)',
                                ),
                                onTap: () => Navigator.pop(context, 'wa_day'),
                              ),
                              ListTile(
                                leading: const Icon(Icons.message_outlined),
                                title: const Text(
                                  'Texto WhatsApp - semana (próximos 7 días)',
                                ),
                                onTap: () => Navigator.pop(context, 'wa_week'),
                              ),
                            ],
                          ),
                        ),
                      );

                      if (choice == 'png_day') {
                        await _exportFlyerDayPng(
                          businessName: businessName,
                          serviceDescription: serviceDescription,
                          slogan: slogan,
                          day: _selectedDay,
                          startStr: startStr,
                          endStr: endStr,
                          slots: slots,
                          appts: appts,
                          slotMinutes: slotMinutes,
                          maxConcurrent: maxConcurrent,
                          settingsRef: settingsRef,
                          settings: settings,
                        );
                      } else if (choice == 'png_week') {
                        await _exportFlyerWeekPng(
                          uid: user.uid,
                          businessName: businessName,
                          serviceDescription: serviceDescription,
                          slogan: slogan,
                          settings: settings,
                          anchorDay: _selectedDay,
                          settingsRef: settingsRef,
                        );
                      } else if (choice == 'wa_day') {
                        final today = _dayOnly(DateTime.now());
                        final sel = _dayOnly(_selectedDay);
                        if (sel.isBefore(today)) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Solo se comparte para fechas futuras (o hoy).',
                              ),
                            ),
                          );
                          return;
                        }
                        final msg = _buildAvailableTextForDay(
                          businessName: businessName,
                          day: _selectedDay,
                          startStr: startStr,
                          endStr: endStr,
                          slots: slots,
                          appts: appts,
                          slotMinutes: slotMinutes,
                          maxConcurrent: maxConcurrent,
                        );
                        await _openWhatsApp(message: msg);
                      } else if (choice == 'wa_week') {
                        final today = _dayOnly(DateTime.now());
                        final anchor = _dayOnly(_selectedDay);
                        final startDay = anchor.isBefore(today)
                            ? today
                            : anchor;

                        final line1 = businessName.trim().isEmpty
                            ? '*Turnos disponibles*'
                            : '*${businessName.trim()} - Turnos disponibles*';
                        final header =
                            '$line1\n🗓️ Próximos 7 días desde ${_fmtDate(startDay)}\n\n';

                        final slotM = slotMinutes;
                        final bufM = bufferMinutes;
                        final maxC = maxConcurrent;

                        final endDayExclusive = startDay.add(
                          const Duration(days: 7),
                        );
                        final q = await FirebaseFirestore.instance
                            .collection('users')
                            .doc(user.uid)
                            .collection('appointments')
                            .where(
                              'startAt',
                              isGreaterThanOrEqualTo: Timestamp.fromDate(
                                startDay,
                              ),
                            )
                            .where(
                              'startAt',
                              isLessThan: Timestamp.fromDate(endDayExclusive),
                            )
                            .get();

                        final apptsRange = q.docs.map((d) {
                          final data = d.data();
                          final startAt = (data['startAt'] as Timestamp)
                              .toDate();
                          final duration =
                              (data['durationMinutes'] ?? slotM) as int;
                          final endAt = startAt.add(
                            Duration(minutes: duration),
                          );
                          return _Appt(
                            id: d.id,
                            start: startAt,
                            end: endAt,
                            durationMinutes: duration,
                            clientName: (data['clientName'] ?? '').toString(),
                            clientPhone: (data['clientPhone'] ?? '').toString(),
                            notes: (data['notes'] ?? '').toString(),
                            status: (data['status'] ?? 'confirmed').toString(),
                            amountPaid: data['amountPaid'] as num?,
                            currency: (data['currency'] ?? 'PYG').toString(),
                          );
                        }).toList();

                        final work =
                            (settings['workHours'] ?? {})
                                as Map<String, dynamic>;

                        final out = StringBuffer(header);
                        bool any = false;

                        for (int i = 0; i < 7; i++) {
                          final day = startDay.add(Duration(days: i));
                          final key = _dayKeyFromDate(day);
                          final dw = work[key];
                          if (dw == null) continue;

                          final s = (dw['start'] ?? '').toString();
                          final e = (dw['end'] ?? '').toString();
                          if (s.isEmpty || e.isEmpty) continue;

                          final workStart = _atTime(day, s);
                          final workEnd = _atTime(day, e);

                          final step = slotM + bufM;
                          final listSlots = <DateTime>[];
                          var cur = workStart;
                          while (true) {
                            final se = cur.add(Duration(minutes: slotM));
                            if (se.isAfter(workEnd)) break;
                            listSlots.add(cur);
                            cur = cur.add(Duration(minutes: step));
                            if (cur.isAfter(workEnd)) break;
                          }

                          final apptsDay = apptsRange
                              .where((a) => _dayOnly(a.start) == _dayOnly(day))
                              .toList();
                          final msgDay = _buildAvailableTextForDay(
                            businessName: '',
                            day: day,
                            startStr: s,
                            endStr: e,
                            slots: listSlots,
                            appts: apptsDay,
                            slotMinutes: slotM,
                            maxConcurrent: maxC,
                          );

                          final bulletLines = msgDay
                              .split('\n')
                              .where((l) => l.trim().startsWith('•'))
                              .toList();

                          if (bulletLines.isEmpty) continue;

                          any = true;
                          out.writeln(
                            '📅 *${_weekdayLabel(day)} ${_fmtDate(day)}* ($s-$e)',
                          );
                          for (final bl in bulletLines) {
                            out.writeln(bl);
                          }
                          out.writeln('');
                        }

                        if (!any) {
                          out.writeln(
                            'No hay horarios disponibles en los próximos 7 días.',
                          );
                        } else {
                          out.writeln(
                            '📲 Para reservar, respondé este mensaje.',
                          );
                        }

                        await _openWhatsApp(message: out.toString());
                      }
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _headerRow(
                          businessName,
                          slotMinutes,
                          bufferMinutes,
                          maxConcurrent,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '📅 ${_weekdayLabel(_selectedDay)} ${_fmtDate(_selectedDay)} • $startStr-$endStr',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton.tonal(
                              onPressed: openShareMenu,
                              child: const Text('Disponibles'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _filtersRow(),
                        const SizedBox(height: 10),
                        _summaryPill(
                          confirmed: totals.confirmed,
                          completed: totals.completed,
                          canceled: totals.canceled,
                          totalPaid: totals.totalPaid,
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: ListView.separated(
                            itemCount: slots.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final slotStart = slots[i];
                              final slotEnd = slotStart.add(
                                Duration(minutes: slotMinutes),
                              );

                              final overlapsAll = appts
                                  .where(
                                    (a) => _overlaps(
                                      slotStart,
                                      slotEnd,
                                      a.start,
                                      a.end,
                                    ),
                                  )
                                  .toList();

                              final overlapsActive = overlapsAll
                                  .where((a) => a.status != 'canceled')
                                  .toList();
                              final used = overlapsActive.length;
                              final remaining = math.max(
                                0,
                                maxConcurrent - used,
                              );
                              final past = _isPastSlot(slotStart);

                              final bool isFocus =
                                  _focusSlotStart != null &&
                                  _dayOnly(_focusSlotStart!) ==
                                      _dayOnly(slotStart) &&
                                  _focusSlotStart!.hour == slotStart.hour &&
                                  _focusSlotStart!.minute == slotStart.minute;

                              final hasConfirmed = overlapsAll.any(
                                (a) => a.status == 'confirmed',
                              );
                              final hasCompleted = overlapsAll.any(
                                (a) => a.status == 'completed',
                              );
                              final hasCanceled = overlapsAll.any(
                                (a) => a.status == 'canceled',
                              );

                              bool visibleByFilter = true;
                              switch (_filter) {
                                case _Filter.all:
                                  visibleByFilter = true;
                                  break;
                                case _Filter.libre:
                                  visibleByFilter = remaining > 0;
                                  break;
                                case _Filter.confirmado:
                                  visibleByFilter = hasConfirmed;
                                  break;
                                case _Filter.concretado:
                                  visibleByFilter = hasCompleted;
                                  break;
                                case _Filter.cancelado:
                                  visibleByFilter = hasCanceled;
                                  break;
                              }

                              if (!visibleByFilter) {
                                return const SizedBox.shrink();
                              }

                              String firstName = '';
                              int extra = 0;
                              if (overlapsActive.isNotEmpty) {
                                final n = overlapsActive.first.clientName
                                    .trim();
                                firstName = n.isEmpty
                                    ? ''
                                    : n.split(RegExp(r'\s+')).first;
                                extra = math.max(0, overlapsActive.length - 1);
                              }

                              final occ = used / math.max(1, maxConcurrent);
                              final occClamped = occ.clamp(0.0, 1.0);
                              final theme = Theme.of(context);
                              final isDark =
                                  theme.colorScheme.brightness ==
                                  Brightness.dark;
                              final freeDark = isDark && used == 0;
                              final cardColor = freeDark
                                  ? Colors.white
                                  : theme.colorScheme.surface;
                              final borderColor = theme.dividerColor.withValues(
                                alpha: isDark ? 0.25 : 0.06,
                              );
                              final shadowColor = Colors.black.withValues(
                                alpha: isDark ? 0.35 : 0.05,
                              );
                              final overlayColor = used == 0
                                  ? Colors.transparent
                                  : (used < maxConcurrent
                                        ? theme.colorScheme.tertiary.withValues(
                                            alpha: isDark ? 0.22 : 0.18,
                                          )
                                        : theme.colorScheme.error.withValues(
                                            alpha: isDark ? 0.22 : 0.16,
                                          ));

                              String statusLabel;
                              IconData icon;
                              if (used == 0) {
                                statusLabel = past
                                    ? 'Libre (pasado) 0/$maxConcurrent'
                                    : 'Libre 0/$maxConcurrent';
                                icon = past
                                    ? Icons.history_toggle_off
                                    : Icons.event_available;
                              } else if (used < maxConcurrent) {
                                statusLabel = 'Disponible $used/$maxConcurrent';
                                icon = Icons.event_repeat;
                              } else {
                                statusLabel = 'Lleno $used/$maxConcurrent';
                                icon = Icons.event_busy;
                              }

                              final hasCompletedActive = overlapsActive.any(
                                (a) => a.status == 'completed',
                              );
                              final hasConfirmedActive = overlapsActive.any(
                                (a) => a.status == 'confirmed',
                              );

                              final stateTxt = [
                                if (hasConfirmedActive) 'Confirmado',
                                if (hasCompletedActive) 'Concretado',
                                if (hasCanceled) 'Cancelado',
                              ].join(' • ');

                              final clientTxt = (firstName.isEmpty)
                                  ? ''
                                  : (extra > 0
                                        ? ' • $firstName +$extra'
                                        : ' • $firstName');

                              String cupoLabel() {
                                if (maxConcurrent <= 1) return '';
                                if (used >= maxConcurrent) {
                                  return 'Lleno $used/$maxConcurrent';
                                }
                                return 'Cupos $used/$maxConcurrent';
                              }

                              Color cupoBg() {
                                if (used >= maxConcurrent) {
                                  return theme.colorScheme.errorContainer;
                                }
                                if (remaining == 1) {
                                  return theme.colorScheme.tertiaryContainer;
                                }
                                return theme.colorScheme.primaryContainer;
                              }

                              Color cupoFg() {
                                if (used >= maxConcurrent) {
                                  return theme.colorScheme.onErrorContainer;
                                }
                                if (remaining == 1) {
                                  return theme.colorScheme.onTertiaryContainer;
                                }
                                return theme.colorScheme.onPrimaryContainer;
                              }

                              return InkWell(
                                onTap: () async {
                                  await _openSlotDetail(
                                    uid: user.uid,
                                    businessName: businessName,
                                    slotStart: slotStart,
                                    slotMinutes: slotMinutes,
                                    maxConcurrent: maxConcurrent,
                                    overlapsAll: overlapsAll,
                                  );
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: cardColor,
                                    borderRadius: BorderRadius.circular(14),
                                    border: isFocus
                                        ? Border.all(
                                            color: Colors.deepPurple.withValues(
                                              alpha: 0.55,
                                            ),
                                            width: 2,
                                          )
                                        : Border.all(
                                            color: borderColor,
                                            width: 1,
                                          ),
                                    boxShadow: [
                                      BoxShadow(
                                        blurRadius: 16,
                                        offset: const Offset(0, 10),
                                        color: shadowColor,
                                      ),
                                    ],
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: FractionallySizedBox(
                                            widthFactor: occClamped,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: overlayColor,
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      ListTile(
                                        dense: true,
                                        leading: Icon(icon),
                                        title: Text(
                                          '${_fmtTime(slotStart)} - ${_fmtTime(slotEnd)}',
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                color: freeDark
                                                    ? Colors.black
                                                    : theme
                                                          .colorScheme
                                                          .onSurface,
                                              ),
                                        ),
                                        subtitle: Text(
                                          '$statusLabel$clientTxt${stateTxt.isEmpty ? '' : ' • $stateTxt'}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: freeDark
                                                    ? Colors.black54
                                                    : theme
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                              ),
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (maxConcurrent > 1)
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 4,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: cupoBg(),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: Text(
                                                  cupoLabel(),
                                                  style: theme
                                                      .textTheme
                                                      .labelSmall
                                                      ?.copyWith(
                                                        color: cupoFg(),
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                ),
                                              ),
                                            const SizedBox(width: 8),
                                            Icon(
                                              Icons.chevron_right,
                                              color: freeDark
                                                  ? Colors.black54
                                                  : null,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Tip: tocá un horario para ver los turnos dentro del slot y agregar si hay cupo.',
                          style: TextStyle(fontSize: 11),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Totals {
  final int confirmed;
  final int completed;
  final int canceled;
  final num totalPaid;

  _Totals({
    required this.confirmed,
    required this.completed,
    required this.canceled,
    required this.totalPaid,
  });
}

class _Appt {
  final String id;
  final DateTime start;
  final DateTime end;
  final int durationMinutes;
  final String clientName;
  final String? clientPhone;
  final String notes;
  final String status; // confirmed | completed | canceled
  final num? amountPaid;
  final String currency;

  _Appt({
    required this.id,
    required this.start,
    required this.end,
    required this.durationMinutes,
    required this.clientName,
    required this.clientPhone,
    required this.notes,
    required this.status,
    required this.amountPaid,
    required this.currency,
  });

  factory _Appt.fromDoc(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final ts = data['startAt'] as Timestamp?;
    final start = ts?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
    final duration = (data['durationMinutes'] as int?) ?? 60;
    final end = start.add(Duration(minutes: duration));
    return _Appt(
      id: doc.id,
      start: start,
      end: end,
      durationMinutes: duration,
      clientName: (data['clientName'] as String?) ?? '',
      clientPhone: data['clientPhone'] as String?,
      notes: (data['notes'] as String?) ?? '',
      status: (data['status'] as String?) ?? 'confirmed',
      amountPaid: data['amountPaid'] as num?,
      currency: (data['currency'] as String?) ?? 'PYG',
    );
  }
}

class _AvailSlotLine {
  final String time;
  final int cupos;
  _AvailSlotLine({required this.time, required this.cupos});
}

class _FlyerDayBlock {
  final String title;
  final String hoursLine;
  final List<_AvailSlotLine> lines;

  _FlyerDayBlock({
    required this.title,
    required this.hoursLine,
    required this.lines,
  });
}

class _FlyerPalette {
  final Color bgStart;
  final Color bgEnd;
  final bool useGradient;
  final Color card;
  final Color titleText;
  final Color bodyText;
  final Color nameColor;
  final Color sloganColor;
  final Color dayTitleColor;
  final Color timesColor;
  final Color badgeBg;
  final Color badgeText;
  final Color iconBg;
  final Color iconColor;

  const _FlyerPalette({
    required this.bgStart,
    required this.bgEnd,
    required this.useGradient,
    required this.card,
    required this.titleText,
    required this.bodyText,
    required this.nameColor,
    required this.sloganColor,
    required this.dayTitleColor,
    required this.timesColor,
    required this.badgeBg,
    required this.badgeText,
    required this.iconBg,
    required this.iconColor,
  });

  static Color _colorFrom(dynamic value, Color fallback) {
    if (value is int) return Color(value);
    if (value is num) return Color(value.toInt());
    return fallback;
  }

  static _FlyerPalette fromMap(
    Map<String, dynamic> map, {
    required _FlyerPalette fallback,
  }) {
    return _FlyerPalette(
      bgStart: _colorFrom(map['bgStart'], fallback.bgStart),
      bgEnd: _colorFrom(map['bgEnd'], fallback.bgEnd),
      useGradient: map['useGradient'] is bool
          ? map['useGradient'] as bool
          : fallback.useGradient,
      card: _colorFrom(map['card'], fallback.card),
      titleText: _colorFrom(map['titleText'], fallback.titleText),
      bodyText: _colorFrom(map['bodyText'], fallback.bodyText),
      nameColor: _colorFrom(map['nameColor'], fallback.nameColor),
      sloganColor: _colorFrom(map['sloganColor'], fallback.sloganColor),
      dayTitleColor: _colorFrom(map['dayTitleColor'], fallback.dayTitleColor),
      timesColor: _colorFrom(map['timesColor'], fallback.timesColor),
      badgeBg: _colorFrom(map['badgeBg'], fallback.badgeBg),
      badgeText: _colorFrom(map['badgeText'], fallback.badgeText),
      iconBg: _colorFrom(map['iconBg'], fallback.iconBg),
      iconColor: _colorFrom(map['iconColor'], fallback.iconColor),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'bgStart': bgStart.toARGB32(),
      'bgEnd': bgEnd.toARGB32(),
      'useGradient': useGradient,
      'card': card.toARGB32(),
      'titleText': titleText.toARGB32(),
      'bodyText': bodyText.toARGB32(),
      'nameColor': nameColor.toARGB32(),
      'sloganColor': sloganColor.toARGB32(),
      'dayTitleColor': dayTitleColor.toARGB32(),
      'timesColor': timesColor.toARGB32(),
      'badgeBg': badgeBg.toARGB32(),
      'badgeText': badgeText.toARGB32(),
      'iconBg': iconBg.toARGB32(),
      'iconColor': iconColor.toARGB32(),
    };
  }

  bool sameAs(_FlyerPalette other) {
    return bgStart.toARGB32() == other.bgStart.toARGB32() &&
        bgEnd.toARGB32() == other.bgEnd.toARGB32() &&
        useGradient == other.useGradient &&
        card.toARGB32() == other.card.toARGB32() &&
        titleText.toARGB32() == other.titleText.toARGB32() &&
        bodyText.toARGB32() == other.bodyText.toARGB32() &&
        nameColor.toARGB32() == other.nameColor.toARGB32() &&
        sloganColor.toARGB32() == other.sloganColor.toARGB32() &&
        dayTitleColor.toARGB32() == other.dayTitleColor.toARGB32() &&
        timesColor.toARGB32() == other.timesColor.toARGB32() &&
        badgeBg.toARGB32() == other.badgeBg.toARGB32() &&
        badgeText.toARGB32() == other.badgeText.toARGB32() &&
        iconBg.toARGB32() == other.iconBg.toARGB32() &&
        iconColor.toARGB32() == other.iconColor.toARGB32();
  }

  _FlyerPalette copyWith({
    Color? bgStart,
    Color? bgEnd,
    bool? useGradient,
    Color? card,
    Color? titleText,
    Color? bodyText,
    Color? nameColor,
    Color? sloganColor,
    Color? dayTitleColor,
    Color? timesColor,
    Color? badgeBg,
    Color? badgeText,
    Color? iconBg,
    Color? iconColor,
  }) {
    return _FlyerPalette(
      bgStart: bgStart ?? this.bgStart,
      bgEnd: bgEnd ?? this.bgEnd,
      useGradient: useGradient ?? this.useGradient,
      card: card ?? this.card,
      titleText: titleText ?? this.titleText,
      bodyText: bodyText ?? this.bodyText,
      nameColor: nameColor ?? this.nameColor,
      sloganColor: sloganColor ?? this.sloganColor,
      dayTitleColor: dayTitleColor ?? this.dayTitleColor,
      timesColor: timesColor ?? this.timesColor,
      badgeBg: badgeBg ?? this.badgeBg,
      badgeText: badgeText ?? this.badgeText,
      iconBg: iconBg ?? this.iconBg,
      iconColor: iconColor ?? this.iconColor,
    );
  }
}

class _FlyerPalettePreset {
  final String name;
  final _FlyerPalette palette;

  const _FlyerPalettePreset({required this.name, required this.palette});
}
