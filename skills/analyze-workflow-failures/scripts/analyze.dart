import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  int days = 7;
  List<String> repos = [];
  
  for (var arg in args) {
    if (arg.startsWith('--days=')) {
      days = int.tryParse(arg.substring(7)) ?? 7;
    } else {
      repos.add(arg);
    }
  }

  if (repos.isEmpty) {
    print('Usage: dart analyze.dart <repo1> [repo2...] [--days=7]');
    exit(1);
  }
  
  var date = DateTime.now().subtract(Duration(days: days)).toIso8601String().split("T")[0];
  var endDate = DateTime.now().toIso8601String().split("T")[0];
  var sb = StringBuffer();
  sb.writeln('# Workflow Failures Report ($date to $endDate)');
  sb.writeln('');

  for (var repo in repos) {
    print('Fetching workflow runs for $repo since $date...');
    var result = await Process.run('gh', [
      'run', 'list', '--repo', repo, '--created', '>=$date', 
      '--limit', '1000', '--json', 'databaseId,name,conclusion,headBranch,url,createdAt'
    ]);

    if (result.exitCode != 0) {
      print('Failed to fetch runs for $repo: ${result.stderr}');
      sb.writeln('## Repository: `$repo`');
      sb.writeln('Failed to fetch runs. Ensure `gh` CLI is authenticated and repo exists.');
      sb.writeln('');
      continue;
    }

    List<dynamic> runs = jsonDecode(result.stdout);
    
    int success = 0;
    int failure = 0;
    int actionRequired = 0;
    
    int depSuccess = 0;
    int depFailure = 0;
    int depActionRequired = 0;
    
    var failedRuns = <Map<String, dynamic>>[];

    for (var run in runs) {
      var conclusion = run['conclusion'];
      var headBranch = run['headBranch']?.toString() ?? '';
      var isDependabot = headBranch.contains('dependabot');
      
      if (isDependabot) {
        if (conclusion == 'success') {
          depSuccess++;
        } else if (conclusion == 'failure') {
          depFailure++;
          failedRuns.add(run);
        } else if (conclusion == 'action_required') {
          depActionRequired++;
        }
      } else {
        if (conclusion == 'success') {
          success++;
        } else if (conclusion == 'failure') {
          failure++;
          failedRuns.add(run);
        } else if (conclusion == 'action_required') {
          actionRequired++;
        }
      }
    }

    var totalCompleted = success + failure;
    var successRate = totalCompleted > 0 ? (success / totalCompleted * 100).toStringAsFixed(1) : '0.0';
    var failureRate = totalCompleted > 0 ? (failure / totalCompleted * 100).toStringAsFixed(1) : '0.0';

    var depTotalCompleted = depSuccess + depFailure;
    var depSuccessRate = depTotalCompleted > 0 ? (depSuccess / depTotalCompleted * 100).toStringAsFixed(1) : '0.0';
    var depFailureRate = depTotalCompleted > 0 ? (depFailure / depTotalCompleted * 100).toStringAsFixed(1) : '0.0';

    sb.writeln('## Repository: `$repo`');
    sb.writeln('### Overview (Non-Dependabot)');
    sb.writeln('- **Total Runs:** ${runs.length - (depSuccess + depFailure + depActionRequired)}');
    sb.writeln('- **Successes:** $success ($successRate%)');
    sb.writeln('- **Failures:** $failure ($failureRate%)');
    if (actionRequired > 0) sb.writeln('- **Action Required:** $actionRequired');
    sb.writeln('');
    
    if (depTotalCompleted > 0 || depActionRequired > 0) {
      sb.writeln('### Overview (Dependabot)');
      sb.writeln('- **Total Runs:** ${depSuccess + depFailure + depActionRequired}');
      sb.writeln('- **Successes:** $depSuccess ($depSuccessRate%)');
      sb.writeln('- **Failures:** $depFailure ($depFailureRate%)');
      if (depActionRequired > 0) sb.writeln('- **Action Required:** $depActionRequired');
      sb.writeln('');
    }
    
    if (failedRuns.isNotEmpty) {
      sb.writeln('### Failure Analysis');
      
      print('Analyzing ${failedRuns.length} failed runs for $repo...');
      Map<String, int> causeCounts = {};
      
      StringBuffer failureDetails = StringBuffer();
      
      for (int i = 0; i < failedRuns.length; i++) {
        var run = failedRuns[i];
        var id = run['databaseId'];
        print('  Fetching logs for $id (${i+1}/${failedRuns.length})...');
        
        var logResult = await Process.run('gh', [
          'run', 'view', id.toString(), '--repo', repo, '--log-failed'
        ]);
        
        String cause = 'Could not determine cause.';
        String simplifiedCause = 'Unknown';
        
        if (logResult.exitCode == 0) {
          var lines = logResult.stdout.toString().split('\n');
          
          var errorLines = lines.where((l) => 
            l.contains('Exception') || 
            l.contains('Error') || 
            l.contains('FAILED') || 
            l.contains('FAIL:') ||
            l.contains('Expected:') ||
            l.contains('Test failed') ||
            l.contains('Error:') ||
            l.contains('Exception:')
          ).toList();
          
          if (errorLines.isNotEmpty) {
            cause = errorLines.take(3).map((l) {
              var idx = l.indexOf('\t');
              if (idx != -1 && idx < 30) {
                return l.substring(idx + 1).trim();
              }
              return l.trim();
            }).join('\n');
            
            for (var l in cause.split('\n')) {
              var testMatch = RegExp(r'([A-Za-z0-9_]+Test).*FAILED').firstMatch(l);
              if (testMatch != null) {
                simplifiedCause = testMatch.group(1)!;
                break;
              }
              var fileMatch = RegExp(r'([A-Za-z0-9_]+\.(?:kt|dart|java))').firstMatch(l);
              if (fileMatch != null) {
                simplifiedCause = fileMatch.group(1)!;
                break;
              }
              var errorMatch = RegExp(r'(?:Exception|Error):[^\n]+').firstMatch(l);
              if (errorMatch != null) {
                simplifiedCause = errorMatch.group(0)!.substring(0, errorMatch.group(0)!.length > 80 ? 80 : errorMatch.group(0)!.length);
                break;
              }
            }
          }
        }
        
        causeCounts[simplifiedCause] = (causeCounts[simplifiedCause] ?? 0) + 1;
        
        failureDetails.writeln('#### [${run["name"]} - ${run["headBranch"]}](${run["url"]})');
        failureDetails.writeln('- **Date:** ${run["createdAt"]}');
        failureDetails.writeln('- **Run ID:** `${run["databaseId"]}` (Click header for logs)');
        failureDetails.writeln('- **Cause:**');
        failureDetails.writeln('  ```text');
        for (var line in cause.split('\n')) {
          failureDetails.writeln('  $line');
        }
        failureDetails.writeln('  ```');
        failureDetails.writeln('');
      }
      
      var sortedCauses = causeCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      var significantCauses = sortedCauses.where((e) => e.value > 1).toList();
      
      if (significantCauses.isNotEmpty) {
        sb.writeln('#### Top Repeated Causes');
        for (var e in significantCauses) {
          sb.writeln('- **${e.key}**: ${e.value} occurrences');
        }
        sb.writeln('');
      }
      
      sb.write(failureDetails.toString());
    }
  }

  print('\n\n--- REPORT START ---\n\n');
  print(sb.toString());
}
