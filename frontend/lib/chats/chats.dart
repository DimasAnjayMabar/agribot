import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:frontend/chats/sidebar.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------------------
// Konfigurasi
// ---------------------------------------------------------------------------

final _dio = Dio(
  BaseOptions(
    baseUrl: 'http://localhost:8000',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
    headers: {'Content-Type': 'application/json'},
  ),
);

final _storage = FlutterSecureStorage(
  aOptions: const AndroidOptions(encryptedSharedPreferences: true),
  webOptions: const WebOptions(
    dbName: 'agribot_secure',
    publicKey: 'agribot_key',
  ),
);

const _kBaseUrl              = 'http://localhost:8000';
const _kTokenRefreshInterval = Duration(minutes: 25);

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class ChatTopic {
  final int    id;
  String       title;
  final String createdAt;

  ChatTopic({required this.id, required this.title, required this.createdAt});

  factory ChatTopic.fromJson(Map<String, dynamic> j) => ChatTopic(
        id       : j['id']         as int,
        title    : j['title']      as String,
        createdAt: j['created_at'] as String,
      );
}

class ChatMessage {
  final int    id;
  final int    chatId;
  final String question;
  String       response;
  String       processingStatus;
  final String createdAt;

  ChatMessage({
    required this.id,
    required this.chatId,
    required this.question,
    required this.response,
    required this.processingStatus,
    required this.createdAt,
  });

  ChatMessage copyWith({
    String? response,
    String? processingStatus,
  }) {
    return ChatMessage(
      id: id,
      chatId: chatId,
      question: question,
      response: response ?? this.response,
      processingStatus: processingStatus ?? this.processingStatus,
      createdAt: createdAt,
    );
  }

  /// Dibuat dari response POST /chat/send — hanya metadata, tanpa response AI.
  factory ChatMessage.pending({
    required int    id,
    required int    chatId,
    required String question,
    required String createdAt,
  }) =>
      ChatMessage(
        id              : id,
        chatId          : chatId,
        question        : question,
        response        : '',
        processingStatus: 'pending',
        createdAt       : createdAt,
      );

  /// Dibuat dari response GET /chat/message/{id} atau GET /topics/{id} — data lengkap dari DB.
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id              : j['id']                as int,
        chatId          : j['chat_id']           as int,
        question        : j['question']          as String,
        response        : j['response']          as String? ?? '',
        processingStatus: j['processing_status'] as String? ?? 'pending',
        createdAt       : j['created_at']        as String,
      );

  bool get isPending      => processingStatus == 'pending';
  bool get isDone         => processingStatus == 'done';
  bool get isFailed       => processingStatus == 'failed';
  bool get isDisconnected => processingStatus == 'disconnected';
}

class ChatUserProfile {
  final String name;
  final String email;
  final String username;

  const ChatUserProfile({
    required this.name,
    required this.email,
    required this.username,
  });

  factory ChatUserProfile.fromJson(Map<String, dynamic> j) => ChatUserProfile(
        name    : j['name']     as String,
        email   : j['email']   as String,
        username: j['username'] as String,
      );
}

// ---------------------------------------------------------------------------
// Greetings
// ---------------------------------------------------------------------------

const _kGreetings = [
  'Halo! Ada yang bisa saya bantu hari ini? 🌱',
  'Selamat datang! Silakan tanyakan seputar pertanian kepada saya.',
  'Hai! Saya siap membantu menjawab pertanyaan agrikultur Anda.',
  'Halo, petani hebat! Ada pertanyaan seputar tanaman atau lahan?',
  'Selamat datang kembali! Apa yang ingin Anda ketahui hari ini?',
  'Hai! Saya AgriBot — tanyakan apa saja soal pertanian. 🌾',
  'Halo! Butuh saran soal pupuk, hama, atau panen? Saya siap bantu!',
];

// ---------------------------------------------------------------------------
// SSE Client
// ---------------------------------------------------------------------------

class SseEvent {
  final String type;
  final String data;
  const SseEvent({required this.type, required this.data});
}

class SseClient {
  static Stream<SseEvent> subscribe(String url, String token) async* {
    final client = http.Client();
    final request = http.Request('GET', Uri.parse(url))
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-cache'
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Connection'] = 'keep-alive';

    http.StreamedResponse response;
    try {
      response = await client.send(request);
      print('✅ SSE Connected, status: ${response.statusCode}');
    } catch (e) {
      print('❌ SSE Connection failed: $e');
      throw Exception('SSE connect gagal: $e');
    }

    if (response.statusCode != 200) {
      print('❌ SSE HTTP error: ${response.statusCode}');
      throw Exception('SSE connect gagal: HTTP ${response.statusCode}');
    }

    String buffer = '';
    String currentEventType = 'message';

    try {
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        buffer += chunk;
        
        // Proses per baris
        final lines = buffer.split('\n');
        buffer = lines.last;
        
        for (var i = 0; i < lines.length - 1; i++) {
          final line = lines[i].trim();
          
          if (line.isEmpty) {
            // Empty line means end of event
            continue;
          }
          
          if (line.startsWith('event:')) {
            currentEventType = line.substring(6).trim();
            print('📡 SSE Event Type: $currentEventType');
          } else if (line.startsWith('data:')) {
            final data = line.substring(5).trim();
            print('📡 SSE Data: $data');
            if (data.isNotEmpty) {
              yield SseEvent(type: currentEventType, data: data);
              currentEventType = 'message'; // Reset
            }
          } else if (line.startsWith(':')) {
            // Heartbeat comment
            print('💓 SSE Heartbeat');
          }
        }
      }
    } finally {
      client.close();
      print('🏁 SSE Client closed');
    }
  }
}

