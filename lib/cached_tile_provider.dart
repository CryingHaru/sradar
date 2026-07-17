import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class CachedTileProvider extends TileProvider {
  CachedTileProvider({super.headers});

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    return CachedTileImageProvider(url, headers: headers);
  }
}

class CachedTileImageProvider extends ImageProvider<CachedTileImageProvider> {
  final String url;
  final Map<String, String>? headers;

  CachedTileImageProvider(this.url, {this.headers});

  @override
  Future<CachedTileImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CachedTileImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(CachedTileImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<CachedTileImageProvider>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(CachedTileImageProvider key, ImageDecoderCallback decode) async {
    try {
      final cacheDir = await getTemporaryDirectory();
      // Generamos un hash simple a partir de la URL para usarlo como nombre de archivo único
      final hash = key.url.hashCode.toString();
      final file = File('${cacheDir.path}/map_tiles/$hash.png');

      // Nos aseguramos de que el directorio del caché exista
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }

      Uint8List bytes;
      if (await file.exists()) {
        bytes = await file.readAsBytes();
      } else {
        final uri = Uri.parse(key.url);
        final response = await http.get(uri, headers: key.headers);
        if (response.statusCode == 200) {
          bytes = response.bodyBytes;
          await file.writeAsBytes(bytes);
        } else {
          throw Exception('Error al descargar la tesela: ${response.statusCode}');
        }
      }

      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return decode(buffer);
    } catch (e) {
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is CachedTileImageProvider && other.url == url;
  }

  @override
  int get hashCode => url.hashCode;
}
