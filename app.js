// ---------------------------------------------------------------
// Utilidad para llamar a la API (misma URL que sirve la página)
// ---------------------------------------------------------------
async function api(ruta, opciones = {}) {
    let resp;
    try {
        resp = await fetch('/api' + ruta, {
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            ...opciones,
        });
    } catch (_) {
        const msg = 'Falla de conexión con el servidor. Verifica que el sistema y PostgreSQL estén activos.';
        mostrarAlertaGlobal(msg);
        throw new Error(msg);
    }
    let datos = null;
    try { datos = await resp.json(); } catch (_) { /* respuesta sin cuerpo */ }
    if (!resp.ok) {
        const msg = (datos && datos.error) ||
            (resp.status >= 500
                ? `Falla interna del sistema (${resp.status}). Revisa la base de datos o intenta de nuevo.`
                : `Error en la solicitud (${resp.status}).`);
        if (resp.status >= 500) mostrarAlertaGlobal(msg);
        const error = new Error(msg);
        error.status = resp.status;
        throw error;
    }
    ocultarAlertaGlobal();
    return datos;
}

function mostrarAlertaGlobal(msg) {
    const box = document.getElementById('global-alert');
    if (!box) return;
    document.getElementById('global-alert-msg').textContent = '⚠ ' + msg;
    box.classList.remove('hidden');
}

function ocultarAlertaGlobal() {
    const box = document.getElementById('global-alert');
    if (box) box.classList.add('hidden');
}

// ---------------------------------------------------------------
// Login / sesión
// ---------------------------------------------------------------
// Vistas que NO debe ver cada rol (la API también las bloquea)
const VISTAS_OCULTAS = {
    'Dispensador':      ['audit', 'entries', 'users'],
    'Administrador':    ['dispensation', 'entries'],
    'Jefe de Farmacia': ['users'],
};

function mostrarApp(usuario) {
    window.usuarioActual = usuario;
    document.getElementById('rol-usuario').textContent = 'ROL: ' + usuario.rol;

    // Menú según el rol
    const ocultas = VISTAS_OCULTAS[usuario.rol] || [];
    document.querySelectorAll('#nav-select option').forEach(op => {
        op.hidden = op.disabled = ocultas.includes(op.value);
    });
    document.getElementById('mon-generar').classList.toggle('hidden', usuario.rol !== 'Jefe de Farmacia');
    document.getElementById('nav-select').value = 'monitor';
    switchView('monitor');

    const loginView = document.getElementById('view-login');
    loginView.classList.add('hidden');
    document.getElementById('app-container').classList.remove('hidden');
}

function mostrarLogin() {
    const loginView = document.getElementById('view-login');
    loginView.style.opacity = '1';
    loginView.classList.remove('hidden');
    document.getElementById('app-container').classList.add('hidden');
    document.getElementById('password').value = '';
}

async function handleLogin(event) {
    event.preventDefault();
    const correo = document.getElementById('username').value.trim();
    const password = document.getElementById('password').value;
    const error = document.getElementById('login-error');
    const boton = document.getElementById('login-btn');

    if (!correo || !password) {
        error.textContent = 'Faltan datos: ingresa tu correo y contraseña.';
        error.classList.remove('hidden');
        return;
    }
    error.classList.add('hidden');
    boton.disabled = true;
    boton.textContent = 'Verificando...';
    try {
        const usuario = await api('/login', {
            method: 'POST',
            body: JSON.stringify({ correo, password }),
        });
        mostrarApp(usuario);
    } catch (e) {
        error.textContent = e.message;
        error.classList.remove('hidden');
        document.getElementById('password').value = '';
    } finally {
        boton.disabled = false;
        boton.textContent = 'Ingresar al Sistema';
    }
}

async function cerrarSesion() {
    try { await api('/logout', { method: 'POST' }); } catch (_) { /* da igual */ }
    window.usuarioActual = null;
    mostrarLogin();
}

// Si ya hay una sesión activa (por ejemplo al recargar la página), entrar directo
document.addEventListener('DOMContentLoaded', async () => {
    try {
        mostrarApp(await api('/me'));
    } catch (_) {
        mostrarLogin();
    }
});

// ---------------------------------------------------------------
// MONITOR DE INVENTARIO Y ALERTAS
// ---------------------------------------------------------------
const esc = s => String(s ?? '').replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const fmtFecha = iso => String(iso).slice(0, 10).split('-').reverse().join('/');
const esJefe = () => window.usuarioActual && window.usuarioActual.rol === 'Jefe de Farmacia';

const NIVELES = {
    CADUCADO:     { texto: 'Caducado', clase: 'bg-red-600 text-white border-red-700' },
    CADUCIDAD_30: { texto: '≤ 30 días', clase: 'bg-red-50 text-red-700 border-red-500' },
    CADUCIDAD_60: { texto: '≤ 60 días', clase: 'bg-orange-50 text-orange-700 border-orange-400' },
    CADUCIDAD_90: { texto: '≤ 90 días', clase: 'bg-yellow-50 text-yellow-700 border-yellow-400' },
};
const ICONO_ALERTA = {
    STOCK_MINIMO: '📉', CADUCADO: '⛔',
    CADUCIDAD_30: '🕒', CADUCIDAD_60: '🕒', CADUCIDAD_90: '🕒',
};

function mostrarErrorMonitor(msg) {
    const el = document.getElementById('mon-error');
    el.textContent = msg;
    el.classList.toggle('hidden', !msg);
}

async function cargarMonitor() {
    try {
        const [m, alertas] = await Promise.all([api('/monitor'), api('/alertas')]);
        mostrarErrorMonitor('');
        pintarKpis(m.kpi);
        pintarReorden(m.reorden);
        pintarCaducidad(m.por_caducar);
        pintarAlertas(alertas);
        document.getElementById('mon-actualizado').textContent =
            new Date().toLocaleTimeString('es-MX');
    } catch (e) {
        if (e.status === 401) return mostrarLogin();   // la sesión expiró
        mostrarErrorMonitor('No se pudo actualizar el monitor: ' + e.message);
    }
}

function pintarKpis(k) {
    document.getElementById('kpi-total').textContent = Number(k.total_insumos).toLocaleString('es-MX');
    document.getElementById('kpi-bajo').textContent = k.insumos_bajo_minimo;
    document.getElementById('kpi-bajo-sub').textContent =
        k.insumos_bajo_minimo > 0 ? '⚡ Notificado a Compras' : '✓ Sin faltantes';
    document.getElementById('kpi-caduca').textContent = k.lotes_caducan_30d;
    document.getElementById('kpi-caduca-sub').textContent =
        k.lotes_caducados > 0
            ? '⛔ ' + k.lotes_caducados + ' lote(s) ya caducado(s) con stock'
            : '⏳ Prioridad de salida (PEPS)';
    document.getElementById('kpi-disp').textContent =
        k.disponibilidad_pct === null ? '—' : k.disponibilidad_pct + '%';
}

function pintarReorden(filas) {
    document.getElementById('reorden-count').textContent = filas.length;
    const tbody = document.getElementById('tabla-reorden');
    if (!filas.length) {
        tbody.innerHTML = '<tr><td colspan="6" class="p-4 text-center text-teal-700 font-bold">✓ Ningún insumo por debajo del mínimo</td></tr>';
        return;
    }
    tbody.innerHTML = filas.map(f => {
        const critico = f.estado === 'ALERTA_COMPRAS';
        const badge = critico
            ? '<span class="border border-red-500 text-red-700 bg-red-50 px-2 py-1 text-xs font-bold">Alerta Compras</span>'
            : '<span class="border border-yellow-500 text-yellow-700 bg-yellow-50 px-2 py-1 text-xs font-bold">Reorden Pendiente</span>';
        return `<tr class="border-b border-slate-200">
            <td class="p-3 font-bold">${esc(f.codigo_insumo)}</td>
            <td class="p-3">${esc(f.descripcion_farmaco)}</td>
            <td class="p-3">${esc(f.ubicacion_actual || '—')}</td>
            <td class="p-3 text-center font-bold ${critico ? 'text-red-600' : 'text-yellow-700'}">${f.stock} und.</td>
            <td class="p-3 text-center text-slate-500">${f.minimo} und.</td>
            <td class="p-3 text-center">${badge}</td>
        </tr>`;
    }).join('');
}

