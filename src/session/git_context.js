// SmallCode — Auto Git Context
// When user mentions "fix tests", "fix the bug", "what changed", etc.
// automatically include recent git diff as context

const { execFileSync } = require('child_process');
const { sanitizeToolOutput } = require('../security/sanitize');

/**
 * Detect if the user's message implies they want context about recent changes.
 */
function shouldInjectGitContext(message) {
  const triggers = [
    /\b(fix|debug|broken|failing|error|bug)\b.*\b(test|spec|check)\b/i,
    /\bwhat('s| is| did).*chang/i,
    /\brecent (change|commit|edit|update)/i,
    /\bfix (the|this|my)\b/i,
    /\bwhy (is|does|did).*fail/i,
    /\brevert\b/i,
    /\blast (change|commit|edit)/i,
  ];
  return triggers.some(re => re.test(message));
}

/**
 * Get recent git diff context (staged + unstaged changes).
 * Returns formatted string for injection, or empty string.
 */
function getGitDiffContext(cwd, maxLines = 100) {
  // Use execFileSync with arg arrays — never a shell — so the cwd path
  // (which can contain spaces or unusual characters) cannot be misinterpreted.
  const opts = { cwd, encoding: 'utf-8', timeout: 5000 };
  try {
    execFileSync('git', ['rev-parse', '--git-dir'], { ...opts, timeout: 3000 });
  } catch {
    return '';
  }

  let diff = '';
  try {
    const unstaged = execFileSync('git', ['diff', '--stat', '--no-color'], opts).trim();
    if (unstaged) {
      // Cap --stat output to 40 lines (large repos can have thousands of changed files)
      const statLines = unstaged.split('\n');
      const cappedStat = statLines.length > 40
        ? statLines.slice(0, 40).join('\n') + `\n... (${statLines.length - 40} more files)`
        : unstaged;
      diff += `Unstaged changes:\n${sanitizeToolOutput(cappedStat)}\n\n`;
      const fullDiff = execFileSync('git', ['diff', '--no-color'], opts);
      const lines = fullDiff.split('\n').slice(0, maxLines);
      diff += sanitizeToolOutput(lines.join('\n'));
      if (fullDiff.split('\n').length > maxLines) {
        diff += `\n... (${fullDiff.split('\n').length - maxLines} more lines)`;
      }
    }
  } catch {}

  try {
    const staged = execFileSync('git', ['diff', '--cached', '--stat', '--no-color'], opts).trim();
    if (staged && !diff.includes(staged)) {
      diff += `\nStaged changes:\n${sanitizeToolOutput(staged)}\n`;
    }
  } catch {}

  try {
    const lastCommit = execFileSync('git', ['log', '--oneline', '-1'], { ...opts, timeout: 3000 }).trim();
    if (lastCommit) {
      diff += `\nLast commit: ${sanitizeToolOutput(lastCommit)}\n`;
    }
  } catch {}

  if (!diff.trim()) return '';
  return `\n\n--- Recent git changes ---\n${diff.trim()}\n`;
}

module.exports = { shouldInjectGitContext, getGitDiffContext };
