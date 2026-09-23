const sb = window.supabaseClient;
let me = null;
let people = [];

function show(tab) {
  document.querySelectorAll('main > section').forEach((s) => { s.hidden = s.id !== tab; });
  document.querySelectorAll('.navi[data-tab]').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
}
document.querySelectorAll('.navi[data-tab]').forEach((b) => { b.onclick = () => show(b.dataset.tab); });

async function boot() {
  me = await loadProfile();
  if (!me) return;
  if (me.role !== 'admin') { location.href = roleHome(me.role); return; }
  await Promise.all([renderHome(), renderPeople(), renderApps(), renderFees(), renderFlags(), renderAlerts(), renderPayouts(), renderChat()]);
}

async function renderHome() {
  const { data, error } = await sb.rpc('admin_global_stats');
  if (error) { document.getElementById('home').innerHTML = `<p class="err">${escapeHtml(error.message)}</p>`; return; }
  const s = Array.isArray(data) ? data[0] : data || {};
  document.getElementById('home').innerHTML = `<div class="grid 3">
    <div class="card"><div class="kicker">Settled volume</div><div class="kpi">${money(s.total_settled)}</div></div>
    <div class="card"><div class="kicker">Admin profit (earnings fees)</div><div class="kpi">${money(s.total_admin_profit)}</div><div class="faint">Platform fee on settled volume</div></div>
    <div class="card"><div class="kicker">Paid out</div><div class="kpi">${money(s.total_withdrawn)}</div></div>
    <div class="card"><div class="kicker">Pending payouts</div><div class="kpi">${Number(s.pending_withdrawals_count || 0)}</div><div class="faint">${money(s.pending_withdrawals_amount)}</div></div>
    <div class="card"><div class="kicker">Active books</div><div class="kpi">${Number(s.active_creators || 0)}</div></div>
    <div class="card"><div class="kicker">Settled payments</div><div class="kpi">${Number(s.payment_count || 0)}</div></div>
  </div>`;
}

async function renderPeople() {
  const { data, error } = await sb.rpc('admin_list_business_profiles');
  if (error) { document.getElementById('people').innerHTML = `<p class="err">${escapeHtml(error.message)}</p>`; return; }
  people = data || [];
  const rows = people.map((p) => `<tr>
    <td>${escapeHtml(p.display_name || '')}<div class="faint">${escapeHtml(p.email)}</div></td>
    <td>${p.role === 'moderator' ? 'Reseller' : p.role === 'creator' ? 'Freelancer' : p.role}</td>
    <td>${escapeHtml(p.account_status)}</td>
    <td>${escapeHtml(p.reseller_name || '—')}</td>
    <td>${Number(p.platform_fee_percent || 0).toFixed(2)}%</td>
    <td>${escapeHtml(p.hide_small_payments_mode)}</td>
    <td>${money(p.available)}</td>
    <td>
      <button class="btn ghost" data-fee="${p.id}">Platform fee</button>
      ${p.role === 'moderator' ? `<button class="btn ghost" data-comm="${p.id}">Reseller cut</button>` : ''}
      <button class="btn ghost" data-hide="${p.id}">Hide &lt;$10</button>
    </td>
  </tr>`).join('');
  document.getElementById('people').innerHTML = `<div class="card" style="overflow:auto">
    <table class="table"><thead><tr><th>Profile</th><th>Role</th><th>Status</th><th>Reseller</th><th>Earn fee</th><th>Small filter</th><th>Available</th><th></th></tr></thead>
    <tbody>${rows || '<tr><td colspan="8">No profiles</td></tr>'}</tbody></table>
  </div>`;
  document.querySelectorAll('[data-fee]').forEach((btn) => {
    btn.onclick = async () => {
      const raw = prompt('Platform fee % on this book\'s settled earnings');
      if (raw == null) return;
      const { error: e } = await sb.rpc('admin_set_platform_fee', { p_user_id: btn.dataset.fee, p_percent: Number(raw) });
      if (e) return toast(e.message);
      toast('Fee saved', true); renderPeople(); renderHome();
    };
  });
  document.querySelectorAll('[data-comm]').forEach((btn) => {
    btn.onclick = async () => {
      const raw = prompt('Reseller commission % on affiliate net (after platform fee, not link cost)');
      if (raw == null) return;
      const { error: e } = await sb.rpc('admin_set_reseller_commission', { p_reseller_id: btn.dataset.comm, p_percent: Number(raw) });
      if (e) return toast(e.message);
      toast('Commission saved', true); renderPeople();
    };
  });
  document.querySelectorAll('[data-hide]').forEach((btn) => {
    btn.onclick = async () => {
      const raw = prompt('inherit / on / off', 'inherit');
      if (!raw) return;
      const { error: e } = await sb.rpc('admin_set_profile_hide_small', { p_user_id: btn.dataset.hide, p_mode: raw.trim() });
      if (e) return toast(e.message);
      toast('Filter saved', true); renderPeople();
    };
  });
}

