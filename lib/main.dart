import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart';
import 'dart:async';
import 'dart:math';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const NavigationApp());

class NavigationApp extends StatelessWidget {
  const NavigationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Navigation',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final Location _locationService = Location();
  final FlutterTts _tts = FlutterTts();
  final Random _random = Random();
  final PolylinePoints _polylinePoints = PolylinePoints();

  LatLng _currentLocation = const LatLng(37.7749, -122.4194);
  List<Marker> _nearbyHospitals = [];
  List<CircleMarker> _congestionHeatmap = [];
  List<LatLng> _optimizedRoute = [];
  double _trafficIndex = 0.0; // Real-time traffic index
  double _sirTrafficIndex = 0.05; // Proportion of congested roads (I)
  double _recoveredRoads = 0.0; // Proportion of recovered roads (R)
  Timer? _updateTimer;
  bool _emergencyMode = false;
  List<LatLng> _userPath = [];
  DateTime? _routeStartTime;

  final TextEditingController _startController = TextEditingController();
  final TextEditingController _endController = TextEditingController();
  LatLng? _startPoint;
  LatLng? _endPoint;
  bool _showRouteOptions = false;
  String? _routeSummary;
  String _selectedProfile = 'fastest'; // Default routing profile

  // New Features
  UserBehavior _userBehavior = UserBehavior();
  TrafficSimulation _trafficSimulation = TrafficSimulation();
  SIRModel _sirModel = SIRModel();
  bool _ecoFriendlyMode = false;

