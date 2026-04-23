// lib/chats/chats_page.dart
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:frontend/chats/service_chats.dart';
import 'package:frontend/chats/sidebar.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';

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
// Platform Helpers
// ---------------------------------------------------------------------------

bool _isMobileDevice(BuildContext context) {
  final width = MediaQuery.of(context).size.width;
  // Web mobile atau aplikasi mobile (lebar < 768)
  return width < 768 ||
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS));
}

bool _isDesktopDevice(BuildContext context) {
  return !_isMobileDevice(context);
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
  late final ChatService _chatService;

  bool _sidebarOpen = true;
  late final AnimationController _sidebarCtrl;
  late final Animation<double> _sidebarAnim;

  List<ChatTopic> _topics = [];
  ChatUserProfile? _profile;
  bool _loadingTopics = true;

  int? _activeChatId;
  List<ChatMessage> _messages = [];
  bool _loadingMessages = false;

  bool _sending = false;
  String? _pendingQuestion;

  final Map<int, SseTracker> _trackers = {};

  int? _renamingId;
  String? _renamingTemp;
  String? _greeting;

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();

    _sidebarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: 1.0,
    );
    _sidebarAnim = CurvedAnimation(
      parent: _sidebarCtrl,
      curve: Curves.easeInOut,
    );

    _chatService = ChatService(
      onForceLogout: _handleForceLogout,
      onTokenUpdated: (_) => setState(() {}),
    );

    _initAuth();
  }

  @override
  void dispose() {
    _cancelAllTrackers();
    _chatService.dispose();
    _sidebarCtrl.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  // ── Auth ──────────────────────────────────────────────────────────────────

  Future<void> _initAuth() async {
    final isAuthenticated = await _chatService.initAuth();
    if (!isAuthenticated) {
      if (mounted) context.go('/users/login');
      return;
    }
    await Future.wait([_fetchTopics(), _fetchProfile()]);
    _pickGreeting();
  }

  void _handleForceLogout() {
    if (mounted) context.go('/users/login');
  }

  Future<void> _logout() async {
    _cancelAllTrackers();
    await _chatService.logout();
    if (mounted) context.go('/users/login');
  }

  // ── SSE Tracker ───────────────────────────────────────────────────────────

  void _startTracking(int detailId) {
    _trackers[detailId]?.cancel();
    final tracker = SseTracker(detailId: detailId);
    _trackers[detailId] = tracker;

    tracker.sseSub = _chatService
        .subscribeToStream(detailId)
        .listen(
          (event) async {
            if (!mounted) return;

            if (event.type == 'done' ||
                event.type == 'error' ||
                event.type == 'stopped') {
              await _fetchAndApplyMessage(detailId);
              _stopTracking(detailId);
            } else if (event.type == 'timeout') {
              _markDisconnected(detailId);
              _stopTracking(detailId);
            }
          },
          onError: (error) {
            if (mounted) _markDisconnected(detailId);
            _stopTracking(detailId);
          },
          onDone: () {
            if (mounted) {
              final msg = _messages.firstWhere(
                (m) => m.id == detailId,
                orElse: () => ChatMessage(
                  id: detailId,
                  chatId: 0,
                  question: '',
                  response: '',
                  processingStatus: 'pending',
                  createdAt: '',
                ),
              );
              if (msg.isPending) _markDisconnected(detailId);
            }
            _stopTracking(detailId);
          },
          cancelOnError: true,
        );

    Future.delayed(const Duration(seconds: 30), () {
      if (mounted && _trackers.containsKey(detailId)) {
        final msg = _messages.firstWhere(
          (m) => m.id == detailId,
          orElse: () => ChatMessage(
            id: detailId,
            chatId: 0,
            question: '',
            response: '',
            processingStatus: 'pending',
            createdAt: '',
          ),
        );
        if (msg.isPending) _fetchAndApplyMessage(detailId);
      }
    });
  }

  Future<void> _fetchAndApplyMessage(int detailId) async {
    if (!mounted) return;
    final updated = await _chatService.fetchMessage(detailId);
    if (updated != null) {
      _applyMessageUpdate(updated);
    } else {
      _markDisconnected(detailId);
    }
  }

  void _applyMessageUpdate(ChatMessage updated) {
    if (!mounted) return;
    final idx = _messages.indexWhere((m) => m.id == updated.id);
    if (idx != -1) {
      setState(() => _messages[idx] = updated);
      _scrollToBottom();
    }
  }

  void _markDisconnected(int detailId) {
    if (!mounted) return;
    final idx = _messages.indexWhere((m) => m.id == detailId);
    if (idx != -1) {
      setState(() => _messages[idx].processingStatus = 'disconnected');
    }
  }

  void _stopTracking(int detailId) {
    _trackers[detailId]?.cancel();
    _trackers.remove(detailId);
    if (mounted) setState(() {});
  }

  void _cancelAllTrackers() {
    for (final t in _trackers.values) t.cancel();
    _trackers.clear();
  }

  // ── Fetch ─────────────────────────────────────────────────────────────────

  Future<void> _fetchTopics() async {
    final topics = await _chatService.fetchTopics();
    if (mounted) {
      setState(() {
        _topics = topics;
        _loadingTopics = false;
      });
    }
  }

  Future<void> _fetchProfile() async {
    final profile = await _chatService.fetchProfile();
    if (mounted && profile != null) setState(() => _profile = profile);
  }

  Future<void> _fetchMessages(int chatId) async {
    setState(() {
      _loadingMessages = true;
      _messages = [];
    });

    final msgs = await _chatService.fetchMessages(chatId);

    if (!mounted) return;

    if (msgs == null) {
      setState(() => _loadingMessages = false);
      _showSnack('Gagal memuat pesan.');
      return;
    }

    setState(() {
      _messages = msgs;
      _loadingMessages = false;
    });
    _scrollToBottom();

    for (final msg in msgs.where((m) => m.isPending)) {
      _startTracking(msg.id);
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _pickGreeting() {
    setState(
      () => _greeting = _kGreetings[Random().nextInt(_kGreetings.length)],
    );
  }

  void _newChat() {
    _cancelAllTrackers();
    _pickGreeting();
    setState(() {
      _activeChatId = null;
      _messages = [];
      _pendingQuestion = null;
    });
  }

  void _selectTopic(ChatTopic topic) {
    _cancelAllTrackers();
    setState(() {
      _activeChatId = topic.id;
      _greeting = null;
      _pendingQuestion = null;
    });
    _fetchMessages(topic.id);
    if (MediaQuery.of(context).size.width < 768) _toggleSidebar();
  }

  Future<void> _sendMessage({
    String? overrideText,
    int? replaceDetailId,
  }) async {
    final text = overrideText ?? _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    if (overrideText == null) _inputCtrl.clear();
    setState(() {
      _sending = true;
      _pendingQuestion = replaceDetailId == null ? text : null;
    });
    _scrollToBottom();

    final msg = await _chatService.sendMessage(
      chatId: _activeChatId,
      question: text,
    );

    if (msg == null) {
      setState(() {
        _pendingQuestion = null;
        _sending = false;
      });
      _showSnack('Gagal mengirim pesan. Coba lagi.');
      return;
    }

    if (_activeChatId == null) {
      setState(() {
        _activeChatId = msg.chatId;
        _greeting = null;
        _pendingQuestion = null;
        _messages.add(msg);
        _sending = false;
      });
      await _fetchTopics();
    } else if (replaceDetailId != null) {
      final idx = _messages.indexWhere((m) => m.id == replaceDetailId);
      setState(() {
        _pendingQuestion = null;
        if (idx != -1) {
          _messages[idx] = msg;
        } else {
          _messages.add(msg);
        }
        _sending = false;
      });
    } else {
      setState(() {
        _pendingQuestion = null;
        _messages.add(msg);
        _sending = false;
      });
    }

    _scrollToBottom();
    _startTracking(msg.id);
  }

  Future<void> _uploadPdf(Uint8List bytes, String fileName) async {
    final result = await _chatService.uploadPdf(
      fileBytes: bytes,
      fileName:  fileName,
    );
    if (!mounted) return;
    final success = result?['success'] == true;
    final message = success
        ? 'PDF "$fileName" diterima dan sedang diproses. Mungkin perlu beberapa saat untuk bot bisa menjawab pertanyaan terkait informasi baru'
        : (result?['detail'] as String? ??
           result?['message'] as String? ??
           'Gagal mengunggah file. Coba lagi.');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.poppins(fontSize: 13)),
        backgroundColor:
            success ? const Color(0xFF16DB65) : const Color(0xFFFF4444),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _editMessage(ChatMessage msg, String newQuestion) async {
    if (_sending) return;
    setState(() => _sending = true);

    final updated = await _chatService.editMessage(msg.id, newQuestion);

    if (updated != null) {
      final idx = _messages.indexWhere((m) => m.id == msg.id);
      if (idx != -1) setState(() => _messages[idx] = updated);
      _startTracking(msg.id);
    } else {
      _showSnack('Gagal mengedit pesan.');
    }

    if (mounted) setState(() => _sending = false);
  }

  Future<void> _regenerateResponse(ChatMessage msg) async {
    if (_sending) return;
    setState(() => _sending = true);

    final updated = await _chatService.regenerateResponse(msg.id);

    if (updated != null) {
      final idx = _messages.indexWhere((m) => m.id == msg.id);
      if (idx != -1) setState(() => _messages[idx] = updated);
      _startTracking(msg.id);
    } else {
      _showSnack('Gagal regenerate jawaban.');
    }

    if (mounted) setState(() => _sending = false);
  }

  Future<void> _stopGeneration(int detailId) async {
    final success = await _chatService.stopGeneration(detailId);
    if (!success && mounted) {
      _showSnack('Gagal menghentikan generate.');
    }
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _showSnack('Disalin ke clipboard.');
  }

  Future<void> _playTTS(ChatMessage msg) async {
    if (msg.response.isEmpty) {
      _showSnack('Belum ada jawaban untuk dibacakan.');
      return;
    }
    _showSnack('Memuat suara...');

    try {
      await _chatService.playTTS(msg.id);
    } catch (e) {
      _showSnack('Gagal memutar suara.');
    }
  }

  Future<void> _stopTTS() async {
    try {
      await _chatService.stopTTS();
    } catch (e) {
      _showSnack('Gagal menghentikan suara.');
    }
  }

  Future<void> _resendMessage(ChatMessage msg) async {
    await _sendMessage(overrideText: msg.question, replaceDetailId: msg.id);
  }

  Future<void> _deleteTopic(ChatTopic topic) async {
    final success = await _chatService.deleteTopic(topic.id);
    if (success) {
      _cancelAllTrackers();
      setState(() {
        _topics.removeWhere((t) => t.id == topic.id);
        if (_activeChatId == topic.id) {
          _activeChatId = null;
          _messages = [];
          _pendingQuestion = null;
          _pickGreeting();
        }
      });
    } else {
      _showSnack('Gagal menghapus topik.');
    }
  }

  Future<void> _renameTopic(ChatTopic topic, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) return;
    final success = await _chatService.renameTopic(topic.id, trimmed);
    if (success) {
      setState(() {
        topic.title = trimmed;
        _renamingId = null;
      });
    } else {
      _showSnack('Gagal mengganti judul.');
    }
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
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: GoogleFonts.poppins(fontSize: 13)),
        backgroundColor: const Color(0xFF111111),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final int? pendingDetailId = _trackers.isNotEmpty
        ? _trackers.keys.first
        : null;

    return Scaffold(
      backgroundColor: const Color(0xFF020202),
      body: Row(
        children: [
          SizeTransition(
            sizeFactor: _sidebarAnim,
            axis: Axis.horizontal,
            child: ChatSidebar(
              topics: _topics,
              loading: _loadingTopics,
              activeChatId: _activeChatId,
              profile: _profile,
              renamingId: _renamingId,
              renamingTemp: _renamingTemp,
              onNewChat: _newChat,
              onSelectTopic: _selectTopic,
              onDeleteTopic: _deleteTopic,
              onStartRename: (t) => setState(() {
                _renamingId = t.id;
                _renamingTemp = t.title;
              }),
              onConfirmRename: (t, v) => _renameTopic(t, v),
              onCancelRename: () => setState(() => _renamingId = null),
              onRenameChange: (v) => setState(() => _renamingTemp = v),
              onProfileTap: () => context.go('/user_profile'),
              onLogout: _logout,
            ),
          ),
          Expanded(
            child: Column(
              children: [
                _ChatTopBar(
                  sidebarOpen: _sidebarOpen,
                  onToggleSidebar: _toggleSidebar,
                  title: _activeChatId != null
                      ? _topics
                            .firstWhere(
                              (t) => t.id == _activeChatId,
                              orElse: () => ChatTopic(
                                id: 0,
                                title: 'Chat',
                                createdAt: '',
                              ),
                            )
                            .title
                      : 'Chat Baru',
                  hasPending: _trackers.isNotEmpty,
                ),
                Expanded(child: _buildBody()),
                _InputBar(
                  controller: _inputCtrl,
                  focusNode: _inputFocus,
                  sending: _sending,
                  onSend: () => _sendMessage(),
                  onUploadPdf: _uploadPdf,
                  pendingDetailId: pendingDetailId,
                  onStop: pendingDetailId != null
                      ? () => _stopGeneration(pendingDetailId)
                      : null,
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
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFF16DB65),
          strokeWidth: 2,
        ),
      );
    }
    if (_activeChatId == null &&
        _messages.isEmpty &&
        _pendingQuestion == null) {
      return _GreetingView(greeting: _greeting ?? _kGreetings[0]);
    }
    if (_messages.isEmpty && _pendingQuestion == null) {
      return const _GreetingView(
        greeting: 'Topik ini masih kosong. Mulai percakapan! 💬',
      );
    }

    final itemCount = _messages.length + (_pendingQuestion != null ? 1 : 0);

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      itemCount: itemCount,
      itemBuilder: (_, i) {
        if (_pendingQuestion != null && i == _messages.length) {
          return _PendingBubble(question: _pendingQuestion!);
        }

        final msg = _messages[i];

        if (msg.isPending) {
          return _PendingBubble(question: msg.question);
        }

        if (msg.isDisconnected) {
          return _DisconnectedBubble(
            message: msg,
            onResend: () => _resendMessage(msg),
          );
        }

        if (msg.isFailed) {
          return _ErrorBubble(text: msg.response);
        }

        if (msg.isStopped) {
          return ValueListenableBuilder<int?>(
            valueListenable: _chatService.playingTtsId,
            builder: (context, playingId, _) {
              final isPlaying = playingId == msg.id;
              return _StoppedBubble(
                response: msg.response,
                onRegenerate: () => _regenerateResponse(msg),
                onCopyAnswer: () => _copyText(msg.response),
                isPlayingTts: isPlaying,
                onToggleTTS: () {
                  if (isPlaying) {
                    _stopTTS();
                  } else {
                    _playTTS(msg);
                  }
                },
              );
            },
          );
        }

        // Status 'done' — jawaban lengkap
        return ValueListenableBuilder<int?>(
          valueListenable: _chatService.playingTtsId,
          builder: (context, playingId, _) {
            final isPlaying = playingId == msg.id;
            return _MessagePair(
              message: msg,
              onEdit: (newQ) => _editMessage(msg, newQ),
              onRegenerate: () => _regenerateResponse(msg),
              onCopyQuestion: () => _copyText(msg.question),
              onCopyAnswer: () => _copyText(msg.response),
              isPlayingTts: isPlaying,
              onToggleTTS: () {
                if (isPlaying) {
                  _stopTTS();
                } else {
                  _playTTS(msg);
                }
              },
            );
          },
        );
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

  final bool sidebarOpen;
  final VoidCallback onToggleSidebar;
  final String title;
  final bool hasPending;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D0D),
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
                  border: Border.all(color: const Color(0xFF1A1A1A)),
                ),
                child: Icon(
                  sidebarOpen ? Icons.menu_open_rounded : Icons.menu_rounded,
                  size: 18,
                  color: const Color(0xFFA3A3A3),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
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
                  Text(
                    'Memproses',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: const Color(0xFF16DB65),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
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
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _ctrl,
    child: Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(
        color: Color(0xFF16DB65),
        shape: BoxShape.circle,
      ),
    ),
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
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0x3316DB65),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF16DB65).withOpacity(0.4),
                  width: 1.5,
                ),
              ),
              child: const Icon(
                Icons.eco_rounded,
                color: Color(0xFF16DB65),
                size: 30,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              greeting,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.white,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Ketik pertanyaan Anda di bawah untuk memulai.',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: const Color(0xFFA3A3A3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message Pair — done / failed / stopped
// ---------------------------------------------------------------------------

class _MessagePair extends StatefulWidget {
  const _MessagePair({
    required this.message,
    required this.onEdit,
    required this.onRegenerate,
    required this.onCopyQuestion,
    required this.onCopyAnswer,
    required this.isPlayingTts,
    required this.onToggleTTS,
  });

  final ChatMessage message;
  final void Function(String) onEdit;
  final VoidCallback onRegenerate;
  final VoidCallback onCopyQuestion;
  final VoidCallback onCopyAnswer;
  final bool isPlayingTts;
  final VoidCallback onToggleTTS;

  @override
  State<_MessagePair> createState() => _MessagePairState();
}

class _MessagePairState extends State<_MessagePair> {
  bool _hovered = false;

  void _showQuestionActions(BuildContext context) {
    final isMobile = _isMobileDevice(context);

    if (isMobile) {
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF111111),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(
                  Icons.edit_outlined,
                  color: Color(0xFF16DB65),
                ),
                title: Text(
                  'Edit pertanyaan',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showEditDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.copy_rounded,
                  color: Color(0xFF16DB65),
                ),
                title: Text(
                  'Salin pertanyaan',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onCopyQuestion();
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final isMobile = _isMobileDevice(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── User bubble dengan action buttons ───────────────────────────────
          if (isMobile)
            GestureDetector(
              onLongPress: () => _showQuestionActions(context),
              child: _UserBubble(text: msg.question),
            )
          else
            MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _UserBubble(text: msg.question),
                  AnimatedOpacity(
                    opacity: _hovered && !msg.isStopped ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6, right: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ActionChip(
                            icon: Icons.edit_outlined,
                            label: 'Edit',
                            onTap: () => _showEditDialog(context),
                          ),
                          const SizedBox(width: 6),
                          _ActionChip(
                            icon: Icons.copy_rounded,
                            label: 'Salin',
                            onTap: widget.onCopyQuestion,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (msg.isStopped)
                    AnimatedOpacity(
                      opacity: _hovered ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6, right: 4),
                        child: _ActionChip(
                          icon: Icons.copy_rounded,
                          label: 'Salin',
                          onTap: widget.onCopyQuestion,
                        ),
                      ),
                    ),
                ],
              ),
            ),

          const SizedBox(height: 12),

          // ── AI response area ──────────────────────────────────────────
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AiBubble(text: msg.response),
              const SizedBox(height: 8),
              _AnswerActions(
                onRegenerate: widget.onRegenerate,
                onCopy: widget.onCopyAnswer,
                isPlayingTts: widget.isPlayingTts,
                onToggleTTS: widget.onToggleTTS,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context) {
    final ctrl = TextEditingController(text: widget.message.question);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111111),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          'Edit Pertanyaan',
          style: GoogleFonts.poppins(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: null,
            style: GoogleFonts.poppins(fontSize: 14, color: Colors.white),
            cursorColor: const Color(0xFF16DB65),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF1A1A1A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(
                  color: Color(0xFF16DB65),
                  width: 1.5,
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Batal',
              style: GoogleFonts.poppins(color: const Color(0xFFA3A3A3)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF16DB65),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              elevation: 0,
            ),
            onPressed: () {
              final text = ctrl.text.trim();
              if (text.isNotEmpty && text != widget.message.question) {
                Navigator.pop(ctx);
                widget.onEdit(text);
              }
            },
            child: Text(
              'Simpan',
              style: GoogleFonts.poppins(
                color: Colors.black,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Action Chip
// ---------------------------------------------------------------------------

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active 
              ? const Color(0xFF16DB65).withOpacity(0.15) 
              : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active 
                ? const Color(0xFF16DB65).withOpacity(0.5) 
                : const Color(0xFF2A2A2A),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon, 
              size: 13, 
              color: active ? const Color(0xFF16DB65) : const Color(0xFFA3A3A3)
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.poppins(
                fontSize: 11,
                color: active ? const Color(0xFF16DB65) : const Color(0xFFA3A3A3),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Answer Actions 
// ---------------------------------------------------------------------------

class _AnswerActions extends StatelessWidget {
  const _AnswerActions({
    required this.onRegenerate,
    required this.onCopy,
    required this.isPlayingTts,
    required this.onToggleTTS,
  });

  final VoidCallback onRegenerate;
  final VoidCallback onCopy;
  final bool isPlayingTts;
  final VoidCallback onToggleTTS;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 40), 
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _ActionChip(
            icon: Icons.refresh_rounded,
            label: 'Generate ulang',
            onTap: onRegenerate,
          ),
          _ActionChip(
            icon: Icons.copy_rounded,
            label: 'Salin',
            onTap: onCopy,
          ),
          _ActionChip(
            icon: isPlayingTts ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            label: isPlayingTts ? 'Stop Suara' : 'Dengarkan',
            onTap: onToggleTTS,
            active: isPlayingTts,
          ),
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

  @override
  State<_PendingBubble> createState() => _PendingBubbleState();
}

class _PendingBubbleState extends State<_PendingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _UserBubble(text: widget.question),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AiAvatar(),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF111111),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(4),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  border: Border.all(color: const Color(0xFF1A1A1A)),
                ),
                child: FadeTransition(
                  opacity: _anim,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(
                      3,
                      (i) => Padding(
                        padding: EdgeInsets.only(left: i == 0 ? 0 : 5),
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: Color(0xFF16DB65),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
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
  final ChatMessage message;
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0x33FF9800),
                  border: Border.all(
                    color: const Color(0xFFFF9800).withOpacity(0.4),
                  ),
                ),
                child: const Icon(
                  Icons.wifi_off_rounded,
                  color: Color(0xFFFF9800),
                  size: 15,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1200),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                    border: Border.all(
                      color: const Color(0xFFFF9800).withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Koneksi terputus sebelum jawaban diterima.',
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          color: const Color(0xFFFFB74D),
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: onResend,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A1A00),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(0xFFFF9800).withOpacity(0.5),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.refresh_rounded,
                                color: Color(0xFFFF9800),
                                size: 14,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Kirim ulang pertanyaan',
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  color: const Color(0xFFFF9800),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stopped Bubble
// ---------------------------------------------------------------------------

class _StoppedBubble extends StatelessWidget {
  const _StoppedBubble({
    required this.response,
    required this.onRegenerate,
    required this.onCopyAnswer,
    required this.isPlayingTts,
    required this.onToggleTTS,
  });

  final String response;
  final VoidCallback onRegenerate;
  final VoidCallback onCopyAnswer;
  final bool isPlayingTts;
  final VoidCallback onToggleTTS;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AiAvatar(),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF111111),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(4),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  border: Border.all(color: const Color(0xFF2A2A2A)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (response.isNotEmpty) ...[
                      MarkdownBody(
                        data: response,
                        selectable: true,
                        extensionSet: md.ExtensionSet.gitHubWeb,
                        onTapLink: (text, href, title) {
                          if (href != null) launchUrl(Uri.parse(href));
                        },
                        styleSheet: _markdownStyleSheet(),
                      ),
                      const Divider(
                        color: Color(0xFF2A2A2A),
                        height: 20,
                        thickness: 1,
                      ),
                    ],
                    Row(
                      children: [
                        const Icon(
                          Icons.stop_circle_outlined,
                          color: Color(0xFFA3A3A3),
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Generate dihentikan',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: const Color(0xFFA3A3A3),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _AnswerActions(
          onRegenerate: onRegenerate,
          onCopy: onCopyAnswer,
          isPlayingTts: isPlayingTts,
          onToggleTTS: onToggleTTS,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Markdown StyleSheet helper
// ---------------------------------------------------------------------------

MarkdownStyleSheet _markdownStyleSheet() {
  return MarkdownStyleSheet(
    p: GoogleFonts.poppins(fontSize: 14, color: Colors.white, height: 1.7),
    strong: GoogleFonts.poppins(
      fontSize: 14,
      color: Colors.white,
      fontWeight: FontWeight.w600,
    ),
    em: GoogleFonts.poppins(
      fontSize: 14,
      color: Colors.white,
      fontStyle: FontStyle.italic,
    ),
    h1: GoogleFonts.poppins(
      fontSize: 20,
      color: Colors.white,
      fontWeight: FontWeight.w700,
      height: 1.4,
    ),
    h2: GoogleFonts.poppins(
      fontSize: 17,
      color: Colors.white,
      fontWeight: FontWeight.w600,
      height: 1.4,
    ),
    h3: GoogleFonts.poppins(
      fontSize: 15,
      color: Colors.white,
      fontWeight: FontWeight.w600,
      height: 1.4,
    ),
    code: GoogleFonts.sourceCodePro(
      fontSize: 13,
      color: const Color(0xFF16DB65),
      backgroundColor: const Color(0xFF1A2A1A),
    ),
    codeblockDecoration: BoxDecoration(
      color: const Color(0xFF0A1A0A),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFF16DB65).withOpacity(0.2)),
    ),
    codeblockPadding: const EdgeInsets.all(14),
    listBullet: GoogleFonts.poppins(
      fontSize: 14,
      color: const Color(0xFF16DB65),
    ),
    listIndent: 20,
    blockquote: GoogleFonts.poppins(
      fontSize: 14,
      color: const Color(0xFFCCCCCC),
      fontStyle: FontStyle.italic,
      height: 1.6,
    ),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: const Color(0xFF16DB65).withOpacity(0.5),
          width: 3,
        ),
      ),
    ),
    blockquotePadding: const EdgeInsets.only(left: 12),
    a: GoogleFonts.poppins(
      fontSize: 14,
      color: const Color(0xFF16DB65),
      decoration: TextDecoration.underline,
      decorationColor: const Color(0xFF16DB65).withOpacity(0.5),
    ),
  );
}

// ---------------------------------------------------------------------------
// Shared Bubbles
// ---------------------------------------------------------------------------

class _AiAvatar extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: 30,
    height: 30,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: const Color(0x3316DB65),
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
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.65,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0x3316DB65),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
          border: Border.all(color: const Color(0xFF16DB65).withOpacity(0.25)),
        ),
        child: Text(
          text,
          style: GoogleFonts.poppins(
            fontSize: 14,
            color: Colors.white,
            height: 1.6,
          ),
        ),
      ),
    );
  }
}