// ---------------------------------------------------------------------------
// _SseTracker — satu SSE subscription per pesan pending, tanpa polling
// ---------------------------------------------------------------------------

class _SseTracker {
  final int                     detailId;
  StreamSubscription<SseEvent>? sseSub;

  _SseTracker({required this.detailId});

  void cancel() {
    sseSub?.cancel();
    sseSub = null;
  }
}

// ---------------------------------------------------------------------------
// ChatsPage
// ---------------------------------------------------------------------------

class ChatsPage extends StatefulWidget {
  const ChatsPage({super.key});

  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage>
    with SingleTickerProviderStateMixin {
  String? _accessToken;
  int?    _userId;
  Timer?  _tokenTimer;

  bool _sidebarOpen = true;
  late final AnimationController _sidebarCtrl;
  late final Animation<double>   _sidebarAnim;

  List<ChatTopic>  _topics        = [];
  ChatUserProfile? _profile;
  bool             _loadingTopics = true;

  int?              _activeChatId;
  List<ChatMessage> _messages        = [];
  bool              _loadingMessages = false;

  bool    _sending         = false;
  String? _pendingQuestion;

  final Map<int, _SseTracker> _trackers = {};

  int?    _renamingId;
  String? _renamingTemp;
  String? _greeting;

  final _inputCtrl  = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _sidebarCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 250), value: 1.0);
    _sidebarAnim = CurvedAnimation(
      parent: _sidebarCtrl, curve: Curves.easeInOut);
    _initAuth();
  }

  @override
  void dispose() {
    _tokenTimer?.cancel();
    for (final t in _trackers.values) t.cancel();
    _trackers.clear();
    _sidebarCtrl.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  // ── Auth ──────────────────────────────────────────────────────────────────

  Future<void> _initAuth() async {
    try {
      _accessToken = await _storage.read(key: 'access_token');
      final uid    = await _storage.read(key: 'user_id');
      _userId      = uid != null ? int.tryParse(uid) : null;
    } catch (_) {}

    if (_accessToken == null || _accessToken!.isEmpty || _userId == null) {
      if (mounted) context.go('/users/login');
      return;
    }
    _startTokenTimer();
    await Future.wait([_fetchTopics(), _fetchProfile()]);
    _pickGreeting();
  }

  void _startTokenTimer() {
    _tokenTimer?.cancel();
    _tokenTimer = Timer.periodic(_kTokenRefreshInterval, (_) => _silentRefresh());
  }

  Future<void> _silentRefresh() async {
    final rt = await _storage.read(key: 'refresh_token');
    if (rt == null || rt.isEmpty) { _forceLogout(); return; }
    try {
      final res = await _dio.post('/users/refresh-token', data: {'refresh_token': rt});
      if (res.statusCode == 200) {
        final d = res.data['data'] as Map<String, dynamic>;
        await Future.wait([
          _storage.write(key: 'access_token',  value: d['access_token']  as String),
          _storage.write(key: 'refresh_token', value: d['refresh_token'] as String),
        ]);
        if (mounted) setState(() => _accessToken = d['access_token'] as String);
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) _forceLogout();
    } catch (_) {}
  }

  Future<void> _forceLogout() async {
    _tokenTimer?.cancel();
    for (final t in _trackers.values) t.cancel();
    _trackers.clear();
    await Future.wait([
      _storage.delete(key: 'access_token'),
      _storage.delete(key: 'refresh_token'),
      _storage.delete(key: 'user_id'),
      _storage.delete(key: 'session_created_at'),
    ]);
    if (mounted) context.go('/users/login');
  }

  Map<String, dynamic> get _authHeader => {'Authorization': 'Bearer $_accessToken'};

  // ── SSE Tracker ───────────────────────────────────────────────────────────
  void _startTracking(int detailId) {
    print('🔍 Starting SSE tracking for detail_id: $detailId');
    _trackers[detailId]?.cancel();
    final tracker = _SseTracker(detailId: detailId);
    _trackers[detailId] = tracker;

    final url = '$_kBaseUrl/chat/stream/$detailId';
    final token = _accessToken ?? '';
    print('🌐 SSE URL: $url');

    tracker.sseSub = SseClient.subscribe(url, token).listen(
      (event) async {
        print('📨 SSE event received: ${event.type} for detail_id $detailId');
        print('📦 Event data: ${event.data}');
        
        if (!mounted) {
          print('⚠️ Widget not mounted, ignoring event');
          return;
        }
        
        if (event.type == 'done' || event.type == 'error') {
          print('🔄 Fetching message from API for detail_id: $detailId');
          await _fetchAndApplyMessage(detailId);
          _stopTracking(detailId);
        } else if (event.type == 'waiting') {
          print('⏳ Waiting for response...');
        } else if (event.type == 'timeout') {
          print('⏰ Timeout received for detail_id: $detailId');
          _markDisconnected(detailId);
          _stopTracking(detailId);
        }
      },
      onError: (error) {
        print('❌ SSE error for $detailId: $error');
        if (mounted) {
          _markDisconnected(detailId);
        }
        _stopTracking(detailId);
      },
      onDone: () {
        print('🏁 SSE connection closed for $detailId');
        if (mounted) {
          final msg = _messages.firstWhere(
            (m) => m.id == detailId,
            orElse: () => ChatMessage(
              id: detailId, chatId: 0, question: '',
              response: '', processingStatus: 'pending', createdAt: ''),
          );
          if (msg.isPending) {
            print('⚠️ SSE closed but message still pending, marking as disconnected');
            _markDisconnected(detailId);
          }
        }
        _stopTracking(detailId);
      },
      cancelOnError: true,
    );

    Future.delayed(const Duration(seconds: 30), () {
      if (mounted && _trackers.containsKey(detailId)) {
        print('⏰ Fallback timeout triggered for detail_id: $detailId');
        final msg = _messages.firstWhere(
          (m) => m.id == detailId,
          orElse: () => ChatMessage(
            id: detailId, chatId: 0, question: '',
            response: '', processingStatus: 'pending', createdAt: ''),
        );
        if (msg.isPending) {
          _fetchAndApplyMessage(detailId);
        }
      }
    });
  }

  Future<void> _fetchAndApplyMessage(int detailId) async {
    if (!mounted) return;
    print('📥 Fetching message $detailId from API');
    try {
      final res = await _dio.get(
        '/chat/message/$detailId',
        options: Options(headers: _authHeader),
      );
      
      final jsonData = res.data['data'] as Map<String, dynamic>;
      final updated = ChatMessage.fromJson(jsonData);
      print('✅ Message fetched: id=${updated.id}, status=${updated.processingStatus}, response_length=${updated.response.length}');
      
      _applyMessageUpdate(updated);
    } catch (e) {
      print('❌ Error fetching message: $e');
      _markDisconnected(detailId);
    }
  }

  void _applyMessageUpdate(ChatMessage updated) {
    if (!mounted) return;
    print('🔄 Applying update for message ${updated.id}');
    
    final idx = _messages.indexWhere((m) => m.id == updated.id);
    if (idx == -1) {
      print('⚠️ Message ${updated.id} not found in _messages list');
      print('Current messages: ${_messages.map((m) => m.id).toList()}');
      return;
    }
    
    print('📝 Updating message at index $idx');
    setState(() {
      _messages[idx] = updated;
    });
    
    _scrollToBottom();
    print('✨ UI updated for message ${updated.id}');
  }

  void _markDisconnected(int detailId) {
    if (!mounted) return;
    print('⚠️ Marking message $detailId as disconnected');
    final idx = _messages.indexWhere((m) => m.id == detailId);
    if (idx != -1) {
      setState(() {
        _messages[idx].processingStatus = 'disconnected';
      });
    }
  }

  void _stopTracking(int detailId) {
    _trackers[detailId]?.cancel();
    _trackers.remove(detailId);
  }

  void _cancelAllTrackers() {
    for (final t in _trackers.values) t.cancel();
    _trackers.clear();
  }

  // ── Fetch ─────────────────────────────────────────────────────────────────

  Future<void> _fetchTopics() async {
    try {
      final res  = await _dio.get('/topics', options: Options(headers: _authHeader));
      final data = res.data['data'] as Map<String, dynamic>;
      final list = (data['topics'] as List)
          .map((e) => ChatTopic.fromJson(e as Map<String, dynamic>))
          .toList();
      if (mounted) setState(() { _topics = list; _loadingTopics = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingTopics = false);
    }
  }

  Future<void> _fetchProfile() async {
    if (_userId == null) return;
    try {
      final res  = await _dio.get('/users/$_userId', options: Options(headers: _authHeader));
      final data = res.data['data'] as Map<String, dynamic>;
      if (mounted) setState(() => _profile = ChatUserProfile.fromJson(data));
    } catch (_) {}
  }

  Future<void> _fetchMessages(int chatId) async {
    setState(() { _loadingMessages = true; _messages = []; });
    try {
      final res  = await _dio.get('/topics/$chatId', options: Options(headers: _authHeader));
      final data = res.data['data'] as Map<String, dynamic>;
      // GET /topics/{id} return history lengkap — response AI sudah ada di DB
      final msgs = (data['messages'] as List)
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
      if (mounted) {
        setState(() { _messages = msgs; _loadingMessages = false; });
        _scrollToBottom();
        // Recovery: pesan pending dari sesi sebelumnya → buka SSE ulang
        for (final msg in msgs.where((m) => m.isPending)) {
          _startTracking(msg.id);
        }
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMessages = false);
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _pickGreeting() {
    setState(() => _greeting = _kGreetings[Random().nextInt(_kGreetings.length)]);
  }

  void _newChat() {
    _cancelAllTrackers();
    _pickGreeting();
    setState(() { _activeChatId = null; _messages = []; _pendingQuestion = null; });
  }

  void _selectTopic(ChatTopic topic) {
    _cancelAllTrackers();
    setState(() { _activeChatId = topic.id; _greeting = null; _pendingQuestion = null; });
    _fetchMessages(topic.id);
    if (MediaQuery.of(context).size.width < 768) _toggleSidebar();
  }

  Future<void> _sendMessage({String? overrideText, int? replaceDetailId}) async {
    final text = overrideText ?? _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    if (overrideText == null) _inputCtrl.clear();
    setState(() {
      _sending         = true;
      _pendingQuestion = replaceDetailId == null ? text : null;
    });
    _scrollToBottom();

    try {
      final res  = await _dio.post(
        '/chat/send',
        data   : {'chat_id': _activeChatId, 'question': text},
        options: Options(headers: _authHeader),
      );

      // POST /chat/send hanya return metadata (id, chat_id, question, status).
      // Jawaban AI TIDAK ada di sini — akan datang via SSE sinyal → GET /chat/message/{id}.
      final data = res.data['data'] as Map<String, dynamic>;
      final msg  = ChatMessage.pending(
        id       : data['id']         as int,
        chatId   : data['chat_id']    as int,
        question : data['question']   as String,
        createdAt: data['created_at'] as String,
      );

      if (_activeChatId == null) {
        setState(() {
          _activeChatId = msg.chatId;
          _greeting     = null;
          _pendingQuestion = null;
          _messages.add(msg);
          _sending = false;
        });
        await _fetchTopics();
      } else if (replaceDetailId != null) {
        final idx = _messages.indexWhere((m) => m.id == replaceDetailId);
        setState(() {
          _pendingQuestion = null;
          if (idx != -1) _messages[idx] = msg; else _messages.add(msg);
        });
      } else {
        setState(() { _pendingQuestion = null; _messages.add(msg); });
      }

      _scrollToBottom();
      _startTracking(msg.id); // SSE → sinyal → GET /chat/message/{id}

    } catch (_) {
      setState(() => _pendingQuestion = null);
      _showSnack('Gagal mengirim pesan. Coba lagi.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _resendMessage(ChatMessage msg) async {
    await _sendMessage(overrideText: msg.question, replaceDetailId: msg.id);
  }

  Future<void> _deleteTopic(ChatTopic topic) async {
    try {
      await _dio.delete('/topics/${topic.id}', options: Options(headers: _authHeader));
      _cancelAllTrackers();
      setState(() {
        _topics.removeWhere((t) => t.id == topic.id);
        if (_activeChatId == topic.id) {
          _activeChatId = null; _messages = []; _pendingQuestion = null;
          _pickGreeting();
        }
      });
    } catch (_) { _showSnack('Gagal menghapus topik.'); }
  }

  Future<void> _renameTopic(ChatTopic topic, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) return;
    try {
      await _dio.patch('/topics/${topic.id}',
          data: {'title': trimmed}, options: Options(headers: _authHeader));
      setState(() { topic.title = trimmed; _renamingId = null; });
    } catch (_) { _showSnack('Gagal mengganti judul.'); }
  }

  Future<void> _logout() async {
    _cancelAllTrackers();
    try { await _dio.post('/users/logout', options: Options(headers: _authHeader)); } catch (_) {}
    await _forceLogout();
  }

  void _toggleSidebar() {
    setState(() => _sidebarOpen = !_sidebarOpen);
    _sidebarOpen ? _sidebarCtrl.forward() : _sidebarCtrl.reverse();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve   : Curves.easeOut,
        );
      }
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content        : Text(msg, style: GoogleFonts.poppins(fontSize: 13)),
      backgroundColor: const Color(0xFF111111),
      behavior       : SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020202),
      body: Row(
        children: [
          SizeTransition(
            sizeFactor: _sidebarAnim,
            axis      : Axis.horizontal,
            child: ChatSidebar(
              topics         : _topics,
              loading        : _loadingTopics,
              activeChatId   : _activeChatId,
              profile        : _profile,
              renamingId     : _renamingId,
              renamingTemp   : _renamingTemp,
              onNewChat      : _newChat,
              onSelectTopic  : _selectTopic,
              onDeleteTopic  : _deleteTopic,
              onStartRename  : (t) => setState(() { _renamingId = t.id; _renamingTemp = t.title; }),
              onConfirmRename: (t, v) => _renameTopic(t, v),
              onCancelRename : () => setState(() => _renamingId = null),
              onRenameChange : (v) => setState(() => _renamingTemp = v),
              onProfileTap   : () => context.go('/user_profile'),
              onLogout       : _logout,
            ),
          ),
          Expanded(
            child: Column(
              children: [
                _ChatTopBar(
                  sidebarOpen    : _sidebarOpen,
                  onToggleSidebar: _toggleSidebar,
                  title: _activeChatId != null
                      ? _topics.firstWhere(
                          (t) => t.id == _activeChatId,
                          orElse: () => ChatTopic(id: 0, title: 'Chat', createdAt: '')).title
                      : 'Chat Baru',
                  hasPending: _trackers.isNotEmpty,
                ),
                Expanded(child: _buildBody()),
                _InputBar(
                  controller: _inputCtrl,
                  focusNode : _inputFocus,
                  sending   : _sending,
                  onSend    : _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loadingMessages) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF16DB65), strokeWidth: 2));
    }
    if (_activeChatId == null && _messages.isEmpty && _pendingQuestion == null) {
      return _GreetingView(greeting: _greeting ?? _kGreetings[0]);
    }
    if (_messages.isEmpty && _pendingQuestion == null) {
      return const _GreetingView(greeting: 'Topik ini masih kosong. Mulai percakapan! 💬');
    }

    final itemCount = _messages.length + (_pendingQuestion != null ? 1 : 0);
    return ListView.builder(
      controller: _scrollCtrl,
      padding   : const EdgeInsets.fromLTRB(24, 24, 24, 8),
      itemCount : itemCount,
      itemBuilder: (_, i) {
        if (_pendingQuestion != null && i == _messages.length) {
          return _PendingBubble(question: _pendingQuestion!);
        }
        final msg = _messages[i];
        if (msg.isPending)      return _PendingBubble(question: msg.question);
        if (msg.isDisconnected) return _DisconnectedBubble(message: msg, onResend: () => _resendMessage(msg));
        return _MessagePair(message: msg);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Chat Top Bar
// ---------------------------------------------------------------------------

class _ChatTopBar extends StatelessWidget {
  const _ChatTopBar({
    required this.sidebarOpen,
    required this.onToggleSidebar,
    required this.title,
    required this.hasPending,
  });

  final bool sidebarOpen; final VoidCallback onToggleSidebar;
  final String title; final bool hasPending;

  @override
  Widget build(BuildContext context) {
    return Container(
      height  : 56,
      padding : const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color : Color(0xFF0D0D0D),
        border: Border(bottom: BorderSide(color: Color(0xFF1A1A1A))),
      ),
      child: Row(
        children: [
          Tooltip(
            message: sidebarOpen ? 'Sembunyikan Sidebar' : 'Tampilkan Sidebar',
            child: InkWell(
              onTap: onToggleSidebar,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border      : Border.all(color: const Color(0xFF1A1A1A)),
                ),
                child: Icon(
                  sidebarOpen ? Icons.menu_open_rounded : Icons.menu_rounded,
                  size: 18, color: const Color(0xFFA3A3A3),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(title,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
          ),
          if (hasPending) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: 'Menunggu respons AI (pipeline aktif)...',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PulsingDot(),
                  const SizedBox(width: 5),
                  Text('Memproses', style: GoogleFonts.poppins(
                      fontSize: 11, color: const Color(0xFF16DB65), fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  @override State<_PulsingDot> createState() => _PulsingDotState();
}
class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => FadeTransition(
    opacity: _ctrl,
    child: Container(width: 7, height: 7,
      decoration: const BoxDecoration(color: Color(0xFF16DB65), shape: BoxShape.circle)),
  );
}

// ---------------------------------------------------------------------------
// Greeting View
// ---------------------------------------------------------------------------

class _GreetingView extends StatelessWidget {
  const _GreetingView({required this.greeting});
  final String greeting;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color : const Color(0x3316DB65), shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF16DB65).withOpacity(0.4), width: 1.5),
              ),
              child: const Icon(Icons.eco_rounded, color: Color(0xFF16DB65), size: 30),
            ),
            const SizedBox(height: 20),
            Text(greeting, textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.white, height: 1.6)),
            const SizedBox(height: 10),
            Text('Ketik pertanyaan Anda di bawah untuk memulai.', textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 13, color: const Color(0xFFA3A3A3))),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message Pair
// ---------------------------------------------------------------------------

class _MessagePair extends StatelessWidget {
  const _MessagePair({required this.message});
  final ChatMessage message;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _UserBubble(text: message.question),
          const SizedBox(height: 12),
          if (message.isFailed) _ErrorBubble(text: message.response)
          else _AiBubble(text: message.response),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pending Bubble
// ---------------------------------------------------------------------------

class _PendingBubble extends StatefulWidget {
  const _PendingBubble({required this.question});
  final String question;
  @override State<_PendingBubble> createState() => _PendingBubbleState();
}
class _PendingBubbleState extends State<_PendingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _anim;
  @override void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _UserBubble(text: widget.question),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _AiAvatar(),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color      : const Color(0xFF111111),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4), topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16),
                ),
                border: Border.all(color: const Color(0xFF1A1A1A)),
              ),
              child: FadeTransition(
                opacity: _anim,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(3, (i) => Padding(
                    padding: EdgeInsets.only(left: i == 0 ? 0 : 5),
                    child: Container(width: 7, height: 7,
                      decoration: const BoxDecoration(color: Color(0xFF16DB65), shape: BoxShape.circle)),
                  )),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Disconnected Bubble
// ---------------------------------------------------------------------------

class _DisconnectedBubble extends StatelessWidget {
  const _DisconnectedBubble({required this.message, required this.onResend});
  final ChatMessage  message;
  final VoidCallback onResend;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _UserBubble(text: message.question),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 30, height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle, color: const Color(0x33FF9800),
                border: Border.all(color: const Color(0xFFFF9800).withOpacity(0.4)),
              ),
              child: const Icon(Icons.wifi_off_rounded, color: Color(0xFFFF9800), size: 15),
            ),
            const SizedBox(width: 10),
            Expanded(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color      : const Color(0xFF1A1200),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4), topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16),
                ),
                border: Border.all(color: const Color(0xFFFF9800).withOpacity(0.3)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Koneksi terputus sebelum jawaban diterima.',
                  style: GoogleFonts.poppins(fontSize: 13, color: const Color(0xFFFFB74D), height: 1.5)),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: onResend,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A1A00),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFF9800).withOpacity(0.5)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.refresh_rounded, color: Color(0xFFFF9800), size: 14),
                      const SizedBox(width: 6),
                      Text('Kirim ulang pertanyaan',
                        style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFFFF9800), fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ),
              ]),
            )),
          ]),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Markdown block splitter & sanitizer
