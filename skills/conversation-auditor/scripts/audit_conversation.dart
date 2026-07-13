import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  if (args.length < 2) {
    print('Usage: dart run audit_conversation.dart <conversation_id> <app_data_dir>');
    exit(1);
  }

  var conversationId = args[0];
  var appDataDir = args[1];
  
  var transcriptPath = '$appDataDir/brain/$conversationId/.system_generated/logs/transcript.jsonl';
  var file = File(transcriptPath);

  if (!file.existsSync()) {
    print('Error: Transcript not found at $transcriptPath');
    return;
  }

  var toolCounts = <String, int>{};
  var runCommands = <String>[];
  var largeSteps = <Map<String, dynamic>>[];
  var toolSequences = <Map<String, dynamic>>[];

  String? lastTool;
  int sequenceCount = 0;

  var linesStream = file.openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  await for (var line in linesStream) {
    if (line.trim().isEmpty) continue;
    
    Map<String, dynamic> step;
    try {
      step = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      continue;
    }

    var stepIndex = step['step_index'] ?? 0;
    var content = step['content']?.toString() ?? '';
    var contentLength = content.length;

    // Check for large context usage
    if (contentLength > 10000) {
      largeSteps.add({
        'step': stepIndex,
        'type': step['type'],
        'source': step['source'],
        'length': contentLength,
      });
    }

    // Analyze tool calls
    var toolCalls = step['tool_calls'];
    if (toolCalls is List && toolCalls.isNotEmpty) {
      for (var tc in toolCalls) {
        if (tc is! Map) continue;
        
        dynamic toolNameRaw = tc['name'];
        if (toolNameRaw == null && tc['function'] is Map) {
          toolNameRaw = tc['function']['name'];
        }
        
        String toolName;
        if (toolNameRaw is Map && toolNameRaw.containsKey('name')) {
          toolName = toolNameRaw['name'].toString();
        } else {
          toolName = toolNameRaw?.toString() ?? tc.toString();
        }

        toolCounts[toolName] = (toolCounts[toolName] ?? 0) + 1;

        // Track run_commands
        if (toolName == 'run_command') {
          dynamic argsData = tc['args'] ?? tc['arguments'];
          if (argsData == null && tc['function'] is Map) {
            argsData = tc['function']['arguments'];
          }

          if (argsData is String) {
            try {
              argsData = jsonDecode(argsData);
            } catch (e) {
              argsData = <String, dynamic>{};
            }
          }

          if (argsData is Map) {
            dynamic cmd = argsData['CommandLine'] ?? argsData['command_line'] ?? argsData['command'];
            if (cmd != null) {
              if (cmd is String && cmd.startsWith('"') && cmd.endsWith('"')) {
                try {
                  cmd = jsonDecode(cmd);
                } catch (_) {}
              }
              runCommands.add(cmd.toString());
            } else {
              String argsStr = argsData.toString();
              runCommands.add(argsStr.length > 100 ? argsStr.substring(0, 100) : argsStr);
            }
          }
        }

        // Track sequences
        if (toolName == lastTool) {
          sequenceCount++;
        } else {
          if (sequenceCount > 2 && lastTool != null) {
            toolSequences.add({
              'tool': lastTool,
              'count': sequenceCount,
              'ending_step': stepIndex,
            });
          }
          lastTool = toolName;
          sequenceCount = 1;
        }
      }
    }
  }

  // Check last sequence
  if (sequenceCount > 2 && lastTool != null) {
    toolSequences.add({
      'tool': lastTool,
      'count': sequenceCount,
      'ending_step': 'end',
    });
  }

  print('--- Audit Report for Conversation $conversationId ---');
  
  print('\n1. Tool Usage Frequencies:');
  var sortedTools = toolCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (var entry in sortedTools) {
    print('  - ${entry.key}: ${entry.value}');
  }

  print('\n2. Repeated Tool Sequences (Potential for bulk operations or new MCP):');
  for (var seq in toolSequences) {
    print('  - ${seq['tool']} called ${seq['count']} times in a row (ending around step ${seq['ending_step']})');
  }

  print('\n3. Shell Commands Executed (Potential for scripting):');
  var cmdCounts = <String, int>{};
  for (var cmd in runCommands) {
    cmdCounts[cmd] = (cmdCounts[cmd] ?? 0) + 1;
  }
  var sortedCmds = cmdCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (var entry in sortedCmds.take(10)) {
    print('  - [${entry.value}x] ${entry.key}');
  }

  print('\n4. Largest Context Hogs (Content > 10,000 chars):');
  largeSteps.sort((a, b) => (b['length'] as int).compareTo(a['length'] as int));
  for (var ls in largeSteps.take(5)) {
    print('  - Step ${ls['step']} (${ls['type']} from ${ls['source']}): ${ls['length']} characters');
  }
}
