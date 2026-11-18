# SIH-FARMACIA

SIH-FARMACIA es un sistema web para administrar el inventario farmacéutico de un hospital y mantener trazabilidad sobre cada movimiento de medicamento. Permite consultar existencias, detectar lotes próximos a caducar, registrar entradas y traslados, ejecutar salidas bajo la regla PEPS y revisar la bitácora de auditoría.

El proyecto está compuesto por una interfaz web en HTML y JavaScript, una API REST en Flask y una base de datos PostgreSQL. Flask sirve también la página y protege las operaciones mediante sesiones y roles.

## Funcionalidades generales

- Inicio de sesión con correo y contraseña.
- Menú con vistas seleccionadas según el rol del usuario.
- Consulta de indicadores y alertas de inventario.
- Registro de entradas de lotes nuevos o existentes.
- Traslado de existencias entre áreas.
- Dispensación de medicamentos con selección automática del lote que caduca primero.
- Alta y búsqueda de médicos y pacientes desde la pantalla de dispensación.
- Trazabilidad histórica de cualquier lote.
- Bitácora de movimientos con filtros y exportación CSV.
- Administración de usuarios.
- Protección tanto en el frontend como en la API y en PostgreSQL mediante roles.

El flujo operativo principal es:

1. El usuario inicia sesión y accede al monitor correspondiente a su perfil.
2. El personal autorizado registra la recepción de un lote o usa un lote ya existente.
3. El inventario queda asociado a una ubicación dentro del hospital.
4. Los medicamentos pueden trasladarse entre áreas.
5. Cuando se realiza una dispensación, el sistema verifica la cantidad disponible.
6. Para sustancias controladas exige médico y paciente.
7. El procedimiento PEPS descuenta primero los lotes con la fecha de caducidad más próxima.
8. La operación queda registrada en la base de datos y puede consultarse en trazabilidad y auditoría.

## Ventanas del sistema

### 1. Monitor de Inventario y Alertas

Es la vista inicial después del inicio de sesión.

Muestra:

- Cantidad total de insumos activos.
- Insumos que están por debajo del stock mínimo.
- Lotes próximos a caducar en 90, 60 y 30 días.
- Alertas pendientes.
- Estado general de disponibilidad.
- Botón para actualizar la información.

El Jefe de Farmacia puede generar nuevas alertas. Las demás vistas muestran el monitor sin esa opción.

### 2. Registro de Dispensación

Permite registrar la salida de un medicamento.

El formulario solicita:

- Insumo.
- Cantidad.
- Ubicación de origen.
- Área de destino, cuando corresponde.
- Médico y paciente.

Los médicos y pacientes pueden buscarse por nombre o identificador. La opción **+ Nuevo** permite abrir un diálogo y crear el registro sin salir de esta pantalla.

Para sustancias controladas, médico y paciente son obligatorios. El sistema valida que la cantidad solicitada no sea mayor al stock vigente. Al confirmar, PostgreSQL aplica PEPS y devuelve los lotes que fueron descontados.

Esta función está disponible para **Jefe de Farmacia** y **Dispensador**.

### 3. Trazabilidad y Control

Permite buscar un lote por su número.

Muestra su ubicación actual y el historial de:

- Existencia en inventario.
- Entradas.
- Traslados.
- Dispensaciones.
- Médico y paciente asociados, cuando existan y el perfil tenga permiso para verlos.

Es útil para retiros de mercado, controles sanitarios y auditorías.

### 4. Bitácora de Auditoría

Presenta los cambios registrados en el sistema en modo de solo lectura.

Permite filtrar por:

- Fecha desde y hasta.
- Usuario o proceso automático.
- Tabla modificada.
- Acción INSERT, UPDATE o DELETE.
- Sustancias controladas.

También permite navegar entre páginas y exportar los registros filtrados a CSV. Al hacer clic en una fila se puede consultar el detalle de los datos anteriores y nuevos.

Esta vista está disponible para **Jefe de Farmacia** y **Administrador**.

### 5. Entradas y Traslados

Esta ventana contiene dos operaciones.

#### Registrar entrada

Permite registrar la llegada de un medicamento mediante dos modalidades:

- **Lote nuevo:** captura insumo, proveedor, número de lote, fechas, precio y ubicación.
- **Lote existente:** agrega unidades a un lote que ya está registrado.

#### Trasladar

Permite mover unidades entre ubicaciones. El usuario selecciona insumo, cantidad, origen y destino. El sistema descuenta primero los lotes que caducan antes y muestra las existencias disponibles por ubicación.

Esta vista está disponible únicamente para **Jefe de Farmacia**.

### 6. Gestión de Usuarios

Permite al Administrador revisar los usuarios y su estado.

Las operaciones disponibles son:

- Crear usuario.
- Modificar nombre, correo y rol.
- Cambiar contraseña.
- Activar o desactivar usuario.