function pintarCaducidad(filas) {
    document.getElementById('caducidad-count').textContent = filas.length;
    const tbody = document.getElementById('tabla-caducidad');
    if (!filas.length) {
        tbody.innerHTML = '<tr><td colspan="4" class="p-4 text-center text-teal-700 font-bold">✓ Sin lotes próximos a caducar</td></tr>';
        return;
    }
    tbody.innerHTML = filas.map(f => {
        const n = NIVELES[f.nivel] || NIVELES.CADUCIDAD_90;
        const dias = f.dias_para_caducar < 0
            ? 'hace ' + Math.abs(f.dias_para_caducar) + ' d'
            : 'en ' + f.dias_para_caducar + ' d';
        return `<tr class="border-b border-slate-200">
            <td class="p-3"><div class="font-bold">${esc(f.numero_lote)}</div>
                <div class="text-xs text-slate-500">${esc(f.descripcion_farmaco)}</div></td>
            <td class="p-3 text-center">${fmtFecha(f.fecha_caducidad)}
                <div class="text-xs text-slate-500">${dias}</div></td>
            <td class="p-3 text-center font-bold">${f.stock_total}</td>
            <td class="p-3 text-center"><span class="border px-2 py-1 text-xs font-bold ${n.clase}">${n.texto}</span></td>
        </tr>`;
    }).join('');
}

function pintarAlertas(alertas) {
    document.getElementById('alertas-count').textContent = alertas.length;
    const ul = document.getElementById('lista-alertas');
    if (!alertas.length) {
        ul.innerHTML = '<li class="p-4 text-center text-teal-700 font-bold text-sm">✓ Sin alertas pendientes</li>';
        return;
    }
    ul.innerHTML = alertas.map(a => `<li class="p-3 flex items-start gap-3">
        <span class="text-xl">${ICONO_ALERTA[a.tipo] || '🔔'}</span>
        <div class="flex-1 min-w-0">
            <div class="text-sm">${esc(a.mensaje)}</div>
            <div class="text-xs text-slate-400 font-mono mt-1">${new Date(a.fecha_generada).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' })}</div>
        </div>
        ${esJefe() ? `<button onclick="atenderAlerta(${Number(a.id_alerta)})" class="shrink-0 border-2 border-slate-800 px-2 py-1 text-xs font-bold uppercase hover:bg-slate-100">Atender</button>` : ''}
    </li>`).join('');
}

async function atenderAlerta(id) {
    try {
        await api('/alertas/' + id + '/atender', { method: 'POST' });
        await cargarMonitor();
    } catch (e) {
        mostrarErrorMonitor(e.message);
    }
}

async function generarAlertas() {
    const btn = document.getElementById('mon-generar');
    btn.disabled = true;
    try {
        const r = await api('/alertas/generar', { method: 'POST' });
        await cargarMonitor();
        mostrarErrorMonitor('');
        btn.textContent = '✓ ' + r.nuevas + ' nueva(s)';
        setTimeout(() => { btn.textContent = '⚡ Generar alertas'; }, 2500);
    } catch (e) {
        mostrarErrorMonitor(e.message);
    } finally {
        btn.disabled = false;
    }
}

// Refresco automático cada 60 s, solo si el Monitor está a la vista
setInterval(() => {
    const vista = document.getElementById('view-monitor');
    if (window.usuarioActual && vista && !vista.classList.contains('hidden')) cargarMonitor();
}, 60000);

// ---------------------------------------------------------------
// REGISTRO DE DISPENSACIÓN
// ---------------------------------------------------------------
let insumosDisp = {};          // id_insumo -> datos del insumo
const historialDisp = [];      // salidas hechas en esta sesión

async function cargarDispensacion() {
    try {
        const c = await api('/catalogos');
        insumosDisp = {};
        c.insumos.forEach(i => { insumosDisp[i.id_insumo] = i; });

        // Insumos (se conserva la selección actual al recargar)
        const selInsumo = document.getElementById('disp-insumo');
        const previo = selInsumo.value;
        selInsumo.innerHTML = '<option value="">— Selecciona un insumo —</option>' +
            c.insumos.map(i => {
                const sinStock = i.stock_vigente <= 0;
                const texto = `${i.descripcion_farmaco} (${i.codigo_insumo})` +
                    (i.es_controlado ? ' ⚠ Controlado' : '') +
                    (sinStock ? ' — sin stock' : ` — ${i.stock_vigente} disp.`);
                return `<option value="${i.id_insumo}" ${sinStock ? 'disabled' : ''}>${esc(texto)}</option>`;
            }).join('');
        if (previo && insumosDisp[previo] && insumosDisp[previo].stock_vigente > 0) selInsumo.value = previo;

        // Ubicaciones: origen (obligatorio) y destino (opcional)
        const opcionesUbic = c.ubicaciones.map(u =>
            `<option value="${u.id_ubicacion}">${esc(u.nombre_area)}${u.anaquel_seccion ? ' · ' + esc(u.anaquel_seccion) : ''}</option>`).join('');
        const selOrigen = document.getElementById('disp-origen');
        const origenPrevio = selOrigen.value;
        selOrigen.innerHTML = opcionesUbic;
        if (origenPrevio) {
            selOrigen.value = origenPrevio;
        } else {
            const central = c.ubicaciones.find(u => /central/i.test(u.nombre_area));
            if (central) selOrigen.value = central.id_ubicacion;
        }
        const selDestino = document.getElementById('disp-destino');
        const destinoPrevio = selDestino.value;
        selDestino.innerHTML = '<option value="">— Sin destino —</option>' + opcionesUbic;
        selDestino.value = destinoPrevio;

        actualizarInfoInsumo();
    } catch (e) {
        if (e.status === 401) return mostrarLogin();
        mostrarErrorDisp('No se pudo cargar el catálogo: ' + e.message);
    }
}

function actualizarInfoInsumo() {
    const i = insumosDisp[document.getElementById('disp-insumo').value];
    const info = document.getElementById('disp-insumo-info');
    const controlado = !!(i && i.es_controlado);
    if (!i) {
        info.innerHTML = '&nbsp;';
        info.className = 'text-xs font-mono mt-1 text-slate-500';
    } else if (controlado) {
        info.textContent = '⚠ Sustancia controlada: médico y paciente son obligatorios.';
        info.className = 'text-xs font-mono mt-1 text-red-600 font-bold';
    } else {
        info.textContent = `Stock vigente total: ${i.stock_vigente}`;
        info.className = 'text-xs font-mono mt-1 text-slate-500';
    }
    document.getElementById('disp-medico-req').textContent = controlado ? '*' : '';
    document.getElementById('disp-paciente-req').textContent = controlado ? '*' : '';
}

function mostrarErrorDisp(msg) {
    const el = document.getElementById('disp-error');
    el.textContent = msg;
    el.classList.toggle('hidden', !msg);
}

// ---- Buscador con autocompletado (médicos y pacientes) ----
function crearBuscador(prefijo, ruta, etiqueta, detalle) {
    const input = document.getElementById(`disp-${prefijo}-q`);
    const lista = document.getElementById(`disp-${prefijo}-lista`);
    let temporizador = null;
    let resultados = [];

    const cerrar = () => lista.classList.add('hidden');
    const limpiarSeleccion = () => {
        delete input.dataset.id;
        input.classList.remove('border-emerald-500');
    };
    const buscar = async (q) => {
        try {
            resultados = await api(`/${ruta}?q=${encodeURIComponent(q)}`);
            lista.innerHTML = resultados.length
                ? resultados.map((r, n) => `<li><button type="button" data-n="${n}" class="w-full text-left p-2 hover:bg-slate-100 border-b border-slate-200">
                        <div class="text-sm font-bold">${esc(etiqueta(r))}</div>
                        <div class="text-xs text-slate-500">${esc(detalle(r))}</div></button></li>`).join('')
                : '<li class="p-2 text-xs text-slate-400">Sin coincidencias. Usa "+ Nuevo" para registrarlo.</li>';
            lista.classList.remove('hidden');
        } catch (e) {
            cerrar();
            mostrarErrorDisp(`No se pudo consultar ${ruta}: ${e.message}`);
        }
    };

    input.addEventListener('focus', () => {
        if (!input.dataset.id) buscar(input.value.trim());
    });
    input.addEventListener('input', () => {
        limpiarSeleccion();
        clearTimeout(temporizador);
        temporizador = setTimeout(() => buscar(input.value.trim()), 200);
    });

    lista.addEventListener('click', ev => {
        const btn = ev.target.closest('button[data-n]');
        if (!btn) return;
        const r = resultados[Number(btn.dataset.n)];
        input.value = etiqueta(r);
        input.dataset.id = r[`id_${prefijo}`];
        input.classList.add('border-emerald-500');
        cerrar();
    });
    document.addEventListener('click', ev => {
        if (!lista.contains(ev.target) && ev.target !== input) cerrar();
    });
}

