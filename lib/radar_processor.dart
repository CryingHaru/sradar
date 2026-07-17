import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:latlong2/latlong.dart';

// -- MODELOS DE DATOS --

class RainPixel {
  final double lat;
  final double lng;
  final String intensity;

  RainPixel({
    required this.lat,
    required this.lng,
    required this.intensity,
  });
}

class City {
  final String name;
  final LatLng coords;

  const City({
    required this.name,
    required this.coords,
  });
}

class PredictionResult {
  final String city;
  final int? eta; // 0 = Lloviendo ahora, null = Sin lluvia prevista
  final String? intensity;
  final String text;

  PredictionResult({
    required this.city,
    required this.eta,
    required this.intensity,
    required this.text,
  });
}

class StormDynamics {
  final double speedKmh;
  final String heading;
  final LatLng velocity;

  StormDynamics({
    required this.speedKmh,
    required this.heading,
    required this.velocity,
  });
}

class RadarFrame {
  final String imagen;
  final Uint8List processedPngBytes;
  final List<RainPixel> rainPixels;

  RadarFrame({
    required this.imagen,
    required this.processedPngBytes,
    required this.rainPixels,
  });
}

// -- CONSTANTES --

const double latMin = 12.95790;
const double lngMin = -88.71762;
const double latMax = 14.03883;
const double lngMax = -87.60535;

const List<City> cities = [
  City(name: "San Miguel", coords: LatLng(13.4833, -88.1833)),
  City(name: "Estanzuelas", coords: LatLng(13.6432, -88.4936)),
  City(name: "El Tránsito", coords: LatLng(13.3500, -88.3500)),
  City(name: "Jucuapa", coords: LatLng(13.5167, -88.3833)),
  City(name: "Chinameca", coords: LatLng(13.5000, -88.3500)),
  City(name: "Usulután", coords: LatLng(13.3500, -88.4500)),
  City(name: "Santiago de María", coords: LatLng(13.4833, -88.4667)),
  City(name: "San Francisco Gotera", coords: LatLng(13.6939, -88.1075)),
  City(name: "Santa Rosa de Lima", coords: LatLng(13.6247, -87.8936)),
  City(name: "La Unión", coords: LatLng(13.3369, -87.8439)),
  City(name: "El Delirio", coords: LatLng(13.3932, -88.1691)),
  City(name: "Moncagua", coords: LatLng(13.5333, -88.2667)),
  City(name: "Quelepa", coords: LatLng(13.5000, -88.2500)),
  City(name: "Chirilagua", coords: LatLng(13.2208, -88.1386)),
  City(name: "Puerto Parada", coords: LatLng(13.2667, -88.4333)),
  City(name: "Sesori", coords: LatLng(13.7167, -88.3667)),
  City(name: "Jiquilisco", coords: LatLng(13.3167, -88.5667)),
  City(name: "Nueva Guadalupe", coords: LatLng(13.5333, -88.3500)),
  City(name: "Anamorós", coords: LatLng(13.7381, -87.8814)),
  City(name: "Berlín", coords: LatLng(13.5000, -88.5333)),
];

// -- LÓGICA DE PROCESAMIENTO Y PROYECCIÓN --

class RadarProcessor {
  // Clasifica la intensidad según la distancia euclidiana de color
  static String classifyIntensity(int r, int g, int b) {
    const List<List<int>> snetColors = [
      [0, 229, 255], // ligera
      [0, 200, 83],  // moderada
      [255, 214, 0], // fuerte
      [255, 109, 0], // muy fuerte
      [213, 0, 0],   // severa
    ];
    const List<String> names = ['ligera', 'moderada', 'fuerte', 'muy fuerte', 'severa'];

    double minDistance = double.infinity;
    String closest = 'ligera';

    for (int i = 0; i < snetColors.length; i++) {
      final sc = snetColors[i];
      final double dist = (r - sc[0]) * (r - sc[0]) +
          (g - sc[1]) * (g - sc[1]) +
          (b - sc[2]) * (b - sc[2]).toDouble();
      if (dist < minDistance) {
        minDistance = dist;
        closest = names[i];
      }
    }
    return closest;
  }

