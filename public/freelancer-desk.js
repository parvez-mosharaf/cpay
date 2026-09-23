const sb = window.supabaseClient;
const exp = { theme: 'keypad', invoice: 'default', wallet: 'all_wallets' };
let me = null, resellerId = null;

function show(tab) {
  document.querySelectorAll('main > section').forEach((s) => { s.hidden = s.id !== tab; });
  document.querySelectorAll('.navi[data-tab]').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
}
document.querySelectorAll('.navi[data-tab]').forEach((b) => { b.onclick = () => show(b.dataset.tab); });

async function boot() {
  me = await loadProfile();
  if (!me) return;
  if (me.role === 'admin') { location.href = 'admin.html'; return; }
  if (me.role === 'moderator') { location.href = 'reseller.html'; return; }
  document.getElementById('hello').textContent = (me.display_name || 'Freelancer') + ' desk';
  const { data: rid } = await sb.rpc('my_reseller_id');
  resellerId = rid;
  await Promise.all([renderHome(), renderLinks(), renderPays(), renderCash(), renderTeam(), renderChat(), renderProfile()]);
}

async function renderHome() {
  const [{ data: bal }, { data: day }, { data: split }] = await Promise.all([
    sb.rpc('get_my_balance'),
    sb.rpc('my_daily_settled'),
    sb.rpc('my_earnings_split'),
  ]);
  const b = Array.isArray(bal) ? bal[0] : bal || {};
  const d = Array.isArray(day) ? day[0] : day || {};
  const s = Array.isArray(split) ? split[0] : split || {};
  document.getElementById('home').innerHTML = `<div class="grid 3">
    <div class="card"><div class="kicker">Available</div><div class="kpi">${money(s.net || b.available)}</div><div class="faint">Your book only</div></div>
    <div class="card"><div class="kicker">Settled on your links</div><div class="kpi">${money(s.settled || d.total_settled || 0)}</div></div>
    <div class="card"><div class="kicker">Platform fee paid</div><div class="kpi">${money(s.platform_fee)}</div><div class="faint">Admin fee — not link cost</div></div>
    <div class="card"><div class="kicker">Reseller commission out</div><div class="kpi">${money(s.reseller_commission_out)}</div><div class="faint">${Number(s.commission_percent || 0).toFixed(2)}% of net after platform fee</div></div>
    <div class="card"><div class="kicker">Link cost rate</div><div class="kpi">${Number(s.cost_percent || 0).toFixed(2)}%</div><div class="faint">${s.cost_locked ? 'Locked by your reseller' : 'You can set this on each link'}</div></div>
  </div>`;
}

async function renderLinks() {
  const { data: links } = await sb.from('payment_links').select('*').eq('user_id', me.id).is('deleted_at', null).order('created_at', { ascending: false });
  const list = (links || []).map((l) => `<tr>
    <td><a href="/${escapeHtml(l.slug)}" target="_blank">/${escapeHtml(l.slug)}</a></td>
    <td>${escapeHtml(l.display_name || '')}</td>
    <td>${escapeHtml(l.theme || 'domain')}</td>
    <td>${escapeHtml(l.wallet_mode || 'all_wallets')}</td>
    <td>${l.is_active ? 'Live' : 'Off'}</td>
  </tr>`).join('');
  document.getElementById('links').innerHTML = `
    <div class="card">
      <h3>New payment link</h3>
      <div class="field"><label>Display name</label><input id="linkName" placeholder="Your public name"></div>
      <div class="field"><label>Link cost % (payer markup, not platform fee)</label><input id="linkCost" type="number" min="0" step="0.1" value="${Number(me.cost_percent || 0)}" ${me.cost_locked ? "disabled" : ""}></div><p class="muted">${me.cost_locked ? "Reseller locked this rate for your book." : "This is added to what the payer pays. It is not the admin platform fee."}</p>
      ${layoutPicker(exp.theme, exp.wallet, exp.invoice)}
      <button class="btn primary" id="makeLink">Generate link</button>
    </div>
    <div class="card" style="margin-top:14px;overflow:auto">
      <table class="table"><thead><tr><th>Slug</th><th>Name</th><th>Design</th><th>Wallets</th><th>Status</th></tr></thead>
      <tbody>${list || '<tr><td colspan="5">No links yet</td></tr>'}</tbody></table>
    </div>`;
  bindExperience(exp);
  document.getElementById('makeLink').onclick = makeLink;
}

async function makeLink() {
  const name = document.getElementById('linkName').value.trim();
  if (!name) return toast('Enter a name');
  const { data, error } = await sb.rpc('create_link_variants', { p_display_name: name, p_styles: ['kebab'] });
  if (error) return toast(error.message);
  const row = Array.isArray(data) ? data[0] : data;
  if (row?.slug) {
    const { data: link } = await sb.from('payment_links').select('id').eq('slug', row.slug).maybeSingle();
    if (link?.id) {
      await sb.rpc('set_payment_link_experience', {
        p_link_id: link.id, p_theme: exp.theme, p_wallet_mode: exp.wallet, p_invoice_theme: exp.invoice,
      });
    }
    const cost = Number(document.getElementById('linkCost').value);
    if (Number.isFinite(cost)) await sb.rpc('set_my_cost_percent', { p_percent: cost }).catch(() => {});
  }
  toast('Link ready', true);
  await renderLinks();
}

