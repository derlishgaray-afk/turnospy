import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

enum _ExitAction { save, discard, cancel }

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _businessNameCtrl = TextEditingController();
  final _serviceDescriptionCtrl = TextEditingController();
  final _sloganCtrl = TextEditingController();
  final _slotCtrl = TextEditingController();
  final _bufferCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final PageStorageBucket _scrollBucket = PageStorageBucket();
  late final DocumentReference _settingsRef;
  late final Stream<DocumentSnapshot> _settingsStream;

  int _maxConcurrent = 1;
  String _themeMode = 'light';

  bool _loading = false;
  bool _loadedOnce = false;
  bool _dirty = false;
  bool _bypassConfirm = false;
  bool _isHydrating = false;
  String? _error;
  late final Map<String, GlobalKey> _dayKeys;

  // Si un día está cerrado => value = null
  final Map<String, Map<String, String>?> _workHours = {
    'mon': {'start': '08:00', 'end': '18:00'},
    'tue': {'start': '08:00', 'end': '18:00'},
    'wed': {'start': '08:00', 'end': '18:00'},
    'thu': {'start': '08:00', 'end': '18:00'},
    'fri': {'start': '08:00', 'end': '18:00'},
    'sat': {'start': '08:00', 'end': '12:00'},
    'sun': null,
  };

  final _days = const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser!;
    _settingsRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('settings')
        .doc('default');
    _settingsStream = _settingsRef.snapshots();
    _dayKeys = {for (final d in _days) d: GlobalKey()};
    _businessNameCtrl.addListener(_markDirtyIfNeeded);
    _serviceDescriptionCtrl.addListener(_markDirtyIfNeeded);
    _sloganCtrl.addListener(_markDirtyIfNeeded);
    _slotCtrl.addListener(_markDirtyIfNeeded);
    _bufferCtrl.addListener(_markDirtyIfNeeded);
  }

  @override
  void dispose() {
    _businessNameCtrl.dispose();
    _serviceDescriptionCtrl.dispose();
    _sloganCtrl.dispose();
    _slotCtrl.dispose();
    _bufferCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  String _dayLabel(String k) {
    switch (k) {
      case 'mon':
        return 'Lunes';
      case 'tue':
        return 'Martes';
      case 'wed':
        return 'Miércoles';
      case 'thu':
        return 'Jueves';
      case 'fri':
        return 'Viernes';
      case 'sat':
        return 'Sábado';
      case 'sun':
        return 'Domingo';
      default:
        return k;
    }
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  int _clampMinutes(int minutes) {
    if (minutes < 0) return 0;
    if (minutes > 1439) return 1439;
    return minutes;
  }

  String _minToTime(int minutes) {
    final m = _clampMinutes(minutes);
    final hh = _two(m ~/ 60);
    final mm = _two(m % 60);
    return '$hh:$mm';
  }

  int _toMin(String hhmm) {
    final parts = hhmm.split(':');
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    return h * 60 + m;
  }

  int _defaultBreakStartMin(Map<String, String> cfg) {
    final start = cfg['start'];
    final end = cfg['end'];
    if (start == null || end == null) return 12 * 60;
    final s = _toMin(start);
    final e = _toMin(end);
    if (e <= s) return s;
    return s + ((e - s) ~/ 2);
  }

  void _ensureBreakDefaults(String dayKey) {
    final cfg = _workHours[dayKey];
    if (cfg == null) return;
    final startMin = _defaultBreakStartMin(cfg);
    cfg['breakStart'] ??= _minToTime(startMin);
    cfg['breakEnd'] ??= _minToTime(startMin + 30);
  }

  void _adjustTime(String dayKey, String field, int deltaMinutes) {
    final cfg = _workHours[dayKey];
    if (cfg == null) return;
    setState(() {
      if (field == 'breakStart' || field == 'breakEnd') {
        _ensureBreakDefaults(dayKey);
      }

      final current = (cfg[field] ?? cfg['start'] ?? '08:00').toString();
      final next = _clampMinutes(_toMin(current) + deltaMinutes);
      cfg[field] = _minToTime(next);
    });
    _dirty = true;
    _ensureDayVisible(dayKey);
  }

  void _markDirtyIfNeeded() {
    if (_isHydrating) return;
    _dirty = true;
    _bypassConfirm = false;
  }

  void _ensureDayVisible(String dayKey) {
    final key = _dayKeys[dayKey];
    if (key == null) return;
    // En pantallas pequeñas (móvil), evitamos el auto-scroll.
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    if (shortestSide < 600) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: 0.2,
      );
    });
  }

  void _clearBreak(String dayKey) {
    final cfg = _workHours[dayKey];
    if (cfg == null) return;
    setState(() {
      cfg.remove('breakStart');
      cfg.remove('breakEnd');
    });
    _dirty = true;
    _ensureDayVisible(dayKey);
  }

  void _addBreak(String dayKey) {
    final cfg = _workHours[dayKey];
    if (cfg == null) return;
    setState(() {
      _ensureBreakDefaults(dayKey);
    });
    _dirty = true;
    _ensureDayVisible(dayKey);
  }

  bool _breakOkForDay(Map<String, String> cfg) {
    final start = cfg['start'];
    final end = cfg['end'];
    final bs = cfg['breakStart'];
    final be = cfg['breakEnd'];
    if (start == null || end == null) return true;

    if (bs == null || be == null) return true;

    final s = _toMin(start);
    final e = _toMin(end);
    final b1 = _toMin(bs);
    final b2 = _toMin(be);

    return s < b1 && b1 < b2 && b2 < e;
  }

  bool _timeOrderOk(String start, String end) {
    final s = start.split(':');
    final e = end.split(':');
    final sh = int.parse(s[0]);
    final sm = int.parse(s[1]);
    final eh = int.parse(e[0]);
    final em = int.parse(e[1]);
    final sMin = sh * 60 + sm;
    final eMin = eh * 60 + em;
    return eMin > sMin;
  }

  void _loadFromDoc(Map<String, dynamic> data) {
    // Solo cargamos 1 vez para no pisar edición
    if (_loadedOnce) return;
    _loadedOnce = true;
    _isHydrating = true;

    _businessNameCtrl.text = (data['businessName'] ?? '').toString();
    _serviceDescriptionCtrl.text =
        (data['serviceDescription'] ?? '').toString();
    _sloganCtrl.text = (data['slogan'] ?? '').toString();
    _themeMode = (data['themeMode'] ?? 'light').toString() == 'dark'
        ? 'dark'
        : 'light';
    _slotCtrl.text = (data['slotMinutesDefault'] ?? 30).toString();
    _bufferCtrl.text = (data['bufferMinutes'] ?? 0).toString();

    final mc = data['maxConcurrentAppointments'];
    _maxConcurrent = (mc is int)
        ? mc
        : int.tryParse((mc ?? '1').toString()) ?? 1;

    final wh = data['workHours'];
    if (wh is Map) {
      for (final day in _workHours.keys) {
        final v = wh[day];
        if (v == null) {
          _workHours[day] = null;
        } else if (v is Map) {
          final start = (v['start'] ?? '').toString();
          final end = (v['end'] ?? '').toString();
          if (start.isNotEmpty && end.isNotEmpty) {
            final map = <String, String>{'start': start, 'end': end};
            final breakStart = (v['breakStart'] ?? '').toString();
            final breakEnd = (v['breakEnd'] ?? '').toString();
            if (breakStart.isNotEmpty) map['breakStart'] = breakStart;
            if (breakEnd.isNotEmpty) map['breakEnd'] = breakEnd;
            _workHours[day] = map;
          } else {
            _workHours[day] = null;
          }
        }
      }
    }
    _dirty = false;
    _isHydrating = false;
  }

  Future<void> _save(DocumentReference settingsRef) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final slot = int.tryParse(_slotCtrl.text.trim());
      final buffer = int.tryParse(_bufferCtrl.text.trim());

      if (slot == null || slot < 5 || slot > 240) {
        throw Exception('Duración inválida. Usá un número entre 5 y 240.');
      }
      if (buffer == null || buffer < 0 || buffer > 120) {
        throw Exception('Buffer inválido. Usá un número entre 0 y 120.');
      }
      if (_maxConcurrent < 1 || _maxConcurrent > 3) {
        throw Exception('Simultáneos inválido. Elegí entre 1 y 3.');
      }

      for (final entry in _workHours.entries) {
        final day = entry.key;
        final v = entry.value;
        if (v == null) continue;
        final start = (v['start'] ?? '').trim();
        final end = (v['end'] ?? '').trim();
        if (start.isEmpty || end.isEmpty) {
          throw Exception('Horario incompleto en ${_dayLabel(day)}.');
        }
        if (!_timeOrderOk(start, end)) {
          throw Exception(
            'Horario inválido en ${_dayLabel(day)}: fin debe ser mayor a inicio.',
          );
        }

        if (!_breakOkForDay(v)) {
          throw Exception(
            'Descanso inválido en ${_dayLabel(day)} (debe estar dentro del horario y con inicio < fin).',
          );
        }
      }

      await settingsRef.update({
        'businessName': _businessNameCtrl.text.trim(),
        'serviceDescription': _serviceDescriptionCtrl.text.trim(),
        'slogan': _sloganCtrl.text.trim(),
        'themeMode': _themeMode,
        'slotMinutesDefault': slot,
        'bufferMinutes': buffer,
        'maxConcurrentAppointments': _maxConcurrent,
        'workHours': _workHours,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        _dirty = false;
        _bypassConfirm = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configuración guardada.')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _confirmExit(DocumentReference settingsRef) async {
    if (_bypassConfirm || !_dirty) return true;
    final action = await showDialog<_ExitAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Guardar cambios'),
        content: const Text(
          'Tenés cambios sin guardar. ¿Querés guardarlos antes de salir?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _ExitAction.cancel),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _ExitAction.discard),
            child: const Text('Descartar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _ExitAction.save),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    switch (action) {
      case _ExitAction.save:
        await _save(settingsRef);
        return false;
      case _ExitAction.discard:
        return true;
      case _ExitAction.cancel:
      default:
        return false;
    }
  }

  Widget _timeStepper({
    required BuildContext context,
    required String value,
    VoidCallback? onMinus,
    VoidCallback? onPlus,
  }) {
    final theme = Theme.of(context);
    final textColor =
        (onMinus == null && onPlus == null) ? theme.disabledColor : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: onMinus,
            icon: const Icon(Icons.remove, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          IconButton(
            onPressed: onPlus,
            icon: const Icon(Icons.add, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }

  Widget _dayRow(String dayKey) {
    final isClosed = _workHours[dayKey] == null;
    final start = isClosed ? '--:--' : _workHours[dayKey]!['start']!;
    final end = isClosed ? '--:--' : _workHours[dayKey]!['end']!;

    final breakStart = (!isClosed) ? _workHours[dayKey]!['breakStart'] : null;
    final breakEnd = (!isClosed) ? _workHours[dayKey]!['breakEnd'] : null;
    final breakStartLabel = breakStart ?? '--:--';
    final breakEndLabel = breakEnd ?? '--:--';

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 520;

        final dayLabel = Text(
          _dayLabel(dayKey),
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        );

        final timeControls = Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            _timeStepper(
              context: context,
              value: start,
              onMinus: (_loading || isClosed)
                  ? null
                  : () => _adjustTime(dayKey, 'start', -10),
              onPlus: (_loading || isClosed)
                  ? null
                  : () => _adjustTime(dayKey, 'start', 10),
            ),
            const Text('-'),
            _timeStepper(
              context: context,
              value: end,
              onMinus: (_loading || isClosed)
                  ? null
                  : () => _adjustTime(dayKey, 'end', -10),
              onPlus: (_loading || isClosed)
                  ? null
                  : () => _adjustTime(dayKey, 'end', 10),
            ),
          ],
        );

        final closedControl = Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text('Cerrado'),
            Switch(
              value: isClosed,
              onChanged: _loading
                  ? null
                  : (v) {
                      setState(() {
                        if (v) {
                          _workHours[dayKey] = null;
                        } else {
                          _workHours[dayKey] = {
                            'start': '08:00',
                            'end': '18:00',
                          };
                        }
                      });
                      _dirty = true;
                      _ensureDayVisible(dayKey);
                    },
            ),
          ],
        );

        final header = isNarrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: dayLabel),
                      closedControl,
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.center,
                    child: timeControls,
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(flex: 3, child: dayLabel),
                  Expanded(
                    flex: 4,
                    child: Align(
                      alignment: Alignment.center,
                      child: timeControls,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: closedControl,
                    ),
                  ),
                ],
              );

        final breakRow = Wrap(
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            const Text(
              'Descanso',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            _timeStepper(
              context: context,
              value: breakStartLabel,
              onMinus: (_loading || isClosed)
                  ? null
                  : () => _adjustTime(dayKey, 'breakStart', -10),
              onPlus: (_loading || isClosed)
                  ? null
                  : () => _adjustTime(dayKey, 'breakStart', 10),
            ),
            const Text('-'),
            _timeStepper(
              context: context,
              value: breakEndLabel,
              onMinus: (_loading || isClosed)
                  ? null
                  : () => _adjustTime(dayKey, 'breakEnd', -10),
              onPlus: (_loading || isClosed)
                  ? null
                  : () => _adjustTime(dayKey, 'breakEnd', 10),
            ),
            IconButton(
              tooltip: 'Quitar descanso',
              onPressed:
                  (_loading || isClosed) ? null : () => _clearBreak(dayKey),
              icon: const Icon(Icons.close, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ],
        );

        return Container(
          key: _dayKeys[dayKey],
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              if (!isClosed && breakStart == null && breakEnd == null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _loading ? null : () => _addBreak(dayKey),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Agregar descanso'),
                  ),
                ),
              ] else if (!isClosed) ...[
                const SizedBox(height: 6),
                breakRow,
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _bypassConfirm || !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmExit(_settingsRef).then((ok) {
          if (ok && context.mounted) Navigator.pop(context);
        });
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Configuración'),
          actions: [
            IconButton(
              tooltip: 'Guardar',
              onPressed: _loading ? null : () => _save(_settingsRef),
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: StreamBuilder<DocumentSnapshot>(
              stream: _settingsStream,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Error: ${snap.error}'),
                  );
                }
                if (!snap.hasData || !snap.data!.exists) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No existe settings/default. Volvé a configurar el negocio.',
                    ),
                  );
                }

                final data = snap.data!.data() as Map<String, dynamic>;
                _loadFromDoc(data);

                return PageStorage(
                  bucket: _scrollBucket,
                  child: SingleChildScrollView(
                    key: const PageStorageKey<String>('settings_page_scroll'),
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _businessNameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nombre del negocio (opcional)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _serviceDescriptionCtrl,
                          maxLines: 2,
                          onChanged: (_) => _markDirtyIfNeeded(),
                          decoration: const InputDecoration(
                            labelText: 'Descripción del trabajo',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _sloganCtrl,
                          maxLines: 1,
                          onChanged: (_) => _markDirtyIfNeeded(),
                          decoration: const InputDecoration(
                            labelText: 'Eslogan',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),

                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _slotCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Turno por defecto (min)',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: _bufferCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Buffer (min)',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                      DropdownButtonFormField<int>(
                        initialValue: _maxConcurrent,
                        items: const [1, 2, 3]
                            .map(
                                (v) => DropdownMenuItem(
                                  value: v,
                                  child: Text('$v simultáneo(s)'),
                                ),
                              )
                              .toList(),
                          onChanged: _loading
                              ? null
                          : (v) {
                              setState(() => _maxConcurrent = v ?? 1);
                              _dirty = true;
                            },
                        decoration: const InputDecoration(
                          labelText: 'Atención simultánea',
                          border: OutlineInputBorder(),
                        ),
                      ),

                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: _themeMode,
                        items: const [
                          DropdownMenuItem(
                            value: 'light',
                            child: Text('Tema claro'),
                          ),
                          DropdownMenuItem(
                            value: 'dark',
                            child: Text('Tema oscuro'),
                          ),
                        ],
                        onChanged: _loading
                            ? null
                            : (v) {
                                setState(() => _themeMode = v ?? 'light');
                                _dirty = true;
                              },
                        decoration: const InputDecoration(
                          labelText: 'Tema',
                          border: OutlineInputBorder(),
                        ),
                      ),

                      const SizedBox(height: 16),
                      const Text(
                        'Horarios por día:',
                        style: TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 10),

                        for (final d in _days) _dayRow(d),

                        if (_error != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            _error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                        const SizedBox(height: 10),

                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