// ---------------------------------------------------------------------------

/// Tipe blok konten: teks biasa atau tabel markdown mentah.
sealed class _MdBlock {}
class _MdText  extends _MdBlock { _MdText(this.text);   final String text; }
class _MdTable extends _MdBlock { _MdTable(this.lines); final List<String> lines; }

/// Pisahkan markdown menjadi blok teks dan blok tabel.
/// <br> di luar tabel → \n biasa.
/// <br> di dalam baris tabel → dibiarkan apa adanya (dihandle _RawTableWidget).
List<_MdBlock> _splitBlocks(String raw) {
  final lines   = raw.split('\n');
  final blocks  = <_MdBlock>[];
  final textBuf = <String>[];
  final tableBuf= <String>[];

  bool inTable  = false;

  void flushText() {
    if (textBuf.isEmpty) return;
    final joined = textBuf.join('\n')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (joined.isNotEmpty) blocks.add(_MdText(joined));
    textBuf.clear();
  }

  void flushTable() {
    if (tableBuf.isEmpty) return;
    blocks.add(_MdTable(List.of(tableBuf)));
    tableBuf.clear();
  }

  final tableRowRe = RegExp(r'^\s*\|.*\|\s*$');
  final sepRowRe   = RegExp(r'^\s*\|[-| :]+\|\s*$');

  for (final line in lines) {
    final isRow = tableRowRe.hasMatch(line);
    final isSep = sepRowRe.hasMatch(line);

    if (isRow || isSep) {
      if (!inTable) { flushText(); inTable = true; }
      tableBuf.add(line);
    } else {
      if (inTable) { flushTable(); inTable = false; }
      textBuf.add(line);
    }
  }

  if (inTable) flushTable(); else flushText();
  return blocks;
}