async function renderApps() {
  const { data, error } = await sb.rpc('admin_list_account_applications');
  if (error) { document.getElementById('apps').innerHTML = `<p class="muted">Applications RPC: ${escapeHtml(error.message)}</p>`; return; }
  const rows = (data || []).map((a) => `<tr>
    <td>${escapeHtml(a.display_name || a.email)}</td>
    <td>${escapeHtml(a.requested_role)}</td>
    <td>${escapeHtml(a.status)}</td>
    <td>
      <button class="btn primary" data-approve="${a.user_id}">Approve</button>
      <button class="btn danger" data-reject="${a.user_id}">Reject</button>
    </td>
  </tr>`).join('');
  document.getElementById('apps').innerHTML = `<div class="card" style="overflow:auto"><table class="table"><thead><tr><th>Applicant</th><th>Role</th><th>Status</th><th></th></tr></thead><tbody>${rows || '<tr><td colspan="4">Queue empty</td></tr>'}</tbody></table></div>`;
  document.querySelectorAll('[data-approve]').forEach((b) => b.onclick = () => review(b.dataset.approve, 'approved'));
  document.querySelectorAll('[data-reject]').forEach((b) => b.onclick = () => review(b.dataset.reject, 'rejected'));
}
async function review(id, status) {
  const { error } = await sb.rpc('admin_review_account_application', { p_user_id: id, p_status: status });
  if (error) return toast(error.message);
  toast('Updated', true); renderApps(); renderPeople();
}

async function renderFees() {
  document.getElementById('fees').innerHTML = `<div class="card">
    <p class="muted">Three different knobs. Platform fee = admin cut on settled. Link cost = payer markup. Reseller commission = attach cut on net after platform fee.</p>
    <div class="field"><label>Default platform fee % on earnings</label><input id="defFee" type="number" min="0" max="90" step="0.1" value="3"></div>
    <button class="btn primary" id="saveDefFee">Save default fee</button>
    <div class="field" style="margin-top:14px"><label>Default reseller commission % (affiliate books only)</label><input id="defComm" type="number" min="0" max="50" step="0.1" value="8"></div>
    <button class="btn primary" id="saveDefComm">Save default commission</button>
    <hr style="border-color:var(--line);margin:20px 0">
    <div class="field"><label>Hide settled payments under $</label><input id="hideAmt" type="number" min="0" value="10"></div>
    <div class="row">
      <button class="btn primary" id="hideOn">Turn global filter ON</button>
      <button class="btn ghost" id="hideOff">Turn global filter OFF</button>
    </div>
    <p class="muted">Individual profiles can still override with inherit / on / off.</p>
  </div>`;
  document.getElementById('saveDefFee').onclick = async () => {
    const { error } = await sb.rpc('admin_set_default_platform_fee', { p_percent: Number(document.getElementById('defFee').value) });
    if (error) return toast(error.message);
    toast('Default fee saved', true);
  };
  document.getElementById('saveDefComm').onclick = async () => {
    const { error } = await sb.rpc('admin_set_default_reseller_commission', { p_percent: Number(document.getElementById('defComm').value) });
    if (error) return toast(error.message);
    toast('Default commission saved', true);
  };
  document.getElementById('hideOn').onclick = () => setHide(true);
  document.getElementById('hideOff').onclick = () => setHide(false);
}
async function setHide(on) {
  const { error } = await sb.rpc('admin_set_hide_small_payments', { p_enabled: on, p_threshold: Number(document.getElementById('hideAmt').value) || 10 });
  if (error) return toast(error.message);
  toast(on ? 'Global filter on' : 'Global filter off', true);
}