crearBuscador('medico', 'medicos',
    m => `${m.nombre}`, m => `Cédula ${m.cedula_profesional}${m.especialidad ? ' · ' + m.especialidad : ''}`);
crearBuscador('paciente', 'pacientes',
    p => `${p.nombre}`, p => `Expediente ${p.expediente_folio}${p.area_ingreso ? ' · ' + p.area_ingreso : ''}`);

async function guardarMedico(event) {
    event.preventDefault();
    const error = document.getElementById('med-error');
    const cedula = document.getElementById('med-cedula').value.trim();
    const nombre = document.getElementById('med-nombre').value.trim();
    const especialidad = document.getElementById('med-especialidad').value.trim();
    error.classList.add('hidden');
    if (!cedula || !nombre) {
        error.textContent = 'Captura la cédula profesional y el nombre.';
        error.classList.remove('hidden');
        return;
    }
    try {
        const medico = await api('/medicos', {
            method: 'POST',
            body: JSON.stringify({ cedula_profesional: cedula, nombre, especialidad }),
        });
        const input = document.getElementById('disp-medico-q');
        input.value = medico.nombre;
        input.dataset.id = medico.id_medico;
        input.classList.add('border-emerald-500');
        document.getElementById('dlg-medico').close();
        event.target.reset();
    } catch (e) {
        error.textContent = e.message;
        error.classList.remove('hidden');
    }
}

async function guardarPaciente(event) {
    event.preventDefault();
    const error = document.getElementById('pac-error');
    const expediente = document.getElementById('pac-expediente').value.trim();
    const nombre = document.getElementById('pac-nombre').value.trim();
    const area_ingreso = document.getElementById('pac-area').value.trim();
    error.classList.add('hidden');
    if (!expediente || !nombre) {
        error.textContent = 'Captura el expediente/folio y el nombre.';
        error.classList.remove('hidden');
        return;
    }
    try {
        const paciente = await api('/pacientes', {
            method: 'POST',
            body: JSON.stringify({ expediente_folio: expediente, nombre, area_ingreso }),
        });
        const input = document.getElementById('disp-paciente-q');
        input.value = paciente.nombre;
        input.dataset.id = paciente.id_paciente;
        input.classList.add('border-emerald-500');
        document.getElementById('dlg-paciente').close();
        event.target.reset();
    } catch (e) {
        error.textContent = e.message;
        error.classList.remove('hidden');
    }
}

// ---- Envío del formulario ----
async function ejecutarDispensacion(event) {
    event.preventDefault();
    mostrarErrorDisp('');

    const idInsumo = document.getElementById('disp-insumo').value;
    const cantidad = parseInt(document.getElementById('disp-cantidad').value, 10);
    const origen = document.getElementById('disp-origen').value;
    const destino = document.getElementById('disp-destino').value;
    const inMedico = document.getElementById('disp-medico-q');
    const inPaciente = document.getElementById('disp-paciente-q');
    const idMedico = inMedico.dataset.id || null;
    const idPaciente = inPaciente.dataset.id || null;
    const insumo = insumosDisp[idInsumo];

    if (!insumo) return mostrarErrorDisp('Selecciona el insumo.');
    if (!Number.isInteger(cantidad) || cantidad <= 0) return mostrarErrorDisp('Escribe una cantidad mayor a cero.');
    if (cantidad > insumo.stock_vigente)
        return mostrarErrorDisp(`Stock vigente insuficiente (disponible: ${insumo.stock_vigente}).`);
    if (!origen) return mostrarErrorDisp('Indica de dónde sale el medicamento.');
    if (inMedico.value.trim() && !idMedico) return mostrarErrorDisp('Elige al médico de la lista de resultados.');
    if (inPaciente.value.trim() && !idPaciente) return mostrarErrorDisp('Elige al paciente de la lista de resultados.');
    if (insumo.es_controlado && (!idMedico || !idPaciente))
        return mostrarErrorDisp('Sustancia controlada: elige médico y paciente.');

    const boton = document.getElementById('disp-btn');
    const textoBoton = document.getElementById('disp-btn-texto');
    boton.disabled = true;
    textoBoton.textContent = 'REGISTRANDO…';
    try {
        const r = await api('/dispensaciones', {
            method: 'POST',
            body: JSON.stringify({
                id_insumo: Number(idInsumo),
                cantidad,
                id_ubicacion_origen: Number(origen),
                id_ubicacion_destino: destino ? Number(destino) : null,
                id_medico: idMedico ? Number(idMedico) : null,
                id_paciente: idPaciente ? Number(idPaciente) : null,
            }),
        });
        pintarResultadoDisp(r, insumo, cantidad);

        // Limpiar lo que cambia en cada salida y refrescar el stock mostrado
        document.getElementById('disp-cantidad').value = '';
        [inMedico, inPaciente].forEach(i => { i.value = ''; delete i.dataset.id; i.classList.remove('border-emerald-500'); });
        await cargarDispensacion();
    } catch (e) {
        if (e.status === 401) return mostrarLogin();
        mostrarErrorDisp(e.message);
    } finally {
        boton.disabled = false;
        textoBoton.textContent = 'EJECUTAR SALIDA';
    }
}

function pintarResultadoDisp(r, insumo, cantidad) {
    const varios = r.lotes.length > 1;
    const tarjetas = r.lotes.map(l => `
        <div class="border-2 border-emerald-500 bg-emerald-50 p-3 mb-3 shadow-sm">
            <div class="font-bold text-emerald-800 mb-1">LOTE ASIGNADO: ${esc(l.numero_lote)}</div>
            <div class="text-emerald-700 text-xs">Caducidad: ${fmtFecha(l.fecha_caducidad)}</div>
            <div class="text-emerald-700 text-xs mt-1">Descontado: ${l.cantidad} de ${esc(l.ubicacion_origen)}</div>
        </div>`).join('');

    document.getElementById('disp-resultado').innerHTML = `
        <div class="font-bold text-emerald-700 mb-1">✓ SALIDA REGISTRADA</div>
        <div class="text-xs text-slate-600 mb-1">${esc(insumo.descripcion_farmaco)} · ${cantidad} und.</div>
        <div class="text-xs text-slate-400 mb-3" title="${esc(r.folio)}">Folio ${esc(String(r.folio).slice(0, 8))}</div>
        ${tarjetas}
        ${varios ? '<div class="text-xs text-slate-500">La cantidad se repartió en ' + r.lotes.length + ' lotes porque el primero no alcanzaba.</div>' : ''}`;

    historialDisp.unshift(`${new Date().toLocaleTimeString('es-MX')} · ${cantidad} × ${insumo.descripcion_farmaco}`);
    historialDisp.length = Math.min(historialDisp.length, 5);
    document.getElementById('disp-historial').innerHTML =
        historialDisp.map(h => `<li>${esc(h)}</li>`).join('');
}

// ---------------------------------------------------------------
// TRAZABILIDAD Y CONTROL
// ---------------------------------------------------------------
let ultimoRastreo = null;   // para exportar a CSV

function avisoTraz(msg, tipo) {
    const el = document.getElementById('traz-aviso');
    el.textContent = msg || '';
    el.className = 'mb-4 text-sm font-semibold rounded p-2 font-mono border ' +
        (!msg ? 'hidden' : tipo === 'error'
            ? 'text-red-700 bg-red-50 border-red-300'
            : 'text-slate-700 bg-slate-50 border-slate-300');
}