  // Recolora el buffer de píxeles RGBA a la paleta Windy con transparencia dinámica
  // Aplica transparencia de fondo absoluta y un desvanecimiento radial (vignette)
  static Uint8List recolorRgba(Uint8List rgbaBytes, int width, int height) {
    final Uint8List outBytes = Uint8List.fromList(rgbaBytes);
    final double cx = width / 2.0;
    final double cy = height / 2.0;
    final double maxR = math.min(width, height) / 2.0;

    const List<List<int>> snetColors = [
      [0, 229, 255],
      [0, 200, 83],
      [255, 214, 0],
      [255, 109, 0],
      [213, 0, 0],
    ];

    const List<List<int>> targetColors = [
      [60, 60, 180, 110], // azul-púrpura traslúcido
      [0, 130, 160, 170], // cian-teal medio-transparente
      [0, 180, 110, 210], // verde vibrante
      [130, 210, 0, 240], // verde-amarillo intenso
      [245, 115, 75, 255], // naranja-rojo opaco
    ];

    for (int i = 0; i < outBytes.length; i += 4) {
      final int r = outBytes[i];
      final int g = outBytes[i + 1];
      final int b = outBytes[i + 2];
      final int a = outBytes[i + 3];

      // Calcular posición espacial
      final int pixelIndex = i ~/ 4;
      final int px = pixelIndex % width;
      final int py = pixelIndex ~/ width;
      final double dist = math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
      
      // Vignette radial: desvanecimiento al acercarse al borde
      double radialAlpha = 1.0;
      if (dist > maxR) {
        radialAlpha = 0.0;
      } else if (dist > maxR * 0.82) {
        // Desvanecer suavemente del 82% al 98% de la distancia radial máxima
        radialAlpha = math.max(0.0, 1.0 - (dist - maxR * 0.82) / (maxR * 0.16));
      }

      if (radialAlpha > 0.0 && a > 30 && (r > 15 || g > 15 || b > 15) && !(r > 240 && g > 240 && b > 240)) {
        double minDistance = double.infinity;
        int closestIdx = 0;

        for (int j = 0; j < snetColors.length; j++) {
          final sc = snetColors[j];
          final double distColor = (r - sc[0]) * (r - sc[0]) +
              (g - sc[1]) * (g - sc[1]) +
              (b - sc[2]) * (b - sc[2]).toDouble();
          if (distColor < minDistance) {
            minDistance = distColor;
            closestIdx = j;
          }
        }

        final double originalAlpha = (a / 255.0) * radialAlpha;
        final target = targetColors[closestIdx];

        outBytes[i] = target[0];
        outBytes[i + 1] = target[1];
        outBytes[i + 2] = target[2];
        outBytes[i + 3] = (target[3] * originalAlpha).round().clamp(0, 255);
      } else {
        outBytes[i + 3] = 0; // Transparencia absoluta para fondo, marcas y ruidos
      }
    }
    return outBytes;
  }

  // Extrae los píxeles con lluvia mapeándolos a latitud y longitud terrestres
  static List<RainPixel> extractRainPixels(Uint8List rgbaBytes, int width, int height) {
    final List<RainPixel> rainPixels = [];
    const int step = 2; // Escanear 1 de cada 4 píxeles para optimizar

    for (int y = 0; y < height; y += step) {
      for (int x = 0; x < width; x += step) {
        final int idx = (y * width + x) * 4;
        if (idx + 3 >= rgbaBytes.length) continue;

        final int r = rgbaBytes[idx];
        final int g = rgbaBytes[idx + 1];
        final int b = rgbaBytes[idx + 2];
        final int a = rgbaBytes[idx + 3];

        if (a > 30 && (r > 15 || g > 15 || b > 15) && !(r > 240 && g > 240 && b > 240)) {
          final double lng = lngMin + (x / (width - 1)) * (lngMax - lngMin);
          final double lat = latMax - (y / (height - 1)) * (latMax - latMin);

          final String intensity = classifyIntensity(r, g, b);
          rainPixels.add(RainPixel(lat: lat, lng: lng, intensity: intensity));
        }
      }
    }
    return rainPixels;
  }

