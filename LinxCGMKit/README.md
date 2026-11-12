# LinxCGMKit para Loop (experimental)

Plugin CGM para Loop que lee el sensor **LinX** directamente por Bluetooth
(anuncios BLE, servicio `181F`, fabricante `0x0059`).

> ⚠️ **Experimental, no oficial y no es un dispositivo médico.**
> La conversión del valor bruto a glucosa usa una curva fija obtenida por el
> autor original con dos medidas propias, **no** la calibración de fábrica de LinX.
> Úsalo primero en **lazo abierto** y compara durante días con la app oficial
> de LinX y con glucemias capilares antes de activar el lazo cerrado.

## Origen

- Código original: [LinxCGMKit-Trio](https://github.com/Hristos0527/LinxCGMKit-Trio)
  de Hristos (@Hristos0527), licencia **AGPL-3.0** (ver `LICENSE`).
- Copiado desde la copia `nicolevanelstvandenhoek/LinxCGMKit-Trio`, commit
  `ef53ef3fb0e43e97fd9c6269503b9e27799890e6`.
- Se incluye en el repositorio como carpeta (no como submódulo) porque lleva
  cambios propios.

## Cambios respecto al original

1. **Sensor obligatorio.** Sin un sensor seleccionado no se envía ninguna lectura
   a Loop. El nombre anunciado debe coincidir exactamente (o como sufijo tras
   `-` de al menos 8 caracteres). Los anuncios sin nombre solo se aceptan de un
   periférico confirmado antes por nombre. Antes se aceptaba cualquier LinX
   cercano y también los anuncios sin nombre.
2. **Límites de calibración.** Se rechazan referencias fuera de 40–400 mg/dL, a más
   de 100 mg/dL del valor del sensor, o que den una pendiente fuera del ±30 % de
   la curva base. Dos puntos demasiado próximos solo corrigen el desplazamiento.
3. **Estado real del sensor.** `hasValidSensorSession` e `isStateValid` son falsos
   si no hay lectura en 15 minutos, si no hay sensor seleccionado o si la sesión
   ha terminado. Loop no permite el lazo cerrado en ese caso.
4. **Alerta de pérdida de señal** a los 20 minutos sin lecturas. Se retira
   sola cuando vuelven los datos.
5. **Borrado limpio:** `delete(completion:)` detiene el escáner BLE.
6. Los observadores de estado son débiles (evita fugas de memoria de la pantalla de
   ajustes).
7. El trabajo de Bluetooth del latido de Loop se hace en la cola principal.
8. El producto del plugin se genera como `LinxCGMPlugin.loopplugin`, y los textos
   de la interfaz están en español.

## Limitaciones conocidas

- La curva bruta → glucosa no está validada clínicamente.
- Suavizado: media ponderada de 10 minutos, lo que añade unos minutos de retraso
  en cambios rápidos.
- La recepción en segundo plano depende de que iOS entregue anuncios BLE. Sin
  restauración de estado, puede fallar si la bomba no mantiene Loop despierto.
- Los valores se recortan entre 40 y 400 mg/dL.