async function rastrearLote(event) {
    event.preventDefault();
    const lote = document.getElementById('traz-lote').value.trim();
    if (!lote) return avisoTraz('Escribe el número de lote.', 'error');

    const boton = document.getElementById('traz-btn');
    boton.disabled = true;
    avisoTraz('');
    try {
        const r = await api('/trazabilidad?lote=' + encodeURIComponent(lote));
        ultimoRastreo = r;
        if (!r.resultados.length) {
            document.getElementById('traz-resultado').innerHTML = '';
            return avisoTraz('No hay existencias ni entregas registradas para el lote "' + lote + '".', 'info');
        }
        pintarTrazabilidad(r);
    } catch (e) {
        if (e.status === 401) return mostrarLogin();
        document.getElementById('traz-resultado').innerHTML = '';
        avisoTraz(e.message, 'error');
    } finally {
        boton.disabled = false;
    }
}

function badgeCaducidad(fecha) {
    const hoy = new Date(); hoy.setHours(0, 0, 0, 0);
    const dias = Math.round((new Date(String(fecha).slice(0, 10) + 'T00:00:00') - hoy) / 86400000);
    if (dias < 0)   return '<span class="border px-2 py-0.5 text-xs font-bold bg-red-600 text-white border-red-700">CADUCADO</span>';
    if (dias <= 30) return `<span class="border px-2 py-0.5 text-xs font-bold bg-red-50 text-red-700 border-red-500">Caduca en ${dias} d</span>`;
    if (dias <= 90) return `<span class="border px-2 py-0.5 text-xs font-bold bg-yellow-50 text-yellow-700 border-yellow-400">Caduca en ${dias} d</span>`;
    return '';
}

// Médico/paciente: para el Administrador la base de datos devuelve "Restringido"
function celdaPersona(nombre, detalle) {
    if (!nombre) return '—';
    if (nombre === 'Restringido') return '<span class="text-slate-400 text-xs">🔒 Restringido</span>';
    return esc(nombre) + '<div class="text-xs text-slate-500">' + esc(detalle) + '</div>';
}

function pintarTrazabilidad(r) {
    // Un mismo número de lote puede existir en insumos distintos: un bloque por insumo
    const grupos = {};
    r.resultados.forEach(f => { (grupos[f.codigo_insumo] = grupos[f.codigo_insumo] || []).push(f); });

    const bloques = Object.values(grupos).map(filas => {
        const p = filas[0];
        const enInv = filas.filter(f => f.situacion === 'EN_INVENTARIO');
        const entregas = filas.filter(f => f.situacion === 'DISPENSADO');
        const totalInv = enInv.reduce((s, f) => s + f.cantidad, 0);
        const totalEnt = entregas.reduce((s, f) => s + f.cantidad, 0);

        const tarjeta = (titulo, principal, secundario) => `
            <div class="wireframe-border p-3">
                <div class="text-xs font-bold text-slate-500 uppercase">${titulo}</div>
                <div class="font-bold mt-1">${principal}</div>
                <div class="text-xs text-slate-500 font-mono mt-1">${secundario}</div>
            </div>`;

        const filasInv = enInv.length ? enInv.map(f => `
            <tr class="border-b border-slate-200">
                <td class="p-3 font-bold">${esc(f.ubicacion)}</td>
                <td class="p-3">${esc(f.anaquel || '—')}</td>
                <td class="p-3 text-center font-bold">${f.cantidad}</td>
            </tr>`).join('')
            : '<tr><td colspan="3" class="p-3 text-center text-slate-400">Sin existencias en inventario (todo entregado)</td></tr>';

        const filasEnt = entregas.length ? entregas.map(f => `
            <tr class="border-b border-slate-200">
                <td class="p-3 whitespace-nowrap">${new Date(f.fecha_evento).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' })}</td>
                <td class="p-3">${celdaPersona(f.medico, 'Céd. ' + f.cedula_profesional)}</td>
                <td class="p-3">${celdaPersona(f.paciente, f.expediente_folio)}</td>
                <td class="p-3">${esc(f.ubicacion || '—')}</td>
                <td class="p-3 text-center font-bold">${f.cantidad}</td>
            </tr>`).join('')
            : '<tr><td colspan="5" class="p-3 text-center text-slate-400">Este lote aún no se ha entregado</td></tr>';

        return `
        <div class="mb-8">
            <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-4">
                ${tarjeta('Insumo', esc(p.descripcion_farmaco), esc(p.codigo_insumo))}
                ${tarjeta('Proveedor', esc(p.proveedor), 'RFC ' + esc(p.proveedor_rfc))}
                ${tarjeta('Lote y caducidad', esc(p.numero_lote) + ' ' + badgeCaducidad(p.fecha_caducidad), 'Caduca: ' + fmtFecha(p.fecha_caducidad))}
                ${tarjeta('Resumen', totalInv + ' en inventario · ' + totalEnt + ' entregadas', 'Total recibido: ' + (totalInv + totalEnt))}
            </div>

            <div class="grid grid-cols-1 xl:grid-cols-5 gap-6">
                <div class="wireframe-border xl:col-span-2">
                    <div class="bg-slate-100 p-3 border-b-2 border-slate-800 font-bold text-sm uppercase">📦 Dónde está ahora</div>
                    <div class="overflow-x-auto"><table class="w-full text-sm text-left">
                        <thead class="text-xs uppercase font-bold text-slate-700 border-b-2 border-slate-800">
                            <tr><th class="p-3">Ubicación</th><th class="p-3">Anaquel</th><th class="p-3 text-center">Cantidad</th></tr>
                        </thead>
                        <tbody class="font-mono text-slate-700">${filasInv}</tbody>
                    </table></div>
                </div>

                <div class="wireframe-border xl:col-span-3">
                    <div class="bg-slate-100 p-3 border-b-2 border-slate-800 font-bold text-sm uppercase">🧑‍⚕️ A quién se entregó</div>
                    <div class="overflow-x-auto"><table class="w-full text-sm text-left">
                        <thead class="text-xs uppercase font-bold text-slate-700 border-b-2 border-slate-800">
                            <tr><th class="p-3">Fecha</th><th class="p-3">Médico</th><th class="p-3">Paciente</th><th class="p-3">Destino</th><th class="p-3 text-center">Cant.</th></tr>
                        </thead>
                        <tbody class="font-mono text-slate-700">${filasEnt}</tbody>
                    </table></div>
                </div>
            </div>
        </div>`;
    }).join('');

    const aviso = (window.usuarioActual && window.usuarioActual.rol === 'Administrador')
        ? '<p class="font-mono text-xs text-slate-500 mb-3">🔒 Los datos de médicos y pacientes están restringidos para tu perfil.</p>' : '';
    document.getElementById('traz-resultado').innerHTML = `
        ${bloques}
        ${aviso}
        <div class="flex justify-between items-center border-t border-slate-300 pt-3">
            <span class="font-mono text-xs text-slate-500">Consulta resuelta en ${r.tiempo_ms} ms</span>
            <button onclick="exportarTrazabilidad()" class="border-2 border-slate-800 px-3 py-1 text-xs font-bold uppercase hover:bg-slate-100">⬇ Exportar CSV</button>
        </div>`;
}

function exportarTrazabilidad() {
    if (!ultimoRastreo || !ultimoRastreo.resultados.length) return;
    const encabezado = ['Lote', 'Código insumo', 'Insumo', 'Proveedor', 'RFC proveedor', 'Caducidad',
        'Situación', 'Ubicación', 'Anaquel', 'Cantidad', 'Médico', 'Cédula', 'Paciente', 'Expediente', 'Fecha'];
    const filas = ultimoRastreo.resultados.map(f => [
        f.numero_lote, f.codigo_insumo, f.descripcion_farmaco, f.proveedor, f.proveedor_rfc,
        fmtFecha(f.fecha_caducidad), f.situacion === 'EN_INVENTARIO' ? 'En inventario' : 'Entregado',
        f.ubicacion, f.anaquel, f.cantidad, f.medico, f.cedula_profesional, f.paciente,
        f.expediente_folio, f.fecha_evento ? new Date(f.fecha_evento).toLocaleString('es-MX') : '',
    ]);
    descargarCSV('trazabilidad_' + ultimoRastreo.lote.replace(/[^\w-]/g, '') + '_' +
        new Date().toISOString().slice(0, 10) + '.csv', encabezado, filas);
}

