import os from 'node:os';
import { pathToFileURL } from 'node:url';
import { writeFile, rename, unlink } from 'node:fs/promises';

// Confirmed against the installed ClaudeHUD parser and its actual heartbeat.stdin:
// rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}; reset is Unix seconds.
// Read only status-line stdin. No credentials, network requests or transcript reads.
const text = (value, fallback) => typeof value === 'string' && value.trim()
  ? value.replace(/[\x00-\x1f\x7f-\x9f|]/g, ' ').trim()
  : fallback;
const percent = (value) => typeof value === 'number' && Number.isFinite(value)
  && value >= 0 && value <= 100 ? value : null;

export function captureStatus(data = {}) {
  const effort = data.effort?.level ?? data.effort ?? data.model?.effort ?? data.reasoning_effort;
  const bucket = value => ({
    used_percentage: percent(value?.used_percentage),
    resets_at: typeof value?.resets_at === 'number' && Number.isFinite(value.resets_at)
      && value.resets_at > 0 ? value.resets_at : null,
  });
  return {
    captured_at: new Date().toISOString(),
    model: { display_name: text(data.model?.display_name, text(data.model?.id, '?')).slice(0, 120) },
    effort: typeof effort === 'string' ? text(effort, '').slice(0, 30) : '',
    rate_limits: {
      five_hour: bucket(data.rate_limits?.five_hour),
      seven_day: bucket(data.rate_limits?.seven_day),
    },
  };
}

async function saveCapture(data) {
  const destination = process.env.CLAUDE_STATUS_CAPTURE
    || new URL('./logs/claude-usage.json', import.meta.url);
  const target = destination instanceof URL ? destination.pathname : destination;
  // A sibling temporary file keeps concurrent board reads on complete JSON.
  const temporary = destination instanceof URL
    ? new URL(`${destination.href}.${process.pid}.tmp`)
    : `${target}.${process.pid}.tmp`;
  try {
    await writeFile(temporary, JSON.stringify(captureStatus(data), null, 2));
    await rename(temporary, destination);
  } catch {
    // A capture failure must never hide the terminal status line.
  } finally {
    await unlink(temporary).catch(() => {});
  }
}

function resetTime(seconds) {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds <= 0) return '?';
  const date = new Date(seconds * 1000);
  if (Number.isNaN(date.getTime())) return '?';
  const minutes = Math.max(0, Math.ceil((date.getTime() - Date.now()) / 60000));
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

export function renderStatus(data = {}, host = os.hostname(), cwd = process.cwd()) {
  const workspace = text(data.workspace?.current_dir, text(data.cwd, cwd));
  const model = text(data.model?.display_name, text(data.model?.id, '?'));
  const context = percent(data.context_window?.used_percentage);
  const fiveHour = percent(data.rate_limits?.five_hour?.used_percentage);
  const weekly = percent(data.rate_limits?.seven_day?.used_percentage);
  const fields = [
    `${text(host, '?')}:${workspace}`,
    model,
    `ctx ${context === null ? '?' : `${Math.round(context)}% used`}`,
    `5h ${fiveHour === null ? '?' : `${Math.round(100 - fiveHour)}% left`} reset ${resetTime(data.rate_limits?.five_hour?.resets_at)}`,
    `주간 ${weekly === null ? '?' : `${Math.round(100 - weekly)}% left`}`,
  ];
  return fields.slice(0, 3).join(' | ') + '\n' + fields.slice(3).join(' | ');
}

// Unified display (2026-11-21 user): "모델 강도 | 5h N% 남음 (… 후 초기화) | 주간 N% 남음" / "ctx N% 사용 | 폴더".
function displayStatus(data = {}, cwd = process.cwd()) {
  const pct = (v) => (typeof v === 'number' && Number.isFinite(v) ? Math.round(v) : null);
  const model = text(data.model?.display_name, text(data.model?.id, '?'));
  const effortRaw = data.effort?.level ?? data.effort ?? data.model?.effort ?? data.reasoning_effort;
  const effort = typeof effortRaw === 'string' ? ` ${effortRaw}` : '';
  const five = pct(data.rate_limits?.five_hour?.used_percentage);
  const week = pct(data.rate_limits?.seven_day?.used_percentage);
  const ctx = pct(data.context_window?.used_percentage);
  const folder = text(data.workspace?.current_dir, text(data.cwd, cwd));
  return [
    `${model}${effort} | 5h ${five === null ? '?' : `${100 - five}% 남음`} (${resetTime(data.rate_limits?.five_hour?.resets_at)} 후 초기화) | 주간 ${week === null ? '?' : `${100 - week}% 남음`}`,
    `ctx ${ctx === null ? '?' : `${ctx}% 사용`} | ${folder}`,
  ].join('\n');
}
function colorize(s) {
  const E = '\x1b[', R = E + '0m';
  return s.split('\n').map((line, i) => line
    .replace(/^([^|]+?)(\s\|)/, i === 0 ? `${E}36m$1${R}$2` : '$1$2')
    .replace(/(\d+)% 남음/g, (m, n) => `${E}${Number(n) >= 50 ? '32' : Number(n) >= 20 ? '33' : '31'}m${m}${R}`)
    .replace(/(ctx \d+% 사용)/, `${E}33m$1${R}`)
    .replace(/\| ([^|]+)$/, (m, p) => (i === 1 ? `| ${E}1;34m${p}${R}` : m))
    .replace(/\s\|\s/g, (m) => `${E}90m${m}${R}`)).join('\n');
}if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let body = '';
  for await (const chunk of process.stdin) body += chunk;
  let data;
  try {
    const parsed = JSON.parse(body);
    data = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    data = {};
  }
  await saveCapture(data);
  process.stdout.write(`${colorize(displayStatus(data))}\n`);
}
