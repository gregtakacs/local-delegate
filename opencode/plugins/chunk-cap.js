// chunk-cap.js — verbatim port of Cline's editor size gate + Cline's own schema wording.
//
// FIDELITY RULE: this file quotes Cline; it does not paraphrase or improve on it. Every user-facing
// string comes from stock Cline source; the one number that departs from it, delegate's default
// cap, is named and explained below:
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
// DODGE DISCLOSED: apply_patch can write files here, so a model could exceed the cap in one
// patch. Cline's model had the identical hole and never used it. Reproducing Cline includes
// reproducing the hole; a run that exploits it is measured behavior, not a bug to patch.
//
// REJECTION MECHANISM (OpenCode 2, @opencode/plugin 2.3.0): `context.tool.transform` wraps the
// write and edit tools' `execute`, so the size check runs before the real tool; a throw fails the
// call and the message reaches the model as the tool result. Same position, same shape as Cline's
// validator. (OpenCode 1 did this from a `tool.execute.before` hook; 2.x has no such rejection
// point, so the wrap is the faithful equivalent.)
//
// The same transform edits the tool descriptions. Cline's model sees the size guidance BEFORE the
// call, in the tool schema; opencode's own descriptions say nothing. We APPEND (never replace —
// opencode's own descriptions document opencode's args and must stay true) Cline's constraint
// sentences verbatim, minus clauses describing Cline-tool mechanics opencode lacks (insert_line),
// since those would be false here. OpenCode 2 names the shell tool `shell` (1.x: `bash`).

// Cline schemas.ts:10 is INPUT_ARG_CHAR_LIMIT = 6000. delegate departs from it deliberately, twice:
// the default is 8000, and DELEGATE_CHUNK_CAP lets an operator raise or lower the cap for their own
// model. Measured on one install (2026-11-12): 9 of 14 rejections at 6000 were under 8000 chars and
// each cost a full turn, while the payloads the cap exists to stop (one-shot whole files) ran
// 10k–18k. Anything that isn't an integer >= 1000 falls back to the default.
const CLINE_INPUT_ARG_CHAR_LIMIT = 6000; // reference only: Cline's own value
const DELEGATE_DEFAULT_CHAR_LIMIT = 8000;
const configured = Number.parseInt(process.env.DELEGATE_CHUNK_CAP ?? "", 10);
const INPUT_ARG_CHAR_LIMIT =
  Number.isInteger(configured) && configured >= 1000 ? configured : DELEGATE_DEFAULT_CHAR_LIMIT;

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

// The payload fields each capped tool carries in OpenCode 2 (write: path/content; edit:
// path/oldString/newString). Cline checks old_text before new_text; that order is preserved.
const PAYLOADS = {
  write: ["content"], // Cline: editor create path, capped via new_text
  edit: ["oldString", "newString"],
};
const GUIDES = {
  edit: "\n" + CLINE_OLD_TEXT_GUIDE + "\n" + CLINE_NEW_TEXT_GUIDE,
  write: "\n" + CLINE_NEW_TEXT_GUIDE,
  shell: "\n" + CLINE_BASH_GUIDE,
};

export default {
  id: "delegate-chunk-cap",
  async setup(context) {
    await context.tool.transform((editor) => {
      for (const id of Object.keys(GUIDES)) {
        editor.update(id, (tool) => {
          tool.description = (tool.description || "") + GUIDES[id];
          const fields = PAYLOADS[id];
          if (!fields) return;
          const execute = tool.execute;
          tool.execute = async (input, ctx) => {
            const args = input || {};
            for (const field of fields) {
              const value = args[field];
              if (typeof value === "string" && value.length > INPUT_ARG_CHAR_LIMIT) {
                throw new Error(sizeError(field, value));
              }
            }
            return execute(input, ctx);
          };
        });
      }
    });
  },
};