class _AiBubble extends StatelessWidget {
  const _AiBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AiAvatar(),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
              border: Border.all(color: const Color(0xFF1A1A1A)),
            ),
            child: MarkdownBody(
              data: text,
              selectable: true,
              extensionSet: md.ExtensionSet.gitHubWeb,
              onTapLink: (text, href, title) {
                if (href != null) launchUrl(Uri.parse(href));
              },
              styleSheet: _markdownStyleSheet(),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBubble extends StatelessWidget {
  const _ErrorBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0x33FF4444),
            border: Border.all(color: const Color(0xFFFF4444).withOpacity(0.4)),
          ),
          child: const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFFF4444),
            size: 15,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A0A0A),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
              border: Border.all(
                color: const Color(0xFFFF4444).withOpacity(0.3),
              ),
            ),
            child: Text(
              text.isNotEmpty
                  ? text
                  : 'Terjadi kesalahan saat memproses pertanyaan.',
              style: GoogleFonts.poppins(
                fontSize: 14,
                color: const Color(0xFFFF8888),
                height: 1.6,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Intents untuk Shortcuts
// ---------------------------------------------------------------------------

class SendMessageIntent extends Intent {
  const SendMessageIntent();
}

// ---------------------------------------------------------------------------
// Input Bar
// ---------------------------------------------------------------------------

class _InputBar extends StatefulWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
    required this.onUploadPdf,
    this.pendingDetailId,
    this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final VoidCallback onSend;
  final Future<void> Function(Uint8List bytes, String filename) onUploadPdf;
  final int? pendingDetailId;
  final VoidCallback? onStop;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(() {
      final has = widget.controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  void _showUploadDialog(BuildContext context) {
    String?    _selectedFileName;
    Uint8List? _selectedFileBytes;
    bool       _isUploading = false;
 
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
 
          Future<void> pickFile() async {
            final result = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['pdf'],
              withData: true,
            );
            if (result == null) return;
            final picked = result.files.single;
            if (picked.bytes == null) return;
            setDialogState(() {
              _selectedFileName  = picked.name;
              _selectedFileBytes = picked.bytes;
            });
          }
 
          Future<void> doUpload() async {
            if (_selectedFileBytes == null || _selectedFileName == null) return;
            setDialogState(() => _isUploading = true);
            await widget.onUploadPdf(_selectedFileBytes!, _selectedFileName!);
            if (ctx.mounted) Navigator.of(ctx).pop();
          }
 
          return Dialog(
            backgroundColor: const Color(0xFF111111),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFF1A1A1A)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF16DB65).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.auto_stories_rounded,
                            color: Color(0xFF16DB65), size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Tambah Pengetahuan Bot',
                          style: GoogleFonts.poppins(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (!_isUploading)
                        GestureDetector(
                          onTap: () => Navigator.of(ctx).pop(),
                          child: const Icon(Icons.close_rounded,
                              color: Color(0xFF666666), size: 20),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tambahkan pengetahuan bot di sini',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      color: const Color(0xFFA3A3A3),
                    ),
                  ),
                  const SizedBox(height: 20),
 
                  // Upload area
                  GestureDetector(
                    onTap: _isUploading ? null : pickFile,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 24, horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D0D0D),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _selectedFileName != null
                              ? const Color(0xFF16DB65).withOpacity(0.5)
                              : const Color(0xFF2A2A2A),
                        ),
                      ),
                      child: Column(
                        children: [
                          if (_isUploading)
                            const SizedBox(
                              width: 36, height: 36,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Color(0xFF16DB65),
                              ),
                            )
                          else
                            Icon(
                              _selectedFileName != null
                                  ? Icons.picture_as_pdf_rounded
                                  : Icons.upload_file_rounded,
                              color: _selectedFileName != null
                                  ? const Color(0xFF16DB65)
                                  : const Color(0xFF555555),
                              size: 36,
                            ),
                          const SizedBox(height: 10),
                          if (_isUploading) ...[
                            Text(
                              'Mengunggah "$_selectedFileName"...',
                              style: GoogleFonts.poppins(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF16DB65),
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Mohon tunggu, jangan tutup dialog ini',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                color: const Color(0xFF666666),
                              ),
                            ),
                          ] else if (_selectedFileName != null) ...[
                            Text(
                              _selectedFileName!,
                              style: GoogleFonts.poppins(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF16DB65),
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Ketuk untuk mengganti file',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                color: const Color(0xFF666666),
                              ),
                            ),
                          ] else ...[
                            Text(
                              'Ketuk untuk memilih file PDF',
                              style: GoogleFonts.poppins(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF888888),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Hanya file .pdf yang didukung',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                color: const Color(0xFF555555),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
 
                  const SizedBox(height: 20),
 
                  // Buttons
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: _isUploading
                              ? null
                              : () => Navigator.of(ctx).pop(),
                          style: TextButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          child: Text(
                            'Batal',
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              color: _isUploading
                                  ? const Color(0xFF444444)
                                  : const Color(0xFF888888),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          onPressed:
                              (_selectedFileName != null && !_isUploading)
                                  ? doUpload
                                  : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                (_selectedFileName != null && !_isUploading)
                                    ? const Color(0xFF16DB65)
                                    : const Color(0xFF1A1A1A),
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            elevation: 0,
                          ),
                          child: Text(
                            'Unggah',
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: (_selectedFileName != null &&
                                      !_isUploading)
                                  ? Colors.black
                                  : const Color(0xFF555555),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPending = widget.pendingDetailId != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D0D),
        border: Border(top: BorderSide(color: Color(0xFF1A1A1A))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Tombol Upload PDF
          Padding(
            padding: const EdgeInsets.only(bottom: 0),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Tooltip(
                message: 'Unggah PDF pengetahuan bot',
                child: ElevatedButton(
                  onPressed: () => _showUploadDialog(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A1A1A),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: const Icon(
                    Icons.upload_file_rounded,
                    color: Color(0xFF888888),
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: Shortcuts(
                shortcuts: <ShortcutActivator, Intent>{
                  // HANYA CEGAT ENTER SAJA. Shift+Enter dibiarkan lewat agar ditangani bawaan TextField
                  const SingleActivator(LogicalKeyboardKey.enter): const SendMessageIntent(),
                  const SingleActivator(LogicalKeyboardKey.numpadEnter): const SendMessageIntent(),
                },
                child: Actions(
                  actions: <Type, Action<Intent>>{
                    SendMessageIntent: CallbackAction<SendMessageIntent>(
                      onInvoke: (intent) {
                        if (!widget.sending && widget.controller.text.trim().isNotEmpty) {
                          widget.onSend();
                        }
                        return null;
                      },
                    ),
                  },
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    enabled: !widget.sending,
                    style: GoogleFonts.poppins(fontSize: 14, color: Colors.white),
                    cursorColor: const Color(0xFF16DB65),
                    decoration: InputDecoration(
                      hintText: 'Ketik pertanyaan Anda...',
                      hintStyle: GoogleFonts.poppins(
                        fontSize: 14,
                        color: const Color(0xFFA3A3A3),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF111111),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF1A1A1A)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF1A1A1A)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: Color(0xFF16DB65),
                          width: 1.5,
                        ),
                      ),
                      disabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF1A1A1A)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 48,
            height: 48,
            child: hasPending
                ? Tooltip(
                    message: 'Hentikan generate',
                    child: ElevatedButton(
                      onPressed: widget.onStop,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF4444),
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: const Icon(
                        Icons.stop_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  )
                : ElevatedButton(
                    onPressed: (widget.sending || !_hasText)
                        ? null
                        : widget.onSend,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _hasText && !widget.sending
                          ? const Color(0xFF16DB65)
                          : const Color(0xFF1A1A1A),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: widget.sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(
                            Icons.arrow_upward_rounded,
                            color: Colors.black,
                            size: 20,
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}