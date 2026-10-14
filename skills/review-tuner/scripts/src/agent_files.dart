/// The agent instruction files review-tuner looks for (propose mode) and
/// strips from `evaluate` checkouts, so simulated reviewers see only the
/// arm's guidance. Documented once in `references/formats.md`.
library;

/// File or directory names that mark agent files anywhere in a repository.
const agentNames = {
  'AGENTS.md',
  'CLAUDE.md',
  'GEMINI.md',
  'SKILL.md',
  '.gemini',
  '.agents',
  '.claude',
  '.cursor',
  '.aiconfig',
  '.aiexclude',
};

/// Repo-relative agent file paths that only count at that exact location.
const agentPaths = {'.github/copilot-instructions.md'};

/// The agent file or directory containing repo-relative [path] (its
/// shortest such prefix), or null if [path] is not an agent file.
String? agentRoot(String path) {
  if (agentPaths.contains(path)) return path;
  var segments = path.split('/');
  for (var i = 0; i < segments.length; i++) {
    if (agentNames.contains(segments[i])) {
      return segments.sublist(0, i + 1).join('/');
    }
  }
  return null;
}
