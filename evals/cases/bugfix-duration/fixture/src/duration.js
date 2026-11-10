// Formats a duration in milliseconds for humans: "1 hour, 2 minutes", "45 seconds".
// Used by the status page and the CLI; both rely on the exact output format below.

const UNITS = [
  ["day", 86400000],
  ["hour", 3600000],
  ["minute", 60000],
  ["second", 1000],
];

export function formatDuration(ms, { largest = 2 } = {}) {
  if (ms == 0) return "0 seconds";
  const parts = [];
  let rest = ms;
  for (const [name, size] of UNITS) {
    const n = Math.round(rest / size);
    if (n > 0) {
      parts.push(`${n} ${name}s`);
      rest -= n * size;
    }
    if (parts.length > largest) break;
  }
  return parts.join(", ");
}

export function parseDuration(text) {
  const m = /^(\d+)(ms|s|m|h|d)$/.exec(text);
  if (!m) return null;
  const n = parseInt(m[1]);
  return n * { ms: 1, s: 1000, m: 60000, h: 3600000, d: 86400000 }[m[2]];
}
