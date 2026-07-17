import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'radar_processor.dart';
import 'radar_service.dart';
import 'cached_tile_provider.dart';

class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> with SingleTickerProviderStateMixin {
  // Parámetros geográficos del radar
  final LatLng radarCenter = const LatLng(13.4989, -88.16276);
  final LatLngBounds radarBounds = LatLngBounds(
    const LatLng(12.95790, -88.71762),
    const LatLng(14.03883, -87.60535),
  );
  // Controladores y estado
  late final MapController _mapController;
  bool _isLoading = true;
  String _statusMessage = 'Conectando...';
  int _secondsToNextUpdate = 0;
  Timer? _countdownTimer;

  // Datos de viento de Open-Meteo para suavizado continuo (rollback/forecast)
  double _windSpeedKmh = 20.0;
  double _windDirectionDegrees = 90.0; // Viento desde el Este (hacia el Oeste)

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _secondsToNextUpdate = _getSecondsToNextClockMark();
    _startCountdown();
    _fetchWindData().then((_) {
      _refreshLiveRadar();
    });
  }

  // Consulta la API de Open-Meteo para obtener velocidad y rumbo del viento
  Future<void> _fetchWindData() async {
    try {
      final response = await http.get(Uri.parse(
          'https://api.open-meteo.com/v1/forecast?latitude=13.69&longitude=-89.19&current=wind_speed_10m,wind_direction_10m'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final current = data['current'];
        if (current != null) {
          setState(() {
            _windSpeedKmh = (current['wind_speed_10m'] as num).toDouble();
            _windDirectionDegrees = (current['wind_direction_10m'] as num).toDouble();
          });
          debugPrint('Viento Open-Meteo obtenido: $_windSpeedKmh km/h, $_windDirectionDegrees grados');
        }
      }
    } catch (e) {
      debugPrint('Error al obtener viento de Open-Meteo: $e');
    }
  }  // Secuencia de frames de la línea de tiempo
  List<RadarFrame> _rawFrames = [];
  List<InterpolatedFrame> _timelineFrames = [];
  int _activeFrameIndex = 0;
  bool _isPlaying = false;
  Timer? _playTimer;

  // Servicio de procesamiento secundario en Isolates
  final RadarService _radarService = RadarService();
  List<String> _liveFilenames = [];

  // Datos de predicción activos
  List<PredictionResult> _predictions = [];
  StormDynamics? _stormDynamics;

  // Marcadores y selección
  LatLng? _customMarkerLocation;
  PredictionResult? _customPrediction;
  City? _selectedCity;
  PredictionResult? _selectedCityPrediction;

  // Control de colapso del panel lateral de predicciones
  bool _isPredictionsExpanded = false;



  @override
  void dispose() {
    _countdownTimer?.cancel();
    _playTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  int _getSecondsToNextClockMark() {
    final now = DateTime.now();
    final int minutes = now.minute;
    final int seconds = now.second;

    final int nextMultipleOf5 = 5 * (minutes ~/ 5) + 5;
    final int diffMinutes = nextMultipleOf5 - minutes;
    final int totalSeconds = diffMinutes * 60 - seconds;

    return totalSeconds + 30; // 30s de margen de publicación
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _secondsToNextUpdate--;
        if (_secondsToNextUpdate <= 0) {
          _secondsToNextUpdate = _getSecondsToNextClockMark();
          _refreshLiveRadar();
        }
      });
    });
  }

  // Descarga el listado y procesa los frames para el modo Live
  Future<void> _refreshLiveRadar() async {
    setState(() {
      _statusMessage = 'Consultando radar...';
    });

    try {
      final response = await http.get(Uri.parse(
          'https://www.snet.gob.sv/googlemaps/radares/listJSON.php'));
      if (response.statusCode != 200) {
        throw Exception('Código de respuesta SNET: ${response.statusCode}');
      }

      final rawText = response.body;
      final cleanJson = rawText
          .replaceAll(RegExp(r'imagen\s*:'), '"imagen":')
          .replaceAll("'", '"');

      final List<dynamic> list = jsonDecode(cleanJson);
      if (list.isEmpty) {
        throw Exception('No hay imágenes en el listado de SNET');
      }

      final List<String> filenames =
          list.map((item) => item['imagen'] as String).toList();

      // Guardar el listado histórico completo (3 horas = 36 imágenes)
      _liveFilenames = filenames.take(36).toList();

      // Para nowcasting inicial, necesitamos las 3 imágenes más recientes (índices 0, 1, 2)
      final List<RadarFrame> recentFrames = [];
      _statusMessage = 'Procesando imágenes...';

      for (int i = 0; i < math.min(_liveFilenames.length, 3); i++) {
        final filename = _liveFilenames[i];
        final frame = await _radarService.getOrDownloadLiveFrame(filename);
        recentFrames.add(frame);
      }

      // Reorganizar el timeline en orden cronológico (antiguo a reciente)
      final List<RadarFrame> initialTimeline = recentFrames.reversed.toList();

      setState(() {
        _rawFrames = initialTimeline;
        _timelineFrames = _generateInterpolatedTimeline(_rawFrames);
        _activeFrameIndex = _timelineFrames.length - 26;
        _isLoading = false;
        _statusMessage = 'Sincronizado';
        _updateActiveFrameData();
      });

      // Iniciar la descarga del resto de los frames históricos en segundo plano
      _startBackgroundPreload();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = 'Error al actualizar';
      });
      _showErrorSnackBar('Error de conexión con SNET: $e');
    }
  }

  // Precarga asíncrona en segundo plano del resto de los 36 frames
  void _startBackgroundPreload() async {
    for (int i = 3; i < _liveFilenames.length; i++) {
      if (!mounted) break;
      final String filename = _liveFilenames[i];
      try {
        final frame = await _radarService.getOrDownloadLiveFrame(filename);
        if (!mounted) break;

        setState(() {
          // Insertar al inicio (más antiguo) para mantener orden cronológico
          _rawFrames.insert(0, frame);
          _timelineFrames = _generateInterpolatedTimeline(_rawFrames);
          _activeFrameIndex += 5;
        });
      } catch (e) {
        debugPrint('Error en precarga de frame $filename: $e');
      }
    }
  }



  // Carga un frame de la línea de tiempo por índice
  Future<void> _loadFrameAtIndex(int index) async {
    if (index < 0 || index >= _timelineFrames.length) return;

    setState(() {
      _activeFrameIndex = index;
      _updateActiveFrameData();
    });
  }

  // Actualiza los datos activos (predicciones, dinámicas) en base al frame interpolado actual
  void _updateActiveFrameData() {
    if (_timelineFrames.isEmpty) return;
    final activeFrame = _timelineFrames[_activeFrameIndex];

    setState(() {
      _stormDynamics = activeFrame.dynamics;
      _predictions = activeFrame.predictions;

      if (_customMarkerLocation != null) {
        _customPrediction = RadarProcessor.predictForCoords(
          _customMarkerLocation!.latitude,
          _customMarkerLocation!.longitude,
          "Ubicación seleccionada",
          activeFrame.rainPixels,
          activeFrame.dynamics,
        );
      } else {
        _customPrediction = null;
      }

      if (_selectedCity != null) {
        _selectedCityPrediction = _predictions.firstWhere(
          (p) => p.city == _selectedCity!.name,
          orElse: () => PredictionResult(
            city: _selectedCity!.name,
            eta: null,
            intensity: null,
            text: "Sin datos",
          ),
        );
      } else {
        _selectedCityPrediction = null;
      }
    });
  }

  // Desplaza un LatLngBounds sumando un desfase en latitud y longitud
  LatLngBounds _shiftBounds(LatLngBounds baseBounds, double dLat, double dLng) {
    return LatLngBounds(
      LatLng(baseBounds.southWest.latitude + dLat, baseBounds.southWest.longitude + dLng),
      LatLng(baseBounds.northEast.latitude + dLat, baseBounds.northEast.longitude + dLng),
    );
  }

  // Interpola la etiqueta de hora sumando o restando minutos de forma segura usando DateTime
  String _interpolateTimeLabel(String label, int minutesAdded) {
    
    final regExp = RegExp(r'^(\d{4})-(\d{2})-(\d{2})\s+(\d{2})-(\d{2})-(\d{2})');
    final match = regExp.firstMatch(label);
    if (match != null) {
      final int year = int.parse(match.group(1)!);
      final int month = int.parse(match.group(2)!);
      final int day = int.parse(match.group(3)!);
      final int hour = int.parse(match.group(4)!);
      final int minute = int.parse(match.group(5)!);
      final int second = int.parse(match.group(6)!);
      
      final dt = DateTime(year, month, day, hour, minute, second).add(Duration(minutes: minutesAdded));
      
      final yStr = dt.year.toString();
      final moStr = dt.month.toString().padLeft(2, '0');
      final dStr = dt.day.toString().padLeft(2, '0');
      final hStr = dt.hour.toString().padLeft(2, '0');
      final miStr = dt.minute.toString().padLeft(2, '0');
      final sStr = dt.second.toString().padLeft(2, '0');
      
      return "$yStr-$moStr-$dStr $hStr-$miStr-$sStr";
    }
    return label;
  }

  // Genera el timeline completo con cuadros fantasmas interpolados, incluyendo rollback y forecast por viento
  List<InterpolatedFrame> _generateInterpolatedTimeline(List<RadarFrame> rawFrames) {
    if (rawFrames.isEmpty) return [];
    
    // 1. Calcular el vector de viento en latitud y longitud por minuto
    // Dirección del viento de Open-Meteo indica de dónde viene el viento.
    // La dirección hacia donde sopla el viento es (dirección + 180).
    final double angleRad = (90.0 - (_windDirectionDegrees + 180.0)) * math.pi / 180.0;
    final double vxKmh = _windSpeedKmh * math.cos(angleRad);
    final double vyKmh = _windSpeedKmh * math.sin(angleRad);
    // 1 grado latitud ≈ 111 km
    final double vyMin = (vyKmh / 111.0) / 60.0;
    // 1 grado longitud ≈ 111 km * cos(lat). A 13.5 grados lat, cos(13.5) = 0.972
    final double vxMin = (vxKmh / (111.0 * 0.972)) / 60.0;

    final List<InterpolatedFrame> timeline = [];
    final firstRaw = rawFrames.first;
    
    // Calcular dinámicas del primer frame
    final List<RainPixel> firstPixelsT0 = firstRaw.rainPixels;
    final initialDynamics = RadarProcessor.calculateStormDynamics(firstPixelsT0, [], []);

    // ROLLBACK: 25 frames (25 a 1 minuto ANTES de la primera captura raw)
    for (int j = 25; j >= 1; j--) {
      final double t = j.toDouble();
      
      // Desplazamiento opuesto al viento para retroceder en el tiempo
      final boundsA = _shiftBounds(radarBounds, -t * vyMin, -t * vxMin);
      
      // La opacidad va de 0.0 (hace 25m) a 1.0 (hace 0m)
      final double opacity = 1.0 - (t / 25.0);
      
      final rolledBackPixels = firstRaw.rainPixels.map((p) {
        return RainPixel(
          lat: p.lat - t * vyMin,
          lng: p.lng - t * vxMin,
          intensity: p.intensity,
        );
      }).toList();
      
      final timeLabel = _interpolateTimeLabel(firstRaw.imagen, -j);

      // Predicciones para este frame de rollback
      final List<PredictionResult> predictions = [];
      for (final city in cities) {
        final pred = RadarProcessor.predictForCoords(
          city.coords.latitude,
          city.coords.longitude,
          city.name,
          rolledBackPixels,
          initialDynamics,
        );
        predictions.add(pred);
      }
      predictions.sort((a, b) {
        if (a.eta == null && b.eta == null) return a.city.compareTo(b.city);
        if (a.eta == null) return 1;
        if (b.eta == null) return -1;
        return a.eta!.compareTo(b.eta!);
      });

      timeline.add(InterpolatedFrame(
        imagen: timeLabel,
        frameA: firstRaw,
        boundsA: boundsA,
        opacityA: opacity,
        opacityB: 0.0,
        rainPixels: rolledBackPixels,
        dynamics: initialDynamics,
        predictions: predictions,
      ));
    }

    // FRAMES OBSERVADOS Y PASOS INTERMEDIOS DE 1 MINUTO
    for (int i = 0; i < rawFrames.length - 1; i++) {
      final current = rawFrames[i];
      final next = rawFrames[i + 1];
      
      final List<RainPixel> pixelsT0 = current.rainPixels;
      final List<RainPixel> pixelsT5 = i >= 1 ? rawFrames[i - 1].rainPixels : <RainPixel>[];
      final List<RainPixel> pixelsT10 = i >= 2 ? rawFrames[i - 2].rainPixels : <RainPixel>[];
      
      final dynamics = RadarProcessor.calculateStormDynamics(pixelsT0, pixelsT5, pixelsT10);
      
      final LatLng? c0 = RadarProcessor.getCentroid(current.rainPixels);
      final LatLng? c1 = RadarProcessor.getCentroid(next.rainPixels);
      
      // Control inteligente de desvíos:
      // Si la distancia entre centroides es menor a 15 km, usamos el centroide (continuidad).
      // Si salta más de 15 km (nueva celda de tormenta) o es nulo, usamos el viento de Open-Meteo para evitar movimientos no naturales.
      double dLat = 5 * vyMin;
      double dLng = 5 * vxMin;
      if (c0 != null && c1 != null) {
        final dist = RadarProcessor.haversineDist(c0.latitude, c0.longitude, c1.latitude, c1.longitude);
        if (dist < 15.0) {
          dLat = c1.latitude - c0.latitude;
          dLng = c1.longitude - c0.longitude;
        }
      }
      
      for (int k = 0; k < 5; k++) {
        final double t = k / 5.0;
        
        final boundsA = _shiftBounds(radarBounds, t * dLat, t * dLng);
        final boundsB = _shiftBounds(radarBounds, -(1 - t) * dLat, -(1 - t) * dLng);
        
        final interpolatedPixels = current.rainPixels.map((p) {
          return RainPixel(
            lat: p.lat + t * dLat,
            lng: p.lng + t * dLng,
            intensity: p.intensity,
          );
        }).toList();
        
        final timeLabel = _interpolateTimeLabel(current.imagen, k);

        final List<PredictionResult> predictions = [];
        for (final city in cities) {
          final pred = RadarProcessor.predictForCoords(
            city.coords.latitude,
            city.coords.longitude,
            city.name,
            interpolatedPixels,
            dynamics,
          );
          predictions.add(pred);
        }
        predictions.sort((a, b) {
          if (a.eta == null && b.eta == null) return a.city.compareTo(b.city);
          if (a.eta == null) return 1;
          if (b.eta == null) return -1;
          return a.eta!.compareTo(b.eta!);
        });
        
        timeline.add(InterpolatedFrame(
          imagen: timeLabel,
          frameA: current,
          frameB: next,
          boundsA: boundsA,
          boundsB: boundsB,
          opacityA: 1.0 - t,
          opacityB: t,
          rainPixels: interpolatedPixels,
          dynamics: dynamics,
          predictions: predictions,
        ));
      }
    }

    // FORECAST: 26 frames (0 a 25 minutos DESPUÉS del último raw frame)
    final lastRaw = rawFrames.last;
    final List<RainPixel> lastPixelsT0 = lastRaw.rainPixels;
    final List<RainPixel> lastPixelsT5 = rawFrames.length >= 2 ? rawFrames[rawFrames.length - 2].rainPixels : <RainPixel>[];
    final List<RainPixel> lastPixelsT10 = rawFrames.length >= 3 ? rawFrames[rawFrames.length - 3].rainPixels : <RainPixel>[];
    final finalDynamics = RadarProcessor.calculateStormDynamics(lastPixelsT0, lastPixelsT5, lastPixelsT10);

    for (int j = 0; j <= 25; j++) {
      final double t = j.toDouble();
      
      // Desplazamiento en sentido del viento para avanzar en el tiempo
      final boundsA = _shiftBounds(radarBounds, t * vyMin, t * vxMin);
      
      // La opacidad va de 1.0 (en 0m) a 0.0 (en 25m)
      final double opacity = 1.0 - (t / 25.0);
      
      final forecastedPixels = lastRaw.rainPixels.map((p) {
        return RainPixel(
          lat: p.lat + t * vyMin,
          lng: p.lng + t * vxMin,
          intensity: p.intensity,
        );
      }).toList();
      
      final timeLabel = _interpolateTimeLabel(lastRaw.imagen, j);

      final List<PredictionResult> predictions = [];
      for (final city in cities) {
        final pred = RadarProcessor.predictForCoords(
          city.coords.latitude,
          city.coords.longitude,
          city.name,
          forecastedPixels,
          finalDynamics,
        );
        predictions.add(pred);
      }
      predictions.sort((a, b) {
        if (a.eta == null && b.eta == null) return a.city.compareTo(b.city);
        if (a.eta == null) return 1;
        if (b.eta == null) return -1;
        return a.eta!.compareTo(b.eta!);
      });

      timeline.add(InterpolatedFrame(
        imagen: timeLabel,
        frameA: lastRaw,
        boundsA: boundsA,
        opacityA: opacity,
        opacityB: 0.0,
        rainPixels: forecastedPixels,
        dynamics: finalDynamics,
        predictions: predictions,
      ));
    }

    return timeline;
  }

  // Reproducción automática del timeline
  void _startPlayback() {
    if (_timelineFrames.isEmpty) return;
    _playTimer?.cancel();
    setState(() {
      _isPlaying = true;
    });

    _playTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!mounted) return;
      int nextIdx = _activeFrameIndex + 1;
      if (nextIdx >= _timelineFrames.length) {
        nextIdx = 0; // Bucle
      }
      _loadFrameAtIndex(nextIdx);
    });
  }

  void _stopPlayback() {
    _playTimer?.cancel();
    if (mounted) {
      setState(() {
        _isPlaying = false;
      });
    }
  }

  void _togglePlayback() {
    if (_isPlaying) {
      _stopPlayback();
    } else {
      _startPlayback();
    }
  }


  Color _getSeverityColor(String? intensity) {
    switch (intensity) {
      case 'ligera':
        return const Color(0xFF3B82F6); // Azul
      case 'moderada':
        return const Color(0xFF06B6D4); // Cian
      case 'fuerte':
        return const Color(0xFF10B981); // Verde
      case 'muy fuerte':
        return const Color(0xFFF59E0B); // Naranja
      case 'severa':
        return const Color(0xFFEF4444); // Rojo
      default:
        return const Color(0xFF6B7280); // Gris (Despejado)
    }
  }


  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFFEF4444),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeFrame = _timelineFrames.isNotEmpty ? _timelineFrames[_activeFrameIndex] : null;
    final String activeTimeStr = activeFrame != null
        ? parseImageDate(activeFrame.imagen)
        : 'Cargando datos...';

    // Determinar cuántas ciudades tienen lluvia activa o proyectada
    final int stormsCount = _predictions.where((p) => p.eta != null).length;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. MAPA BASE
          Container(
            color: Colors.black,
            child: FlutterMap(
             mapController: _mapController,
            options: MapOptions(
              initialCenter: radarCenter,
              initialZoom: 9.2,
              minZoom: 9.2,
              maxZoom: 16.0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              cameraConstraint: CameraConstraint.containCenter(
                bounds: LatLngBounds(
                  const LatLng(13.2, -89.8), // Área restringida para el centro de la pantalla
                  const LatLng(14.3, -87.9),
                ),
              ),
              onTap: (tapPosition, point) async {
                setState(() {
                  _customMarkerLocation = point;
                  _selectedCity = null; // Quitar ciudad seleccionada si pulsa mapa libre
                  _selectedCityPrediction = null;
                });
                if (activeFrame != null && _stormDynamics != null) {
                  final pred = await _radarService.calculateCustomPrediction(
                    lat: point.latitude,
                    lng: point.longitude,
                    latestRainPixels: activeFrame.rainPixels,
                    dynamics: _stormDynamics!,
                  );
                  if (mounted) {
                    setState(() {
                      _customPrediction = pred;
                    });
                  }
                }
              },
            ),
            children: [
              // Capa de satélite ESRI (Restringida a El Salvador + margen amplio)
              ColorFiltered(
                colorFilter: const ColorFilter.matrix([
                  0.35, 0, 0, 0, 0,
                  0, 0.35, 0, 0, 0,
                  0, 0, 0.35, 0, 0,
                  0, 0, 0, 1.0, 0,
                ]),
                child: TileLayer(
                  urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                  userAgentPackageName: 'com.radar.marn',
                  tileProvider: CachedTileProvider(),
                  tileBounds: LatLngBounds(
                    const LatLng(12.2, -91.2),
                    const LatLng(15.0, -87.0),
                  ),
                ),
              ),
              // Capa de límites y etiquetas ESRI (Restringida a El Salvador + margen amplio)
              TileLayer(
                urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                userAgentPackageName: 'com.radar.marn',
                tileProvider: CachedTileProvider(),
                tileBounds: LatLngBounds(
                  const LatLng(12.2, -91.2),
                  const LatLng(15.0, -87.0),
                ),
              ),
              // Círculo de cobertura del radar (60 km)
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: radarCenter,
                    radius: 60000, // 60 km
                    useRadiusInMeter: true,
                    color: const Color(0x083B82F6),
                    borderColor: const Color(0xCC3B82F6),
                    borderStrokeWidth: 1.5,
                  ),
                ],
              ),
              // Superposición de la imagen del radar (con desvanecimiento cruzado e interpolación de movimiento)
              if (activeFrame != null)
                OverlayImageLayer(
                  overlayImages: [
                    OverlayImage(
                      bounds: activeFrame.boundsA,
                      opacity: activeFrame.opacityA * 0.70,
                      imageProvider: MemoryImage(activeFrame.frameA.processedPngBytes),
                    ),
                    if (activeFrame.frameB != null && activeFrame.opacityB > 0.0)
                      OverlayImage(
                        bounds: activeFrame.boundsB!,
                        opacity: activeFrame.opacityB * 0.70,
                        imageProvider: MemoryImage(activeFrame.frameB!.processedPngBytes),
                      ),
                  ],
                ),
              // Marcadores de las ciudades principales (solo cuando está seleccionada)
              MarkerLayer(
                markers: cities.map((city) {
                  final bool isSelected = _selectedCity?.name == city.name;
                  if (!isSelected) return null;

                  // Obtener la predicción de la ciudad para pintar su color correspondiente
                  final pred = _predictions.firstWhere(
                    (p) => p.city == city.name,
                    orElse: () => PredictionResult(
                      city: city.name,
                      eta: null,
                      intensity: null,
                      text: "",
                    ),
                  );

                  final Color markerColor = _getSeverityColor(pred.intensity);

                  return Marker(
                    point: city.coords,
                    width: 44,
                    height: 44,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedCity = city;
                          _selectedCityPrediction = pred;
                          _customMarkerLocation = null; // Ocultar marcador manual si pulsa ciudad
                          _mapController.move(city.coords, 10.5);
                        });
                      },
                      child: Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          width: 18.0,
                          height: 18.0,
                          decoration: BoxDecoration(
                            color: markerColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.amber,
                              width: 2.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: markerColor.withOpacity(0.6),
                                blurRadius: 8,
                                spreadRadius: 3,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).whereType<Marker>().toList(),
              ),
              // Marcador de ubicación seleccionada manualmente
              if (_customMarkerLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _customMarkerLocation!,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.blue,
                        size: 32,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),

          // 2. PANEL COMPACTO DE CABECERA (METADATOS EN ESQUINA SUPERIOR)
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            child: _buildGlassPanel(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Cuenta regresiva / estado
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: _statusMessage == 'Sincronizado' || _statusMessage == 'Demo Activa'
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFFF59E0B),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _formatSeconds(_secondsToNextUpdate),
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFD1D5DB),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.refresh, color: Color(0xFF9CA3AF), size: 16),
                        onPressed: _isLoading ? null : _refreshLiveRadar,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    activeTimeStr,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 3. CAPAS DE INFORMACIÓN FLOTANTES (POPUP/DETALLE ACTIVO)
          if (_selectedCity != null || _customMarkerLocation != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 210, // Ubicado sobre la barra de control de tiempo y leyenda
              child: _buildGlassPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _selectedCity != null
                              ? _selectedCity!.name
                              : 'Ubicación Personalizada',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.close, color: Color(0xFF9CA3AF), size: 18),
                          onPressed: () {
                            setState(() {
                              _selectedCity = null;
                              _selectedCityPrediction = null;
                              _customMarkerLocation = null;
                              _customPrediction = null;
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _getSeverityColor(
                              _selectedCity != null
                                  ? _selectedCityPrediction?.intensity
                                  : _customPrediction?.intensity,
                            ).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: _getSeverityColor(
                                _selectedCity != null
                                    ? _selectedCityPrediction?.intensity
                                    : _customPrediction?.intensity,
                              ).withOpacity(0.6),
                            ),
                          ),
                          child: Text(
                            (_selectedCity != null
                                    ? _selectedCityPrediction?.intensity
                                    : _customPrediction?.intensity) ??
                                'DESPEJADO',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: _getSeverityColor(
                                _selectedCity != null
                                    ? _selectedCityPrediction?.intensity
                                    : _customPrediction?.intensity,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            (_selectedCity != null
                                    ? _selectedCityPrediction?.text
                                    : _customPrediction?.text) ??
                                'Sin información disponible',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFE5E7EB),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // 4. LEYENDA FLOTANTE (ESTILO WINDY)
          Positioned(
            left: 16,
            bottom: 145, // Elevado para que no se clipee con el timeline
            child: _buildGlassPanel(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Intensidad (Reflectividad)',
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: 140,
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      gradient: const LinearGradient(
                        colors: [
                          Color(0x6E3B82F6), // Ligera
                          Color(0xAA06B6D4), // Moderada
                          Color(0xD310B981), // Fuerte
                          Color(0xF0F59E0B), // M. Fuerte
                          Color(0xFFEF4444), // Severa
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  const SizedBox(
                    width: 140,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Lte.', style: TextStyle(fontSize: 7.5, color: Color(0xFF9CA3AF))),
                        Text('Mod.', style: TextStyle(fontSize: 7.5, color: Color(0xFF9CA3AF))),
                        Text('Fte.', style: TextStyle(fontSize: 7.5, color: Color(0xFF9CA3AF))),
                        Text('Sev.', style: TextStyle(fontSize: 7.5, color: Color(0xFF9CA3AF))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 5. BOTÓN EN LA ESQUINA SUPERIOR PARA LAS UBICACIONES (ESTILO GLASS)
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 16,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _isPredictionsExpanded = !_isPredictionsExpanded;
                });
              },
              child: _buildGlassPanel(
                padding: const EdgeInsets.all(10),
                child: Badge(
                  label: Text(stormsCount.toString()),
                  backgroundColor: stormsCount > 0 ? const Color(0xFFEF4444) : const Color(0xFF6B7280),
                  child: const Icon(
                    Icons.location_on_outlined,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),

          // 6. PANEL DESLIZANTE DE PREDICCIONES (AHORACAST / NOWCASTING)
          if (_isPredictionsExpanded)
            Positioned(
              top: MediaQuery.of(context).padding.top + 76,
              right: 16,
              bottom: 145, // Elevado para alinearse con la leyenda
              width: 250,
              child: _buildGlassPanel(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'PREDICCIÓN LLUVIA',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.close, color: Color(0xFF9CA3AF), size: 16),
                          onPressed: () {
                            setState(() {
                              _isPredictionsExpanded = false;
                            });
                          },
                        ),
                      ],
                    ),
                    const Text(
                      'Estimación para la próxima hora',
                      style: TextStyle(fontSize: 9, color: Color(0xFF9CA3AF)),
                    ),
                    const SizedBox(height: 8),
                    if (_stormDynamics != null && _stormDynamics!.speedKmh > 0)
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0x0B3B82F6),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0x223B82F6)),
                        ),
                        child: Text(
                          'Tormentas: ${_stormDynamics!.speedKmh.round()} km/h hacia el ${_stormDynamics!.heading}',
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF90CDF4),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _predictions.isEmpty
                          ? const Center(
                                child: Text(
                                  'Calculando reflectividad...',
                                  style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF), fontStyle: FontStyle.italic),
                                ),
                            )
                          : ListView.separated(
                              padding: EdgeInsets.zero,
                              itemCount: _predictions.length,
                              separatorBuilder: (context, index) => const SizedBox(height: 6),
                              itemBuilder: (context, index) {
                                final pred = _predictions[index];
                                final isRaining = pred.eta != null;
                                final Color statusColor = _getSeverityColor(pred.intensity);

                                return Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: () {
                                      final cityObj = cities.firstWhere((c) => c.name == pred.city);
                                      setState(() {
                                        _selectedCity = cityObj;
                                        _selectedCityPrediction = pred;
                                        _customMarkerLocation = null;
                                        _mapController.move(cityObj.coords, 10.5);
                                      });
                                    },
                                    borderRadius: BorderRadius.circular(6),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.02),
                                        border: Border.all(color: Colors.white.withOpacity(0.04)),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              pred.city,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w500,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.end,
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                                decoration: BoxDecoration(
                                                  color: statusColor.withOpacity(0.15),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  pred.intensity ?? 'DESPEJADO',
                                                  style: TextStyle(
                                                    fontSize: 7.5,
                                                    fontWeight: FontWeight.bold,
                                                    color: statusColor,
                                                  ),
                                                ),
                                              ),
                                              if (isRaining)
                                                Text(
                                                  pred.eta == 0 ? 'Ahora' : '${pred.eta} min',
                                                  style: const TextStyle(
                                                    fontSize: 8.5,
                                                    color: Color(0xFF9CA3AF),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),

          // 7. BARRA DE TIEMPO INTERACTIVA (BOTTOM PLAYBAR)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: _buildGlassPanel(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Botón Play / Pause
                      GestureDetector(
                        onTap: _togglePlayback,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: const BoxDecoration(
                            color: Color(0xFF3B82F6),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                      // Título del visor del timeline
                      Text(
                        _isPlaying ? 'Reproduciendo Historial' : 'Secuencia de Radar',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Slider de la Línea de Tiempo
                  if (_timelineFrames.isNotEmpty) ...[
                    Row(
                      children: [
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3.0,
                              thumbColor: const Color(0xFF3B82F6),
                              activeTrackColor: const Color(0xFF3B82F6),
                              inactiveTrackColor: Colors.white10,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.0),
                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                            ),
                            child: Slider(
                              value: _activeFrameIndex.toDouble(),
                              min: 0,
                              max: (_timelineFrames.length - 1).toDouble(),
                              divisions: _timelineFrames.length > 1 ? _timelineFrames.length - 1 : 1,
                              onChanged: (val) {
                                _stopPlayback();
                                _loadFrameAtIndex(val.toInt());
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Marcas de tiempo de los extremos del Slider
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatTimeLabel(_timelineFrames.first.imagen),
                            style: const TextStyle(fontSize: 8, color: Color(0xFF9CA3AF)),
                          ),
                          Text(
                            _formatTimeLabel(_timelineFrames.last.imagen),
                            style: const TextStyle(fontSize: 8, color: Color(0xFF9CA3AF)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // 8. INDICADOR DE PROCESAMIENTO / CARGA GENERAL
          if (_isLoading)
            Positioned.fill(
              child: Container(
                color: Colors.black45,
                child: Center(
                  child: _buildGlassPanel(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF3B82F6)),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _statusMessage,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }



  // Helper para crear paneles con efecto Glassmorphic (Liquid Glass)
  Widget _buildGlassPanel({required Widget child, EdgeInsetsGeometry? padding}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20.0, sigmaY: 20.0),
        child: Container(
          padding: padding ?? const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0x550B0F19), // 33% dark space blue
                const Color(0x330B0F19), // 20% dark space blue
              ],
            ),
            border: Border.all(
              color: Colors.white.withOpacity(0.12),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 10,
                spreadRadius: -2,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  String _formatSeconds(int totalSeconds) {
    if (totalSeconds < 0) return '0:00';
    final int m = totalSeconds ~/ 60;
    final int s = totalSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _formatTimeLabel(String filename) {
    final match = RegExp(r'\s+(\d{2})-(\d{2})').firstMatch(filename);
    if (match != null) {
      return "${match.group(1)}:${match.group(2)}";
    }
    return filename;
  }

  String parseImageDate(String filename) {
    if (filename.isEmpty) return '-';
    final RegExp regExp = RegExp(r'^(\d{4})-(\d{2})-(\d{2})\s+(\d{2})-(\d{2})-(\d{2})');
    final match = regExp.firstMatch(filename);
    if (match != null) {
      final year = match.group(1);
      final monthIdx = int.parse(match.group(2)!) - 1;
      final day = int.parse(match.group(3)!).toString();
      final hour = match.group(4);
      final minute = match.group(5);
      
      const List<String> months = [
        "enero", "febrero", "marzo", "abril", "mayo", "junio",
        "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"
      ];
      
      return "$day de ${months[monthIdx]} de $year, $hour:$minute";
    }
    return filename;
  }
}

class InterpolatedFrame {
  final String imagen;
  final RadarFrame frameA;
  final RadarFrame? frameB;
  final LatLngBounds boundsA;
  final LatLngBounds? boundsB;
  final double opacityA;
  final double opacityB;
  final List<RainPixel> rainPixels;
  final StormDynamics dynamics;
  final List<PredictionResult> predictions;

  InterpolatedFrame({
    required this.imagen,
    required this.frameA,
    this.frameB,
    required this.boundsA,
    this.boundsB,
    required this.opacityA,
    required this.opacityB,
    required this.rainPixels,
    required this.dynamics,
    required this.predictions,
  });
}
