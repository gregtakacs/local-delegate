// chunk-cap.js — verbatim port of Cline's editor size gate + Cline's own schema wording.
//
// FIDELITY RULE: this file quotes Cline; it does not paraphrase or improve on it. No invented
// numbers live here. Every constant and user-facing string comes from stock Cline source:
//   constant:  schemas.ts:10  export const INPUT_ARG_CHAR_LIMIT = 6000 (same name, same value)
//   validator: helpers.ts:20-33 getEditorSizeError, called EXACTLY ONCE, definitions.ts:717
//   wording:   schemas.ts:205/210 (editor field guidance) and :130 (bash guidance)
// Anything an earlier revision of this file said that Cline does not say has been removed.
//
// WHAT CLINE ACTUALLY ENFORCES (source, not vibes):
//   - Size gate lives only on the editor tool (which also CREATES files, so creation is capped).
//     apply_patch exists in Cline and is NOT size-gated. Uncapping it here is parity, not an
//     oversight — see DODGE below.
//   - Editor timeoutMs defaults to 30000 with retryable:false (definitions.ts:700-712). NOT
//     PORTABLE: opencode exposes no per-tool timeout hook. Disclosed gap; on local files the
//     timeout path is near-unreachable, and its real behavioral role is the "to avoid timeouts"
//     schema wording, which IS ported below via tool.definition.
//
// DODGE DISCLOSED: apply_patch can write files here, so a model could exceed 6000 chars in one
// patch. Cline's model had the identical hole and never used it. Reproducing Cline includes
// reproducing the hole; a run that exploits it is measured behavior, not a bug to patch.
//
// REJECTION MECHANISM (verified against installed 1.17.10 source): Plugin.trigger runs hooks via
// bare `yield* Effect.promise(fn)` with no catch, and tool.execute.before fires before the real
// tool — a throw fails the call and the message reaches the model as the tool result. Same
// position, same shape as Cline's validator.
//
// tool.definition (packages/plugin/src/index.ts): "Modify tool definitions (description and
// parameters) sent to LLM". Cline's model sees the size guidance BEFORE the call, in the tool
// schema; opencode's own descriptions say nothing. We APPEND (never replace — opencode's own
// descriptions document opencode's args and must stay true) Cline's constraint sentences verbatim,
// minus clauses describing Cline-tool mechanics opencode lacks (insert_line), since those would be
// false here.

const INPUT_ARG_CHAR_LIMIT = 6000; // Cline schemas.ts:10, same name, same value

// Cline helpers.ts:25/29, verbatim. Only ${field} is a translation: opencode names payloads
// oldString/newString/content where Cline has old_text/new_text; the model must map its own args.
// Cline checks old_text before new_text (helpers.ts order); that order is preserved below.
const sizeError = (field, value) =>
  `Editor input too large: ${field} was ${value.length} characters, exceeding the recommended limit of ${INPUT_ARG_CHAR_LIMIT}. ` +
  `Split the edit into smaller tool calls so later tool calls are less likely to be truncated or time out.`;

// Cline schemas.ts:205/210/130 — the constraint sentences, verbatim, interpolated with the same
// constant Cline interpolates into them (bash carries the 2x, exactly as schemas.ts:130).
const CLINE_OLD_TEXT_GUIDE =
  `Keep this at or below ${INPUT_ARG_CHAR_LIMIT} characters when possible; larger payloads ` +
  `should be split across multiple tool calls to avoid timeouts.`;
const CLINE_NEW_TEXT_GUIDE =
  `Keep this at or below ${INPUT_ARG_CHAR_LIMIT} characters when possible; for large edits, use ` +
  `multiple calls with small chunks to iteratively edit the file.`;
const CLINE_BASH_GUIDE =
  `MUST keep input short and concise (within ${INPUT_ARG_CHAR_LIMIT * 2} characters) to avoid timeouts.`;

export const ChunkCap = async () => ({
  "tool.execute.before": async (input, output) => {
    // apply_patch deliberately absent: Cline's apply_patch is not size-gated. See DODGE above.
    if (input.tool !== "write" && input.tool !== "edit") return;

    // args live in input.args in production (the shape verify-loop.js runs against); the docs
    // show before-hooks seeing output.args. Read both, prefer whichever is populated.
    const args = (input && input.args) || (output && output.args) || {};
    const payloads =
      input.tool === "write"
        ? [["content", args.content]] // Cline: editor create path, capped via new_text
        : [["oldString", args.oldString], ["newString", args.newString]];

    for (const [field, value] of payloads) {
      if (typeof value === "string" && value.length > INPUT_ARG_CHAR_LIMIT) {
        throw new Error(sizeError(field, value));
      }
    }
  },

  // Cline's pre-call steer, made letter-portable: append Cline's schema guidance to the exact
  // descriptions the model reads, so our model gets the same pre-call steer Cline's got.
  "tool.definition": async (input, output) => {
    if (input.toolID === "edit") {
      output.description += "\n" + CLINE_OLD_TEXT_GUIDE + "\n" + CLINE_NEW_TEXT_GUIDE;
    } else if (input.toolID === "write") {
      output.description += "\n" + CLINE_NEW_TEXT_GUIDE;
    } else if (input.toolID === "bash") {
      output.description += "\n" + CLINE_BASH_GUIDE;
    }
  },
});
