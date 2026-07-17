import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'radar_processor.dart';

class NowcastOutput {
  final StormDynamics dynamics;
  final List<PredictionResult> predictions;

  NowcastOutput({
    required this.dynamics,
    required this.predictions,
  });
}

class RadarService {
  // Caché de frames procesados (para evitar descargas y procesamiento repetido)
  final Map<String, RadarFrame> _liveCache = {};

  // Descarga y procesa un frame en vivo corriendo el procesamiento gráfico en un Isolate
  Future<RadarFrame> getOrDownloadLiveFrame(String filename) async {
    if (_liveCache.containsKey(filename)) {
      return _liveCache[filename]!;
    }

    final url = 'https://radar-cdn.snet.gob.sv/nprogram/SMI/$filename';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('Error al descargar frame $filename: ${response.statusCode}');
    }

    final Uint8List rawBytes = response.bodyBytes;

    // Procesamos en el hilo principal (main isolate) ya que dart:ui requiere 
    // acceso a los decodificadores gráficos de la GPU administrados por el hilo principal
    final RadarFrame processedFrame = await RadarProcessor.processImageBytes(filename, rawBytes);

    _liveCache[filename] = processedFrame;
    return processedFrame;
  }



  // Calcula las predicciones de lluvia y dinámica de tormenta en un Isolate secundario
  Future<NowcastOutput> calculateNowcast({
    required List<RainPixel> pixelsT0,
    required List<RainPixel> pixelsT5,
    required List<RainPixel> pixelsT10,
  }) async {
    // Corremos todo el bucle de proyección Haversine y ordenamiento en un Isolate secundario
    return await Isolate.run(() {
      final dynamics = RadarProcessor.calculateStormDynamics(pixelsT0, pixelsT5, pixelsT10);

      final List<PredictionResult> newPredictions = [];
      for (final city in cities) {
        final pred = RadarProcessor.predictForCoords(
          city.coords.latitude,
          city.coords.longitude,
          city.name,
          pixelsT0,
          dynamics,
        );
        newPredictions.add(pred);
      }

      // Ordenar predicciones: primero ciudades con lluvia proyectada
      newPredictions.sort((a, b) {
        if (a.eta == null && b.eta == null) return a.city.compareTo(b.city);
        if (a.eta == null) return 1;
        if (b.eta == null) return -1;
        return a.eta!.compareTo(b.eta!);
      });

      return NowcastOutput(
        dynamics: dynamics,
        predictions: newPredictions,
      );
    });
  }

  // Calcula una predicción personalizada de coordenadas en un Isolate para no retrasar el hilo de UI
  Future<PredictionResult> calculateCustomPrediction({
    required double lat,
    required double lng,
    required List<RainPixel> latestRainPixels,
    required StormDynamics dynamics,
  }) async {
    return await Isolate.run(() {
      return RadarProcessor.predictForCoords(
        lat,
        lng,
        "Ubicación seleccionada",
        latestRainPixels,
        dynamics,
      );
    });
  }

  // Limpia el caché en memoria del servicio
  void clearCache() {
    _liveCache.clear();
  }
}
