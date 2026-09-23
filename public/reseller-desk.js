const sb = window.supabaseClient;
const exp = { theme: 'keypad', invoice: 'default', wallet: 'all_wallets' };
let me = null;

function show(tab) {
  document.querySelectorAll('main > section').forEach((s) => { s.hidden = s.id !== tab; });
  document.querySelectorAll('.navi[data-tab]').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
}
document.querySelectorAll('.navi[data-tab]').forEach((b) => { b.onclick = () => show(b.dataset.tab); });

async function boot() {
  me = await loadProfile();
  if (!me) return;
  if (me.role === 'admin') { location.href = 'admin.html'; return; }
  if (me.role !== 'moderator') { location.href = 'dashboard.html'; return; }
  document.getElementById('hello').textContent = (me.display_name || 'Reseller') + ' desk';
  await Promise.all([renderHome(), renderTeam(), renderLinks(), renderCash(), renderNotice(), renderChat(), renderProfile()]);
}

async function renderHome() {
  const [{ data: totals }, { data: bal }, { data: split }, { data: comm }] = await Promise.all([
    sb.rpc('my_team_totals'),
    sb.rpc('get_my_balance'),
    sb.rpc('my_earnings_split'),
    sb.rpc('my_commission_totals'),
  ]);
  const t = Array.isArray(totals) ? totals[0] : totals || {};
  const b = Array.isArray(bal) ? bal[0] : bal || {};
  const s = Array.isArray(split) ? split[0] : split || {};
  const c = Array.isArray(comm) ? comm[0] : comm || {};
  const origin = location.origin;
  const aff = me.affiliate_code || '';
  document.getElementById('home').innerHTML = `<div class="grid 3">
    <div class="card"><div class="kicker">Your available</div><div class="kpi">${money(s.net || b.available)}</div><div class="faint">Own links + affiliate commission</div></div>
    <div class="card"><div class="kicker">Commission earned</div><div class="kpi">${money(c.commission_earned || s.reseller_commission_in)}</div><div class="faint">${Number(s.commission_percent || 0).toFixed(2)}% of affiliate net after platform fee</div></div>
    <div class="card"><div class="kicker">Team books</div><div class="kpi">${Number(t.member_count || 0)}</div><div class="faint">Team available ${money(t.team_available)}</div></div>
  </div>
  <div class="card" style="margin-top:14px">
    <div class="kicker">Affiliate</div>
    <p>Only accounts that sign up with this link pay you commission. Assigned-only accounts do not.</p>
    <code>${escapeHtml(origin + '/register.html?role=freelancer&ref=' + aff)}</code>
    <p class="muted" style="margin-top:10px">Link cost = what the payer is marked up. Platform fee = admin cut. Commission = your cut of the freelancer net. Admin can change any of the three.</p>
  </div>`;
}

