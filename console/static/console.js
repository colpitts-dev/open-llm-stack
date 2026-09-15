// Stack Console (plan 17): run a named action and stream its output; show a diff and apply on confirmation;
// destructive actions need their name typed back. Vanilla JS, no library: nothing is downloaded at execution.
(function () {
  const token = document.querySelector('meta[name="console-token"]').content;
  const drawer = document.getElementById('drawer'), out = document.getElementById('stream');
  const post = (path, body) => fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Console-Token': token }, body: JSON.stringify(body) });
  function follow(job, cmd) {
    out.hidden = false; out.textContent = ''; drawer.innerHTML = `<span>Running</span><span class="cmd">$ ${esc(cmd)}</span>`;
    const es = new EventSource(`/api/jobs/${job}/stream`);
    es.onmessage = (e) => { out.textContent += JSON.parse(e.data) + '\n'; out.scrollTop = out.scrollHeight; };
    es.addEventListener('done', (e) => { const d = JSON.parse(e.data); es.close();
      drawer.innerHTML = `<span>Last action</span><span class="cmd">$ ${esc(cmd)}</span><span class="${d.exit === 0 ? 'exit' : 'fail'}">exit ${d.exit} · ${d.seconds} s</span><button class="btn" onclick="location.reload()">Refresh screen</button>`; });
  }
  async function run(action, params, destructive) {
    let confirm;
    if (destructive) { confirm = prompt(`This is destructive. Type ${action} to confirm.`); if (confirm !== action) return; }
    const r = await post('/api/run', { action, params, confirm });
    if (!r.ok) { alert(await r.text()); return; }
    const j = await r.json(); follow(j.job, j.cmd);
  }
  document.querySelectorAll('button[data-action]').forEach((b) => b.addEventListener('click', () => run(b.dataset.action, JSON.parse(b.dataset.params || '{}'), !!b.dataset.destructive)));
  document.querySelectorAll('form[data-run]').forEach((f) => f.addEventListener('submit', (e) => { e.preventDefault();
    const params = Object.fromEntries(new FormData(f).entries()); run(f.dataset.run, params, false); }));
  document.querySelectorAll('form[data-write]').forEach((f) => f.addEventListener('submit', async (e) => { e.preventDefault();
    const kind = f.dataset.write, name = f.dataset.name || undefined; let body;
    if (kind === 'env') { const form = {}; f.querySelectorAll('input[name]').forEach((i) => { if (i.name !== 'content' && !(i.dataset.masked === '1' && i.value.startsWith('••••'))) form[i.name] = i.value; }); body = { kind, form }; }
    else body = { kind, name, content: f.querySelector('textarea[name="content"]').value };
    const r = await post('/api/diff', body); if (!r.ok) { alert(await r.text()); return; }
    const d = await r.json(); if (d.empty) { alert('No change.'); return; }
    out.hidden = false; out.textContent = d.diff; drawer.innerHTML = `<span>Diff of ${esc(d.path)}</span><button class="btn primary" id="apply">Apply</button><button class="btn" onclick="location.reload()">Discard</button>`;
    document.getElementById('apply').onclick = async () => {
      const content = kind === 'env' ? null : body.content; const a = await post('/api/apply', { kind, name, content: content ?? d.content ?? '', sig: d.sig });
      if (!a.ok) { alert(await a.text()); return; } const j = await a.json();
      if (j.job) follow(j.job, j.cmd); else { drawer.innerHTML = `<span>Written ${esc(j.written)}</span><button class="btn" onclick="location.reload()">Refresh screen</button>`; }
    };
  }));
  function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
})();