  // Decodifica la imagen, la recolora y extrae los píxeles lluviosos en un único paso
  static Future<RadarFrame> processImageBytes(String filename, Uint8List rawBytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(rawBytes);
    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    final ui.Image image = frameInfo.image;
    final int width = image.width;
    final int height = image.height;

    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      throw Exception("No se pudo obtener el buffer RGBA de la imagen");
    }
    final Uint8List rgbaBytes = byteData.buffer.asUint8List();

    // 1. Extraer los píxeles con lluvia ANTES de recolorear
    final List<RainPixel> rainPixels = extractRainPixels(rgbaBytes, width, height);

    // 2. Recolorear buffer passing dimensions
    final Uint8List recoloredBytes = recolorRgba(rgbaBytes, width, height);

    // 3. Crear ui.Image recoloreada a partir de los bytes
    final Completer<ui.Image> completer = Completer();
    ui.decodeImageFromPixels(
      recoloredBytes,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (ui.Image img) => completer.complete(img),
    );
    final ui.Image recoloredImage = await completer.future;

    // 4. Convertir ui.Image a bytes PNG
    final ByteData? pngByteData = await recoloredImage.toByteData(format: ui.ImageByteFormat.png);
    if (pngByteData == null) {
      throw Exception("No se pudo codificar la imagen recoloreada a PNG");
    }
    final Uint8List processedPngBytes = pngByteData.buffer.asUint8List();

    // Liberar recursos de imágenes nativas
    image.dispose();
    recoloredImage.dispose();

