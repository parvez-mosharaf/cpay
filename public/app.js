function $(id){ return document.getElementById(id); }
function escapeHtml(s){
  return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function money(n){ return '$' + Number(n || 0).toFixed(2); }
function toast(msg, ok){
  const el = $('toast');
  if (!el) return alert(msg);
  el.textContent = msg;
  el.style.color = ok ? 'var(--brand)' : 'var(--danger)';
  el.style.display = 'block';
}
async function requireSession(){
  const { data: { session } } = await window.supabaseClient.auth.getSession();
  if (!session) { location.href = 'login.html'; return null; }
  return session;
}
async function loadProfile(){
  const session = await requireSession();
  if (!session) return null;
  const { data, error } = await window.supabaseClient.from('profiles')
    .select('*').eq('id', session.user.id).single();
  if (error || !data) { location.href = 'login.html'; return null; }
  if (data.account_status && data.account_status !== 'active') {
    await window.supabaseClient.auth.signOut();
    location.href = 'login.html';
    return null;
  }
  window.CPAY_PROFILE = data;
  return data;
}
function roleHome(role){
  if (role === 'admin') return 'admin.html';
  if (role === 'moderator') return 'reseller.html';
  return 'dashboard.html';
}
async function signOut(){
  await window.supabaseClient.auth.signOut();
  location.href = 'login.html';
}
function layoutPicker(selected, wallet, invoice){
  const layouts = window.CPAY_LAYOUTS || {};
  const invoices = window.CPAY_INVOICE_THEMES || {};
  const layoutHtml = Object.entries(layouts).map(([id, meta]) =>
    `<button type="button" class="design ${id===selected?'on':''}" data-theme="${id}">${escapeHtml(meta.label)}<div class="faint">${meta.group}</div></button>`
  ).join('');
  const invoiceHtml = Object.entries(invoices).map(([id, meta]) =>
    `<button type="button" class="design ${id===(invoice||'default')?'on':''}" data-invoice="${id}">${escapeHtml(meta.label)}</button>`
  ).join('');
  return `
    <div class="field"><label>Payment page design</label><div class="designs" id="themePick">${layoutHtml}</div></div>
    <div class="field"><label>Invoice design</label><div class="designs" id="invoicePick">${invoiceHtml}</div></div>
    <div class="field"><label>Who can pay</label>
      <div class="row">
        <button type="button" class="pill ${wallet==='cashapp'?'active':''}" data-wallet="cashapp">Cash App only</button>
        <button type="button" class="pill ${wallet!=='cashapp'?'active':''}" data-wallet="all_wallets">All Lightning wallets + Cash App</button>
      </div>
    </div>`;
}
function bindExperience(state){
  document.querySelectorAll('#themePick .design').forEach(btn => {
    btn.onclick = () => {
      state.theme = btn.dataset.theme;
      document.querySelectorAll('#themePick .design').forEach(b => b.classList.toggle('on', b===btn));
    };
  });
  document.querySelectorAll('#invoicePick .design').forEach(btn => {
    btn.onclick = () => {
      state.invoice = btn.dataset.invoice;
      document.querySelectorAll('#invoicePick .design').forEach(b => b.classList.toggle('on', b===btn));
    };
  });
  document.querySelectorAll('[data-wallet]').forEach(btn => {
    btn.onclick = () => {
      state.wallet = btn.dataset.wallet;
      document.querySelectorAll('[data-wallet]').forEach(b => b.classList.toggle('active', b===btn));
    };
  });
}
window.CPAY_APP = { $, escapeHtml, money, toast, requireSession, loadProfile, roleHome, signOut, layoutPicker, bindExperience };