// ---------------------------------------------------------------------------
// _RichCellContent — render isi satu cell dengan <br> sebagai baris baru
// ---------------------------------------------------------------------------

class _RichCellContent extends StatelessWidget {
  const _RichCellContent({required this.cellText, required this.baseStyle});

  final String    cellText;
  final TextStyle baseStyle;

  static final _brRe      = RegExp(r'<br\s*/?>', caseSensitive: false);
  static final _numberedRe= RegExp(r'^(\d+)\.\s+(.+)$', dotAll: true);
  static final _bulletRe  = RegExp(r'^[-–•]\s+(.+)$',   dotAll: true);

  @override
  Widget build(BuildContext context) {
    final parts = cellText
        .split(_brRe)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    if (parts.isEmpty) return const SizedBox.shrink();

    if (parts.length == 1) {
      return RichText(text: _parseInline(parts.first));
    }

    final widgets = <Widget>[];
    for (var i = 0; i < parts.length; i++) {
      final part        = parts[i];
      final numMatch    = _numberedRe.firstMatch(part);
      final bulletMatch = _bulletRe.firstMatch(part);

      Widget row;
      if (numMatch != null) {
        row = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${numMatch.group(1)}. ',
              style: baseStyle.copyWith(color: const Color(0xFF16DB65), fontWeight: FontWeight.w600)),
          Expanded(child: RichText(text: _parseInline(numMatch.group(2)!))),
        ]);
      } else if (bulletMatch != null) {
        row = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('• ', style: baseStyle.copyWith(color: const Color(0xFF16DB65))),
          Expanded(child: RichText(text: _parseInline(bulletMatch.group(1)!))),
        ]);
      } else {
        row = RichText(text: _parseInline(part));
      }

      widgets.add(row);
      if (i < parts.length - 1) widgets.add(const SizedBox(height: 4));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min, children: widgets);
  }

  TextSpan _parseInline(String text) {
    final spans   = <InlineSpan>[];
    final pattern = RegExp(r'\*\*\*(.*?)\*\*\*|\*\*(.*?)\*\*|\*(.*?)\*');
    int   last    = 0;

    for (final m in pattern.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start), style: baseStyle));
      if      (m.group(1) != null) spans.add(TextSpan(text: m.group(1), style: baseStyle.copyWith(fontWeight: FontWeight.w700, fontStyle: FontStyle.italic)));
      else if (m.group(2) != null) spans.add(TextSpan(text: m.group(2), style: baseStyle.copyWith(fontWeight: FontWeight.w700)));
      else if (m.group(3) != null) spans.add(TextSpan(text: m.group(3), style: baseStyle.copyWith(fontStyle: FontStyle.italic)));
      last = m.end;
    }

    if (last < text.length) spans.add(TextSpan(text: text.substring(last), style: baseStyle));
    return TextSpan(children: spans);
  }
}

