import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:google_maps_cluster_manager_2/google_maps_cluster_manager_2.dart';

enum ClusterAlgorithm { geoHash, maxDist }

class MaxDistParams {
  MaxDistParams(this.epsilon);

  final double epsilon;
}

class ClusterManager<T extends ClusterItem> {
  ClusterManager({
    this.levels = const [1, 4.25, 6.75, 8.25, 11.5, 14.5, 16.0, 16.5, 20.0],
    this.extraPercent = 0.5,
    this.maxItemsForMaxDistAlgo = 200,
    this.clusterAlgorithm = ClusterAlgorithm.geoHash,
    this.maxDistParams,
    this.stopClusteringZoom,
  }) : assert(
          levels.length <= precision,
          'Levels length should be less than or equal to precision',
        );

  // Num of Items to switch from MAX_DIST algo to GEOHASH
  final int maxItemsForMaxDistAlgo;

  /// Zoom levels configuration
  final List<double> levels;

  /// Extra percent of markers to be loaded (ex : 0.2 for 20%)
  final double extraPercent;

  // Clusteringalgorithm
  final ClusterAlgorithm clusterAlgorithm;

  final MaxDistParams? maxDistParams;

  /// Zoom level to stop cluster rendering
  final double? stopClusteringZoom;

  /// Precision of the geohash
  static const precision = kIsWeb ? 12 : 20;

  /// Google Maps map id
  int? _mapId;

  final double _maxLng = 180 - pow(10, -10.0) as double;

  /// Set Google Map Id for the cluster manager
  Future<void> setMapId(int mapId) async {
    _mapId = mapId;
  }

  bool firstInit = true;

  int lastLevel = -1;
  int lastMarkerCount = -1;
  List<Cluster<T>> markers = [];
  List<Cluster<T>> allMarkers = <Cluster<T>>[];

  /// Retrieve cluster markers
  Future<List<Cluster<T>>> getMarkers(
    List<T> items,
    double zoom, {
    bool increaseLevel = false,
  }) async {
    if (_mapId == null) return List.empty();

    late List<T> visibleItems;

    final mapBounds = await GoogleMapsFlutterPlatform.instance
        .getVisibleRegion(mapId: _mapId!);

    if (firstInit) {
      visibleItems = items;
    } else {
      late LatLngBounds inflatedBounds;
      if (clusterAlgorithm == ClusterAlgorithm.geoHash) {
        inflatedBounds = _inflateBounds(mapBounds);
      } else {
        inflatedBounds = mapBounds;
      }

      visibleItems = items.where((i) {
        return inflatedBounds.contains(i.location);
      }).toList();

      if (stopClusteringZoom != null && zoom >= stopClusteringZoom!) {
        lastMarkerCount = visibleItems.length;
        return visibleItems.map((i) => Cluster<T>.fromItems([i])).toList();
      }
    }

    if (clusterAlgorithm == ClusterAlgorithm.geoHash ||
        visibleItems.length >= maxItemsForMaxDistAlgo) {
      var level = _findLevel(levels, zoom);
      do {
        markers = _computeClusters(
          visibleItems,
          List.empty(growable: true),
          level: level,
        );
        allMarkers = _computeClusters(
          items,
          List.empty(growable: true),
          level: level,
        );
        debugPrint("TOKU OLD ${lastMarkerCount}");
        debugPrint("TOKU NEW ${allMarkers.length}");
        level++;
      } while (increaseLevel &&
          allMarkers.length <= lastMarkerCount &&
          level < levels.length);

      lastLevel = level;
    } else {
      markers = _computeClustersWithMaxDist(visibleItems, zoom);
    }
    if (firstInit) {
      firstInit = false;
    }
    // if (increaseLevel) {
    lastMarkerCount = allMarkers.length;
    // }
    return markers;
  }

  LatLngBounds _inflateBounds(LatLngBounds bounds) {
    // Bounds that cross the date line expand compared to their difference with the date line
    var lng = 0.0;
    if (bounds.northeast.longitude < bounds.southwest.longitude) {
      lng = extraPercent *
          ((180.0 - bounds.southwest.longitude) +
              (bounds.northeast.longitude + 180));
    } else {
      lng = extraPercent *
          (bounds.northeast.longitude - bounds.southwest.longitude);
    }

    // Latitudes expanded beyond +/- 90 are automatically clamped by LatLng
    final lat =
        extraPercent * (bounds.northeast.latitude - bounds.southwest.latitude);

    final eLng = (bounds.northeast.longitude + lng).clamp(-_maxLng, _maxLng);
    final wLng = (bounds.southwest.longitude - lng).clamp(-_maxLng, _maxLng);

    return LatLngBounds(
      southwest: LatLng(bounds.southwest.latitude - lat, wLng),
      northeast:
          LatLng(bounds.northeast.latitude + lat, lng != 0 ? eLng : _maxLng),
    );
  }

  void updateMap(Set<Marker> previous, Set<Marker> current) {
    GoogleMapsFlutterPlatform.instance
        .updateMarkers(MarkerUpdates.from(previous, current), mapId: _mapId!);
  }

  Future<void> onCameraUpdate(CameraUpdate cameraUpdate) async {
    await GoogleMapsFlutterPlatform.instance
        .animateCamera(cameraUpdate, mapId: _mapId!);
  }

  int _findLevel(List<double> levels, double zoom) {
    for (var i = levels.length - 1; i >= 0; i--) {
      if (levels[i] <= zoom) {
        return i + 1;
      }
    }

    return 1;
  }

  int _getZoomLevel(double zoom) {
    for (var i = levels.length - 1; i >= 0; i--) {
      if (levels[i] <= zoom) {
        return levels[i].toInt();
      }
    }

    return 1;
  }

  List<Cluster<T>> _computeClustersWithMaxDist(
      List<T> inputItems, double zoom) {
    final scanner = MaxDistClustering<T>(
      epsilon: maxDistParams?.epsilon ?? 20,
    );

    return scanner.run(inputItems, _getZoomLevel(zoom));
  }

  List<Cluster<T>> _computeClusters(
      List<T> inputItems, List<Cluster<T>> markerItems,
      {int level = 5}) {
    if (inputItems.isEmpty) return markerItems;
    final nextGeohash = inputItems[0].geohash.substring(0, level);

    final items = inputItems
        .where((p) => p.geohash.substring(0, level) == nextGeohash)
        .toList();

    markerItems.add(Cluster<T>.fromItems(items));

    final newInputList = List<T>.from(
        inputItems.where((i) => i.geohash.substring(0, level) != nextGeohash));

    return _computeClusters(newInputList, markerItems, level: level);
  }
}