Los usuarios desactivados no pueden iniciar sesión. Esta función no elimina registros; conserva el historial de auditoría.

Esta vista está disponible para **Administrador** y no está disponible para el Jefe de Farmacia ni el Dispensador.

## Perfiles y permisos

La separación de permisos existe en tres niveles:

1. Menú visible en el frontend.
2. Validación de cada ruta en la API Flask.
3. Rol activo dentro de PostgreSQL mediante `SET LOCAL ROLE`.

### Dispensador

Función principal: atender la salida de medicamentos.

Puede acceder a:

- Monitor de Inventario y Alertas.
- Registro de Dispensación.
- Trazabilidad y Control.

Puede realizar:

- Buscar y dar de alta médicos.
- Buscar y dar de alta pacientes.
- Consultar insumos y existencias.
- Registrar dispensaciones.

No puede acceder a:

- Entradas y Traslados.
- Bitácora de Auditoría.
- Gestión de Usuarios.

### Jefe de Farmacia

Función principal: controlar el inventario, entradas, movimientos y operación general.

Puede acceder a:

- Monitor de Inventario y Alertas.
- Registro de Dispensación.
- Trazabilidad y Control.
- Entradas y Traslados.
- Bitácora de Auditoría.

Puede realizar:

- Generar alertas.
- Registrar entradas de lotes nuevos o existentes.
- Trasladar existencias.
- Registrar dispensaciones.
- Dar de alta y actualizar médicos y pacientes.
- Consultar filtros de usuarios y roles en auditoría.
- Exportar y filtrar la bitácora.

No puede acceder a:

- Gestión de Usuarios.

### Administrador

Función principal: administrar cuentas y supervisar la auditoría.

Puede acceder a:

- Monitor de Inventario y Alertas.
- Trazabilidad y Control.
- Bitácora de Auditoría.
- Gestión de Usuarios.

Puede realizar:

- Crear, editar, activar o desactivar usuarios.
- Cambiar contraseñas.
- Cambiar roles autorizados.
- Consultar y exportar la bitácora.
- Aplicar filtros de auditoría.

No puede acceder a:

- Registro de Dispensación.
- Entradas y Traslados.

Los datos personales dentro de ciertos procesos pueden mostrarse restringidos según el nivel de privilegio.

## Seguridad y auditoría

Cada operación autenticada conserva información del usuario y la dirección IP desde la que fue ejecutada. PostgreSQL registra los movimientos a través de funciones y mecanismos de auditoría.

Además:

- Las rutas sensibles validan los roles permitidos.
- Las operaciones usan transacciones con `SET LOCAL ROLE`.
- Las funciones críticas usan permisos explícitos.
- Las consultas usan parámetros para reducir el riesgo de inyección SQL.
- Las contraseñas se almacenan con hash.
- Las sesiones duran hasta ocho horas y usan cookies HTTP-only.
- Los fallos de conexión o PostgreSQL se muestran mediante alertas globales.

## Tecnologías

- HTML5.
- JavaScript.
- Tailwind CSS mediante CDN.
- Flask.
- Python.
- PostgreSQL.
- psycopg y psycopg_pool.
- Flask sessions.
- bcrypt.

## Estructura principal

```text
SIH-FARMACIA/
├── index.html                 Página principal y ventanas
├── app.js                     Navegación, formularios y llamadas API
├── styles.css                 Estilos adicionales
├── backend/
│   ├── app.py                 Inicio de Flask y rutas web
│   ├── api.py                 Endpoints REST
│   ├── auth.py                Inicio y cierre de sesión
│   └── db.py                  Pool y roles de PostgreSQL
├── db/
│   ├── respaldo_farmacia.sql  Respaldo y estructura de la base
│   ├── 13_datos_demo.sql      Datos de demostración
│   └── correccion_permisos.sql Corrección adicional de permisos
└── README.md
```

## Configuración

1. Requiere PostgreSQL y Python.

2. Configura en `.env` la cadena de conexión PostgreSQL y una clave secreta propia.

```text
DATABASE_URL=postgresql://app_backend:CLAVE@localhost:5432/sih_farmacia
SECRET_KEY=CLAVE_LARGA_Y_ALEATORIA
FLASK_DEBUG=1
COOKIE_SECURE=0
```

3. Restaura o crea la base de datos con los archivos SQL de la carpeta `db`.

4. Instala las dependencias del backend:

```powershell o terminal de vsc
cd backend
py -m pip install -r requirements.txt
```
5. Ejecuta el servidor:

```powershell o terminal de vsc
py app.py
```

6. Abre la aplicación en:

```text
http://localhost:5000
```

## Regla PEPS

PEPS significa que los medicamentos se dispensan o trasladan siguiendo el principio de caducidad más próxima. El sistema identifica los lotes vigentes y comienza a descontar unidades del lote cuya fecha de caducidad sea anterior. No entrega lotes caducados.