// ---------------------------------------------------------------------------
// _RawTableWidget — parse & render baris tabel dari raw markdown string
// ---------------------------------------------------------------------------

class _RawTableWidget extends StatelessWidget {
  const _RawTableWidget({required this.lines});
  final List<String> lines;

  /// Pecah baris tabel menjadi list cell string (pertahankan <br> di dalamnya).
  static List<String> _parseCells(String line) {
    // Hapus pipe terdepan & trailing, lalu split by '|'
    // Tapi kita harus hati-hati: '|' di dalam <br> tidak ada, jadi split aman.
    String s = line.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|'))   s = s.substring(0, s.length - 1);
    return s.split('|').map((c) => c.trim()).toList();
  }

  static bool _isSeparator(String line) =>
      RegExp(r'^\s*\|[-| :]+\|\s*$').hasMatch(line);

  @override
  Widget build(BuildContext context) {
    // Filter separator row
    final dataLines = lines.where((l) => !_isSeparator(l)).toList();
    if (dataLines.isEmpty) return const SizedBox.shrink();

    final headerCells = _parseCells(dataLines.first);
    final bodyLines   = dataLines.length > 1 ? dataLines.sublist(1) : <String>[];
    final colCount    = headerCells.length;

    TableRow buildRow(List<String> cells, bool isHeader) {
      return TableRow(
        children: List.generate(colCount, (j) {
          final raw       = j < cells.length ? cells[j] : '';
          final baseStyle = isHeader
              ? GoogleFonts.poppins(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)
              : GoogleFonts.poppins(fontSize: 13, color: const Color(0xFFCCCCCC));
          return TableCell(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              color: isHeader ? const Color(0xFF1A1A1A) : null,
              child: _RichCellContent(cellText: raw, baseStyle: baseStyle),
            ),
          );
        }),
      );
    }