async function renderTeam() {
  const [{ data, error }, { data: rowsComm }] = await Promise.all([
    sb.rpc('my_team_members'),
    sb.rpc('my_affiliate_commission_rows'),
  ]);
  if (error) { document.getElementById('team').innerHTML = `<p class="err">${escapeHtml(error.message)}</p>`; return; }
  const rows = (data || []).map((m) => `<tr>
    <td>${escapeHtml(m.display_name || m.email)}</td>
    <td>${escapeHtml(m.email)}</td>
    <td>${m.affiliate ? 'Affiliate' : 'Assigned'}</td>
    <td>${money(m.available)}</td>
    <td>
      <button class="btn ghost" data-cash="${m.id}" data-name="${escapeHtml(m.display_name || m.email)}">Cash out</button>
      <button class="btn ghost" data-cost="${m.id}">Fix cost</button>
    </td>
  </tr>`).join('');

  const commRows = (rowsComm || []).map((r) => `<tr>
    <td>${escapeHtml(r.freelancer_name || '')}</td>
    <td>/${escapeHtml(r.link_slug || '')}</td>
    <td>${money(r.settled)}</td>
    <td>${money(r.platform_fee)}</td>
    <td>${money(r.commission)}</td>
  </tr>`).join('');
  document.getElementById('team').innerHTML = `<div class="card">
    <p class="muted">Link cost is payer markup — not platform fee, not your commission. You can lock one cost rate onto every freelancer on your team.</p>
    <div class="field"><label>Team payment-link cost %</label><input id="teamCost" type="number" min="0" step="0.1" value="${Number(me.team_cost_percent || me.cost_percent || 0)}"></div>
    <div class="row">
      <button class="btn primary" id="lockAll">Lock this rate on all my freelancers</button>
      <button class="btn ghost" id="unlockAll">Unlock their rates</button>
    </div>
  </div>
  <div class="card" style="overflow:auto;margin-top:14px">
    <table class="table"><thead><tr><th>Name</th><th>Email</th><th>Source</th><th>Available</th><th></th></tr></thead>
    <tbody>${rows || '<tr><td colspan="5">No attached freelancers yet. Share your affiliate link.</td></tr>'}</tbody></table>
  </div>
  <div class="card" style="overflow:auto;margin-top:14px">
    <h3>Affiliate commission ledger</h3>
    <table class="table"><thead><tr><th>Freelancer</th><th>Link</th><th>Settled</th><th>Platform fee</th><th>Your cut</th></tr></thead>
    <tbody>${commRows || '<tr><td colspan="5">No affiliate settlements yet</td></tr>'}</tbody></table>
  </div>`;
  document.querySelectorAll('[data-cash]').forEach((btn) => {
    btn.onclick = () => prepareWithdraw(btn.dataset.cash, btn.dataset.name);
  });
  document.querySelectorAll('[data-cost]').forEach((btn) => {
    btn.onclick = async () => {
      const pct = Number(document.getElementById('teamCost').value);
      const { error: e } = await sb.rpc('reseller_set_freelancer_cost', { p_freelancer_id: btn.dataset.cost, p_percent: pct, p_lock: true });
      if (e) return toast(e.message);
      toast('Cost locked on that freelancer', true);
    };
  });
  const lockAll = document.getElementById('lockAll');
  if (lockAll) lockAll.onclick = async () => {
    const pct = Number(document.getElementById('teamCost').value);
    const { data, error: e } = await sb.rpc('reseller_lock_team_cost', { p_percent: pct, p_lock: true });
    if (e) return toast(e.message);
    toast('Locked on ' + data + ' freelancer book(s)', true);
  };
  const unlockAll = document.getElementById('unlockAll');
  if (unlockAll) unlockAll.onclick = async () => {
    const pct = Number(document.getElementById('teamCost').value);
    const { error: e } = await sb.rpc('reseller_lock_team_cost', { p_percent: pct, p_lock: false });
    if (e) return toast(e.message);
    toast('Rates unlocked. Commission still applies on affiliate settles.', true);
  };
}

function prepareWithdraw(userId, name) {
  show('cash');
  document.getElementById('wUser').value = userId;
  document.getElementById('wWho').textContent = 'Cashing out: ' + name;
}

async function renderLinks() {
  const { data: links } = await sb.from('payment_links').select('*').eq('user_id', me.id).is('deleted_at', null).order('created_at', { ascending: false });
  const list = (links || []).map((l) => `<tr><td><a href="/${escapeHtml(l.slug)}" target="_blank">/${escapeHtml(l.slug)}</a></td><td>${escapeHtml(l.theme || '')}</td><td>${escapeHtml(l.wallet_mode || '')}</td></tr>`).join('');
  document.getElementById('links').innerHTML = `<div class="card">
    <div class="field"><label>Link name</label><input id="linkName"></div>
    <div class="field"><label>Default cost %</label><input id="linkCost" type="number" min="0" step="0.1" value="${Number(me.cost_percent || 0)}"></div>
    ${layoutPicker(exp.theme, exp.wallet, exp.invoice)}
    <button class="btn primary" id="makeLink">Generate my link</button>
  </div>
  <div class="card" style="margin-top:14px;overflow:auto"><table class="table"><thead><tr><th>Slug</th><th>Design</th><th>Wallets</th></tr></thead><tbody>${list || '<tr><td colspan="3">None yet</td></tr>'}</tbody></table></div>`;
  bindExperience(exp);
  document.getElementById('makeLink').onclick = async () => {
    const name = document.getElementById('linkName').value.trim();
    if (!name) return toast('Enter a name');
    const { data, error } = await sb.rpc('create_link_variants', { p_display_name: name, p_styles: ['kebab'] });
    if (error) return toast(error.message);
    const row = Array.isArray(data) ? data[0] : data;
    if (row?.slug) {
      const { data: link } = await sb.from('payment_links').select('id').eq('slug', row.slug).maybeSingle();
      if (link?.id) await sb.rpc('set_payment_link_experience', { p_link_id: link.id, p_theme: exp.theme, p_wallet_mode: exp.wallet, p_invoice_theme: exp.invoice });
    }
    const cost = Number(document.getElementById('linkCost').value);
    if (Number.isFinite(cost)) await sb.rpc('set_my_cost_percent', { p_percent: cost }).catch(() => {});
    toast('Link ready', true);
    renderLinks();
  };
}