// ---------------------------------------------------------------
// Utilidad común: descargar un CSV (con BOM para que Excel lea acentos)
// ---------------------------------------------------------------
function descargarCSV(nombreArchivo, encabezado, filas) {
    // Se escapan comillas y se neutralizan celdas que Excel leería como fórmula
    const celda = v => {
        let t = v === null || v === undefined ? '' : String(v);
        if (/^[=+\-@]/.test(t)) t = "'" + t;
        return '"' + t.replace(/"/g, '""') + '"';
    };
    const csv = '\uFEFF' + [encabezado, ...filas].map(f => f.map(celda).join(',')).join('\r\n');
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = nombreArchivo;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
}

// ---------------------------------------------------------------
// BITÁCORA DE AUDITORÍA
// ---------------------------------------------------------------
const ETIQUETA_TABLA = {
    rol: 'Roles', usuario: 'Usuarios', proveedor: 'Proveedores', insumo: 'Insumos',
    almacen_ubicacion: 'Ubicaciones', medico: 'Médicos', paciente: 'Pacientes',
    lote: 'Lotes', lote_ubicacion: 'Existencias por ubicación',
    entrada_inventario: 'Entradas de inventario', dispensacion: 'Dispensaciones',
};
const ESTILO_ACCION = {
    INSERT: 'text-blue-700 bg-blue-50 border-blue-400',
    UPDATE: 'text-emerald-700 bg-emerald-50 border-emerald-500',
    DELETE: 'text-red-700 bg-red-50 border-red-500',
};
const etiquetaTabla = t => ETIQUETA_TABLA[t] || t;

let bitacoraQS = '';        // filtros aplicados (se conservan al cambiar de página)
let bitacoraPagina = 1;
let bitacoraPaginas = 1;
let filtrosBitacoraCargados = false;

function avisoBitacora(msg, tipo) {
    const el = document.getElementById('aud-aviso');
    el.textContent = msg || '';
    el.className = 'mb-4 text-sm font-semibold rounded p-2 font-mono border ' +
        (!msg ? 'hidden' : tipo === 'error'
            ? 'text-red-700 bg-red-50 border-red-300'
            : 'text-slate-700 bg-slate-50 border-slate-300');
}

async function iniciarBitacora() {
    if (!filtrosBitacoraCargados) {
        try {
            const f = await api('/auditoria/filtros');
            document.getElementById('aud-tabla').innerHTML = '<option value="">Todo</option>' +
                f.tablas.map(t => `<option value="${esc(t)}">${esc(etiquetaTabla(t))}</option>`).join('');
            document.getElementById('aud-usuario').innerHTML = '<option value="">Todos</option>' +
                (f.hay_sistema ? '<option value="sistema">SISTEMA (proceso automático)</option>' : '') +
                f.usuarios.map(u => `<option value="${u.id_usuario}">${esc(u.nombre_usuario || u.usuario)} (${esc(u.usuario)}) · ${esc(u.rol)}</option>`).join('');
            filtrosBitacoraCargados = true;
        } catch (e) {
            if (e.status === 401) return mostrarLogin();
            avisoBitacora('No se pudieron cargar los filtros de auditoría: ' + e.message, 'error');
        }
    }
    cargarBitacora(1);
}

function construirQSBitacora() {
    const p = new URLSearchParams();
    const campos = { desde: 'aud-desde', hasta: 'aud-hasta', usuario: 'aud-usuario', tabla: 'aud-tabla', accion: 'aud-accion' };
    for (const [clave, id] of Object.entries(campos)) {
        const v = document.getElementById(id).value;
        if (v) p.set(clave, v);
    }
    if (document.getElementById('aud-controlado').checked) p.set('controlado', '1');
    return p.toString();
}

function aplicarFiltrosBitacora(event) {
    if (event) event.preventDefault();
    const desde = document.getElementById('aud-desde').value;
    const hasta = document.getElementById('aud-hasta').value;
    if (desde && hasta && desde > hasta) return avisoBitacora('La fecha "Desde" no puede ser posterior a "Hasta".', 'error');
    bitacoraQS = construirQSBitacora();
    cargarBitacora(1);
}

function limpiarFiltrosBitacora() {
    ['aud-desde', 'aud-hasta', 'aud-usuario', 'aud-tabla', 'aud-accion'].forEach(id => { document.getElementById(id).value = ''; });
    document.getElementById('aud-controlado').checked = false;
    bitacoraQS = '';
    cargarBitacora(1);
}

function irPaginaBitacora(delta) {
    const nueva = bitacoraPagina + delta;
    if (nueva >= 1 && nueva <= bitacoraPaginas) cargarBitacora(nueva);
}

async function cargarBitacora(pagina) {
    avisoBitacora('');
    try {
        const qs = (bitacoraQS ? bitacoraQS + '&' : '') + 'pagina=' + pagina;
        const r = await api('/auditoria?' + qs);
        bitacoraPagina = r.pagina;
        bitacoraPaginas = r.paginas;
        pintarBitacora(r);
    } catch (e) {
        if (e.status === 401) return mostrarLogin();
        document.getElementById('tabla-auditoria').innerHTML = '';
        avisoBitacora(e.message, 'error');
    }
}

// Texto legible de "qué se modificó" a partir de los datos guardados
function resumenObjeto(f) {
    const ant = f.datos_anteriores || {}, nue = f.datos_nuevos || {};
    const d = f.datos_nuevos || f.datos_anteriores || {};
    const n = v => (v === null || v === undefined ? '—' : v);
    switch (f.tabla_afectada) {
        case 'dispensacion':       return `${n(d.cantidad_dispensada)} und. del lote #${n(d.id_lote)}`;
        case 'entrada_inventario': return `${n(d.cantidad)} und. al lote #${n(d.id_lote)}`;
        case 'lote_ubicacion':     return f.accion_sql === 'UPDATE'
            ? `Lote #${n(d.id_lote)}: existencia ${n(ant.cantidad)} → ${n(nue.cantidad)}`
            : `Lote #${n(d.id_lote)}: existencia ${n(d.cantidad)}`;
        case 'lote':               return `Lote ${n(d.numero_lote)}`;
        case 'insumo':             return `${n(d.codigo_insumo)} · ${n(d.descripcion_farmaco)}`;
        case 'usuario':            return `${n(d.nombre)} (${n(d.correo)})`;
        case 'medico':
        case 'paciente':           return n(d.nombre);
        case 'proveedor':          return n(d.razon_social);
        case 'almacen_ubicacion':  return n(d.nombre_area);
        case 'rol':                return n(d.nombre_rol);
        default:                   return '';
    }
}

function detalleBitacora(f) {
    const ant = f.datos_anteriores, nue = f.datos_nuevos;
    const valor = v => esc(v === null || v === undefined ? '—' : (typeof v === 'object' ? JSON.stringify(v) : v));
    let filas;
    if (f.accion_sql === 'UPDATE' && ant && nue) {
        const cambiados = Object.keys(nue).filter(k => JSON.stringify(ant[k]) !== JSON.stringify(nue[k]));
        filas = cambiados.length
            ? cambiados.map(k => `<tr><td class="py-1 pr-4 font-bold">${esc(k)}</td><td class="py-1 pr-2 text-red-600 line-through">${valor(ant[k])}</td><td class="py-1 pr-2">→</td><td class="py-1 text-emerald-700 font-bold">${valor(nue[k])}</td></tr>`).join('')
            : '<tr><td class="py-1 text-slate-400">Sin cambios en los valores.</td></tr>';
    } else {
        const datos = nue || ant || {};
        filas = Object.entries(datos).map(([k, v]) =>
            `<tr><td class="py-1 pr-4 font-bold">${esc(k)}</td><td class="py-1">${valor(v)}</td></tr>`).join('');
    }
    return `<div class="text-xs font-bold uppercase text-slate-500 mb-2">${f.accion_sql === 'UPDATE' ? 'Campos modificados (antes → después)' : (f.accion_sql === 'DELETE' ? 'Registro eliminado' : 'Registro creado')}</div>
            <table class="text-xs font-mono">${filas}</table>`;
}

function pintarBitacora(r) {
    const tbody = document.getElementById('tabla-auditoria');
    if (!r.filas.length) {
        tbody.innerHTML = '<tr><td colspan="6" class="p-4 text-center text-slate-400">No hay movimientos con esos filtros.</td></tr>';
    } else {
        tbody.innerHTML = r.filas.map(f => {
            const fecha = new Date(f.timestamp_iso).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'medium' });
            const usuario = f.id_usuario
                ? `<div class="font-bold">${esc(f.nombre_usuario || f.usuario)}</div><div class="text-xs text-slate-500">${esc(f.usuario)}</div>`
                : '<div class="font-bold">SISTEMA</div><div class="text-xs text-slate-500">proceso automático</div>';
            return `<tr class="border-b border-slate-200 cursor-pointer hover:bg-slate-50 ${f.controlado ? 'bg-red-50' : ''}" onclick="alternarDetalleBitacora(${f.id_auditoria})">
                <td class="p-3 whitespace-nowrap">${fecha}</td>
                <td class="p-3">${usuario}</td>
                <td class="p-3">${esc(f.rol)}</td>
                <td class="p-3 text-center"><span class="border px-2 py-0.5 text-xs font-bold ${ESTILO_ACCION[f.accion_sql] || ''}">${esc(f.accion_sql)}</span></td>
                <td class="p-3"><div class="font-bold">${esc(etiquetaTabla(f.tabla_afectada))}${f.controlado ? ' <span class="text-red-600 text-xs">⚠ CONTROLADO</span>' : ''}</div>
                    <div class="text-xs text-slate-500">${esc(resumenObjeto(f))}</div></td>
                <td class="p-3 whitespace-nowrap">${esc(f.terminal_origen_ip)}</td>
            </tr>
            <tr id="aud-det-${f.id_auditoria}" class="hidden border-b border-slate-300 bg-slate-50">
                <td colspan="6" class="p-4">${detalleBitacora(f)}</td>
            </tr>`;
        }).join('');
    }
    const desde = r.total === 0 ? 0 : (r.pagina - 1) * r.por_pagina + 1;
    const hasta = Math.min(r.pagina * r.por_pagina, r.total);
    document.getElementById('aud-conteo').textContent = `Mostrando ${desde}–${hasta} de ${r.total} movimientos`;
    document.getElementById('aud-pagina').textContent = `${r.pagina} / ${r.paginas}`;
    document.getElementById('aud-ant').disabled = r.pagina <= 1;
    document.getElementById('aud-sig').disabled = r.pagina >= r.paginas;
}