    final tableRows = <TableRow>[
      buildRow(headerCells, true),
      ...bodyLines.map((l) => buildRow(_parseCells(l), false)),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.hardEdge,
      child: Table(
        border: TableBorder.all(color: const Color(0xFF2A2A2A), width: 1),
        defaultColumnWidth: const FlexColumnWidth(),
        children: tableRows,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared Bubbles
// ---------------------------------------------------------------------------

class _AiAvatar extends StatelessWidget {
  @override Widget build(BuildContext context) => Container(
    width: 30, height: 30,
    decoration: BoxDecoration(
      shape: BoxShape.circle, color: const Color(0x3316DB65),
      border: Border.all(color: const Color(0xFF16DB65).withOpacity(0.4)),
    ),
    child: const Icon(Icons.eco_rounded, color: Color(0xFF16DB65), size: 15),
  );
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0x3316DB65),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16), topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16), bottomRight: Radius.circular(4),
          ),
          border: Border.all(color: const Color(0xFF16DB65).withOpacity(0.25)),
        ),
        child: Text(text, style: GoogleFonts.poppins(fontSize: 14, color: Colors.white, height: 1.6)),
      ),
    );
  }
}

class _AiBubble extends StatelessWidget {
  const _AiBubble({required this.text});
  final String text;