async function renderCash() {
  document.getElementById('cash').innerHTML = `<div class="card">
    <p id="wWho">Default: your own available balance. Pick a teammate from Team accounts to cash them out.</p>
    <input type="hidden" id="wUser" value="${me.id}">
    <div class="field"><label>Amount USD</label><input id="wAmt" type="number" min="5" step="0.01"></div>
    <div class="field"><label>Method</label>
      <select id="wMethod"><option value="bkash">bKash</option><option value="nagad">Nagad</option><option value="binance">Binance</option><option value="lightning">Lightning</option><option value="usdt_bep20">USDT BEP20</option><option value="bank">Bank</option></select>
    </div>
    <div class="field"><label>Destination</label><input id="wDest"></div>
    <button class="btn primary" id="wBtn">Submit withdrawal</button>
  </div>`;
  document.getElementById('wBtn').onclick = async () => {
    const { error } = await sb.rpc('reseller_request_withdrawal_for', {
      p_user_id: document.getElementById('wUser').value,
      p_amount: Number(document.getElementById('wAmt').value),
      p_method: document.getElementById('wMethod').value,
      p_destination: document.getElementById('wDest').value.trim(),
    });
    if (error) return toast(error.message);
    toast('Queued for admin review', true);
    renderHome(); renderTeam();
  };
}

async function renderNotice() {
  const { data: notices } = await sb.from('reseller_notices').select('*').eq('reseller_id', me.id).order('created_at', { ascending: false }).limit(20);
  const list = (notices || []).map((n) => `<div class="notice" style="margin-bottom:8px"><strong>${escapeHtml(n.title)}</strong><div>${escapeHtml(n.body)}</div></div>`).join('');
  document.getElementById('notice').innerHTML = `<div class="card">
    <div class="field"><label>Title</label><input id="nTitle"></div>
    <div class="field"><label>Message</label><textarea id="nBody"></textarea></div>
    <button class="btn primary" id="nBtn">Send to my freelancers</button>
    <div style="margin-top:16px">${list || '<p class="muted">No notices yet.</p>'}</div>
  </div>`;
  document.getElementById('nBtn').onclick = async () => {
    const { error } = await sb.rpc('post_reseller_notice', {
      p_title: document.getElementById('nTitle').value,
      p_body: document.getElementById('nBody').value,
    });
    if (error) return toast(error.message);
    toast('Notice posted', true);
    renderNotice();
  };
}

async function renderChat() {
  const { data: members } = await sb.rpc('my_team_members');
  const options = (members || []).map((m) => `<option value="${m.id}">${escapeHtml(m.display_name || m.email)}</option>`).join('');
  document.getElementById('chat').innerHTML = `<div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(280px,1fr))">
    <div class="card">
      <div class="field"><label>Freelancer</label><select id="chatWho">${options}</select></div>
      <div id="teamThread"></div>
      <div class="field"><input id="teamMsg"><button class="btn primary" id="sendTeam">Send</button></div>
    </div>
    <div class="card">
      <h3>Admin</h3>
      <div id="adminThread"></div>
      <div class="field"><input id="adminMsg"><button class="btn primary" id="sendAdmin">Send</button></div>
    </div>
  </div>`;
  async function loadTeamThread() {
    const other = document.getElementById('chatWho').value;
    if (!other) { document.getElementById('teamThread').innerHTML = '<p class="muted">No team yet.</p>'; return; }
    const { data: msgs } = await sb.from('team_messages').select('*').eq('reseller_id', me.id).eq('freelancer_id', other).order('created_at', { ascending: true }).limit(80);
    document.getElementById('teamThread').innerHTML = (msgs || []).map((m) => `<div><span class="faint">${m.sender_id === me.id ? 'You' : 'Freelancer'}</span> ${escapeHtml(m.body)}</div>`).join('') || '<p class="muted">No messages.</p>';
  }
  const { data: adminMsgs } = await sb.from('support_messages').select('*').eq('user_id', me.id).order('created_at', { ascending: true }).limit(80);
  document.getElementById('adminThread').innerHTML = (adminMsgs || []).map((m) => `<div><span class="faint">${m.sender === 'admin' ? 'Admin' : 'You'}</span> ${escapeHtml(m.message)}</div>`).join('') || '<p class="muted">No admin messages.</p>';
  document.getElementById('chatWho')?.addEventListener('change', loadTeamThread);
  await loadTeamThread();
  document.getElementById('sendTeam').onclick = async () => {
    const { error } = await sb.rpc('send_team_message', { p_other_id: document.getElementById('chatWho').value, p_body: document.getElementById('teamMsg').value.trim() });
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
    <div class="field"><label>Store slug</label><input id="pSlug" value="${escapeHtml(me.public_slug || '')}"></div>
    <button class="btn primary" id="saveProf">Save</button>
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
