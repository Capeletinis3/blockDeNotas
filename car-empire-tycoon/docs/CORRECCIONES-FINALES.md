# Correcciones finales de la segunda auditoría

Se trabajó sobre el proyecto existente, sin reconstruir sistemas ni la interfaz y sin tocar el modelado 3D.

> **Studio:** no hubo acceso a Roblox Studio. Lo verificado: pruebas automáticas (lógica e interfaz sobre un
> entorno Roblox simulado), Selene, el bot de balance, el `.rbxl` generado con Rojo (`verify_place`: 35
> scripts coinciden) y vistas previas de la interfaz.

## Qué se corrigió

| Punto | Antes | Ahora |
|---|---|---|
| **Calendario después de 2030** | El año visible seguía (2031, 2032…) y nada estaba preparado para pasar el final | El año visible queda en **2030**. Un contador de **años comerciales** aparte (`Rules.periodYear`, `Rules.extraYears`) sigue las misiones anuales y las nuevas generaciones. El HUD muestra «FECHA · AÑO EXTRA N». Producción, ventas, campañas, salarios, investigación y nuevos modelos siguen igual. Para extender el contenido alcanza con subir `CALENDAR.endYear`. |
| **Dinero sin destino** ($1.500 M en 2030) | Con la sede máxima no había en qué invertir | **Expansión global** en 10 regiones: cada una suma +15 % de demanda en todos los tipos y +12 % de autos por minuto en cada línea; el costo crece (de $80 M a $1.650 M) y pide ventas acumuladas. El jugador que optimiza reinvierte de forma continua: 8 regiones en 2030 y las dos últimas en los años extra (≈ 2,5 h después de 2030). Además hay **12 misiones nuevas** de fin de partida (Corporación, Imperio, liderar un tipo con ≥ 35 % de cuota, las 56 investigaciones, regiones, 250.000 y 1.000.000 de autos). No hay impuestos ni mecánicas repetitivas. |
| **Márgenes iguales en todos los tipos** (≈ 61 %) | Una sola sensibilidad al precio | Sensibilidad **por tipo** (`ECON.typeElasticity`): compacto 59 %, sedán 68 %, pickup 70 %, SUV 74 %, deportivo y clásico 75–76 %. Los económicos venden más unidades y los deportivos dejan más margen. **Un solo tipo no domina**: en 2030 rinde $577 M y llega solo a la Corporación; diversificar alcanza el Imperio en 1998. |
| **Ritmo de investigación** | El banco completaba investigaciones al instante; tiempos fuera de los objetivos | El banco (20 min) **acelera** la investigación activa hasta ×2, pero no la completa de golpe. Las tecnologías de más de un año cuestan 8 % menos por año (hasta 40 %), así que quien va atrasado se pone al día. Se mantienen la generación por sede, las bonificaciones con tope y la protección anti-farmeo. |
| **Historial de modelos no permanente** | Con 400 modelos se **borraban** los de menos ventas | Nada se borra. Los 150 modelos más importantes guardan configuración y estadísticas completas; el resto queda **resumido** (solo números y nombre). Por encima de 600, los de menos ventas se suman a «**Otros modelos**», así que los totales nunca se pierden. Se protegen el primer modelo, el más vendido, el más rentable y los dueños de récords. Hay **récords permanentes** de la empresa (`g.records`): primer modelo, lote más vendido, lote más rentable y mejor mes. |
| **Error encontrado por las pruebas nuevas** | Al cerrar el lote de un modelo nuevo con el historial lleno, la entrada recién creada (0 ventas) podía resumirse **antes** de sumar sus números, y esas ventas se perdían | Primero se suman los números y después se recorta; la entrada en uso queda protegida. |
| **Primeros 30 minutos** | Entre Empresa pequeña (15 min) y Sede empresarial (46 min) no había meta de historia | Misiones «Mejorá la fábrica 12 veces» y «Vendé 3.000 autos (requisito de la Sede empresarial)». Ciclo medido con el bot: primera venta 0,3 min, primera ganancia 1,4 min, primera investigación 1,3 min, Empresa pequeña 15 min. |
| **Interfaz 2D** | — | Demostración nueva «Imperio (después de 2030)» para probar el fin de partida. Compañía: tarjeta «Expansión global» con requisitos, confirmación y costo (con la sede máxima pasa arriba de «Marca»). HUD: «Expansión global» como siguiente acción y progreso de la próxima región. Catálogo › Historia: récords permanentes, «Otros modelos», orden por ventas, búsqueda y «Mostrar más» de a 20 (la lista no crece sin límite). Mercado: «Mercado mundial ×N». Investigación: muestra el descuento por difusión y la aceleración del banco. |

**Esquema 5:** la migración 4 → 5 agrega `expansion = 0` y arma los récords desde el historial existente;
no cambia dinero, fecha ni modelos.