  Widget _buildMarkdownStyleSheet(String rawText) {
    final blocks = _splitBlocks(rawText);
    if (blocks.length == 1 && blocks.first is _MdText) {
      return _mdBody((blocks.first as _MdText).text);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: blocks.map((b) {
        if (b is _MdText)  return _mdBody(b.text);
        if (b is _MdTable) return _RawTableWidget(lines: b.lines);
        return const SizedBox.shrink();
      }).toList(),
    );
  }

  Widget _mdBody(String text) => MarkdownBody(
    data: text, selectable: true, extensionSet: md.ExtensionSet.gitHubWeb,
    onTapLink: (text, href, title) { if (href != null) launchUrl(Uri.parse(href)); },
    styleSheet: MarkdownStyleSheet(
      p        : GoogleFonts.poppins(fontSize: 14, color: Colors.white, height: 1.7),
      strong   : GoogleFonts.poppins(fontSize: 14, color: Colors.white, fontWeight: FontWeight.w600),
      em       : GoogleFonts.poppins(fontSize: 14, color: Colors.white, fontStyle: FontStyle.italic),
      h1       : GoogleFonts.poppins(fontSize: 20, color: Colors.white, fontWeight: FontWeight.w700, height: 1.4),
      h2       : GoogleFonts.poppins(fontSize: 17, color: Colors.white, fontWeight: FontWeight.w600, height: 1.4),
      h3       : GoogleFonts.poppins(fontSize: 15, color: Colors.white, fontWeight: FontWeight.w600, height: 1.4),
      code     : GoogleFonts.sourceCodePro(fontSize: 13, color: const Color(0xFF16DB65), backgroundColor: const Color(0xFF1A2A1A)),
      codeblockDecoration: BoxDecoration(
        color: const Color(0xFF0A1A0A), borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF16DB65).withOpacity(0.2)),
      ),
      codeblockPadding: const EdgeInsets.all(14),
      listBullet: GoogleFonts.poppins(fontSize: 14, color: const Color(0xFF16DB65)),
      listIndent: 20,
      blockquote: GoogleFonts.poppins(fontSize: 14, color: const Color(0xFFCCCCCC), fontStyle: FontStyle.italic, height: 1.6),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: const Color(0xFF16DB65).withOpacity(0.5), width: 3)),
      ),
      blockquotePadding: const EdgeInsets.only(left: 12),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: const Color(0xFF2A2A2A), width: 1)),
      ),
      a                : GoogleFonts.poppins(fontSize: 14, color: const Color(0xFF16DB65), decoration: TextDecoration.underline, decorationColor: const Color(0xFF16DB65).withOpacity(0.5)),
      tableHead        : GoogleFonts.poppins(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600),
      tableBody        : GoogleFonts.poppins(fontSize: 13, color: const Color(0xFFCCCCCC)),
      tableBorder      : TableBorder.all(color: const Color(0xFF2A2A2A), width: 1),
      tableHeadAlign   : TextAlign.left,
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      pPadding : const EdgeInsets.only(bottom: 8),
      h1Padding: const EdgeInsets.only(top: 4, bottom: 8),
      h2Padding: const EdgeInsets.only(top: 4, bottom: 6),
      h3Padding: const EdgeInsets.only(top: 4, bottom: 4),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _AiAvatar(), const SizedBox(width: 10),
      Expanded(child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color      : const Color(0xFF111111),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4), topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16),
          ),
          border: Border.all(color: const Color(0xFF1A1A1A)),
        ),
        child: _buildMarkdownStyleSheet(text),
      )),
    ]);
  }
}

