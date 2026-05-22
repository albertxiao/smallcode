// SmallCode — Session Sharing
// Export a session as a shareable markdown file or gist URL

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const { redactValue, redactString } = require('../security/sanitize');

/**
 * Export a session to a markdown file.
 * Output is redacted to strip secrets that may appear in messages.
 */
function exportToMarkdown(session, outputPath) {
  const safe = redactValue(session);
  let md = `# SmallCode Session: ${safe.title || 'Untitled'}\n\n`;
  md += `**Model:** ${safe.model}\n`;
  md += `**Date:** ${safe.createdAt}\n`;
  md += `**Messages:** ${(safe.messages || []).length}\n\n`;
  md += `---\n\n`;

  for (const msg of (safe.messages || [])) {
    const content = typeof msg.content === 'string' ? msg.content : JSON.stringify(msg.content);
    if (msg.role === 'user') {
      md += `## You\n\n${content}\n\n`;
    } else if (msg.role === 'assistant') {
      md += `## AI\n\n${content}\n\n`;
    } else if (msg.role === 'tool') {
      md += `> Tool: ${(content || '').slice(0, 200)}\n\n`;
    }
  }

  fs.writeFileSync(outputPath, md, { mode: 0o600 });
  return outputPath;
}

/**
 * Export session as a GitHub Gist (requires gh CLI).
 *
 * IMPORTANT: We use execFileSync with an args array — the prior version
 * built a shell command string with the session title interpolated, which
 * was exploitable via a crafted title (e.g. one starting with `"; rm -rf`).
 */
function exportToGist(session) {
  // Use the OS temp dir (not cwd) so we don't leave a session file behind
  // in the project on crash, and so we don't write a copy with relaxed
  // permissions to a directory the user may have shared.
  const safeId = String(session.id || '').replace(/[^A-Za-z0-9_-]/g, '');
  const tmpFile = path.join(os.tmpdir(), `smallcode-session-${safeId}-${Date.now()}.md`);
  exportToMarkdown(session, tmpFile);

  const desc = `SmallCode session: ${(session.title || 'untitled').slice(0, 80)}`;

  try {
    const output = execFileSync(
      'gh',
      ['gist', 'create', tmpFile, '--desc', desc, '--public'],
      { encoding: 'utf-8', timeout: 15000 },
    );
    try { fs.unlinkSync(tmpFile); } catch {}
    const url = output.trim().split('\n').pop();
    return { url, success: true };
  } catch (e) {
    try { fs.unlinkSync(tmpFile); } catch {}
    return { error: redactString(e.message || String(e)), success: false };
  }
}

module.exports = { exportToMarkdown, exportToGist };
