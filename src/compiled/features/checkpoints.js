// @ts-nocheck
'use strict';
// Generated from marrow/features_1_6.marrow — edit_with_approval flow checkpoint
// In-memory implementation for CLI use (no DB)

const { counter } = require('../metrics');
const { logger } = require('../logger');

// Pending decisions: flowRunId|checkpointName → { resolve, timer }
const __pending = new Map();

function pendingKey(flowRunId, checkpointName) {
  return flowRunId + '|' + checkpointName;
}

// Approval callback — set by the TUI to handle y/n prompts
let _approvalHandler = null;

function setApprovalHandler(fn) {
  _approvalHandler = fn;
}

async function awaitDecision(flowRunId, checkpointName, timeoutMs, onTimeout) {
  return new Promise((resolve) => {
    let timer = null;
    if (timeoutMs && timeoutMs > 0) {
      timer = setTimeout(() => {
        const entry = __pending.get(pendingKey(flowRunId, checkpointName));
        if (!entry) return;
        __pending.delete(pendingKey(flowRunId, checkpointName));
        resolve({
          decision: onTimeout === 'cancel' ? 'cancel' : 'reject',
          timed_out: true,
          actor_id: 'system:timeout',
          edited_payload: null,
        });
      }, timeoutMs);
    }
    __pending.set(pendingKey(flowRunId, checkpointName), { resolve, timer });
    // If an approval handler is registered, invoke it immediately
    if (_approvalHandler) {
      _approvalHandler(flowRunId, checkpointName)
        .then((decision) => {
          submitDecision(flowRunId, checkpointName, decision, null, 'user');
        })
        .catch(() => {
          submitDecision(flowRunId, checkpointName, 'reject', null, 'system:error');
        });
    }
  });
}

function submitDecision(flowRunId, checkpointName, decision, editedPayload, actorId) {
  const key = pendingKey(flowRunId, checkpointName);
  const entry = __pending.get(key);
  if (!entry) return { ok: false, reason: 'no pending checkpoint' };
  if (entry.timer) clearTimeout(entry.timer);
  __pending.delete(key);
  counter('flow.checkpoint_decided', { checkpoint: checkpointName, decision });
  entry.resolve({
    decision,
    edited_payload: editedPayload,
    actor_id: actorId,
    timed_out: false,
  });
  return { ok: true };
}

function buildShowsPayload(ctx, paths) {
  const out = {};
  for (const path of paths) {
    const segs = path.split('.');
    let cur = ctx;
    for (const s of segs) {
      if (cur && typeof cur === 'object' && s in cur) cur = cur[s];
      else { cur = undefined; break; }
    }
    out[path] = cur;
  }
  return out;
}

module.exports = { awaitDecision, submitDecision, buildShowsPayload, setApprovalHandler };