function alternarDetalleBitacora(id) {
    const fila = document.getElementById('aud-det-' + id);
    if (fila) fila.classList.toggle('hidden');
}

async function exportarBitacora() {
    avisoBitacora('');
    try {
        const r = await api('/auditoria/exportar' + (bitacoraQS ? '?' + bitacoraQS : ''));
        if (!r.filas.length) return avisoBitacora('No hay movimientos que exportar con esos filtros.', 'info');
        const encabezado = ['Fecha y hora', 'ID usuario', 'Nombre', 'Rol', 'Acción', 'Qué se modificó',
            'Detalle', 'Sustancia controlada', 'Terminal', 'Datos anteriores', 'Datos nuevos'];
        const filas = r.filas.map(f => [
            new Date(f.timestamp_iso).toLocaleString('es-MX'), f.usuario, f.nombre_usuario || '', f.rol,
            f.accion_sql, etiquetaTabla(f.tabla_afectada), resumenObjeto(f), f.controlado ? 'Sí' : 'No',
            f.terminal_origen_ip,
            f.datos_anteriores ? JSON.stringify(f.datos_anteriores) : '',
            f.datos_nuevos ? JSON.stringify(f.datos_nuevos) : '',
        ]);
        descargarCSV('bitacora_auditoria_' + new Date().toISOString().slice(0, 10) + '.csv', encabezado, filas);
        if (r.truncado) avisoBitacora('Se exportaron los ' + r.limite + ' movimientos más recientes. Acota las fechas para obtener el resto.', 'info');
    } catch (e) {
        if (e.status === 401) return mostrarLogin();
        avisoBitacora(e.message, 'error');
    }
}

// ---------------------------------------------------------------
// Utilidades de formularios (mensajes y selects)
// ---------------------------------------------------------------
function hoyLocalISO() {
    const d = new Date();
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}

// Muestra un mensaje de error o de éxito en un par de <p>
function mensajeForm(idError, idOk, tipo, texto) {
    const err = document.getElementById(idError);
    const ok = idOk ? document.getElementById(idOk) : null;
    err.classList.add('hidden');
    if (ok) ok.classList.add('hidden');
    if (!texto) return;
    const el = tipo === 'ok' ? ok : err;
    el.textContent = texto;
    el.classList.remove('hidden');
}

// Reemplaza las opciones de un <select> conservando lo que estaba elegido
function fijarOpciones(id, html, porDefecto) {
    const sel = document.getElementById(id);
    const previo = sel.value;
    sel.innerHTML = html;
    if (previo && [...sel.options].some(o => o.value === previo)) sel.value = previo;
    else if (porDefecto !== undefined && porDefecto !== null) sel.value = porDefecto;
}

// ---------------------------------------------------------------
// ENTRADAS Y TRASLADOS
// ---------------------------------------------------------------
let modoEntrada = 'nuevo';
let ubicacionesEnt = [];
let insumosEnt = {};

function cambiarModoEntrada(modo) {
    modoEntrada = modo;
    document.getElementById('ent-bloque-nuevo').classList.toggle('hidden', modo !== 'nuevo');
    document.getElementById('ent-bloque-existente').classList.toggle('hidden', modo !== 'existente');
    const activo = 'flex-1 py-2 bg-black text-white';
    const inactivo = 'flex-1 py-2 bg-white text-slate-700 hover:bg-slate-100';
    document.getElementById('ent-modo-nuevo').className = modo === 'nuevo' ? activo : inactivo;
    document.getElementById('ent-modo-existente').className =
        (modo === 'existente' ? activo : inactivo) + ' border-l-2 border-slate-800';
    mensajeForm('ent-error', 'ent-ok', null, '');
}
cambiarModoEntrada('nuevo');

async function cargarEntradas() {
    try {
        const [c, provs, lotes, ultimas] = await Promise.all(
            [api('/catalogos'), api('/proveedores'), api('/lotes'), api('/entradas')]);
        ubicacionesEnt = c.ubicaciones;
        insumosEnt = {};
        c.insumos.forEach(i => { insumosEnt[i.id_insumo] = i; });

        const central = c.ubicaciones.find(u => /central/i.test(u.nombre_area));
        const centralId = central ? String(central.id_ubicacion) : null;
        const opcUbic = c.ubicaciones.map(u =>
            `<option value="${u.id_ubicacion}">${esc(u.nombre_area)}${u.anaquel_seccion ? ' · ' + esc(u.anaquel_seccion) : ''}</option>`).join('');
        const opcInsumos = '<option value="">— Selecciona un insumo —</option>' + c.insumos.map(i =>
            `<option value="${i.id_insumo}">${esc(i.descripcion_farmaco)} (${esc(i.codigo_insumo)})</option>`).join('');

        fijarOpciones('ent-insumo', opcInsumos);
        fijarOpciones('ent-proveedor', '<option value="">— Selecciona un proveedor —</option>' + provs.map(p =>
            `<option value="${p.id_proveedor}">${esc(p.razon_social)} (${esc(p.rfc)})</option>`).join(''));
        fijarOpciones('ent-lote', '<option value="">— Selecciona un lote —</option>' + lotes
            .filter(l => l.dias_para_caducar >= 0)
            .map(l => `<option value="${l.id_lote}">${esc(l.numero_lote)} · ${esc(l.descripcion_farmaco)} · caduca ${fmtFecha(l.fecha_caducidad)} · stock ${l.stock_total}</option>`).join(''));
        fijarOpciones('ent-ubic', opcUbic, centralId);

        fijarOpciones('tras-insumo', '<option value="">— Selecciona un insumo —</option>' + c.insumos
            .filter(i => i.stock_vigente > 0)
            .map(i => `<option value="${i.id_insumo}">${esc(i.descripcion_farmaco)} (${esc(i.codigo_insumo)}) — ${i.stock_vigente} disp.</option>`).join(''));
        fijarOpciones('tras-origen', opcUbic, centralId);
        fijarOpciones('tras-destino', '<option value="">— Selecciona destino —</option>' + opcUbic);

        pintarUltimasEntradas(ultimas);
        cargarExistencias();
    } catch (e) {
        if (e.status === 401) return mostrarLogin();
        mensajeForm('ent-error', 'ent-ok', 'error', 'No se pudo cargar la pantalla: ' + e.message);
    }
}