## Resultados del bot (`lune run tests/balance.luau normal 660 [plano|uno]`)

| | Optimizador | Simple («plano») | Un solo tipo («uno») |
|---|---|---|---|
| Empresa pequeña / Sede empresarial | 15 min / 47 min | 15 / 48 min | 17 / 77 min |
| Corporación / Imperio | 1980 / 1998 | 2001 / — | 1992 / — |
| Regiones en 2030 | 8 | — | — |
| Ingresos 2020–2029 | $2.278 M | $284 M | $359 M |
| Dinero al llegar a 2030 | $909 M (antes $1.507 M sin destino) | $340 M | $577 M |

Tiempos reales de investigación (media / máxima, en minutos):

| | Pequeña (1–2) | Normal (3–5) | Importante (6–10) | Gran avance (10–15) |
|---|---|---|---|---|
| Optimizador (usa el banco) | 1,1 / 1,3 | 3,6 / 5,0 | 5,5 / 9,5 | 7,5 / 9,3 |
| Simple (sede 3 hasta 2001) | 1,1 / 1,3 | 6,6 / 13,5 | 8,9 / 19,1 | 15,7 / 17,4 |

Las 56 investigaciones se completan en las tres estrategias. El jugador activo termina dentro de los rangos
o un poco antes (el banco lo premia). El que no amplía la sede tarda más en las grandes, como máximo
≈ 19 min.

**Tamaño de la partida:** la del bot después de 60 años y dos horas extra ocupa ≈ 190 KB; una partida con
2.500 modelos, ≈ 340 KB. Con 3 empresas por cuenta queda muy por debajo del límite de 4 MB por clave.

## Pruebas

- `lune run tests/run.luau` → **1.230 comprobaciones, 0 fallas**. Las nuevas:
  - [F1] llegar a 2030;
  - [F2] tres horas después del final (producción, ventas, campañas, salarios, investigación, generación nueva, misiones anuales);
  - [F3][F4] guardar y recuperar una partida larga sin mover el calendario;
  - [F5] las 56 investigaciones y la revisión de año, nivel, PI, dinero y requisitos;
  - [F6] tiempos reales;
  - [F7] estrategias;
  - [F8] inversión después de la sede máxima y reglas de la expansión;
  - [F9] historial con 2.500 modelos sin perder récords ni totales;
  - [F9b] migración 4 → 5;
  - [F10] lote, venta y Cerrar venta en un año extra; y la demostración «Imperio».
- `lune run tests/ui.luau` → **307 comprobaciones, 0 fallas**. Suma el fin de partida (Compañía, Historia, Sede y Mercado) en 1600×900, 1280×720, 844×390 y 390×844.
- `selene src tests` sin avisos · `tests/verify_place.luau`: el `.rbxl` coincide con las fuentes.

## Pendiente

- Probar en Roblox Studio (lista abajo).
- En celular el HUD no muestra la fecha (ya era así); el año extra se ve en Compañía › Resumen.
- El jugador que no amplía la sede investiga las tecnologías grandes en 15–19 min (por encima del objetivo). Es la consecuencia buscada de no crecer; si se quiere acortar, se puede bajar `RESEARCH_TIERS` o subir `diffusionPerYear`.
- Eventos de temporada, amigos y tienda siguen marcados «no implementado». Los modelos 3D quedan para la fase 3D.

## Cómo probar en Studio

1. Abrir `CarEmpireTycoon.rbxl`. Para guardar de verdad: publicar y activar *Enable Studio Access to API Services*.
2. Partida nueva:
   - diseñar, lanzar un lote y ver la primera venta en menos de un minuto;
   - en Misiones, después de «Ampliá a Empresa pequeña» aparecen «Mejorá la fábrica 12 veces» y «Vendé 3.000 autos».
3. Investigación:
   - con el banco cargado, la barra avanza el doble de rápido y el banco baja;
   - una tecnología de años anteriores muestra «(−X % por difusión)».
4. Fin de partida sin jugar horas: menú › Demostraciones › **«Imperio (después de 2030)»** (nueva; no
   guarda nada). Verificar que:
   - el HUD dice «FECHA · AÑO EXTRA 1» con «Mar 2030», y que a 4× el año visible no pasa de 2030;
   - Compañía muestra «Expansión global» arriba, con «Abrir Sudamérica · $80.000.000»;
   - el botón confirma, descuenta el dinero y en Mercado aparece «Mercado mundial ×1,15»;
   - Misiones tiene las metas de fin de partida listas para reclamar.
5. Catálogo › Historia de modelos: récords de la empresa (primer modelo, lote más vendido y más rentable), búsqueda y «Mostrar más modelos».
6. Salir y volver a entrar: la fecha, el año extra, las regiones y los récords se conservan (el calendario no avanza sin conexión).
7. Device Emulator en 1600×900, 1280×720, 844×390 y 390×844, con Compañía y Catálogo › Historia.
