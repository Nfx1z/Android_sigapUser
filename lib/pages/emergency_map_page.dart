import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:url_launcher/url_launcher.dart';

/// Displays a reported location using only data received over BLE.
/// No map tiles are fetched — this screen must work with zero internet,
/// since it exists precisely for when the field device has no connectivity.
class EmergencyMapPage extends StatelessWidget {
  final ll.LatLng position;
  final String title;
  final String? disasterName;
  final String? destructionName;
  final DateTime? sentAt;

  const EmergencyMapPage({
    super.key,
    required this.position,
    this.title = 'Lokasi',
    this.disasterName,
    this.destructionName,
    this.sentAt,
  });

  Future<void> _openInGoogleMaps() async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${position.latitude},${position.longitude}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _copyCoordinates(BuildContext context) async {
    final text =
        '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}';
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Koordinat disalin')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasDisasterInfo = disasterName != null && destructionName != null;
    final timeLabel = sentAt != null
        ? '${sentAt!.hour.toString().padLeft(2, '0')}:${sentAt!.minute.toString().padLeft(2, '0')} '
        '${sentAt!.day}/${sentAt!.month}/${sentAt!.year}'
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: const Color(0xFFE53935),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Offline location indicator — pure visual, no network calls.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 36),
              color: const Color(0xFFFFF3F3),
              child: Column(
                children: [
                  CustomPaint(
                    size: const Size(140, 140),
                    painter: _CompassPainter(),
                    child: const SizedBox(
                      width: 140,
                      height: 140,
                      child: Icon(Icons.location_on, color: Color(0xFFE53935), size: 44),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Lokasi diterima via Bluetooth',
                    style: TextStyle(color: Colors.grey[600], fontSize: 13, fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2)),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasDisasterInfo) ...[
                    Row(
                      children: [
                        const Icon(Icons.warning_amber, color: Color(0xFFE53935)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$disasterName · Kerusakan $destructionName',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (timeLabel != null)
                      Text('Dikirim: $timeLabel', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                    const SizedBox(height: 12),
                    const Divider(),
                    const SizedBox(height: 12),
                  ],
                  Text('Koordinat GPS', style: TextStyle(color: Colors.grey[600], fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}',
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Salin koordinat',
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () => _copyCoordinates(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _toDMS(position.latitude, position.longitude),
                    style: TextStyle(color: Colors.grey[600], fontSize: 13, fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: _openInGoogleMaps,
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('Buka di Google Maps (perlu internet)'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE53935),
                      side: const BorderSide(color: Color(0xFFE53935)),
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tombol di atas memerlukan koneksi internet dan bersifat opsional. '
                        'Data lokasi di atas sudah lengkap tanpa internet.',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _toDMS(double lat, double lng) {
    String convert(double value, String pos, String neg) {
      final direction = value >= 0 ? pos : neg;
      final abs = value.abs();
      final degrees = abs.floor();
      final minutesFull = (abs - degrees) * 60;
      final minutes = minutesFull.floor();
      final seconds = (minutesFull - minutes) * 60;
      return '$degrees°${minutes.toString().padLeft(2, '0')}\'${seconds.toStringAsFixed(1)}"$direction';
    }

    return '${convert(lat, 'N', 'S')}  ${convert(lng, 'E', 'W')}';
  }
}

/// Simple offline compass-ring decoration around the location pin.
/// Drawn entirely locally — no tiles, no network.
class _CompassPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final ringPaint = Paint()
      ..color = const Color(0xFFE53935).withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius, ringPaint);
    canvas.drawCircle(center, radius * 0.66, ringPaint);

    final tickPaint = Paint()
      ..color = const Color(0xFFE53935).withOpacity(0.4)
      ..strokeWidth = 2;
    for (int i = 0; i < 4; i++) {
      final angle = (pi / 2) * i;
      final outer = Offset(center.dx + radius * cos(angle), center.dy + radius * sin(angle));
      final inner = Offset(center.dx + (radius - 10) * cos(angle), center.dy + (radius - 10) * sin(angle));
      canvas.drawLine(inner, outer, tickPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}