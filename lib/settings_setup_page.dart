import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

enum _ExitAction { save, discard, cancel }

class SettingsSetupPage extends StatefulWidget {
  const SettingsSetupPage({super.key});

  @override
  State<SettingsSetupPage> createState() => _SettingsSetupPageState();
}

class _SettingsSetupPageState extends State<SettingsSetupPage> {
  final _businessNameCtrl = TextEditingController();
  final _serviceDescriptionCtrl = TextEditingController();
  final _sloganCtrl = TextEditingController();
  final _slotCtrl = TextEditingController(text: '30');
  final _bufferCtrl = TextEditingController(text: '0');
  final ScrollController _scrollCtrl = ScrollController();
  final PageStorageBucket _scrollBucket = PageStorageBucket();

  int _maxConcurrent = 1;
  String _themeMode = 'light';

  bool _loading = false;
  bool _dirty = false;
  bool _bypassConfirm = false;
  String? _error;
  late final Map<String, GlobalKey> _dayKeys;

  final _days = const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

  // Si un día está cerrado => value = null
  final Map<String, Map<String, String>?> _workHours = {
    'mon': {'start': '08:00', 'end': '18:00'},
    'tue': {'start': '08:00', 'end': '18:00'},
    'wed': {'start': '08:00', 'end': '18:00'},
    'thu': {'start': '08:00', 'end': '18:00'},
    'fri': {'start': '08:00', 'end': '18:00'},
    'sat': {'start': '08:00', 'end': '12:00'},
    'sun': null, // cerrado por defecto
  };

  @override
  void initState() {
    super.initState();
    _dayKeys = {for (final d in _days) d: GlobalKey()};
    _businessNameCtrl.addListener(_markDirty);
    _serviceDescriptionCtrl.addListener(_markDirty);
    _sloganCtrl.addListener(_markDirty);
    _slotCtrl.addListener(_markDirty);
    _bufferCtrl.addListener(_markDirty);
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

  void _markDirty() {
    _dirty = true;
    _bypassConfirm = false;
  }

  void _ensureDayVisible(String dayKey) {
    final key = _dayKeys[dayKey];
    if (key == null) return;
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

  Future<void> _pickTime(String day, String field) async {
    final dayMap = _workHours[day];
    if (dayMap == null) return;

    final current = dayMap[field] ?? '08:00';
    final parts = current.split(':');
    final initial = TimeOfDay(
      hour: int.parse(parts[0]),
      minute: int.parse(parts[1]),
    );

    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: 'Seleccionar hora',
      cancelText: 'Cancelar',
      confirmText: 'Aceptar',
    );

    if (picked != null) {
      final hh = picked.hour.toString().padLeft(2, '0');
      final mm = picked.minute.toString().padLeft(2, '0');
      setState(() => _workHours[day]![field] = '$hh:$mm');
      _dirty = true;
      _ensureDayVisible(day);
    }
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

  Future<bool> _save() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('No hay usuario autenticado.');

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

      // Validar horarios por día abierto
      for (final entry in _workHours.entries) {
        final day = entry.key;
        final v = entry.value;
        if (v == null) continue; // cerrado
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
      }

      final settingsRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('settings')
          .doc('default');

      await settingsRef.set({
        'businessName': _businessNameCtrl.text.trim(),
        'serviceDescription': _serviceDescriptionCtrl.text.trim(),
        'slogan': _sloganCtrl.text.trim(),
        'themeMode': _themeMode,
        'timezone': 'America/Asuncion',
        'slotMinutesDefault': slot,
        'bufferMinutes': buffer,
        'maxConcurrentAppointments': _maxConcurrent,
        'workHours': _workHours, // maps o null
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _dirty = false;
      return true;
    } catch (e) {
      setState(() => _error = e.toString());
      return false;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _confirmExit() async {
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
        final ok = await _save();
        if (ok && mounted) {
          _bypassConfirm = true;
          Navigator.pop(context);
        }
        return false;
      case _ExitAction.discard:
        return true;
      case _ExitAction.cancel:
      default:
        return false;
    }
  }

  Widget _dayCard(String dayKey) {
    final isClosed = _workHours[dayKey] == null;
    final start = isClosed ? '--:--' : _workHours[dayKey]!['start']!;
    final end = isClosed ? '--:--' : _workHours[dayKey]!['end']!;

    final breakStart = (!isClosed) ? _workHours[dayKey]!['breakStart'] : null;
    final breakEnd = (!isClosed) ? _workHours[dayKey]!['breakEnd'] : null;

    String breakLabel() {
      if (breakStart == null && breakEnd == null) return '--:-- - --:--';
      final left = breakStart ?? '--:--';
      final right = breakEnd ?? '--:--';
      return '$left - $right';
    }

    return Card(
      key: _dayKeys[dayKey],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _dayLabel(dayKey),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Row(
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
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('Horario: $start - $end',
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            Text('Descanso: ${breakLabel()}',
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 10),

            // Horario principal
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: (_loading || isClosed)
                        ? null
                        : () => _pickTime(dayKey, 'start'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: const Size(0, 36),
                    ),
                    child: const Text('Inicio'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: (_loading || isClosed)
                        ? null
                        : () => _pickTime(dayKey, 'end'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: const Size(0, 36),
                    ),
                    child: const Text('Fin'),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Descanso
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: (_loading || isClosed)
                        ? null
                        : () => _pickTime(dayKey, 'breakStart'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: const Size(0, 36),
                    ),
                    child: const Text('Descanso inicio'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: (_loading || isClosed)
                        ? null
                        : () => _pickTime(dayKey, 'breakEnd'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: const Size(0, 36),
                    ),
                    child: const Text('Descanso fin'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Quitar descanso',
                  onPressed: (_loading || isClosed)
                      ? null
                      : () => _clearBreak(dayKey),
                  icon: const Icon(Icons.close),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _bypassConfirm || !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmExit().then((ok) {
          if (ok && context.mounted) Navigator.pop(context);
        });
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Configurar negocio'),
          actions: [
            IconButton(
              tooltip: 'Cerrar sesión',
              icon: const Icon(Icons.logout),
              onPressed: () => FirebaseAuth.instance.signOut(),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: PageStorage(
              bucket: _scrollBucket,
              child: SingleChildScrollView(
                key: const PageStorageKey<String>('settings_setup_scroll'),
                controller: _scrollCtrl,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Primera vez: configurá duración, simultáneos y horarios.',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 16),

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
                      onChanged: (_) => _markDirty(),
                      decoration: const InputDecoration(
                        labelText: 'Descripción del trabajo',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _sloganCtrl,
                      maxLines: 1,
                      onChanged: (_) => _markDirty(),
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
                              labelText: 'Duración por defecto (min)',
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
                              labelText: 'Buffer entre turnos (min)',
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

                  const SizedBox(height: 12),
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

                  const SizedBox(height: 20),
                  const Text(
                    'Horarios por día:',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 8),

                    ..._days.map(_dayCard),

                    const SizedBox(height: 12),
                    if (_error != null) ...[
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 8),
                    ],

                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _loading ? null : _save,
                        child: Text(
                          _loading ? 'Guardando...' : 'Guardar configuración',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
