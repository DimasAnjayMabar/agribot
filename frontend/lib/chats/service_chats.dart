// lib/chats/services/chat_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

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

const _kBaseUrl = 'http://localhost:8000';
const _kTokenRefreshInterval = Duration(minutes: 25);

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class ChatTopic {
  final int id;
  String title;
  final String createdAt;

  ChatTopic({required this.id, required this.title, required this.createdAt});

  factory ChatTopic.fromJson(Map<String, dynamic> j) => ChatTopic(
        id: j['id'] as int,
        title: j['title'] as String,
        createdAt: j['created_at'] as String,
      );
}

class ChatMessage {
  final int id;
  final int chatId;
  final String question;
  String response;
  String processingStatus;
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

  factory ChatMessage.pending({
    required int id,
    required int chatId,
    required String question,
    required String createdAt,
  }) =>
      ChatMessage(
        id: id,
        chatId: chatId,
        question: question,
        response: '',
        processingStatus: 'pending',
        createdAt: createdAt,
      );

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as int,
        chatId: j['chat_id'] as int,
        question: j['question'] as String,
        response: j['response'] as String? ?? '',
        processingStatus: j['processing_status'] as String? ?? 'pending',
        createdAt: j['created_at'] as String,
      );

  bool get isPending => processingStatus == 'pending';
  bool get isDone => processingStatus == 'done';
  bool get isFailed => processingStatus == 'failed';
  bool get isDisconnected => processingStatus == 'disconnected';
  bool get isStopped => processingStatus == 'stopped';
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
        name: j['name'] as String,
        email: j['email'] as String,
        username: j['username'] as String,
      );
}

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

        final lines = buffer.split('\n');
        buffer = lines.last;

        for (var i = 0; i < lines.length - 1; i++) {
          final line = lines[i].trim();

          if (line.isEmpty) {
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
              currentEventType = 'message';
            }
          } else if (line.startsWith(':')) {
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
// Chat Service (Main API Logic)
// ---------------------------------------------------------------------------

class ChatService {
  String? _accessToken;
  int? _userId;
  Timer? _tokenTimer;

  String? get accessToken => _accessToken;
  int? get userId => _userId;

  Map<String, dynamic> get _authHeader => {'Authorization': 'Bearer $_accessToken'};

  // Callbacks untuk UI
  final VoidCallback? onForceLogout;
  final void Function(String? token)? onTokenUpdated;

  ChatService({this.onForceLogout, this.onTokenUpdated});

  // -------------------------------------------------------------------------
  // Auth Methods
  // -------------------------------------------------------------------------

  Future<bool> initAuth() async {
    try {
      _accessToken = await _storage.read(key: 'access_token');
      final uid = await _storage.read(key: 'user_id');
      _userId = uid != null ? int.tryParse(uid) : null;
    } catch (_) {}

    if (_accessToken == null || _accessToken!.isEmpty || _userId == null) {
      return false;
    }
    _startTokenTimer();
    return true;
  }

  void _startTokenTimer() {
    _tokenTimer?.cancel();
    _tokenTimer = Timer.periodic(_kTokenRefreshInterval, (_) => _silentRefresh());
  }

  Future<void> _silentRefresh() async {
    final rt = await _storage.read(key: 'refresh_token');
    if (rt == null || rt.isEmpty) {
      _forceLogout();
      return;
    }
    try {
      final res = await _dio.post('/users/refresh-token', data: {'refresh_token': rt});
      if (res.statusCode == 200) {
        final d = res.data['data'] as Map<String, dynamic>;
        await Future.wait([
          _storage.write(key: 'access_token', value: d['access_token'] as String),
          _storage.write(key: 'refresh_token', value: d['refresh_token'] as String),
        ]);
        _accessToken = d['access_token'] as String;
        onTokenUpdated?.call(_accessToken);
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        _forceLogout();
      }
    } catch (_) {}
  }

  void _forceLogout() {
    _tokenTimer?.cancel();
    _accessToken = null;
    _userId = null;
    onForceLogout?.call();
  }

  Future<void> forceLogout() async {
    _tokenTimer?.cancel();
    await Future.wait([
      _storage.delete(key: 'access_token'),
      _storage.delete(key: 'refresh_token'),
      _storage.delete(key: 'user_id'),
      _storage.delete(key: 'session_created_at'),
    ]);
    _accessToken = null;
    _userId = null;
  }

  Future<void> logout() async {
    try {
      await _dio.post('/users/logout', options: Options(headers: _authHeader));
    } catch (_) {}
    await forceLogout();
  }

  // -------------------------------------------------------------------------
  // API Methods
  // -------------------------------------------------------------------------

  Future<List<ChatTopic>> fetchTopics() async {
    try {
      final res = await _dio.get('/topics', options: Options(headers: _authHeader));
      final data = res.data['data'] as Map<String, dynamic>;
      return (data['topics'] as List)
          .map((e) => ChatTopic.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<ChatUserProfile?> fetchProfile() async {
    if (_userId == null) return null;
    try {
      final res = await _dio.get('/users/$_userId', options: Options(headers: _authHeader));
      final data = res.data['data'] as Map<String, dynamic>;
      return ChatUserProfile.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  Future<List<ChatMessage>> fetchMessages(int chatId) async {
    try {
      final res = await _dio.get('/topics/$chatId', options: Options(headers: _authHeader));
      final data = res.data['data'] as Map<String, dynamic>;
      return (data['messages'] as List)
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<ChatMessage?> sendMessage({
    required int? chatId,
    required String question,
  }) async {
    try {
      final res = await _dio.post(
        '/chat/send',
        data: {'chat_id': chatId, 'question': question},
        options: Options(headers: _authHeader),
      );
      final data = res.data['data'] as Map<String, dynamic>;
      return ChatMessage.pending(
        id: data['id'] as int,
        chatId: data['chat_id'] as int,
        question: data['question'] as String,
        createdAt: data['created_at'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ChatMessage?> editMessage(int messageId, String newQuestion) async {
    try {
      final res = await _dio.patch(
        '/chat/edit/$messageId',
        data: {'question': newQuestion.trim()},
        options: Options(headers: _authHeader),
      );
      final data = res.data['data'] as Map<String, dynamic>;
      return ChatMessage.pending(
        id: data['id'] as int,
        chatId: data['chat_id'] as int,
        question: data['question'] as String,
        createdAt: data['created_at'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ChatMessage?> regenerateResponse(int messageId) async {
    try {
      final res = await _dio.post(
        '/chat/regenerate/$messageId',
        options: Options(headers: _authHeader),
      );
      final data = res.data['data'] as Map<String, dynamic>;
      return ChatMessage.pending(
        id: data['id'] as int,
        chatId: data['chat_id'] as int,
        question: data['question'] as String,
        createdAt: data['created_at'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ChatMessage?> fetchMessage(int detailId) async {
    try {
      final res = await _dio.get(
        '/chat/message/$detailId',
        options: Options(headers: _authHeader),
      );
      final jsonData = res.data['data'] as Map<String, dynamic>;
      return ChatMessage.fromJson(jsonData);
    } catch (e) {
      print('❌ Error fetching message: $e');
      return null;
    }
  }

  Future<bool> stopGeneration(int detailId) async {
    try {
      await _dio.post(
        '/chat/stop/$detailId',
        options: Options(headers: _authHeader),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteTopic(int topicId) async {
    try {
      await _dio.delete('/topics/$topicId', options: Options(headers: _authHeader));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> renameTopic(int topicId, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) return false;
    try {
      await _dio.patch(
        '/topics/$topicId',
        data: {'title': trimmed},
        options: Options(headers: _authHeader),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // SSE Methods
  // -------------------------------------------------------------------------

  Stream<SseEvent> subscribeToStream(int detailId) {
    final url = '$_kBaseUrl/chat/stream/$detailId';
    final token = _accessToken ?? '';
    return SseClient.subscribe(url, token);
  }

  void dispose() {
    _tokenTimer?.cancel();
  }
}

// ---------------------------------------------------------------------------
// SSE Tracker (Helper untuk UI)
// ---------------------------------------------------------------------------

class SseTracker {
  final int detailId;
  StreamSubscription<SseEvent>? sseSub;

  SseTracker({required this.detailId});

  void cancel() {
    sseSub?.cancel();
    sseSub = null;
  }
}