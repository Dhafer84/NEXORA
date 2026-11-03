import 'package:flutter/material.dart';

import '../chat/chat_panel.dart';
import 'approval_detail_screen.dart';

/// A conversation opened from another screen (an approval's origin).
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Discussion')),
    body: SafeArea(
      top: false,
      child: ChatPanel(
        conversationId: conversationId,
        onOpenApproval: (id) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ApprovalDetailScreen(approvalId: id),
          ),
        ),
      ),
    ),
  );
}
