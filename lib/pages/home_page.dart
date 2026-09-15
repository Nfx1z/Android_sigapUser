import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../models/disaster_options.dart';
import 'emergency_map_page.dart';

enum AppState {
  IDLE,
  SYNCING,
  WAITING_ACK,
  SUCCESS_CANCEL_WINDOW,
  FAILED,
  FINAL,
  CANCEL_WAITING,
  WARNING_PENDING,
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // BLE
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? writeCharacteristic;
  BluetoothCharacteristic? notifyCharacteristic;
  bool isScanning = false;
  bool isConnected = false;
  List<ScanResult> scanResults = [];
  StreamSubscription? scanSubscription;
  StreamSubscription? notifySubscription;
  StreamSubscription? connectionStateSubscription;

  AppState _appState = AppState.IDLE;
  Timer? _cancelWindowTimer;

  // True while a warning-resolution command (cancel/forward) has been sent
  // from the app but the device hasn't confirmed it yet. Disables both
  // warning buttons in the meantime so a double-tap (or tapping both) can't
  // fire two commands for the same pending warning.
  bool _warningActionPending = false;

  // Timer to recover if the device never notifies back after HELP,
  // and dedup state to guard against duplicate notification callbacks.
  Timer? _helpTimeoutTimer;
  String? _lastNotification;
  DateTime? _lastNotificationTime;

  // Timer to recover if the device never sends its initial status sync
  // after connecting (e.g. a dropped notify subscription), so the app
  // doesn't sit on "Menyinkronkan..." forever.
  Timer? _syncTimeoutTimer;

  String statusMessage = "Tidak terhubung";
  Color statusColor = Colors.grey;
  int selectedDisasterIndex = 0;
  int selectedDestructionIndex = 0;
  Position? currentPosition;

  // Data titik kejadian untuk peta
  ll.LatLng? sentLatLng;
  String? sentDisasterName;
  String? sentDestructionName;
  DateTime? sentAt;