async function renderFlags() {
  const keys = [
    ['emergency_payments_stop', 'Emergency: stop new customer payments'],
    ['emergency_withdrawals_stop', 'Emergency: stop withdrawals'],
    ['manual_withdrawals_enabled', 'Manual withdrawals enabled'],
    ['auto_withdraw_enabled', 'Instant Lightning payouts master switch'],
    ['feature_affiliate_enabled', 'Reseller affiliate attach'],
    ['feature_reseller_team_withdraw', 'Reseller can cash out team books'],
    ['feature_reseller_notices', 'Reseller notices'],
    ['hide_small_payments_enabled', 'Global hide-small-payments'],
  ];
  document.getElementById('flags').innerHTML = `<div class="card">${keys.map(([k, label]) => `
    <div class="row" style="justify-content:space-between;align-items:center;margin-bottom:10px">
      <div>${escapeHtml(label)}<div class="faint">${k}</div></div>
      <div>
        <button class="btn primary" data-k="${k}" data-v="true">On</button>
        <button class="btn ghost" data-k="${k}" data-v="false">Off</button>
      </div>
    </div>`).join('')}</div>`;
  document.querySelectorAll('#flags [data-k]').forEach((b) => {
    b.onclick = async () => {
      const { error } = await sb.rpc('admin_set_feature_toggle', { p_key: b.dataset.k, p_enabled: b.dataset.v === 'true' });
      if (error) return toast(error.message);
      toast('Toggle saved', true);
    };
  });
}

async function renderAlerts() {
  const resellers = people.filter((p) => p.role === 'moderator');
  const opts = resellers.map((p) => `<option value="${p.id}">${escapeHtml(p.display_name || p.email)}</option>`).join('');
  document.getElementById('alerts').innerHTML = `<div class="card">
    <p class="muted">Daily 5:00 PM Asia/Dhaka digest: settled total plus per-link earnings (including cost %).</p>
    <div class="field"><label>Reseller</label><select id="alWho">${opts}</select></div>
    <div class="field"><label>Discord webhook</label><input id="alDisc"></div>
    <div class="field"><label>Telegram bot token</label><input id="alTok"></div>
    <div class="field"><label>Telegram chat id</label><input id="alChat"></div>
    <button class="btn primary" id="alSave">Save channel</button>
  </div>`;
  document.getElementById('alSave').onclick = async () => {
    const { error } = await sb.rpc('admin_set_reseller_alerts', {
      p_reseller_id: document.getElementById('alWho').value,
      p_discord_webhook: document.getElementById('alDisc').value,
      p_telegram_bot_token: document.getElementById('alTok').value,
      p_telegram_chat_id: document.getElementById('alChat').value,
      p_enabled: true,
    });
    if (error) return toast(error.message);
    toast('Alert channel saved', true);
  };
}

async function renderPayouts() {
  const { data, error } = await sb.from('withdrawals').select('*').order('requested_at', { ascending: false }).limit(40);
  if (error) { document.getElementById('payouts').innerHTML = `<p class="err">${escapeHtml(error.message)}</p>`; return; }
  const rows = (data || []).map((w) => `<tr><td>${money(w.amount_requested)}</td><td>${escapeHtml(w.method)}</td><td>${escapeHtml(w.status)}</td><td>${escapeHtml(w.destination || '')}</td></tr>`).join('');
  document.getElementById('payouts').innerHTML = `<div class="card" style="overflow:auto"><table class="table"><thead><tr><th>Amount</th><th>Method</th><th>Status</th><th>Destination</th></tr></thead><tbody>${rows || '<tr><td colspan="4">None</td></tr>'}</tbody></table>
    <p class="muted">Force Lightning payout and settlement tools stay in <a href="admin-classic.html">classic ops panel</a>.</p></div>`;
}

async function renderChat() {
  const freelancers = people.filter((p) => p.role !== 'admin');
  const opts = freelancers.map((p) => `<option value="${p.id}">${escapeHtml(p.display_name || p.email)}</option>`).join('');
  document.getElementById('chat').innerHTML = `<div class="card">
    <div class="field"><label>Account</label><select id="cWho">${opts}</select></div>
    <div id="cThread"></div>
    <div class="field"><input id="cMsg"><button class="btn primary" id="cSend">Send</button></div>
  </div>`;
  async function load() {
    const uid = document.getElementById('cWho').value;
    if (!uid) return;
    const { data } = await sb.from('support_messages').select('*').eq('user_id', uid).order('created_at', { ascending: true }).limit(80);
    document.getElementById('cThread').innerHTML = (data || []).map((m) => `<div><span class="faint">${m.sender}</span> ${escapeHtml(m.message)}</div>`).join('') || '<p class="muted">Empty thread</p>';
  }
  document.getElementById('cWho')?.addEventListener('change', load);
  await load();
  document.getElementById('cSend').onclick = async () => {
    const { error } = await sb.from('support_messages').insert({ user_id: document.getElementById('cWho').value, sender: 'admin', message: document.getElementById('cMsg').value.trim() });
    if (error) return toast(error.message);
    load();
  };
}

boot();

const logoutBtn = document.getElementById("logoutBtn");
if (logoutBtn) logoutBtn.onclick = signOut;