    return RadarFrame(
      imagen: filename,
      processedPngBytes: processedPngBytes,
      rainPixels: rainPixels,
    );
  }

  // Calculates the storm centroid
  static LatLng? getCentroid(List<RainPixel> pixels) {
    if (pixels.isEmpty) return null;
    double sumLat = 0;
    double sumLng = 0;
    for (final p in pixels) {
      sumLat += p.lat;
      sumLng += p.lng;
    }
    return LatLng(sumLat / pixels.length, sumLng / pixels.length);
  }

  // Haversine formula
  static double haversineDist(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371.0;
    final double dLat = (lat2 - lat1) * math.pi / 180.0;
    final double dLon = (lon2 - lon1) * math.pi / 180.0;
    final double a = math.sin(dLat / 2.0) * math.sin(dLat / 2.0) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLon / 2.0) *
            math.sin(dLon / 2.0);
    final double c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a));
    return R * c;
  }

  // Estima la velocidad y rumbo del movimiento de la tormenta
  static StormDynamics calculateStormDynamics(
    List<RainPixel> pixelsT0,
    List<RainPixel> pixelsT5,
    List<RainPixel> pixelsT10,
  ) {
    final LatLng? c0 = getCentroid(pixelsT0);
    final LatLng? c5 = getCentroid(pixelsT5);
    final LatLng? c10 = getCentroid(pixelsT10);

    double vLat = 0;
    double vLng = 0;

    if (c0 != null && c5 != null) {
      if (c10 != null) {
        vLat = ((c0.latitude - c5.latitude) + (c5.latitude - c10.latitude)) / 10.0;
        vLng = ((c0.longitude - c5.longitude) + (c5.longitude - c10.longitude)) / 10.0;
      } else {
        vLat = (c0.latitude - c5.latitude) / 5.0;
        vLng = (c0.longitude - c5.longitude) / 5.0;
      }
    }

    final double speedKmh = math.sqrt(vLat * vLat + vLng * vLng) * 111.0 * 60.0;
    double stormSpeedKmh;
    String stormHeading;

    if (pixelsT0.length < 15) {
      vLat = 0;
      vLng = 0;
      stormSpeedKmh = 0;
      stormHeading = '';
    } else if (speedKmh > 120 || speedKmh < 0.5) {
      // Revertir a vientos alisios normales del Este al Oeste a 20 km/h
      vLat = 0;
      vLng = -20.0 / (111.0 * 60.0);
      stormSpeedKmh = 20;
      stormHeading = 'Oeste (Predeterminado)';
    } else {
      stormSpeedKmh = speedKmh;
      final double angle = math.atan2(vLng, vLat) * 180.0 / math.pi;
      final double headingDegrees = (90.0 - angle + 360.0) % 360.0;
      const List<String> directions = [
        "Norte", "Noreste", "Este", "Sureste", "Sur", "Suroeste", "Oeste", "Noroeste"
      ];
      stormHeading = directions[(headingDegrees / 45.0).round() % 8];
    }

    return StormDynamics(
      speedKmh: stormSpeedKmh,
      heading: stormHeading,
      velocity: LatLng(vLat, vLng),
    );
  }

  // Predice la lluvia para coordenadas dadas proyectando la tormenta
  static PredictionResult predictForCoords(
    double lat,
    double lng,
    String label,
    List<RainPixel> latestRainPixels,
    StormDynamics dynamics,
  ) {
    if (latestRainPixels.isEmpty) {
      return PredictionResult(
        city: label,
        eta: null,
        intensity: null,
        text: "Cielo despejado / Sin lluvia",
      );
    }

    // 1. Verificar si ya llueve en la ubicación (menos de 4.5 km)
    RainPixel? closestRain;
    double minCurrentDist = double.infinity;

    for (final p in latestRainPixels) {
      final double dist = haversineDist(lat, lng, p.lat, p.lng);
      if (dist < minCurrentDist) {
        minCurrentDist = dist;
        closestRain = p;
      }
    }

    if (minCurrentDist < 4.5 && closestRain != null) {
      return PredictionResult(
        city: label,
        eta: 0,
        intensity: closestRain.intensity,
        text: "Lloviendo ahora (${closestRain.intensity})",
      );
    }

    // 2. Proyectar la posición de cada píxel detectado
    final List<Map<String, dynamic>> hits = [];

    for (final p in latestRainPixels) {
      for (int t = 1; t <= 60; t++) {
        final double projLat = p.lat + dynamics.velocity.latitude * t;
        final double projLng = p.lng + dynamics.velocity.longitude * t;

        final double dist = haversineDist(lat, lng, projLat, projLng);
        if (dist < 4.5) {
          hits.add({'time': t, 'intensity': p.intensity});
          break; // Impacto encontrado para este píxel
        }
      }
    }

    // 3. Consolidar los impactos
    if (hits.isNotEmpty) {
      hits.sort((a, b) => (a['time'] as int).compareTo(b['time'] as int));
      final earliestHit = hits[0];
      final int eta = earliestHit['time'] as int;

      const Map<String, int> intensityLevels = {
        'ligera': 1,
        'moderada': 2,
        'fuerte': 3,
        'muy fuerte': 4,
        'severa': 5
      };

      String maxIntensity = earliestHit['intensity'] as String;
      final int scanLimit = math.min(hits.length, 8);
      for (int i = 0; i < scanLimit; i++) {
        final String hitIntensity = hits[i]['intensity'] as String;
        if ((intensityLevels[hitIntensity] ?? 0) > (intensityLevels[maxIntensity] ?? 0)) {
          maxIntensity = hitIntensity;
        }
      }

      return PredictionResult(
        city: label,
        eta: eta,
        intensity: maxIntensity,
        text: "Lluvia $maxIntensity en $eta min",
      );
    }

    return PredictionResult(
      city: label,
      eta: null,
      intensity: null,
      text: "Sin lluvia prevista en la próxima hora",
    );
  }

}
