(() => {
'use strict';

const DEFAULTS = {
  mode: 'framed',
  transport: 'unix',
  read_size: 65536,
  read_budget_bytes: 0,
  message_batch_size: 0,
  read_batch_bytes: 0,
  max_buffer: 8388608,
};

const VALUES = {
  read_size: [1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576],
  read_budget_bytes: [0, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216],
  message_batch_size: [0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024],
  read_batch_bytes: [0, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576],
  max_buffer: [65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864],
};

const MESSAGE_SIZES = [16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536, 98304, 131072, 163840, 200000];

let state = { ...DEFAULTS };
let benchmark = null;
let rendered = null;

const el = id => document.getElementById(id);
const canvas = el('chart');
const ctx = canvas.getContext('2d');
const tooltip = el('tooltip');

function uniqSorted(values) {
  return [...new Set(values.filter(v => Number.isFinite(v)).map(Number))].sort((a, b) => a - b);
}

function addDatasetValues(report) {
  const configs = (report.series || []).map(s => s.config || {});
  for (const key of ['read_size', 'read_budget_bytes', 'message_batch_size', 'read_batch_bytes', 'max_buffer']) {
    const incoming = configs.map(c => Number(c[key])).filter(Number.isFinite);
    VALUES[key] = uniqSorted([...VALUES[key], ...incoming]);
  }
}

function formatBytes(n) {
  n = Number(n);
  if (n === 0) return '0';
  if (n >= 1048576 && n % 1048576 === 0) return `${n / 1048576} MiB`;
  if (n >= 1024 && n % 1024 === 0) return `${n / 1024} KiB`;
  if (n >= 1000) return `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)} KB`;
  return `${n} B`;
}

function formatRate(n) {
  if (!Number.isFinite(n)) return '-';
  if (n >= 1e6) return `${(n / 1e6).toFixed(n >= 1e7 ? 1 : 2)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(n >= 1e5 ? 0 : 1)}k`;
  return n.toFixed(0);
}

function nearestIndex(values, value) {
  let best = 0;
  let distance = Infinity;
  for (let i = 0; i < values.length; i++) {
    const d = Math.abs(Math.log2((values[i] || 1) / (value || 1)));
    if (d < distance) { best = i; distance = d; }
  }
  return best;
}

function setupSlider(id, key, formatter) {
  const input = el(id);
  const out = el(`${id}-out`);
  const values = VALUES[key];
  input.max = String(values.length - 1);
  input.value = String(nearestIndex(values, state[key]));
  const apply = () => {
    state[key] = values[Number(input.value)];
    out.value = formatter(state[key]);
    out.textContent = out.value;
    update();
  };
  input.oninput = apply;
  out.value = formatter(state[key]);
  out.textContent = out.value;
}

function setupBatchSlider() {
  const key = state.mode === 'framed' ? 'message_batch_size' : 'read_batch_bytes';
  const values = VALUES[key];
  const input = el('batch');
  input.max = String(values.length - 1);
  input.value = String(nearestIndex(values, state[key]));
  const value = values[Number(input.value)];
  state[key] = value;
  el('batch-out').value = key === 'message_batch_size' ? String(value) : formatBytes(value);
  el('batch-out').textContent = el('batch-out').value;
  el('batch-label').textContent = key;
  el('batch-help').textContent = state.mode === 'framed' ? '0 = on_message' : '0 = direct on_data';
  input.oninput = () => {
    const v = values[Number(input.value)];
    state[key] = v;
    el('batch-out').value = key === 'message_batch_size' ? String(v) : formatBytes(v);
    el('batch-out').textContent = el('batch-out').value;
    update();
  };
}

function resetControls() {
  state = { ...DEFAULTS };
  el('mode').value = state.mode;
  el('transport').value = state.transport;
  setupSlider('read-size', 'read_size', formatBytes);
  setupSlider('read-budget', 'read_budget_bytes', v => v === 0 ? 'unlimited' : formatBytes(v));
  setupBatchSlider();
  setupSlider('max-buffer', 'max_buffer', formatBytes);
  update();
}

function configFor(s = state) {
  return {
    mode: s.mode,
    transport: s.transport,
    read_size: Number(s.read_size),
    read_budget_bytes: Number(s.read_budget_bytes),
    message_batch_size: s.mode === 'framed' ? Number(s.message_batch_size) : 0,
    read_batch_bytes: s.mode === 'raw' ? Number(s.read_batch_bytes) : 0,
    max_buffer: Number(s.max_buffer),
  };
}

function configKey(c) {
  return [c.mode, c.transport, c.read_size, c.read_budget_bytes, c.message_batch_size || 0, c.read_batch_bytes || 0, c.max_buffer].join('|');
}

function pointMap(series) {
  const m = new Map();
  for (const p of series.points || []) {
    const x = Number(p.message_size);
    const y = Number(p.median_messages_per_second ?? p.messages_per_second);
    if (Number.isFinite(x) && Number.isFinite(y) && y > 0) m.set(x, y);
  }
  return m;
}

function interpLogX(map, x) {
  if (map.has(x)) return map.get(x);
  const xs = [...map.keys()].sort((a, b) => a - b);
  if (!xs.length) return NaN;
  if (x < xs[0] || x > xs[xs.length - 1]) return NaN;
  if (x === xs[0]) return map.get(xs[0]);
  if (x === xs[xs.length - 1]) return map.get(xs[xs.length - 1]);
  let hi = 1;
  while (hi < xs.length && xs[hi] < x) hi++;
  const lo = hi - 1;
  const lx = Math.log(x), l0 = Math.log(xs[lo]), l1 = Math.log(xs[hi]);
  const t = (lx - l0) / (l1 - l0);
  const y0 = map.get(xs[lo]), y1 = map.get(xs[hi]);
  return Math.exp(Math.log(y0) + t * (Math.log(y1) - Math.log(y0)));
}

function configDistance(a, b) {
  if (a.mode !== b.mode || a.transport !== b.transport) return Infinity;
  const logDist = (x, y) => Math.abs(Math.log2((Number(x) || 1) / (Number(y) || 1)));
  let d = 0;
  d += logDist(a.read_size, b.read_size) * 1.25;
  if ((a.read_budget_bytes || 0) === 0 || (b.read_budget_bytes || 0) === 0) {
    d += (a.read_budget_bytes || 0) === (b.read_budget_bytes || 0) ? 0 : 1.6;
  } else d += logDist(a.read_budget_bytes, b.read_budget_bytes) * .75;
  if (a.mode === 'framed') {
    const av = a.message_batch_size || 0, bv = b.message_batch_size || 0;
    d += av === bv ? 0 : (av === 0 || bv === 0 ? 1.5 : logDist(av, bv) * .8);
  } else {
    const av = a.read_batch_bytes || 0, bv = b.read_batch_bytes || 0;
    d += av === bv ? 0 : (av === 0 || bv === 0 ? 1.5 : logDist(av, bv) * .8);
  }
  d += logDist(a.max_buffer, b.max_buffer) * .15;
  return d;
}

function measuredCurve(config) {
  if (!benchmark || !Array.isArray(benchmark.series) || !benchmark.series.length) return null;
  const candidates = benchmark.series
    .filter(s => s.config && s.config.mode === config.mode && s.config.transport === config.transport)
    .map(s => ({ series: s, distance: configDistance(config, s.config) }))
    .filter(x => Number.isFinite(x.distance))
    .sort((a, b) => a.distance - b.distance);
  if (!candidates.length) return null;

  const exact = candidates.find(x => x.distance < 1e-9 || configKey(x.series.config) === configKey(config));
  const xs = measuredMessageSizes(config.mode, config.transport);
  if (!xs.length) return null;
  if (exact) {
    const m = pointMap(exact.series);
    return { source: 'exact', neighbors: 1, points: xs.map(x => ({ x, y: interpLogX(m, x) })) };
  }

  const neighbors = candidates.slice(0, Math.min(4, candidates.length));
  const maps = neighbors.map(n => pointMap(n.series));
  const points = xs.map(x => {
    let weighted = 0, total = 0;
    neighbors.forEach((n, i) => {
      const y = interpLogX(maps[i], x);
      if (!Number.isFinite(y)) return;
      const w = 1 / Math.max(.05, n.distance) ** 2;
      weighted += Math.log(y) * w;
      total += w;
    });
    return { x, y: total ? Math.exp(weighted / total) : NaN };
  }).filter(p => Number.isFinite(p.y));
  return points.length ? { source: 'interpolated', neighbors: neighbors.length, points } : null;
}

function measuredMessageSizes(mode, transport) {
  if (!benchmark) return [];
  const sizes = [];
  for (const s of benchmark.series || []) {
    if (!s.config || s.config.mode !== mode || s.config.transport !== transport) continue;
    for (const p of s.points || []) sizes.push(Number(p.message_size));
  }
  return uniqSorted(sizes);
}

function bestEnvelope(mode, transport) {
  if (!benchmark) return null;
  const series = (benchmark.series || []).filter(s => s.config && s.config.mode === mode && s.config.transport === transport);
  if (!series.length) return null;
  const xs = measuredMessageSizes(mode, transport);
  const maps = series.map(pointMap);
  const points = xs.map(x => {
    let best = -Infinity;
    for (const m of maps) {
      const y = interpLogX(m, x);
      if (Number.isFinite(y)) best = Math.max(best, y);
    }
    return { x, y: best };
  }).filter(p => Number.isFinite(p.y));
  return points.length ? points : null;
}

function previewCurve(config) {
  // This model exists only to exercise the UI before a sweep is loaded.
  // It intentionally favors read sizes that amortize syscalls without growing
  // excessively beyond the current message size, and rewards explicit batches
  // more strongly for small messages than large messages.
  return MESSAGE_SIZES.map(size => {
    const callCeiling = config.mode === 'framed' ? 245000 : 285000;
    const byteCeiling = config.transport === 'tcp' ? 2.4e9 : 3.4e9;
    const base = Math.min(callCeiling, byteCeiling / Math.max(16, size));
    const readsPerMessage = Math.max(1, size / config.read_size);
    const readPenalty = 1 / (1 + .11 * Math.max(0, readsPerMessage - 1));
    const overreadRatio = Math.max(1, config.read_size / Math.max(64, size));
    const cachePenalty = 1 / (1 + .018 * Math.max(0, Math.log2(overreadRatio) - 4) ** 2);
    const budget = config.read_budget_bytes || Infinity;
    const budgetPenalty = budget === Infinity ? 1 : Math.min(1, Math.max(.68, budget / Math.max(config.read_size, size * 8)));
    let batchBoost = 1;
    if (config.mode === 'framed') {
      const b = config.message_batch_size || 1;
      batchBoost = 1 + Math.min(.42, Math.log2(b) * .052) * Math.exp(-size / 9000);
    } else {
      const b = config.read_batch_bytes || 0;
      if (b) batchBoost = 1 + Math.min(.32, Math.log2(Math.max(1, b / 4096)) * .045) * Math.exp(-size / 12000);
    }
    if (config.mode === 'framed' && size + 1 > config.max_buffer) return { x: size, y: NaN };
    return { x: size, y: base * readPenalty * cachePenalty * budgetPenalty * batchBoost };
  });
}

function curveFor(config) {
  const measured = measuredCurve(config);
  if (measured) return measured;
  return { source: 'preview', neighbors: 0, points: previewCurve(config) };
}

function defaultConfig() {
  return configFor(DEFAULTS);
}

function bestCurve(mode, transport) {
  const measured = bestEnvelope(mode, transport);
  if (measured) return measured;
  // In preview mode, sample a small useful grid and take its envelope.
  const configs = [];
  for (const rs of [4096, 16384, 65536, 262144]) {
    for (const budget of [0, 65536, 262144]) {
      for (const batch of (mode === 'framed' ? [0, 4, 16, 64, 256] : [0, 16384, 65536, 262144])) {
        configs.push({ ...defaultConfig(), mode, transport, read_size: rs, read_budget_bytes: budget,
          message_batch_size: mode === 'framed' ? batch : 0,
          read_batch_bytes: mode === 'raw' ? batch : 0 });
      }
    }
  }
  const curves = configs.map(previewCurve);
  return MESSAGE_SIZES.map((x, i) => ({ x, y: Math.max(...curves.map(c => c[i].y)) }));
}

function allFinitePoints(lines) {
  return lines.flatMap(line => line.points || []).filter(p => Number.isFinite(p.x) && Number.isFinite(p.y) && p.y > 0);
}

function resizeCanvas() {
  const rect = canvas.getBoundingClientRect();
  const dpr = Math.max(1, window.devicePixelRatio || 1);
  const w = Math.round(rect.width * dpr), h = Math.round(rect.height * dpr);
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w; canvas.height = h;
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { width: rect.width, height: rect.height };
}

function niceMax(value) {
  if (!Number.isFinite(value) || value <= 0) return 1;
  const power = 10 ** Math.floor(Math.log10(value));
  const n = value / power;
  const nice = n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10;
  return nice * power;
}

function drawChart(lines) {
  const { width, height } = resizeCanvas();
  const pad = { left: 72, right: 22, top: 18, bottom: 55 };
  const plotW = width - pad.left - pad.right;
  const plotH = height - pad.top - pad.bottom;
  ctx.clearRect(0, 0, width, height);

  const points = allFinitePoints(lines);
  const xmin = Math.min(...points.map(p => p.x), 16);
  const xmax = Math.max(...points.map(p => p.x), 200000);
  const ymaxRaw = Math.max(...points.map(p => p.y), 1);
  const yMode = el('y-scale').value;
  const ymin = yMode === 'log' ? Math.max(1, 10 ** Math.floor(Math.log10(Math.min(...points.map(p => p.y))))) : 0;
  const ymax = yMode === 'log' ? 10 ** Math.ceil(Math.log10(ymaxRaw)) : niceMax(ymaxRaw * 1.06);

  const xPos = x => pad.left + (Math.log(x) - Math.log(xmin)) / (Math.log(xmax) - Math.log(xmin)) * plotW;
  const yPos = y => {
    if (yMode === 'log') return pad.top + (1 - (Math.log(y) - Math.log(ymin)) / (Math.log(ymax) - Math.log(ymin))) * plotH;
    return pad.top + (1 - y / ymax) * plotH;
  };

  const styles = getComputedStyle(document.documentElement);
  const grid = styles.getPropertyValue('--line').trim();
  const text = styles.getPropertyValue('--muted').trim();
  const accent = styles.getPropertyValue('--accent').trim();
  const accent2 = styles.getPropertyValue('--accent-2').trim();
  const def = styles.getPropertyValue('--default').trim();

  ctx.lineWidth = 1;
  ctx.strokeStyle = grid;
  ctx.fillStyle = text;
  ctx.font = '12px system-ui, sans-serif';
  ctx.textBaseline = 'middle';

  const xTicks = [16, 64, 256, 1024, 4096, 16384, 65536, 200000].filter(v => v >= xmin && v <= xmax);
  xTicks.forEach(x => {
    const px = xPos(x);
    ctx.beginPath(); ctx.moveTo(px, pad.top); ctx.lineTo(px, pad.top + plotH); ctx.stroke();
    ctx.textAlign = 'center';
    ctx.fillText(formatBytes(x), px, pad.top + plotH + 22);
  });

  let yTicks = [];
  if (yMode === 'log') {
    for (let p = Math.floor(Math.log10(ymin)); p <= Math.ceil(Math.log10(ymax)); p++) {
      for (const m of [1, 2, 5]) {
        const v = m * 10 ** p;
        if (v >= ymin && v <= ymax) yTicks.push(v);
      }
    }
  } else {
    for (let i = 0; i <= 5; i++) yTicks.push(ymax * i / 5);
  }
  yTicks.forEach(y => {
    const py = yPos(Math.max(y, ymin || 1));
    ctx.beginPath(); ctx.moveTo(pad.left, py); ctx.lineTo(pad.left + plotW, py); ctx.stroke();
    ctx.textAlign = 'right';
    ctx.fillText(formatRate(y), pad.left - 10, py);
  });

  ctx.fillStyle = text;
  ctx.textAlign = 'center';
  ctx.fillText('Message size (bytes, log scale)', pad.left + plotW / 2, height - 13);
  ctx.save();
  ctx.translate(16, pad.top + plotH / 2);
  ctx.rotate(-Math.PI / 2);
  ctx.fillText('Messages / second', 0, 0);
  ctx.restore();

  const paint = (line, color, dash, widthPx, dots) => {
    ctx.strokeStyle = color;
    ctx.lineWidth = widthPx;
    ctx.setLineDash(dash);
    ctx.beginPath();
    let started = false;
    for (const p of line.points) {
      if (!Number.isFinite(p.y) || p.y <= 0) continue;
      const px = xPos(p.x), py = yPos(p.y);
      if (!started) { ctx.moveTo(px, py); started = true; }
      else ctx.lineTo(px, py);
    }
    ctx.stroke();
    ctx.setLineDash([]);
    if (dots) {
      ctx.fillStyle = color;
      for (const p of line.points) {
        if (!Number.isFinite(p.y) || p.y <= 0) continue;
        ctx.beginPath(); ctx.arc(xPos(p.x), yPos(p.y), 2.6, 0, Math.PI * 2); ctx.fill();
      }
    }
  };

  paint(lines[1], def, [], 2, false);
  paint(lines[2], accent2, [7, 5], 2, false);
  paint(lines[0], accent, [], 3, true);

  rendered = { lines, xPos, yPos, pad, plotW, plotH, width, height };
}

function sourceLabel(source) {
  if (source === 'exact') return 'Exact measured';
  if (source === 'interpolated') return 'Interpolated';
  return 'Preview';
}

function updateSnippet() {
  const c = configFor();
  const batch = c.mode === 'framed'
    ? `        message_batch_size => ${c.message_batch_size},\n`
    : `        read_batch_bytes   => ${c.read_batch_bytes},\n`;
  const text = `sub stream_options ($class) {\n    return {\n        read_size          => ${c.read_size},\n        read_budget_bytes  => ${c.read_budget_bytes},\n${batch}        max_buffer         => ${c.max_buffer},\n    };\n}`;
  el('snippet').textContent = text;
}

function update() {
  const selected = curveFor(configFor());
  const def = curveFor({ ...defaultConfig(), mode: state.mode, transport: state.transport });
  const best = bestCurve(state.mode, state.transport);
  const lines = [
    { name: 'Selected', points: selected.points },
    { name: 'Defaults', points: def.points },
    { name: 'Best known', points: best },
  ];
  drawChart(lines);

  const badge = el('data-badge');
  badge.className = `badge ${selected.source === 'preview' ? 'preview' : 'measured'}`;
  badge.textContent = selected.source === 'exact' ? 'EXACT MEASURED'
    : selected.source === 'interpolated' ? `MEASURED INTERPOLATION (${selected.neighbors})`
    : 'HEURISTIC PREVIEW';
  el('source-card').textContent = sourceLabel(selected.source);
  const bestPoint = selected.points.reduce((a, b) => !a || b.y > a.y ? b : a, null);
  el('peak-card').textContent = bestPoint ? `${formatRate(bestPoint.y)} msg/s` : '-';
  el('peak-size-card').textContent = bestPoint ? formatBytes(bestPoint.x) : '-';
  el('series-card').textContent = benchmark?.series?.length || 0;
  el('truth-note').textContent = selected.source === 'preview'
    ? 'Preview mode is a deliberately simple heuristic so the UI is usable before data is loaded. It is not a Linux::Event benchmark result. Load JSON from the sweep benchmark for measured or measured-interpolated curves.'
    : selected.source === 'exact'
      ? 'The selected curve is backed by an exact benchmark series for this tuning configuration. The best-known envelope is the fastest loaded series at each measured message size.'
      : `The selected curve is interpolated in log-throughput space from ${selected.neighbors} nearby measured tuning series. It is an estimate grounded in the loaded sweep, not an exact run.`;
  updateSnippet();
}

function validateReport(report) {
  if (!report || report.benchmark !== 'linux-event-stream-tuning-sweep') throw new Error('Not a Linux::Event Stream tuning sweep JSON file.');
  if (Number(report.benchmark_contract_version) !== 1) throw new Error(`Unsupported benchmark contract version: ${report.benchmark_contract_version}`);
  if (!Array.isArray(report.series) || !report.series.length) throw new Error('Benchmark file contains no series.');
  for (const series of report.series) {
    if (!series.config || !Array.isArray(series.points)) throw new Error('Malformed benchmark series.');
  }
  return report;
}

async function loadFile(file) {
  const text = await file.text();
  const report = validateReport(JSON.parse(text));
  benchmark = report;
  addDatasetValues(report);
  resetControls();
  const version = report.linux_event_version ? `Linux::Event ${report.linux_event_version}` : 'Linux::Event';
  const when = report.generated_at_utc ? `, ${report.generated_at_utc}` : '';
  el('data-summary').textContent = `${report.series.length} measured tuning series loaded (${version}${when}).`;
}

function clearBenchmark() {
  benchmark = null;
  el('data-summary').textContent = 'No benchmark JSON loaded.';
  resetControls();
}

function nearestPointIndex(points, x) {
  let best = 0, d = Infinity;
  points.forEach((p, i) => {
    const nd = Math.abs(Math.log(p.x) - Math.log(x));
    if (nd < d) { d = nd; best = i; }
  });
  return best;
}

canvas.addEventListener('mousemove', ev => {
  if (!rendered) return;
  const rect = canvas.getBoundingClientRect();
  const mx = ev.clientX - rect.left, my = ev.clientY - rect.top;
  const { pad, plotW, plotH, lines, xPos } = rendered;
  if (mx < pad.left || mx > pad.left + plotW || my < pad.top || my > pad.top + plotH) {
    tooltip.style.display = 'none'; return;
  }
  const selected = lines[0].points;
  const idx = selected.reduce((best, p, i) => Math.abs(xPos(p.x) - mx) < Math.abs(xPos(selected[best].x) - mx) ? i : best, 0);
  const x = selected[idx].x;
  const rows = lines.map(line => {
    const pi = nearestPointIndex(line.points, x);
    return `<div class="r"><span class="muted">${line.name}</span><span>${formatRate(line.points[pi].y)} msg/s</span></div>`;
  }).join('');
  tooltip.innerHTML = `<strong>${formatBytes(x)} message</strong>${rows}`;
  tooltip.style.display = 'block';
  const tw = tooltip.offsetWidth, th = tooltip.offsetHeight;
  tooltip.style.left = `${Math.min(rect.width - tw - 8, mx + 14)}px`;
  tooltip.style.top = `${Math.max(8, Math.min(rect.height - th - 8, my - th / 2))}px`;
});
canvas.addEventListener('mouseleave', () => { tooltip.style.display = 'none'; });

el('mode').onchange = () => {
  state.mode = el('mode').value;
  setupBatchSlider();
  update();
};
el('transport').onchange = () => { state.transport = el('transport').value; update(); };
el('y-scale').onchange = update;
el('reset').onclick = resetControls;
el('load-data').onclick = () => el('file-input').click();
el('file-input').onchange = async ev => {
  const file = ev.target.files?.[0];
  if (!file) return;
  try { await loadFile(file); }
  catch (err) { alert(err.message || String(err)); }
  finally { ev.target.value = ''; }
};
el('clear-data').onclick = clearBenchmark;
el('copy').onclick = async () => {
  const text = el('snippet').textContent;
  let copied = false;
  try {
    await navigator.clipboard.writeText(text);
    copied = true;
  } catch {
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    try { copied = document.execCommand('copy'); } catch {}
    area.remove();
  }
  if (copied) {
    const old = el('copy').textContent;
    el('copy').textContent = 'Copied';
    setTimeout(() => { el('copy').textContent = old; }, 1200);
  } else {
    alert('Clipboard access is unavailable. Copy the policy from the panel instead.');
  }
};

window.addEventListener('resize', () => requestAnimationFrame(update));

el('mode').value = state.mode;
el('transport').value = state.transport;
setupSlider('read-size', 'read_size', formatBytes);
setupSlider('read-budget', 'read_budget_bytes', v => v === 0 ? 'unlimited' : formatBytes(v));
setupBatchSlider();
setupSlider('max-buffer', 'max_buffer', formatBytes);
update();
})();
