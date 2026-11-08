# Actualización integral · progreso

Respaldo: tag git `respaldo-pre-integral` (commit b518f2d, Etapa 3) y copia del `.rbxl` anterior.
El proyecto se edita como código (Rojo); el `.rbxl` se arma con `rojo build place.project.json`.

## Auditoría (fase 1)

| Sistema | Estado encontrado | Acción |
|---|---|---|
| Empresas / ranuras | 4 ranuras (2 gratis, 3-4 bloqueadas sin compra). Nombre obligatorio; color y logo con valores por defecto. **Dificultad** cambia dinero (150k/90k/65k) y demanda (±15 %). | Quitar dificultad (todas iguales), identidad obligatoria, compra de ranuras con Developer Product. |
| Calendario | 2 s/día a 1×, 2×, 3×, pausa por empresa al abrir menús, sin progreso offline, reloj único `Simulation.simulate`. | Cumple. Conectar capacitaciones, campañas y obras al mismo reloj. |
| Personal | Roles (Mecánico, Ingeniero…), una sola «skill», costo de contratación, asignación a estaciones y 4 departamentos viejos (Laboratorio, Ventas, Marketing, Diseño). Despido sin indemnización. Salarios impagos bajan reputación. | Rehacer: 4 departamentos, 3 habilidades c/u, potencial, límites por beneficio, adaptación, deuda salarial con 30 % de las ventas, indemnización. |
| Mercado laboral | Candidatos que se acumulan (hasta 12), 2 por mes, búsqueda fija de $1.000. | 8 por mes que reemplazan, búsqueda general/especializada con precio creciente. |
| Capacitaciones | No existen. | Implementar. |
| Marketing | 3 niveles fijos con cobro mensual, atados a investigaciones. | Campaña de modelo/corporativa con presupuesto, duración, pago al inicio, cancelable. |
| Instalaciones | «Sede» de 5 niveles que da todo junto (líneas 1-5, capacidad, alcance, PI, personal). Estaciones de fábrica. Mejoras instantáneas. Expansión por regiones. | Separar oficinas / fábrica / centro de I+D, líneas 1 gratis · 2 dinero · 3 Robux, obras con duración, expansión por países. |
| Investigación | 4 categorías + «Empresa (provisorio)». | Pasar producción a la fábrica y marketing a campañas; quitar la pestaña. |
| Diseño, lotes, reseñas, ventas | Cumplen (Etapa 2-3). | Conectar bonificaciones de personal, campañas y deuda salarial. |
| Guardado | Esquema 8 con migraciones versionadas, validación completa y perfil con `processed`/`unlocked`. | Esquema 9 con migración de empleados, campañas, instalaciones y dificultad. |
| Interfaz | Menú de ranuras, HUD con barra de navegación, pantallas por sección. Avisos de proximidad en el mundo (`WorldPrompts`). | Ajustar Personal, Marketing, Instalaciones y Ajustes; revisar lo demás. |

## Fases

- [x] 1. Auditoría y respaldo
- [x] 2. Sistemas fundamentales
  - Sin dificultades: todas las empresas empiezan con $90.000 y la misma demanda (`Catalog.START`). Migración 8 → 9 (se quita el campo; el dinero se conserva).
  - Nombre, símbolo y color obligatorios en el servidor (la pantalla propone valores editables).
  - Ranuras 3 y 4: compra individual con Developer Product (`Catalog.PRODUCTS`, id 0 = sin configurar, botón deshabilitado). `Sessions.processReceipt` acredita solo después de guardar y no duplica recibos (`profile.receipts`).
  - Calendario, velocidades y pausa por empresa: ya cumplían (pruebas [E1]).
- [x] 3. Personal (`src/shared/Staff.luau`, valores en `Catalog.STAFF`)
  - 4 departamentos × 3 habilidades, cada beneficio con su tope; potencial individual; aportes y vista previa de contratación con topes.
  - Efectos: velocidad (líneas, en vivo), calidad (puntos al terminar el lote), eficiencia (costo de lotes nuevos), conocimiento/precisión (PI y dinero al empezar), creatividad (avance en vivo), marketing y administración se conectan en fases 5-6.
  - Transferencias con adaptación (50 % → 100 % en 180 días), habilidades conservadas.
  - Sueldos al empezar el mes, deuda salarial, productividad que baja, 30 % de las ventas a la deuda; indemnización salario × años.
  - 8 candidatos por mes, búsqueda general/especializada (+50 % por búsqueda, contador compartido); sin costo de contratación.
  - Esquema 10: migración de empleados viejos (rol → departamento, habilidad y salario conservados).
- [ ] 4. Capacitaciones
- [ ] 5. Marketing
- [ ] 6. Instalaciones
- [ ] 7. Investigación
- [ ] 8. Ciclo automotriz
- [ ] 9. Interfaz
- [ ] 10. Pruebas generales