  static const _tomtomApiKey = 'LAuxGA7NgxkpKlqhR8wApeW2eoN5QiG9';
  static const _osrmUrl = 'https://router.project-osrm.org/route/v1/driving/';
  static const _overpassApiUrl = 'https://overpass-api.de/api/interpreter';
  static const _nominatimUrl = 'https://nominatim.openstreetmap.org/search';

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _initializeLocation();
    _initializeTTS();
    _loadUserPreferences();
    _startUpdates();
  }

  Future<void> _initializeTTS() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
  }

  Future<void> _loadUserPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _emergencyMode = prefs.getBool('emergencyMode') ?? false;
      _ecoFriendlyMode = prefs.getBool('ecoFriendlyMode') ?? false;
    });
  }

  Future<void> _storeComplianceData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('emergencyMode', _emergencyMode);
    await prefs.setBool('ecoFriendlyMode', _ecoFriendlyMode);
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            child: const Text('OK'),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );
  }

  Future<void> _initializeLocation() async {
    try {
      bool serviceEnabled = await _locationService.serviceEnabled();
      if (!serviceEnabled && !await _locationService.requestService()) {
        throw 'Location service disabled';
      }

      PermissionStatus permission = await _locationService.hasPermission();
      if (permission == PermissionStatus.denied &&
          await _locationService.requestPermission() != PermissionStatus.granted) {
        throw 'Location permission denied';
      }

      await _getCurrentLocation();
    } catch (e) {
      _showErrorDialog('Location Error', e.toString());
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      final locationData = await _locationService.getLocation();
      setState(() {
        _currentLocation = LatLng(
          locationData.latitude ?? _currentLocation.latitude,
          locationData.longitude ?? _currentLocation.longitude,
        );
        _userPath.add(_currentLocation);
      });
      _mapController.move(_currentLocation, 14);
    } catch (e) {
      _showErrorDialog('Location Error', e.toString());
    }
  }

  void _startUpdates() {
    _routeStartTime = DateTime.now();
    _updateTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      await _getCurrentLocation();
      _checkRouteCompliance();
      await _fetchTrafficData();
      await _fetchNearbyHospitals();
      _updateTrafficModel();
      if (_emergencyMode) _calculateOptimizedRoute();
      _storeComplianceData();
    });
  }

  Future<void> _fetchTrafficData() async {
    const timeout = Duration(seconds: 5);
    try {
      final response = await http.get(
        Uri.parse(
          'https://api.tomtom.com/traffic/services/4/flowSegmentData/absolute/10/json?'
          'point=${_currentLocation.latitude},${_currentLocation.longitude}&key=$_tomtomApiKey',
        ),
      ).timeout(timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('TomTom API Response: $data');

        final flow = data['flowSegmentData'];
        if (flow['freeFlowSpeed'] == 0 || flow['currentSpeed'] == null || flow['currentSpeed'] == 0) {
          print('Invalid traffic data: Falling back to simulated traffic');
          _simulateTraffic();
          return;
        }

        final speedRatio = 1 - (flow['currentSpeed'] / flow['freeFlowSpeed']);
        setState(() => _trafficIndex = speedRatio.clamp(0.0, 1.0).toDouble());
      } else {
        print('TomTom API Error: ${response.statusCode}');
        _simulateTraffic();
      }
    } catch (e) {
      print('TomTom API Exception: $e');
      _simulateTraffic();
    }
    _updateHeatmap(); // Force heatmap update
  }

  void _simulateTraffic() {
    final simulatedIndex = (0.1 + _random.nextDouble() * 0.2).clamp(0.1, 0.3); // Low traffic index
    print('Simulated Traffic Index: $simulatedIndex');
    setState(() => _trafficIndex = simulatedIndex);
  }

  Future<void> _fetchNearbyHospitals() async {
    final query = '''
      [out:json];
      node
        [amenity=hospital]
        (around:5000,${_currentLocation.latitude},${_currentLocation.longitude});
      out body;
    ''';

    try {
      final response = await http.post(
        Uri.parse(_overpassApiUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: query,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final hospitals = data['elements'] as List<dynamic>;

        setState(() {
          _nearbyHospitals = hospitals.map<Marker>((hospital) => Marker(
            width: 40,
            height: 40,
            point: LatLng(
              (hospital['lat'] as num).toDouble(),
              (hospital['lon'] as num).toDouble(),
            ),
            child: const Icon(Icons.local_hospital, color: Colors.red),
          )).toList();
        });
      } else {
        _showErrorDialog('Hospital Data', 'Failed to fetch hospital data: ${response.statusCode}');
      }
    } catch (e) {
      _showErrorDialog('Hospital Data', 'Failed to fetch hospital locations: $e');
    }
  }

  void _updateTrafficModel() {
    final susceptible = 1 - _sirTrafficIndex - _recoveredRoads; // S = 1 - I - R
    final decayFactor = 0.01; // Small decay factor to simulate natural recovery

    // Update the SIR index (I)
    final deltaI = (_sirModel.beta * susceptible * _sirTrafficIndex) - (_sirModel.gamma * _sirTrafficIndex) - decayFactor;
    setState(() {
      _sirTrafficIndex = (_sirTrafficIndex + deltaI).clamp(0.0, 1.0);
    });

    // Update the recovered roads (R)
    final deltaR = _sirModel.gamma * _sirTrafficIndex; // Rate of change of recovered roads
    setState(() {
      _recoveredRoads = (_recoveredRoads + deltaR).clamp(0.0, 1.0);
    });

    // Check if SIR index exceeds threshold
    if (_sirTrafficIndex >= 0.9) {
      _sirTrafficIndex = 0.1; // Reset to baseline
      _recoveredRoads = 0.0; // Reset recovered roads
      _showNotification("Warning: Traffic congestion is critical! Consider alternative routes.");
    }
  }

  void _updateHeatmap() {
    setState(() {
      _congestionHeatmap = List.generate(20, (index) {
        final point = LatLng(
          _currentLocation.latitude + _random.nextDouble() * 0.02 - 0.01,
          _currentLocation.longitude + _random.nextDouble() * 0.02 - 0.01,
        );
        final radius = 20 + (50 * _trafficIndex); // Increased base radius and scaling factor
        final color = Color.lerp(Colors.green, Colors.red, _trafficIndex)!.withOpacity(0.5);
        print('Heatmap Circle: Point=$point, Radius=$radius, Color=$color');
        return CircleMarker(
          point: point,
          color: color,
          radius: radius,
        );
      });
    });
  }

  Future<void> _calculateOptimizedRoute() async {
    if (_nearbyHospitals.isEmpty) return;

    try {
      final response = await http.get(Uri.parse(
        '$_osrmUrl${_currentLocation.longitude},${_currentLocation.latitude};'
        '${_nearbyHospitals.first.point.longitude},${_nearbyHospitals.first.point.latitude}'
        '?overview=full'
      )).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final polyline = data['routes'][0]['geometry'] as String;
        final points = _polylinePoints.decodePolyline(polyline);

        setState(() => _optimizedRoute = points.map((p) => LatLng(p.latitude, p.longitude)).toList());
        _showNotification("New Optimized Route Calculated");
      }
    } catch (e) {
      _showErrorDialog('Routing Error', 'Failed to calculate route');
    }
  }

  void _checkRouteCompliance() {
    if (_optimizedRoute.isEmpty || _userPath.isEmpty) return;

    final currentPoint = _userPath.last;
    double minDistance = double.infinity;

    for (final point in _optimizedRoute) {
      final distance = _calculateDistance(currentPoint, point);
      if (distance < minDistance) minDistance = distance;
    }

    if (minDistance > 100) {
      _showNotification("Route Deviation Detected! Recalculating...");
      _calculateOptimizedRoute();
    }
  }

  double _calculateDistance(LatLng p1, LatLng p2) {
    final dLat = (p2.latitude - p1.latitude).abs() * 111319.9;
    final dLon = (p2.longitude - p1.longitude).abs() * 111319.9 *
                 cos(p1.latitude * pi / 180);
    return sqrt(pow(dLat, 2) + pow(dLon, 2));
  }

  void _showNotification(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("System Notification"),
        content: Text(message),
        actions: [
          TextButton(
            child: const Text("OK"),
            onPressed: () => Navigator.of(ctx).pop(),
          )
        ],
      ),
    );
    _tts.speak(message);
  }

  Future<LatLng?> _geocodeAddress(String address) async {
    if (address == "Current Location") return _currentLocation;

    try {
      final response = await http.get(
        Uri.parse('$_nominatimUrl?format=json&q=$address'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data.isNotEmpty) {
          return LatLng(
            double.parse(data[0]['lat']),
            double.parse(data[0]['lon']),
          );
        }
      }
      return null;
    } catch (e) {
      _showErrorDialog('Geocoding Error', 'Failed to find location: $e');
      return null;
    }
  }

  Future<void> _calculateCustomRoute() async {
    if (_startController.text.isEmpty || _endController.text.isEmpty) {
      _showErrorDialog('Input Error', 'Please enter both start and end points.');
      return;
    }

    final start = await _geocodeAddress(_startController.text);
    final end = await _geocodeAddress(_endController.text);

    if (start == null || end == null) {
      _showErrorDialog('Geocoding Error', 'Could not find one or both locations.');
      return;
    }

    if (_ecoFriendlyMode) {
      await _calculateEcoFriendlyRoute(start, end);
    } else {
      await _calculateOSRMRoute(start, end);
    }
  }

  Future<void> _calculateOSRMRoute(LatLng start, LatLng end) async {
    try {
      String profile = 'driving'; // Default OSRM profile
      if (_selectedProfile == 'walking') {
        profile = 'walking';
      } else if (_selectedProfile == 'cycling') {
        profile = 'cycling';
      }

      final response = await http.get(Uri.parse(
        '$_osrmUrl${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&profile=$profile'
      )).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final route = data['routes'][0];
        final polyline = route['geometry'] as String;
        final points = _polylinePoints.decodePolyline(polyline);

        setState(() {
          _startPoint = start;
          _endPoint = end;
          _optimizedRoute = points.map((p) => LatLng(p.latitude, p.longitude)).toList();
          _routeSummary = '''
            Distance: ${(route['distance'] / 1000).toStringAsFixed(1)} km
            Duration: ${(route['duration'] / 60).toStringAsFixed(1)} mins
            Profile: $_selectedProfile
          ''';
        });

        _showNotification("Route calculated successfully");
      }
    } catch (e) {
      _showErrorDialog('Routing Error', 'Failed to calculate route: $e');
    }
  }

  Future<void> _calculateEcoFriendlyRoute(LatLng start, LatLng end) async {
    try {
      // Fetch multiple routes from OSRM
      final response = await http.get(Uri.parse(
        '$_osrmUrl${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&alternatives=true'
      )).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final routes = data['routes'] as List<dynamic>;

        // Simulate eco-friendly selection (e.g., choose the route with the least distance)
        final ecoFriendlyRoute = routes.reduce((a, b) => a['distance'] < b['distance'] ? a : b);

        final polyline = ecoFriendlyRoute['geometry'] as String;
        final points = _polylinePoints.decodePolyline(polyline);

        setState(() {
          _startPoint = start;
          _endPoint = end;
          _optimizedRoute = points.map((p) => LatLng(p.latitude, p.longitude)).toList();
          _routeSummary = '''
            Distance: ${(ecoFriendlyRoute['distance'] / 1000).toStringAsFixed(1)} km
            Duration: ${(ecoFriendlyRoute['duration'] / 60).toStringAsFixed(1)} mins
            Profile: eco-friendly
          ''';
        });

        _showNotification("Eco-friendly route calculated successfully");
      }
    } catch (e) {
      _showErrorDialog('Routing Error', 'Failed to calculate eco-friendly route: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Navigation'),
        actions: [
          IconButton(
            icon: Icon(Icons.emergency, color: _emergencyMode ? Colors.red : Colors.white),
            onPressed: () => setState(() => _emergencyMode = !_emergencyMode),
          ),
          IconButton(
            icon: const Icon(Icons.route),
            onPressed: () => setState(() => _showRouteOptions = !_showRouteOptions),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_emergencyMode)
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.red,
              child: const Center(
                child: Text(
                  'EMERGENCY MODE ACTIVE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          if (_showRouteOptions) _buildRouteOptions(),
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                center: _currentLocation,
                zoom: 14.0,
                interactiveFlags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                  subdomains: const ['a', 'b', 'c'],
                ),
                CircleLayer(circles: _congestionHeatmap), // Heatmap layer
                PolylineLayer(
                  polylines: [Polyline(
                    points: _optimizedRoute,
                    color: Colors.blue,
                    strokeWidth: 4,
                  )],
                ),
                MarkerLayer(markers: [
                  if (_startPoint != null)
                    Marker(
                      width: 40,
                      height: 40,
                      point: _startPoint!,
                      child: const Icon(Icons.location_on, color: Colors.green),
                    ),
                  if (_endPoint != null)
                    Marker(
                      width: 40,
                      height: 40,
                      point: _endPoint!,
                      child: const Icon(Icons.location_on, color: Colors.red),
                    ),
                ]),
              ],
            ),
          ),
          if (_routeSummary != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _routeSummary!,
                style: const TextStyle(fontSize: 16),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildTrafficIndicator('Congestion (I)', _sirTrafficIndex, Colors.red),
                _buildTrafficIndicator('Recovered Roads (R)', _recoveredRoads, Colors.green),
                _buildTrafficIndicator('Real-Time Traffic', _trafficIndex, Colors.orange), // Added real-time traffic indicator
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteOptions() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _startController,
                  decoration: const InputDecoration(
                    labelText: 'Start Point',
                    hintText: 'Enter address or "Current Location"',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.my_location),
                onPressed: () {
                  setState(() {
                    _startController.text = "Current Location";
                    _startPoint = _currentLocation;
                  });
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            controller: _endController,
            decoration: const InputDecoration(
              labelText: 'End Point',
              hintText: 'Enter destination address',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: DropdownButton<String>(
            value: _selectedProfile,
            onChanged: (String? newValue) {
              setState(() {
                _selectedProfile = newValue!;
              });
            },
            items: <String>['fastest', 'shortest', 'eco-friendly']
                .map<DropdownMenuItem<String>>((String value) {
              return DropdownMenuItem<String>(
                value: value,
                child: Text(value),
              );
            }).toList(),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton(
              onPressed: _calculateCustomRoute,
              child: const Text('Calculate Route'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _showRouteOptions = false;
                  _optimizedRoute.clear();
                  _routeSummary = null;
                });
              },
              child: const Text('Clear Route'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTrafficIndicator(String label, double value, Color color) {
    return Column(
      children: [
        Text(label),
        CircularProgressIndicator(
          value: value,
          backgroundColor: color.withOpacity(0.2),
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
        Text('${(value * 100).toStringAsFixed(1)}%'),
      ],
    );
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _tts.stop();
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }
}

// New Classes for Additional Features

class UserBehavior {
  double complianceRate; // Tracks how often users follow suggestions
  Map<LatLng, int> routeDeviations; // Tracks deviations from suggested routes

  UserBehavior() : complianceRate = 1.0, routeDeviations = {};

  void updateCompliance(LatLng currentLocation, LatLng suggestedRoute) {
    if (!_isOnRoute(currentLocation, suggestedRoute)) {
      routeDeviations[currentLocation] = (routeDeviations[currentLocation] ?? 0) + 1;
      complianceRate = 1.0 - (routeDeviations.length / 100); // Example calculation
    }
  }

  bool _isOnRoute(LatLng currentLocation, LatLng suggestedRoute) {
    // Check if the user is on the suggested route
    return _calculateDistance(currentLocation, suggestedRoute) < 100; // 100 meters tolerance
  }

  double _calculateDistance(LatLng p1, LatLng p2) {
    // Calculate distance between two points
    final dLat = (p2.latitude - p1.latitude).abs() * 111319.9;
    final dLon = (p2.longitude - p1.longitude).abs() * 111319.9 * cos(p1.latitude * pi / 180);
    return sqrt(pow(dLat, 2) + pow(dLon, 2));
  }
}

class TrafficSimulation {
  Map<LatLng, double> congestionLevels; // Tracks congestion levels across the network

  TrafficSimulation() : congestionLevels = {};

  void updateCongestion(LatLng location, double trafficIndex) {
    congestionLevels[location] = trafficIndex;
  }

  double getSystemWideCongestion() {
    // Calculate average congestion level
    return congestionLevels.values.reduce((a, b) => a + b) / congestionLevels.length;
  }
}

class SIRModel {
  double beta; // Congestion propagation rate
  double gamma; // Congestion dissipation rate

  SIRModel({this.beta = 0.4, this.gamma = 0.25});

  void updateParameters(double trafficIndex) {
    // Adjust beta and gamma based on real-time traffic data
    beta = 0.4 * trafficIndex;
    gamma = 0.25 * (1 - trafficIndex);
  }

  double calculateR0() {
    return beta / gamma; // Basic reproductive number
  }
}