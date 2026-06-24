// Copyright 2026 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

class TurnBlock {
  final int queryNumber;
  final String userRequestSummary;
  int modelInvocations = 0;
  int newCharsIn = 0;
  int newCharsOut = 0;
  int cumulativeTokensAtEnd = 0;
  int cumulativeCachedTokensAtEnd = 0;

  TurnBlock(this.queryNumber, this.userRequestSummary);
}

void main(List<String> arguments) async {
  final conversationId = _parseConversationId(arguments);
  if (conversationId == null) {
    print('Error: Conversation ID not provided. Either set ANTIGRAVITY_CONVERSATION_ID environment variable or pass it as an argument.');
    exit(1);
  }

  final home = Platform.environment['HOME'] ?? '';
  final transcriptPath = '$home/.gemini/jetski/brain/$conversationId/.system_generated/logs/transcript_full.jsonl';
  
  final lines = await _readTranscriptLines(transcriptPath);
  if (lines == null) {
    exit(1);
  }

  _printGranularBreakdown(lines);
}

String formatNumber(num number) {
  final str = number.toString();
  final buffer = StringBuffer();
  int count = 0;
  for (int i = str.length - 1; i >= 0; i--) {
    if (count > 0 && count % 3 == 0 && str[i] != '-') {
      buffer.write(',');
    }
    buffer.write(str[i]);
    count++;
  }
  return buffer.toString().split('').reversed.join();
}

String? _parseConversationId(List<String> arguments) {
  if (arguments.isNotEmpty) {
    return arguments[0];
  }
  return Platform.environment['ANTIGRAVITY_CONVERSATION_ID'];
}

void _printGranularBreakdown(List<String> lines) {
  final blocks = <TurnBlock>[];
  
  int cumulativeInputChars = 0;
  int totalModelCalls = 0;
  int totalProcessedInputTokens = 0;
  int totalOutputTokens = 0;

  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    
    final step = _tryDecodeLine(line);
    if (step == null) continue;

    final stepType = step['type'] as String? ?? '';
    final source = step['source'] as String? ?? '';
    final content = step['content'] as String? ?? '';
    final thinking = step['thinking'] as String? ?? '';
    final toolCalls = step['tool_calls'] != null ? json.encode(step['tool_calls']) : '';
    final chars = content.length + thinking.length + toolCalls.length;

    if (stepType == 'USER_INPUT') {
      var summary = content
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (summary.length > 50) {
        summary = '${summary.substring(0, 47)}...';
      }
      if (summary.isEmpty) {
        summary = 'User Input (Empty)';
      }
      blocks.add(TurnBlock(blocks.length + 1, summary));
    }

    if (blocks.isEmpty) {
      blocks.add(TurnBlock(0, 'System Initialization'));
    }

    final activeBlock = blocks.last;

    if (source != 'MODEL') {
      activeBlock.newCharsIn += chars;
      cumulativeInputChars += content.length;
    } else {
      activeBlock.modelInvocations += 1;
      activeBlock.newCharsOut += chars;
      
      totalModelCalls += 1;
      final estInTokens = (cumulativeInputChars / 4).round();
      final estOutTokens = ((thinking.length + toolCalls.length) / 4).round();
      totalProcessedInputTokens += estInTokens;
      totalOutputTokens += estOutTokens;

      cumulativeInputChars += thinking.length + toolCalls.length;
      
      final systemOverhead = totalModelCalls * 10000;
      final runningTotal = totalProcessedInputTokens + totalOutputTokens + systemOverhead;
      activeBlock.cumulativeTokensAtEnd = runningTotal;
      activeBlock.cumulativeCachedTokensAtEnd = (runningTotal * 0.25).round();
    }
  }

  print('### 📊 Turn-by-Turn Granular Cost Breakdown\n');
  print('| Turn | User Request / Task | Model Calls | Est. New Input Chars | Est. New Output Chars | Cumulative Tokens (No Cache) | Cumulative (With Cache) |');
  print('|---|---|---|---|---|---|---|');

  for (final block in blocks) {
    final queryStr = block.queryNumber == 0 ? 'Init' : '#${block.queryNumber}';
    final formattedIn = formatNumber(block.newCharsIn);
    final formattedOut = formatNumber(block.newCharsOut);
    final formattedCum = formatNumber(block.cumulativeTokensAtEnd);
    final formattedCumCached = formatNumber(block.cumulativeCachedTokensAtEnd);
    print('| $queryStr | `${block.userRequestSummary}` | ${block.modelInvocations} | $formattedIn | $formattedOut | $formattedCum | $formattedCumCached |');
  }

  print('\n### 📈 Total Aggregated Calculations');
  final baseSystemPromptTokens = 10000;
  final totalSystemOverhead = baseSystemPromptTokens * totalModelCalls;
  final grandTotalTokens = totalProcessedInputTokens + totalOutputTokens + totalSystemOverhead;

  print('\n* **Total Model Invocations (Turns):** $totalModelCalls');
  print('* **Total Estimated Input Tokens:** ${formatNumber(totalProcessedInputTokens)}');
  print('* **Total Estimated Output Tokens:** ${formatNumber(totalOutputTokens)}');
  print('* **Total System & Tool Definition Overhead:** ${formatNumber(totalSystemOverhead)}');
  print('* **Grand Total (Without Caching):** **${formatNumber(grandTotalTokens)}**');
  print('* **Grand Total (With Context Caching active):** **~${formatNumber((grandTotalTokens * 0.25).round())}**');
}

Future<List<String>?> _readTranscriptLines(String path) async {
  final file = File(path);
  try {
    if (!await file.exists()) {
      print('Error: Transcript not found at $path');
      return null;
    }
    return await file.readAsLines();
  } catch (e) {
    print('Error: Failed to read transcript file at $path: $e');
    return null;
  }
}

Map<String, dynamic>? _tryDecodeLine(String line) {
  try {
    final decoded = json.decode(line);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } catch (_) {}
  return null;
}