  final String serviceUUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String writeCharUUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  final String notifyCharUUID = "1c95d5e3-d8f7-413a-bf3d-7a2e5d7be87e";

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await requestPermissions();
    await getCurrentLocation();
  }

  @override
  void dispose() {
    _cancelWindowTimer?.cancel();
    _helpTimeoutTimer?.cancel();
    _syncTimeoutTimer?.cancel();
    scanSubscription?.cancel();
    notifySubscription?.cancel();
    connectionStateSubscription?.cancel();
    disconnectDevice();
    super.dispose();
  }

  Future<void> requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.locationWhenInUse,
    ].request();
    bool allGranted = statuses.values.every((status) => status.isGranted);
    if (!allGranted && mounted) {
      setState(() {
        statusMessage = "Izin diperlukan untuk BLE & GPS";
        statusColor = Colors.orange[700]!;
      });
    }
  }

  Future<void> getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            statusMessage = "Aktifkan Lokasi di pengaturan";
            statusColor = Colors.orange[700]!;
          });
        }
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            statusMessage = "Izin lokasi ditolak";
            statusColor = Colors.red[600]!;
          });
        }
        return;
      }

      Position? position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 30),
      );
      if (mounted) setState(() => currentPosition = position);
    } catch (e) {
      debugPrint("GPS Error: $e");
      if (mounted) {
        setState(() {
          statusMessage = "GPS: Tunggu sinyal satelit";
          statusColor = Colors.orange[700]!;
        });
      }
    }
  }

  Future<void> startScan() async {
    bool locationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!locationEnabled) {
      showAlertDialog("Aktifkan Lokasi", "Aktifkan Lokasi di pengaturan perangkat untuk scan BLE");
      return;
    }
    if (!await FlutterBluePlus.isSupported) {
      showAlertDialog("Error", "Perangkat tidak mendukung BLE");
      return;
    }
    BluetoothAdapterState adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      showAlertDialog("Error", "Aktifkan Bluetooth di pengaturan perangkat");
      return;
    }
    if (isScanning) return;

    await scanSubscription?.cancel();
    scanSubscription = null;

    setState(() {
      isScanning = true;
      scanResults.clear();
      statusMessage = "Mencari perangkat...";
      statusColor = Colors.blue[600]!;
    });

    try {
      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

      scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        List<ScanResult> fieldDevices = results.where((result) {
          String name = result.device.platformName;
          return name.isNotEmpty && name.startsWith("Field Device_");
        }).toList();
        if (mounted) setState(() => scanResults = fieldDevices);
      });

      await Future.delayed(const Duration(seconds: 10));
      await FlutterBluePlus.stopScan();
      await scanSubscription?.cancel();
      scanSubscription = null;

      if (mounted) {
        setState(() {
          isScanning = false;
          if (scanResults.isEmpty) {
            statusMessage = "Tidak ada perangkat Field Device ditemukan";
            statusColor = Colors.orange[700]!;
          }
        });
      }
    } catch (e) {
      debugPrint("Scan error: $e");
      await scanSubscription?.cancel();
      scanSubscription = null;
      if (mounted) {
        setState(() {
          isScanning = false;
          statusMessage = "Error: ${e.toString().substring(0, min(e.toString().length, 50))}";
          statusColor = Colors.red[600]!;
        });
      }
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await notifySubscription?.cancel();
      notifySubscription = null;
      await connectionStateSubscription?.cancel();
      connectionStateSubscription = null;

      setState(() {
        statusMessage = "Menghubungkan...";
        statusColor = Colors.blue[600]!;
      });

      await device.connect(timeout: const Duration(seconds: 15));

      connectionStateSubscription = device.connectionState.listen((state) {
        if (mounted && state == BluetoothConnectionState.disconnected && isConnected) {
          _handleUnexpectedDisconnect();
        }
      });

      try {
        await device.requestMtu(185);
      } catch (e) {
        debugPrint("requestMtu gagal, lanjut dengan MTU default: $e");
      }

      List<BluetoothService> services = await device.discoverServices();
      bool foundService = false;

      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUUID.toLowerCase()) {
          foundService = true;
          for (var characteristic in service.characteristics) {
            String charUuid = characteristic.uuid.toString().toLowerCase();
            if (charUuid == writeCharUUID.toLowerCase()) {
              writeCharacteristic = characteristic;
            }
            if (charUuid == notifyCharUUID.toLowerCase()) {
              notifyCharacteristic = characteristic;
              await characteristic.setNotifyValue(true);
              notifySubscription = characteristic.lastValueStream.listen((value) {
                if (value.isNotEmpty) handleNotification(value);
              });
            }
          }
        }
      }

      if (!foundService || writeCharacteristic == null || notifyCharacteristic == null) {
        throw Exception("Service/karakteristik tidak ditemukan");
      }

      if (mounted) {
        setState(() {
          connectedDevice = device;
          isConnected = true;
          // Don't assume IDLE — we don't actually know what the device is
          // doing yet. Wait for its initial status notification (sent ~1s
          // after connect) and let that drive the real state.
          _appState = AppState.SYNCING;
          statusMessage = "Menyinkronkan status alat...";
          statusColor = Colors.blue[600]!;
        });
      }
      _startSyncTimeoutTimer();
      debugPrint("Connected to ${device.platformName}");
    } catch (e) {
      debugPrint("Connection error: $e");
      await notifySubscription?.cancel();
      notifySubscription = null;
      await connectionStateSubscription?.cancel();
      connectionStateSubscription = null;
      if (mounted) {
        setState(() {
          statusMessage = "Gagal terhubung";
          statusColor = Colors.red[600]!;
        });
      }
      try { await device.disconnect(); } catch (_) {}
    }
  }

  void _startSyncTimeoutTimer() {
    _cancelSyncTimeoutTimer();
    _syncTimeoutTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      if (_appState == AppState.SYNCING) {
        setState(() {
          _appState = AppState.IDLE;
          statusMessage = "Alat tidak mengirim status. Periksa layar alat sebelum mengirim.";
          statusColor = Colors.orange[700]!;
        });
      }
    });
  }

  void _cancelSyncTimeoutTimer() {
    _syncTimeoutTimer?.cancel();
    _syncTimeoutTimer = null;
  }

  void _handleUnexpectedDisconnect() {
    notifySubscription?.cancel();
    notifySubscription = null;

    _cancelCancelWindowTimer();
    _cancelHelpTimeoutTimer();
    _cancelSyncTimeoutTimer();

    if (!mounted) return;
    setState(() {
      isConnected = false;
      connectedDevice = null;
      writeCharacteristic = null;
      notifyCharacteristic = null;
      _appState = AppState.IDLE;
      _warningActionPending = false;
      statusMessage = "Koneksi terputus";
      statusColor = Colors.grey[600]!;
    });
  }

  Future<void> disconnectDevice() async {
    if (connectedDevice != null) {
      try {
        await notifySubscription?.cancel();
        await connectionStateSubscription?.cancel();
        await connectedDevice!.disconnect();
      } catch (e) { debugPrint("Disconnect error: $e"); }
      _cancelCancelWindowTimer();
      _cancelHelpTimeoutTimer();
      _cancelSyncTimeoutTimer();
      if (mounted) {
        setState(() {
          connectedDevice = null;
          isConnected = false;
          writeCharacteristic = null;
          notifyCharacteristic = null;
          notifySubscription = null;
          connectionStateSubscription = null;
          _appState = AppState.IDLE;
          statusMessage = "Terputus";
          statusColor = Colors.grey[600]!;
        });
      }
    }
  }

  void _startCancelWindowTimer({Duration? duration}) {
    _cancelWindowTimer?.cancel();
    _cancelWindowTimer = Timer(duration ?? const Duration(minutes: 5), () {
      if (_appState == AppState.SUCCESS_CANCEL_WINDOW && mounted) {
        setState(() {
          _appState = AppState.FINAL;
          statusMessage = "Window cancel telah berakhir";
          statusColor = Colors.grey[600]!;
        });
      }
    });
  }

  void _cancelCancelWindowTimer() => _cancelWindowTimer?.cancel();

  void _startHelpTimeoutTimer() {
    _cancelHelpTimeoutTimer();
    _helpTimeoutTimer = Timer(const Duration(seconds: 25), () {
      if (!mounted) return;
      if (_appState == AppState.WAITING_ACK) {
        setState(() {
          _appState = AppState.IDLE;
          statusMessage = "Tidak ada respon dari perangkat, coba lagi";
          statusColor = Colors.orange[700]!;
        });
        showAlertDialog("Waktu Habis", "Perangkat tidak merespon. Periksa koneksi lalu coba kirim lagi.");
      }
    });
  }

  void _cancelHelpTimeoutTimer() {
    _helpTimeoutTimer?.cancel();
    _helpTimeoutTimer = null;
  }

  String? _disasterNameForCode(int? code) {
    if (code == null) return null;
    for (final item in kDisasterOptions) {
      if (item['code'] == code) return item['name'] as String?;
    }
    return null;
  }

  String? _destructionNameForCode(int? code) {
    if (code == null) return null;
    for (final item in kDestructionOptions) {
      if (item['code'] == code) return item['name'] as String?;
    }
    return null;
  }

  void handleNotification(List<int> value) {
    String rawNotification = utf8.decode(value);
    debugPrint("Received: $rawNotification");
    if (!mounted) return;

    final now = DateTime.now();
    if (_lastNotification == rawNotification &&
        _lastNotificationTime != null &&
        now.difference(_lastNotificationTime!) < const Duration(seconds: 2)) {
      debugPrint("Duplicate notification diabaikan: $rawNotification");
      return;
    }
    _lastNotification = rawNotification;
    _lastNotificationTime = now;

    _cancelHelpTimeoutTimer();
    // Any message at all means the device is alive and talking to us, so
    // the "device never sent a status" fallback no longer applies.
    _cancelSyncTimeoutTimer();

    // Sync payloads only arrive once per connection (see sendInitialSync()
    // on the device) and carry the full in-progress report/warning
    // alongside the plain state word, so a reconnect — or a fresh app
    // launch while the device is already mid-flow — can restore the same
    // picture the device has instead of defaulting to "idle". `isSync`
    // gates the side effects (dialogs, auto-opening the map) that should
    // only fire for a genuinely new event, not for catching the UI up.
    String notification = rawNotification;
    bool isSync = false;
    Duration? syncedCancelWindowRemaining;

    if (rawNotification.startsWith("SYNC_HELP,")) {
      // SYNC_HELP,<stateWord>,<disasterCode>,<destructionCode>,<lat>,<lon>,<remainingCancelMs>
      final parts = rawNotification.split(',');
      if (parts.length >= 6) {
        isSync = true;
        notification = parts[1];
        final disasterCode = int.tryParse(parts[2]);
        final destructionCode = int.tryParse(parts[3]);
        final lat = double.tryParse(parts[4]);
        final lng = double.tryParse(parts[5]);
        if (lat != null && lng != null && (lat != 0.0 || lng != 0.0)) {
          sentLatLng = ll.LatLng(lat, lng);
        }
        sentDisasterName = _disasterNameForCode(disasterCode) ?? sentDisasterName;
        sentDestructionName = _destructionNameForCode(destructionCode) ?? sentDestructionName;
        // The device doesn't track when the report was originally sent, so
        // this is a best-effort stand-in only if the app has no better one.
        sentAt ??= now;
        if (parts.length >= 7) {
          final remainingMs = int.tryParse(parts[6]);
          if (remainingMs != null) {
            syncedCancelWindowRemaining = Duration(milliseconds: remainingMs);
          }
        }
      }
    } else if (rawNotification.startsWith("SYNC_WARNING,")) {
      // SYNC_WARNING,<stateWord>,<subFieldId>
      final parts = rawNotification.split(',');
      if (parts.length >= 2) {
        isSync = true;
        notification = parts[1];
      }
    } else if (rawNotification == "SYNC_UNKNOWN") {
      // Device is locked in a state we don't have a dedicated view for
      // (shouldn't normally happen) — say so rather than guessing.
      setState(() {
        statusMessage = "Perangkat sedang memproses, cek layar alat";
        statusColor = Colors.orange[700]!;
      });
      return;
    }

    setState(() {
      switch (notification) {
        case "WAITING":
          _appState = AppState.WAITING_ACK;
          statusMessage = "Mengirim pesan...";
          statusColor = Colors.blue[600]!;
          break;
        case "SUCCESS":
          _appState = AppState.SUCCESS_CANCEL_WINDOW;
          statusMessage = "Pesan berhasil terkirim! \n(5 menit untuk cancel)";
          statusColor = Colors.green[600]!;
          _startCancelWindowTimer(duration: syncedCancelWindowRemaining);
          if (!isSync) showAlertDialog("Berhasil", "Pesan darurat terkirim!");
          break;
        case "FAILED":
          _appState = AppState.FAILED;
          statusMessage = "Gagal mengirim pesan";
          statusColor = Colors.red[600]!;
          _cancelCancelWindowTimer();
          if (!isSync) showAlertDialog("Gagal", "Pesan darurat gagal terkirim");
          break;
        case "ALARM_WAITING":
          _appState = AppState.WAITING_ACK;
          statusMessage = "Mode alarm otomatis...";
          statusColor = Colors.orange[700]!;
          showAlertDialog("Alarm", "Alarm otomatis terpicu!");
          break;
        case "CANCEL_WAITING":
          _appState = AppState.CANCEL_WAITING;
          statusMessage = "Mengirim cancel...\nTunggu ACK";
          statusColor = Colors.orange[700]!;
          _cancelCancelWindowTimer();
          if (!isSync) showAlertDialog("Cancel Dikirim", "Menunggu konfirmasi pembatalan...");
          break;
        case "CANCELLED":
          _appState = AppState.FINAL;
          statusMessage = "Pesan dibatalkan";
          statusColor = Colors.grey[600]!;
          _cancelCancelWindowTimer();
          if (!isSync) showAlertDialog("Dibatalkan", "Pesan darurat dibatalkan");
          break;
        case "CANCEL_FAILED":
          _appState = AppState.FINAL;
          statusMessage = "Cancel gagal";
          statusColor = Colors.red[600]!;
          _cancelCancelWindowTimer();
          showAlertDialog("Cancel Gagal", "Pembatalan pesan gagal (ACK tidak diterima)");
          break;
        case "READY":
          _appState = AppState.IDLE;
          statusMessage = "Perangkat siap";
          statusColor = Colors.green[600]!;
          _cancelCancelWindowTimer();
          break;
        case "GPS_NOT_READY":
          statusMessage = "GPS di alat belum siap, coba lagi";
          statusColor = Colors.orange[700]!;
          showAlertDialog("GPS Belum Siap", "Field Device belum mendapat sinyal GPS yang valid. Tunggu beberapa saat lalu coba lagi di alat.");
          break;
        case "WARNING_PENDING":
        case "WARNING_FIRE":
        case "WARNING_GAS":
          _appState = AppState.WARNING_PENDING;
          _warningActionPending = false;
          _cancelCancelWindowTimer();
          if (notification == "WARNING_FIRE") {
            statusMessage = "Peringatan: kemungkinan KEBAKARAN HUTAN — cek alat";
          } else if (notification == "WARNING_GAS") {
            statusMessage = "Peringatan: kemungkinan KEBOCORAN GAS — cek alat";
          } else {
            statusMessage = "Ada peringatan sub-field menunggu konfirmasi di alat";
          }
          statusColor = Colors.orange[700]!;
          break;
        case "WARNING_FORWARDED":
          _appState = AppState.IDLE;
          _warningActionPending = false;
          statusMessage = "Peringatan diteruskan ke HQ";
          statusColor = Colors.green[600]!;
          showAlertDialog("Diteruskan", "Peringatan sub-field sudah diteruskan ke HQ.");
          break;
        case "WARNING_DISMISSED":
          _appState = AppState.IDLE;
          _warningActionPending = false;
          statusMessage = "Peringatan dibatalkan";
          statusColor = Colors.grey[600]!;
          break;
        case "FIELD_DATA_SENT":
          break;
        default:
          if (notification.startsWith("SUBFIELD_MISSING:")) {
            final id = notification.split(':').last;
            statusMessage = "Sub-Field #$id tidak merespon";
            statusColor = Colors.red[600]!;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Sub-Field #$id hilang / tidak merespon')),
              );
            });
          } else if (notification.startsWith("SUBFIELD_RECOVERED:")) {
            final id = notification.split(':').last;
            statusMessage = "Sub-Field #$id kembali normal";
            statusColor = Colors.green[600]!;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Sub-Field #$id sudah kembali terhubung')),
              );
            });
          } else {
            statusMessage = notification;
            statusColor = Colors.blue[600]!;
          }
      }
    });
  }

  Future<bool> sendCommand(String command) async {
    if (writeCharacteristic == null) {
      showAlertDialog("Error", "Tidak terhubung ke perangkat");
      return false;
    }
    try {
      List<int> bytes = utf8.encode(command);
      await writeCharacteristic!.write(bytes, withoutResponse: false);
      debugPrint("Sent: $command");
      return true;
    } catch (e) {
      debugPrint("Send error: $e");
      showAlertDialog("Error", "Gagal mengirim: ${e.toString().substring(0, min(40, e.toString().length))}");
      return false;
    }
  }

  Future<void> sendHelpMessage() async {
    if (!isConnected || _appState != AppState.IDLE) return;

    setState(() {
      _appState = AppState.WAITING_ACK;
      statusMessage = "Mendapatkan lokasi GPS...";
      statusColor = Colors.blue[600]!;
    });

    await getCurrentLocation();
    if (currentPosition == null) {
      if (mounted) {
        setState(() {
          _appState = AppState.IDLE;
        });
      }
      showAlertDialog("GPS Tidak Siap", "Aktifkan GPS di perangkat Anda");
      return;
    }

    int disasterCode = kDisasterOptions[selectedDisasterIndex]['code'] ?? 0;
    int destructionCode = kDestructionOptions[selectedDestructionIndex]['code'] ?? 0;

    final latLng = ll.LatLng(currentPosition!.latitude, currentPosition!.longitude);
    final disasterName = kDisasterOptions[selectedDisasterIndex]['name'];
    final destructionName = kDestructionOptions[selectedDestructionIndex]['name'];
    final now = DateTime.now();

    if (mounted) {
      setState(() {
        statusMessage = "Mengirim pesan...";
        statusColor = Colors.blue[600]!;
      });
    }

    String command = "HELP,$disasterCode,$destructionCode,"
        "${currentPosition!.latitude},${currentPosition!.longitude}";
    bool sent = await sendCommand(command);

    if (!sent) {
      if (mounted) {
        setState(() {
          _appState = AppState.IDLE;
          statusMessage = "Gagal mengirim pesan";
          statusColor = Colors.red[600]!;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        sentLatLng = latLng;
        sentDisasterName = disasterName;
        sentDestructionName = destructionName;
        sentAt = now;
      });
    }

    _startHelpTimeoutTimer();
  }

  Future<void> cancelHelp() async {
    if (_appState != AppState.SUCCESS_CANCEL_WINDOW) return;
    await sendCommand("CANCEL");
  }

  Future<void> cancelWarningFromApp() async {
    if (_appState != AppState.WARNING_PENDING || _warningActionPending) return;
    setState(() => _warningActionPending = true);
    final sent = await sendCommand("CANCEL");
    // If the write itself failed, unlock immediately so the person can
    // retry — otherwise wait for the device's WARNING_DISMISSED/FORWARDED/
    // timeout notification to clear the flag, so a slow BLE round-trip
    // can't be double-tapped into two commands.
    if (!sent && mounted) setState(() => _warningActionPending = false);
  }

  Future<void> forwardWarningFromApp() async {
    if (_appState != AppState.WARNING_PENDING || _warningActionPending) return;
    setState(() => _warningActionPending = true);
    final sent = await sendCommand("FORWARD_WARNING");
    if (!sent && mounted) setState(() => _warningActionPending = false);
  }

  void _openEmergencyMapScreen() {
    if (sentLatLng == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => EmergencyMapPage(
          position: sentLatLng!,
          title: 'Lokasi Titik Kejadian',
          disasterName: sentDisasterName,
          destructionName: sentDestructionName,
          sentAt: sentAt,
        ),
      ),
    );
  }

  void showAlertDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            child: const Text("OK"),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('SIGAP - Komunikasi Darurat'),
        centerTitle: true,
        foregroundColor: Colors.black87,
        actions: [
          if (sentLatLng != null)
            IconButton(
              tooltip: 'Lihat lokasi kejadian terakhir',
              icon: const Icon(Icons.map_outlined),
              onPressed: _openEmergencyMapScreen,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusCard(),
            if (_appState == AppState.WARNING_PENDING) ...[
              const SizedBox(height: 16),
              _buildWarningPendingCard(),
            ],
            const SizedBox(height: 20),
            if (!isConnected) ...[
              _buildScanButton(),
              const SizedBox(height: 16),
              _buildDeviceList(),
            ],
            if (isConnected) ...[
              _buildGPSInfo(),
              const SizedBox(height: 16),
              _buildDisasterSelection(),
              const SizedBox(height: 16),
              _buildDestructionSelection(),
              const SizedBox(height: 24),
              _buildSendButton(),
              const SizedBox(height: 16),
              if (_appState == AppState.SUCCESS_CANCEL_WINDOW)
                _buildCancelButton(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          if (_appState == AppState.SYNCING)
            SizedBox(
              width: 52,
              height: 52,
              child: CircularProgressIndicator(strokeWidth: 3, color: statusColor),
            )
          else
            Icon(
              isConnected ? Icons.check_circle : Icons.error_outline,
              size: 52,
              color: statusColor,
            ),
          const SizedBox(height: 12),
          Text(
            statusMessage,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: statusColor,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          if (_appState == AppState.SUCCESS_CANCEL_WINDOW && sentLatLng != null) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _openEmergencyMapScreen,
              icon: const Icon(Icons.location_on, size: 18),
              label: const Text('Lihat Titik Kejadian di Peta'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWarningPendingCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange[50],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange[300]!),
      ),
      child: Column(
        children: [
          Text(
            'Alat sedang menunggu konfirmasi peringatan sub-field.\n'
                'Tahan tombol KIRIM/BATAL di layar alat, atau putuskan dari HP.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.orange[900]),
          ),
          if (_warningActionPending) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange[700]),
                ),
                const SizedBox(width: 8),
                Text('Mengirim perintah, tunggu konfirmasi alat...',
                    style: TextStyle(color: Colors.orange[900], fontSize: 12)),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _warningActionPending ? null : cancelWarningFromApp,
                  icon: const Icon(Icons.cancel_outlined, size: 20),
                  label: const Text('Batalkan'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange[900],
                    side: BorderSide(color: Colors.orange[700]!),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _warningActionPending ? null : forwardWarningFromApp,
                  icon: const Icon(Icons.send, size: 20),
                  label: const Text('Kirim ke HQ'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange[700],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScanButton() {
    return ElevatedButton.icon(
      onPressed: startScan,
      icon: isScanning
          ? const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(Colors.white),
        ),
      )
          : const Icon(Icons.bluetooth_searching, size: 20),
      label: Text(isScanning ? 'Mencari Perangkat...' : 'Cari Field Device'),
    );
  }

  Widget _buildDeviceList() {
    if (scanResults.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Perangkat Ditemukan:',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 12),
        ...scanResults.map((result) => Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            leading: const Icon(Icons.router, color: Colors.blue),
            title: Text(
              result.device.platformName,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Text('RSSI: ${result.rssi} dBm', style: const TextStyle(fontSize: 13)),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            onTap: () => connectToDevice(result.device),
          ),
        )),
      ],
    );
  }

  Widget _buildGPSInfo() {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.location_on, color: Color(0xFFE53935)),
              SizedBox(width: 8),
              Text('Lokasi GPS Anda', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ]),
            const SizedBox(height: 14),
            if (currentPosition != null) ...[
              Text('Lintang: ${currentPosition!.latitude.toStringAsFixed(6)}', style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
              const SizedBox(height: 6),
              Text('Bujur: ${currentPosition!.longitude.toStringAsFixed(6)}', style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
              const SizedBox(height: 14),
              GestureDetector(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => EmergencyMapPage(
                        position: ll.LatLng(currentPosition!.latitude, currentPosition!.longitude),
                        title: 'Lokasi Anda Saat Ini',
                      ),
                    ),
                  );
                },
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        height: 160,
                        child: IgnorePointer(
                          child: FlutterMap(
                            options: MapOptions(
                              initialCenter: ll.LatLng(currentPosition!.latitude, currentPosition!.longitude),
                              initialZoom: 15,
                              interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                            ),
                            children: [
                              TileLayer(
                                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'com.sigap.emergency_comm',
                              ),
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    point: ll.LatLng(currentPosition!.latitude, currentPosition!.longitude),
                                    width: 40,
                                    height: 40,
                                    child: const Icon(Icons.location_on, color: Color(0xFFE53935), size: 40),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.fullscreen, color: Colors.white, size: 14),
                            SizedBox(width: 4),
                            Text('Ketuk untuk perbesar', style: TextStyle(color: Colors.white, fontSize: 11)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              Text('Lokasi tidak tersedia', style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w500)),
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: getCurrentLocation,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Perbarui Lokasi'),
              style: TextButton.styleFrom(foregroundColor: Colors.blue[700]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDisasterSelection() {
    bool enabled = _appState == AppState.IDLE;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Jenis Bencana', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: selectedDisasterIndex,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.warning_amber),
                contentPadding: EdgeInsets.symmetric(vertical: 14, horizontal: 12),
              ),
              items: kDisasterOptions.asMap().entries.map((entry) {
                int index = entry.key;
                Map<String, dynamic> item = entry.value;
                return DropdownMenuItem(value: index, child: Text(item['name'] ?? 'Unknown'));
              }).toList(),
              onChanged: enabled ? (value) { if (value != null) setState(() => selectedDisasterIndex = value); } : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDestructionSelection() {
    bool enabled = _appState == AppState.IDLE;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Tingkat Kerusakan', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: selectedDestructionIndex,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.assessment),
                contentPadding: EdgeInsets.symmetric(vertical: 14, horizontal: 12),
              ),
              items: kDestructionOptions.asMap().entries.map((entry) {
                int index = entry.key;
                Map<String, dynamic> item = entry.value;
                return DropdownMenuItem(value: index, child: Text(item['name'] ?? 'Unknown'));
              }).toList(),
              onChanged: enabled ? (value) { if (value != null) setState(() => selectedDestructionIndex = value); } : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSendButton() {
    return ElevatedButton.icon(
      onPressed: (_appState == AppState.IDLE && isConnected) ? sendHelpMessage : null,
      icon: const Icon(Icons.warning_amber, size: 24),
      label: const Text('Kirim Permintaan Bantuan'),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFFE53935),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 18),
        elevation: 3,
        disabledBackgroundColor: Colors.grey[300],
        disabledForegroundColor: Colors.grey[600],
      ),
    );
  }

  Widget _buildCancelButton() {
    return ElevatedButton.icon(
      onPressed: cancelHelp,
      icon: const Icon(Icons.cancel, size: 20),
      label: const Text('Batalkan Bantuan'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.orange[700],
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
    );
  }
}