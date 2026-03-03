import 'package:flutter/material.dart';

class UserGuidePage extends StatelessWidget {
  const UserGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Guia de uso')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _GuideSection(
            title: '1. Configuracion inicial (primera vez)',
            items: [
              'Inicia sesion con Google o Apple.',
              'Si aparece "Configurar negocio", completalo antes de usar la agenda.',
              'En "Nombre del negocio", escribe como quieres que te vean los clientes.',
              'En "Descripcion" y "Eslogan", escribe un texto corto (opcional).',
              'En "Turno (min)", define la duracion normal de tus atenciones.',
              'En "Buffer", define minutos de pausa entre un cliente y otro (si aplica).',
              'En "Atencion simultanea", elige cuantas personas puedes atender al mismo tiempo.',
              'En "Horarios por dia", marca dias cerrados y ajusta inicio, fin y descanso.',
              'Toca "Guardar configuracion".',
            ],
          ),
          SizedBox(height: 12),
          _GuideSection(
            title: '2. Apertura del dia',
            items: [
              'Abre la app y revisa que estas en la fecha correcta.',
              'Toca "Hoy" para volver al dia actual.',
              'Si necesitas cambiar de fecha, usa Anterior, Siguiente o Calendario.',
              'Si quieres buscar rapidamente un hueco, toca "Proximo libre".',
              'Revisa el resumen del dia (confirmados, concretados, cancelados y cobrado).',
            ],
          ),
          SizedBox(height: 12),
          _GuideSection(
            title: '3. Crear un turno nuevo (paso a paso)',
            items: [
              'Toca un horario libre en la lista.',
              'En la ventana del horario, toca "Agregar turno".',
              'Escribe el nombre del cliente (obligatorio).',
              'Ajusta la duracion si ese cliente necesita mas o menos tiempo.',
              'Agrega notas solo si hace falta (ejemplo: servicio solicitado).',
              'Toca "Guardar".',
              'Si quieres avisar al cliente al instante, usa el icono de compartir para WhatsApp.',
            ],
          ),
          SizedBox(height: 12),
          _GuideSection(
            title: '4. Editar, reagendar o cancelar',
            items: [
              'Toca el horario donde esta el cliente.',
              'Toca el nombre del cliente para abrir la edicion.',
              'Si debes mover la cita, usa el icono de calendario y elige nueva fecha/hora.',
              'Si cambio el servicio, ajusta la duracion.',
              'Si no asistio o suspendio, cambia estado a "Cancelado".',
              'Toca "Guardar" para confirmar cambios.',
            ],
          ),
          SizedBox(height: 12),
          _GuideSection(
            title: '5. Estados y cobro (cuando usar cada uno)',
            items: [
              'Usa "Confirmado" cuando el turno esta reservado.',
              'Usa "Concretado" cuando el cliente ya fue atendido.',
              'Usa "Cancelado" cuando el turno ya no se realizara.',
              'Si marcas "Concretado", carga el monto cobrado para que entre al balance.',
              'Si no cargas cobro, ese turno puede no reflejarse en el total financiero.',
            ],
          ),
          SizedBox(height: 12),
          _GuideSection(
            title: '6. Compartir disponibilidad por WhatsApp',
            items: [
              'Toca el boton "Disponibles".',
              'Elige "Texto WhatsApp - dia" para enviar solo hoy.',
              'Elige "Texto WhatsApp - semana" para enviar proximos 7 dias.',
              'Tambien puedes generar imagen para publicar en estados o redes.',
            ],
          ),
          SizedBox(height: 12),
          _GuideSection(
            title: '7. Cierre del dia (checklist)',
            items: [
              'Revisa que todos los turnos tengan estado correcto.',
              'Confirma que los cobros esten cargados.',
              'Abre "Balance financiero" para revisar lo cobrado.',
              'Cierra sesion al terminar.',
            ],
          ),
          SizedBox(height: 12),
          _GuideSection(
            title: '8. Ajustes cuando cambia tu rutina',
            items: [
              'Si cambias horarios o dias de trabajo, entra a Configuracion.',
              'Actualiza "Turno (min)" si cambias la duracion habitual.',
              'Actualiza cupos en "Atencion simultanea" si atiendes mas o menos personas.',
              'Guarda siempre antes de salir.',
            ],
          ),
        ],
      ),
    );
  }
}

class _GuideSection extends StatelessWidget {
  final String title;
  final List<String> items;

  const _GuideSection({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            for (int i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${i + 1}. ${items[i]}'),
              ),
          ],
        ),
      ),
    );
  }
}