function pintarUltimasEntradas(filas) {
    const tbody = document.getElementById('tabla-entradas');
    if (!filas.length) {
        tbody.innerHTML = '<tr><td colspan="5" class="p-4 text-center text-slate-400">Aún no hay entradas registradas.</td></tr>';
        return;
    }
    tbody.innerHTML = filas.map(f => `<tr class="border-b border-slate-200">
        <td class="p-3 whitespace-nowrap">${new Date(f.fecha_hora).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' })}</td>
        <td class="p-3 font-bold">${esc(f.numero_lote)}</td>
        <td class="p-3">${esc(f.descripcion_farmaco)}</td>
        <td class="p-3">${esc(f.nombre_area)}</td>
        <td class="p-3 text-center font-bold">${f.cantidad}</td>
    </tr>`).join('');
}

async function registrarEntrada(event) {
    event.preventDefault();
    mensajeForm('ent-error', 'ent-ok', null, '');
    const err = t => mensajeForm('ent-error', 'ent-ok', 'error', t);

    const cantidad = parseInt(document.getElementById('ent-cant').value, 10);
    const ubic = document.getElementById('ent-ubic').value;
    if (!ubic) return err('Indica en qué ubicación queda el medicamento.');
    if (!Number.isInteger(cantidad) || cantidad <= 0) return err('Escribe una cantidad mayor a cero.');

    const cuerpo = { id_ubicacion: Number(ubic), cantidad };
    if (modoEntrada === 'existente') {
        const lote = document.getElementById('ent-lote').value;
        if (!lote) return err('Selecciona el lote.');
        cuerpo.id_lote = Number(lote);
    } else {
        const insumo = document.getElementById('ent-insumo').value;
        const proveedor = document.getElementById('ent-proveedor').value;
        const numero = document.getElementById('ent-numero').value.trim();
        const fab = document.getElementById('ent-fab').value;
        const cad = document.getElementById('ent-cad').value;
        const precio = document.getElementById('ent-precio').value;
        if (!insumo) return err('Selecciona el insumo.');
        if (!proveedor) return err('Selecciona el proveedor.');
        if (!numero) return err('Escribe el número de lote.');
        if (!cad) return err('Indica la fecha de caducidad.');
        if (cad < hoyLocalISO()) return err('Ese lote ya está caducado: no se puede dar entrada.');
        if (fab && fab >= cad) return err('La fecha de fabricación debe ser anterior a la de caducidad.');
        if (precio !== '' && Number(precio) < 0) return err('El precio no puede ser negativo.');
        cuerpo.lote_nuevo = {
            id_insumo: Number(insumo), id_proveedor: Number(proveedor), numero_lote: numero,
            fecha_fabricacion: fab || null, fecha_caducidad: cad, precio_unitario: precio === '' ? null : precio,
        };
    }

    const boton = document.getElementById('ent-btn');
    boton.disabled = true;
    try {
        await api('/entradas', { method: 'POST', body: JSON.stringify(cuerpo) });
        const nombreUbic = (ubicacionesEnt.find(u => String(u.id_ubicacion) === ubic) || {}).nombre_area || '';
        mensajeForm('ent-error', 'ent-ok', 'ok', `✓ Entrada registrada: ${cantidad} und. en ${nombreUbic}.`);
        ['ent-cant', 'ent-numero', 'ent-fab', 'ent-cad', 'ent-precio'].forEach(id => { document.getElementById(id).value = ''; });
        await cargarEntradas();
    } catch (e) {
        if (e.status === 401) return mostrarLogin();
        err(e.message);
    } finally {
        boton.disabled = false;
    }
}

async function cargarExistencias() {
    const info = document.getElementById('tras-info');
    const id = document.getElementById('tras-insumo').value;
    if (!id) { info.innerHTML = '&nbsp;'; return; }
    try {
        const filas = await api('/existencias?id_insumo=' + encodeURIComponent(id));
        info.textContent = filas.length
            ? 'Disponible: ' + filas.map(f => `${f.nombre_area} ${f.cantidad}`).join(' · ')
            : 'Sin existencias vigentes de este insumo.';
    } catch (e) {
        info.textContent = 'No se pudieron cargar las existencias: ' + e.message;
    }
}

async function registrarTraslado(event) {
    event.preventDefault();
    mensajeForm('tras-error', 'tras-ok', null, '');
    const err = t => mensajeForm('tras-error', 'tras-ok', 'error', t);

    const insumo = document.getElementById('tras-insumo').value;
    const cantidad = parseInt(document.getElementById('tras-cant').value, 10);
    const origen = document.getElementById('tras-origen').value;
    const destino = document.getElementById('tras-destino').value;
    if (!insumo) return err('Selecciona el insumo.');
    if (!Number.isInteger(cantidad) || cantidad <= 0) return err('Escribe una cantidad mayor a cero.');
    if (!origen || !destino) return err('Indica de dónde sale y a dónde llega.');
    if (origen === destino) return err('El origen y el destino no pueden ser el mismo lugar.');

    const boton = document.getElementById('tras-btn');
    boton.disabled = true;
    try {
        await api('/traslados', {
            method: 'POST',
            body: JSON.stringify({
                id_insumo: Number(insumo), cantidad,
                id_ubicacion_origen: Number(origen), id_ubicacion_destino: Number(destino),
            }),
        });
        const nombre = id => (ubicacionesEnt.find(u => String(u.id_ubicacion) === id) || {}).nombre_area || '';
        mensajeForm('tras-error', 'tras-ok', 'ok', `✓ Traslado realizado: ${cantidad} und. de ${nombre(origen)} a ${nombre(destino)}.`);
        document.getElementById('tras-cant').value = '';
        await cargarExistencias();
    } catch (e) {
        if (e.status === 401) return mostrarLogin();
        err(e.message);
    } finally {
        boton.disabled = false;
    }
}

// ---------------------------------------------------------------
// USUARIOS (Administrador)
// ---------------------------------------------------------------
let usuariosLista = [];
let rolesLista = [];
let usuarioEditando = null;     // objeto usuario, o null si es "nuevo"
let usuarioPassword = null;

function avisoUsuarios(msg, tipo) {
    const el = document.getElementById('usr-aviso');
    el.textContent = msg || '';
    el.className = 'mb-4 text-sm font-semibold rounded p-2 font-mono border ' +
        (!msg ? 'hidden' : tipo === 'error'
            ? 'text-red-700 bg-red-50 border-red-300'
            : 'text-emerald-700 bg-emerald-50 border-emerald-400');
}

async function cargarUsuarios() {
    try {
        const [us, rs] = await Promise.all([api('/usuarios'), api('/roles')]);
        usuariosLista = us;
        rolesLista = rs;
        pintarUsuarios();
    } catch (e) {
        if (e.status === 401) return mostrarLogin();
        avisoUsuarios(e.message, 'error');
    }
}