class _ErrorBubble extends StatelessWidget {
  const _ErrorBubble({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 30, height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle, color: const Color(0x33FF4444),
          border: Border.all(color: const Color(0xFFFF4444).withOpacity(0.4)),
        ),
        child: const Icon(Icons.error_outline_rounded, color: Color(0xFFFF4444), size: 15),
      ),
      const SizedBox(width: 10),
      Expanded(child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color      : const Color(0xFF1A0A0A),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4), topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16),
          ),
          border: Border.all(color: const Color(0xFFFF4444).withOpacity(0.3)),
        ),
        child: Text(
          text.isNotEmpty ? text : 'Terjadi kesalahan saat memproses pertanyaan.',
          style: GoogleFonts.poppins(fontSize: 14, color: const Color(0xFFFF8888), height: 1.6)),
      )),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Input Bar
// ---------------------------------------------------------------------------

class _InputBar extends StatefulWidget {
  const _InputBar({required this.controller, required this.focusNode, required this.sending, required this.onSend});
  final TextEditingController controller;
  final FocusNode             focusNode;
  final bool                  sending;
  final VoidCallback          onSend;
  @override State<_InputBar> createState() => _InputBarState();
}
class _InputBarState extends State<_InputBar> {
  bool _hasText = false;
  @override void initState() {
    super.initState();
    widget.controller.addListener(() {
      final has = widget.controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: const BoxDecoration(
        color : Color(0xFF0D0D0D),
        border: Border(top: BorderSide(color: Color(0xFF1A1A1A))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: TextField(
              controller: widget.controller, focusNode: widget.focusNode,
              maxLines: null, keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline, enabled: !widget.sending,
              style: GoogleFonts.poppins(fontSize: 14, color: Colors.white),
              cursorColor: const Color(0xFF16DB65),
              decoration: InputDecoration(
                hintText : 'Ketik pertanyaan Anda...',
                hintStyle: GoogleFonts.poppins(fontSize: 14, color: const Color(0xFFA3A3A3)),
                filled: true, fillColor: const Color(0xFF111111),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border       : OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF1A1A1A))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF1A1A1A))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF16DB65), width: 1.5)),
                disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF1A1A1A))),
              ),
            ),
          )),
          const SizedBox(width: 10),
          SizedBox(width: 48, height: 48, child: ElevatedButton(
            onPressed: (widget.sending || !_hasText) ? null : widget.onSend,
            style: ElevatedButton.styleFrom(
              backgroundColor: _hasText && !widget.sending ? const Color(0xFF16DB65) : const Color(0xFF1A1A1A),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: widget.sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Icon(Icons.arrow_upward_rounded, color: Colors.black, size: 20),
          )),
        ],
      ),
    );
  }
}