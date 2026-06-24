// Copyright 2026 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';
import 'dart:convert';

void main(List<String> arguments) async {
  var conversationId = _parseConversationId(arguments);
  if (conversationId == null) {
    print('Error: Conversation ID not provided. Either set ANTIGRAVITY_CONVERSATION_ID environment variable or pass it as an argument.');
    exit(1);
  }

  var home = Platform.environment['HOME'] ?? '';
  var transcriptPath = '$home/.gemini/jetski/brain/$conversationId/.system_generated/logs/transcript_full.jsonl';
  
  var lines = await _readTranscriptLines(transcriptPath);
  if (lines == null) {
    exit(1);
  }

  _printStepBreakdown(lines);
  _printCumulativeCalculations(lines);
}

String? _parseConversationId(List<String> arguments) {
  if (arguments.isNotEmpty) {
    return arguments[0];
  }
  return Platform.environment['ANTIGRAVITY_CONVERSATION_ID'];
}

Future<List<String>?> _readTranscriptLines(String path) async {
  var file = File(path);
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

void _printStepBreakdown(List<String> lines) {
  print('### Turn-by-Turn Content Breakdown\n');
  print('| Step | Source | Type | Content Size (Chars) | Role | Est. Tokens (4 chars/token) |');
  print('|---|---|---|---|---|---|');

  for (var line in lines) {
    if (line.trim().isEmpty) continue;
    
    var decoded = _tryDecodeLine(line);
    if (decoded == null) continue;
    
    var stepIndex = decoded['step_index'] as int? ?? 0;
    var source = decoded['source'] as String? ?? '';
    var stepType = decoded['type'] as String? ?? '';
    
    var content = decoded['content'] as String? ?? '';
    var thinking = decoded['thinking'] as String? ?? '';
    var toolCalls = decoded['tool_calls'] != null ? json.encode(decoded['tool_calls']) : '';
    
    var chars = content.length + thinking.length + toolCalls.length;
    var role = source == 'MODEL' ? 'Output (from Agent)' : 'Input (to Agent)';

    var estTokens = (chars / 4).round();
    var formattedChars = formatNumber(chars);
    var formattedTokens = formatNumber(estTokens);
    print('| $stepIndex | $source | $stepType | $formattedChars | $role | $formattedTokens |');
  }
}

void _printCumulativeCalculations(List<String> lines) {
  print('\n### Cumulative Token Calculations');
  print('\nBecause the agent runs in a loop, each time the agent invokes the model (PLANNER_RESPONSE), it sends the *entire accumulated history* up to that point.');

  int cumulativeInputChars = 0;
  int modelCalls = 0;
  int totalProcessedInputTokens = 0;
  int totalOutputTokens = 0;

  for (var line in lines) {
    if (line.trim().isEmpty) continue;
    
    var decoded = _tryDecodeLine(line);
    if (decoded == null) continue;

    var source = decoded['source'] as String? ?? '';
    var content = decoded['content'] as String? ?? '';
    var thinking = decoded['thinking'] as String? ?? '';
    var toolCalls = decoded['tool_calls'] != null ? json.encode(decoded['tool_calls']) : '';

    if (source != 'MODEL') {
      cumulativeInputChars += content.length;
    } else {
      modelCalls += 1;
      var estInTokens = (cumulativeInputChars / 4).round();
      var estOutTokens = ((thinking.length + toolCalls.length) / 4).round();
      totalProcessedInputTokens += estInTokens;
      totalOutputTokens += estOutTokens;
      cumulativeInputChars += thinking.length + toolCalls.length;
    }
  }

  var baseSystemPromptTokens = 10000;
  var totalSystemOverhead = baseSystemPromptTokens * modelCalls;
  var grandTotalTokens = totalProcessedInputTokens + totalOutputTokens + totalSystemOverhead;

  print('\n* **Number of Model Invocations (Turns):** $modelCalls');
  print('* **Estimated Cumulative Input Tokens (Transcript):** ${formatNumber(totalProcessedInputTokens)}');
  print('* **Estimated Output Tokens (Reasoning & Tool Calls):** ${formatNumber(totalOutputTokens)}');
  print('* **Estimated System & Tool Definition Overhead (${formatNumber(baseSystemPromptTokens)}/turn):** ${formatNumber(totalSystemOverhead)}');
  print('* **Grand Total Estimated Tokens (without Caching):** **${formatNumber(grandTotalTokens)}**');
  print('* **Grand Total Estimated Tokens (with Context Caching active):** **~${formatNumber((grandTotalTokens * 0.25).round())}**');
}

Map<String, dynamic>? _tryDecodeLine(String line) {
  try {
    var decoded = json.decode(line);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } catch (_) {
    // Ignore decode issues
  }
  return null;
}

String formatNumber(num number) {
  var str = number.toString();
  var buffer = StringBuffer();
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
