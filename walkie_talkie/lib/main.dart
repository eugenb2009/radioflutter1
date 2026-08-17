import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WalkieTalkieApp());
}

class WalkieTalkieApp extends StatelessWidget {
  const WalkieTalkieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Рация',
      theme: ThemeData.dark(),
      home: const WalkieTalkieHomePage(),
    );
  }
}

// ---------- Модель участника ----------
class Peer {
  final String ip;
  String name;
  DateTime lastSeen;

  Peer({required this.ip, required this.name, required this.lastSeen});
}

// ---------- Сервис рации (UDP + аудио) ----------
class WalkieTalkieService {
  static const int audioPort = 5004;
  static const int discoveryPort = 5005;

  final String deviceName;

  WalkieTalkieService({required this.deviceName});

  RawDatagramSocket? _audioSocket;
  RawDatagramSocket? _discoverySocket;
  FlutterSoundRecorder? _recorder;
  StreamController<Uint8List>? _recordingStreamController;
  StreamSubscription<Uint8List>? _recordingSub;
  FlutterSoundPlayer? _player;
  bool _playerReady = false;
  bool _transmitting = false;
  bool _playerPaused = false;
  Timer? _discoveryTimer;

  final Set<String> _localIps = {};
  final Map<String, Peer> _peers = {};

  List<Peer> get peers => _peers.values.toList();
  VoidCallback? onPeersChanged;

  // ---------- Инициализация ----------
  Future<bool> init() async {
    // 1. Разрешение на микрофон (для iOS/Android; на Windows вернёт granted или ошибку)
    try {
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted && Platform.isIOS || !micStatus.isGranted && Platform.isAndroid) {
        return false;
      }
    } catch (_) {
      // На Windows permission_handler может не работать – игнорируем
    }

    // 2. Локальные IP
    await _collectLocalIps();

    // 3. Плеер
    _player = FlutterSoundPlayer();
    await _player!.openPlayer();
    await _player!.startPlayerFromStream(
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: 16000,
      interleaved: true,
      bufferSize: 8192,
    );
    _playerReady = true;
    _playerPaused = false;

    // 4. Рекордер
    _recorder = FlutterSoundRecorder();
    await _recorder!.openRecorder();

    // 5. Сокет для аудио
    _audioSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      audioPort,
    );
    _audioSocket!.broadcastEnabled = true;
    _audioSocket!.listen(_onAudioEvent);

    // 6. Сокет для обнаружения
    _discoverySocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
    );
    _discoverySocket!.broadcastEnabled = true;
    _discoverySocket!.listen(_onDiscoveryEvent);

    // 7. Периодическая рассылка DISCOVER
    _discoveryTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _sendDiscovery(),
    );

    return true;
  }

  Future<void> _collectLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.any,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          _localIps.add(addr.address);
        }
      }
    } catch (_) {}
  }

  // ---------- Приём аудио ----------
  void _onAudioEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final datagram = _audioSocket?.receive();
      if (datagram != null) {
        _handleAudio(datagram);
      }
    }
  }

  void _handleAudio(Datagram datagram) {
    if (_transmitting) return;
    if (!_playerReady) return;

    final data = datagram.data;
    if (data.isEmpty) return;

    if (_playerPaused) {
      _player!.resumePlayer();
      _playerPaused = false;
    }

    _player!.uint8ListSink?.add(data);
  }

  // ---------- Обнаружение ----------
  void _onDiscoveryEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final datagram = _discoverySocket?.receive();
      if (datagram != null) {
        _handleDiscovery(datagram);
      }
    }
  }

  void _handleDiscovery(Datagram datagram) {
    final ip = datagram.address.address;
    if (_localIps.contains(ip)) return;

    final message = utf8.decode(datagram.data);
    if (message.startsWith('DISCOVER:')) {
      final name = message.substring('DISCOVER:'.length);
      _addPeer(Peer(ip: ip, name: name, lastSeen: DateTime.now()));

      final ack = 'PEER:$deviceName';
      _discoverySocket?.send(
        utf8.encode(ack),
        datagram.address,
        datagram.port,
      );
    } else if (message.startsWith('PEER:')) {
      final name = message.substring('PEER:'.length);
      _addPeer(Peer(ip: ip, name: name, lastSeen: DateTime.now()));
    }
  }

  void _addPeer(Peer peer) {
    final existing = _peers[peer.ip];
    if (existing != null) {
      existing.name = peer.name;
      existing.lastSeen = peer.lastSeen;
    } else {
      _peers[peer.ip] = peer;
    }
    onPeersChanged?.call();
  }

  void _sendDiscovery() {
    final data = utf8.encode('DISCOVER:$deviceName');
    _discoverySocket?.send(
      data,
      InternetAddress('255.255.255.255'),
      discoveryPort,
    );
  }

  // ---------- Передача ----------
  Future<void> startTransmitting() async {
    if (_transmitting) return;
    _transmitting = true;

    if (_playerReady && !_playerPaused) {
      await _player!.pausePlayer();
      _playerPaused = true;
    }

    // Запускаем запись и направляем поток PCM в контроллер
    _recordingStreamController = StreamController<Uint8List>();
    _recordingSub = _recordingStreamController!.stream.listen((data) {
      _audioSocket?.send(
        data,
        InternetAddress('255.255.255.255'),
        audioPort,
      );
    });

    await _recorder!.startRecorder(
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: 16000,
      toStream: _recordingStreamController!.sink,
    );
  }

  Future<void> stopTransmitting() async {
    if (!_transmitting) return;
    _transmitting = false;

    await _recordingSub?.cancel();
    _recordingSub = null;
    await _recorder?.stopRecorder();
    await _recordingStreamController?.close();
    _recordingStreamController = null;

    if (_playerReady && _playerPaused) {
      await _player!.resumePlayer();
      _playerPaused = false;
    }
  }

  // ---------- Завершение ----------
  Future<void> dispose() async {
    _discoveryTimer?.cancel();
    await _recordingSub?.cancel();
    await _recorder?.stopRecorder();
    await _recordingStreamController?.close();
    await _recorder?.closeRecorder();
    await _player?.stopPlayer();
    await _player?.closePlayer();
    _audioSocket?.close();
    _discoverySocket?.close();
  }
}