async function renderPays() {
  const { data, error } = await sb.rpc('get_my_payments', { p_limit: 50, p_offset: 0 });
  if (error) { document.getElementById('pay').innerHTML = `<p class="err">${escapeHtml(error.message)}</p>`; return; }
  const rows = (data || []).map((p) => `<tr><td>${money(p.amount_settled || p.amount_requested)}</td><td>${escapeHtml(p.status)}</td><td>/${escapeHtml(p.link_slug || '')}</td><td>${escapeHtml(String(p.settled_at || p.created_at || '').slice(0, 16))}</td></tr>`).join('');
  document.getElementById('pay').innerHTML = `<div class="card" style="overflow:auto"><table class="table"><thead><tr><th>Amount</th><th>Status</th><th>Link</th><th>When</th></tr></thead><tbody>${rows || '<tr><td colspan="4">No payments</td></tr>'}</tbody></table></div>`;
}

async function renderCash() {
  document.getElementById('cash').innerHTML = `<div class="card">
    <h3>Withdraw available balance</h3>
    <div class="field"><label>Amount USD</label><input id="wAmt" type="number" min="5" step="0.01"></div>
    <div class="field"><label>Method</label>
      <select id="wMethod"><option value="bkash">bKash</option><option value="nagad">Nagad</option><option value="binance">Binance</option><option value="lightning">Lightning</option><option value="usdt_bep20">USDT BEP20</option><option value="bank">Bank</option></select>
    </div>
    <div class="field"><label>Destination</label><input id="wDest" placeholder="wallet / account / you@ln.address"></div>
    <button class="btn primary" id="wBtn">Request withdrawal</button>
  </div>`;
  document.getElementById('wBtn').onclick = async () => {
    const { error } = await sb.rpc('request_withdrawal', {
      p_amount: Number(document.getElementById('wAmt').value),
      p_method: document.getElementById('wMethod').value,
      p_destination: document.getElementById('wDest').value.trim(),
    });
    if (error) return toast(error.message);
    toast('Withdrawal queued', true);
    renderHome();
  };
}

async function renderTeam() {
  const { data: notices } = await sb.from('reseller_notices').select('*').order('created_at', { ascending: false }).limit(20);
  const noteHtml = (notices || []).map((n) => `<div class="notice" style="margin-bottom:8px"><strong>${escapeHtml(n.title)}</strong><div class="muted">${escapeHtml(n.body)}</div></div>`).join('') || '<p class="muted">No notices yet.</p>';
  document.getElementById('team').innerHTML = `<div class="card">
    <p class="muted">${resellerId ? 'You are attached to a reseller team.' : 'Independent freelancer. Use a reseller affiliate link to attach this account.'}</p>
    <h3 style="margin-top:16px">Notices</h3>${noteHtml}
  </div>`;
}

async function renderChat() {
  let thread = '';
  if (resellerId) {
    const { data: msgs } = await sb.from('team_messages').select('*').eq('freelancer_id', me.id).order('created_at', { ascending: true }).limit(80);
    thread = (msgs || []).map((m) => `<div><span class="faint">${m.sender_id === me.id ? 'You' : 'Reseller'}</span> ${escapeHtml(m.body)}</div>`).join('');
  }
  const { data: adminMsgs } = await sb.from('support_messages').select('*').eq('user_id', me.id).order('created_at', { ascending: true }).limit(80);
  const adminThread = (adminMsgs || []).map((m) => `<div><span class="faint">${m.sender === 'admin' ? 'Admin' : 'You'}</span> ${escapeHtml(m.message)}</div>`).join('');
  document.getElementById('chat').innerHTML = `<div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(280px,1fr))">
    <div class="card"><h3>Reseller</h3><div>${thread || '<p class="muted">No reseller thread.</p>'}</div>
      ${resellerId ? '<div class="field" style="margin-top:10px"><input id="teamMsg"><button class="btn primary" id="sendTeam">Send</button></div>' : ''}</div>
    <div class="card"><h3>Admin</h3><div>${adminThread || '<p class="muted">No admin messages.</p>'}</div>
      <div class="field" style="margin-top:10px"><input id="adminMsg"><button class="btn primary" id="sendAdmin">Send</button></div></div>
  </div>`;
  const st = document.getElementById('sendTeam');
  if (st) st.onclick = async () => {
    const { error } = await sb.rpc('send_team_message', { p_other_id: resellerId, p_body: document.getElementById('teamMsg').value.trim() });
    if (error) return toast(error.message);
    renderChat();
  };
  document.getElementById('sendAdmin').onclick = async () => {
    const { error } = await sb.from('support_messages').insert({ user_id: me.id, sender: 'creator', message: document.getElementById('adminMsg').value.trim() });
    if (error) return toast(error.message);
    renderChat();
  };
}

async function renderProfile() {
  document.getElementById('profile').innerHTML = `<div class="card">
    <div class="field"><label>Display name</label><input id="pName" value="${escapeHtml(me.display_name || '')}"></div>
    <div class="field"><label>Bio</label><textarea id="pBio">${escapeHtml(me.bio || '')}</textarea></div>
    <div class="field"><label>Public store slug</label><input id="pSlug" value="${escapeHtml(me.public_slug || '')}"></div>
    <button class="btn primary" id="saveProf">Save profile</button>
    <p class="muted" style="margin-top:10px"><a href="store.html">Open public store</a></p>
  </div>`;
  document.getElementById('saveProf').onclick = async () => {
    const { error } = await sb.rpc('update_my_public_profile', {
      p_display_name: document.getElementById('pName').value,
      p_bio: document.getElementById('pBio').value,
      p_public_slug: document.getElementById('pSlug').value,
    });
    if (error) return toast(error.message);
    toast('Saved', true);
  };
}

boot();

const logoutBtn = document.getElementById("logoutBtn");
if (logoutBtn) logoutBtn.onclick = signOut;