function pintarUsuarios() {
    const yo = window.usuarioActual.id_usuario;
    document.getElementById('tabla-usuarios').innerHTML = usuariosLista.map(u => {
        const propio = u.id_usuario === yo;
        const estado = u.activo
            ? '<span class="border px-2 py-0.5 text-xs font-bold text-emerald-700 bg-emerald-50 border-emerald-500">Activo</span>'
            : '<span class="border px-2 py-0.5 text-xs font-bold text-slate-500 bg-slate-100 border-slate-300">Inactivo</span>';
        const boton = (texto, accion) =>
            `<button onclick="${accion}" class="border-2 border-slate-300 px-2 py-1 text-xs font-bold uppercase hover:border-slate-800">${texto}</button>`;
        const alternar = propio ? '' : boton(u.activo ? 'Desactivar' : 'Activar', `alternarActivo(${u.id_usuario}, ${!u.activo})`);
        return `<tr class="border-b border-slate-200 ${u.activo ? '' : 'bg-slate-50 text-slate-400'}">
            <td class="p-3 font-bold">${esc(u.nombre)}${propio ? ' <span class="text-xs text-slate-500">(tú)</span>' : ''}</td>
            <td class="p-3">${esc(u.correo)}</td>
            <td class="p-3">${esc(u.nombre_rol)}</td>
            <td class="p-3 text-center">${estado}</td>
            <td class="p-3"><div class="flex gap-2 justify-center flex-wrap">
                ${boton('Editar', `abrirEditarUsuario(${u.id_usuario})`)}
                ${boton('Contraseña', `abrirPassword(${u.id_usuario})`)}
                ${alternar}
            </div></td>
        </tr>`;
    }).join('');
}

function llenarRoles(seleccionado) {
    document.getElementById('usr-rol').innerHTML = rolesLista.map(r =>
        `<option value="${r.id_rol}">${esc(r.nombre_rol)}</option>`).join('');
    if (seleccionado) document.getElementById('usr-rol').value = seleccionado;
}

function abrirNuevoUsuario() {
    usuarioEditando = null;
    document.getElementById('dlg-usuario-titulo').textContent = 'Nuevo usuario';
    ['usr-nombre', 'usr-correo', 'usr-pass'].forEach(id => { document.getElementById(id).value = ''; });
    llenarRoles(null);
    document.getElementById('usr-rol').disabled = false;
    document.getElementById('usr-rol-nota').classList.add('hidden');
    document.getElementById('usr-bloque-pass').classList.remove('hidden');
    mensajeForm('usr-error', null, null, '');
    document.getElementById('dlg-usuario').showModal();
}

function abrirEditarUsuario(id) {
    const u = usuariosLista.find(x => x.id_usuario === id);
    if (!u) return;
    usuarioEditando = u;
    const propio = u.id_usuario === window.usuarioActual.id_usuario;
    document.getElementById('dlg-usuario-titulo').textContent = 'Editar usuario';
    document.getElementById('usr-nombre').value = u.nombre;
    document.getElementById('usr-correo').value = u.correo;
    llenarRoles(u.id_rol);
    document.getElementById('usr-rol').disabled = propio;
    document.getElementById('usr-rol-nota').classList.toggle('hidden', !propio);
    document.getElementById('usr-bloque-pass').classList.add('hidden');
    mensajeForm('usr-error', null, null, '');
    document.getElementById('dlg-usuario').showModal();
}

async function guardarUsuario(event) {
    event.preventDefault();
    const err = t => mensajeForm('usr-error', null, 'error', t);
    err('');

    const nombre = document.getElementById('usr-nombre').value.trim();
    const correo = document.getElementById('usr-correo').value.trim().toLowerCase();
    const idRol = Number(document.getElementById('usr-rol').value);
    if (!nombre) return err('Escribe el nombre.');
    if (!correo || !correo.includes('@')) return err('Escribe un correo válido.');

    const boton = document.getElementById('usr-guardar');
    boton.disabled = true;
    try {
        if (usuarioEditando) {
            const cambios = {};
            if (nombre !== usuarioEditando.nombre) cambios.nombre = nombre;
            if (correo !== usuarioEditando.correo) cambios.correo = correo;
            if (!document.getElementById('usr-rol').disabled && idRol !== usuarioEditando.id_rol) cambios.id_rol = idRol;
            if (!Object.keys(cambios).length) { document.getElementById('dlg-usuario').close(); return; }
            await api('/usuarios/' + usuarioEditando.id_usuario, { method: 'PATCH', body: JSON.stringify(cambios) });
            avisoUsuarios('✓ Usuario actualizado.', 'ok');
        } else {
            const password = document.getElementById('usr-pass').value;
            if (password.length < 8) return err('La contraseña debe tener al menos 8 caracteres.');
            if (new TextEncoder().encode(password).length > 72) return err('La contraseña es demasiado larga (máximo 72 caracteres).');
            await api('/usuarios', { method: 'POST', body: JSON.stringify({ nombre, correo, id_rol: idRol, password }) });
            avisoUsuarios('✓ Usuario creado. Entrégale su contraseña inicial de forma segura.', 'ok');
        }
        document.getElementById('dlg-usuario').close();
        await cargarUsuarios();
    } catch (e) {
        if (e.status === 401) { document.getElementById('dlg-usuario').close(); return mostrarLogin(); }
        err(e.message);
    } finally {
        boton.disabled = false;
    }
}

function abrirPassword(id) {
    const u = usuariosLista.find(x => x.id_usuario === id);
    if (!u) return;
    usuarioPassword = u;
    document.getElementById('pass-usuario').textContent = u.nombre + ' · ' + u.correo;
    document.getElementById('pass-nueva').value = '';
    document.getElementById('pass-repite').value = '';
    mensajeForm('pass-error', null, null, '');
    document.getElementById('dlg-password').showModal();
}

async function guardarPassword(event) {
    event.preventDefault();
    const err = t => mensajeForm('pass-error', null, 'error', t);
    err('');
    const nueva = document.getElementById('pass-nueva').value;
    if (nueva.length < 8) return err('La contraseña debe tener al menos 8 caracteres.');
    if (new TextEncoder().encode(nueva).length > 72) return err('La contraseña es demasiado larga (máximo 72 caracteres).');
    if (nueva !== document.getElementById('pass-repite').value) return err('Las contraseñas no coinciden.');

    const boton = document.getElementById('pass-guardar');
    boton.disabled = true;
    try {
        await api('/usuarios/' + usuarioPassword.id_usuario + '/password',
            { method: 'POST', body: JSON.stringify({ password: nueva }) });
        document.getElementById('dlg-password').close();
        avisoUsuarios('✓ Contraseña de ' + usuarioPassword.nombre + ' actualizada.', 'ok');
    } catch (e) {
        if (e.status === 401) { document.getElementById('dlg-password').close(); return mostrarLogin(); }
        err(e.message);
    } finally {
        boton.disabled = false;
    }
}

async function alternarActivo(id, activar) {
    const u = usuariosLista.find(x => x.id_usuario === id);
    if (!u) return;
    if (!activar && !confirm('¿Desactivar a ' + u.nombre + '? Ya no podrá iniciar sesión.')) return;
    try {
        await api('/usuarios/' + id, { method: 'PATCH', body: JSON.stringify({ activo: activar }) });
        avisoUsuarios('✓ ' + u.nombre + (activar ? ' activado.' : ' desactivado.'), 'ok');
        await cargarUsuarios();
    } catch (e) {
        if (e.status === 401) return mostrarLogin();
        avisoUsuarios(e.message, 'error');
    }
}

// ---------------------------------------------------------------
// Navegación entre vistas
// ---------------------------------------------------------------
function switchView(viewId) {
    if (window.usuarioActual) {
        const ocultas = VISTAS_OCULTAS[window.usuarioActual.rol] || [];
        if (ocultas.includes(viewId)) {
            const targetNav = document.getElementById('nav-select');
            targetNav.value = 'monitor';
            return switchView('monitor');
        }
    }
    // Ocultar todas las vistas
    const views = document.querySelectorAll('.view-section');
    views.forEach(view => {
        view.classList.add('hidden');
        view.classList.remove('block');
    });

    // Mostrar la vista seleccionada
    const targetView = document.getElementById('view-' + viewId);
    if (targetView) {
        targetView.classList.remove('hidden');
        if (!targetView.classList.contains('flex')) targetView.classList.add('block');
    }
    if (viewId === 'monitor' && window.usuarioActual) cargarMonitor();
    if (viewId === 'dispensation' && window.usuarioActual) cargarDispensacion();
    if (viewId === 'traceability') document.getElementById('traz-lote').focus();
    if (viewId === 'audit' && window.usuarioActual) iniciarBitacora();
    if (viewId === 'entries' && window.usuarioActual) cargarEntradas();
    if (viewId === 'users' && window.usuarioActual) cargarUsuarios();
}