// ---------- UI ----------
class WalkieTalkieHomePage extends StatefulWidget {
  const WalkieTalkieHomePage({super.key});

  @override
  State<WalkieTalkieHomePage> createState() => _WalkieTalkieHomePageState();
}

class _WalkieTalkieHomePageState extends State<WalkieTalkieHomePage> {
  final WalkieTalkieService _service = WalkieTalkieService(
    deviceName: Platform.isWindows ? 'Мой ПК' : 'Мой iPhone',
  );

  bool _initialized = false;
  bool _permissionDenied = false;
  bool _transmitting = false;
  List<Peer> _peers = [];

  @override
  void initState() {
    super.initState();
    _service.onPeersChanged = () {
      if (mounted) {
        setState(() {
          _peers = _service.peers;
        });
      }
    };
    _init();
  }

  Future<void> _init() async {
    final ok = await _service.init();
    if (!mounted) return;
    setState(() {
      _initialized = ok;
      _permissionDenied = !ok;
      _peers = _service.peers;
    });
  }

  Future<void> _startTransmitting() async {
    await _service.startTransmitting();
    if (mounted) setState(() => _transmitting = true);
  }

  Future<void> _stopTransmitting() async {
    await _service.stopTransmitting();
    if (mounted) setState(() => _transmitting = false);
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Рация')),
      body: Column(
        children: [
          if (_permissionDenied)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Нет доступа к микрофону',
                style: TextStyle(color: Colors.red),
              ),
            ),
          Expanded(
            child: _initialized && _peers.isEmpty
                ? const Center(child: Text('Поиск устройств…'))
                : ListView.builder(
                    itemCount: _peers.length,
                    itemBuilder: (context, index) {
                      final peer = _peers[index];
                      return ListTile(
                        leading: const Icon(Icons.person),
                        title: Text(peer.name),
                        subtitle: Text(peer.ip),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Listener(
              onPointerDown: (_) => _startTransmitting(),
              onPointerUp: (_) => _stopTransmitting(),
              onPointerCancel: (_) => _stopTransmitting(),
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _transmitting ? Colors.red : Colors.blue,
                  boxShadow: [
                    BoxShadow(
                      color: (_transmitting ? Colors.red : Colors.blue)
                          .withValues(alpha: 0.5),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    _transmitting ? 'ГОВОРЮ' : 'НАЖМИ',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}