'use strict';

const token = document.querySelector('meta[name="api-token"]').content;
const state = {
  servers: [], selectedAlias: null, checked: new Set(), query: '', authMode: 'key', history: [], historyIndex: 0,
  runtime: null, configError: '', saving: false, uploading: false, exporting: false, importing: false,
  refreshing: false, openingTerminal: false, deleting: false, resetting: false
};
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { 'Content-Type': 'application/json', 'X-SSH-Space-Token': token, ...(options.headers || {}) }
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `Request failed: ${response.status}`);
  return data;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[character]);
}

function initials(alias) {
  return alias.split(/[-_.]/).filter(Boolean).slice(0, 2).map(part => part[0]).join('').toUpperCase() || 'SH';
}

function friendlyError(error) {
  const message = String(error?.message || error || '').trim();
  const translations = [
    [/failed to fetch|networkerror|request failed/i, '无法连接本地服务，请确认 SSH Space 仍在运行后重试。'],
    [/unauthorized/i, '当前页面凭据已失效，请重新打开 SSH Space。'],
    [/alias.*1-64|valid server alias|别名需要|invalid server alias/i, '别名需为 1-64 个字符，可使用中文、字母、数字、点、下划线或连字符。'],
    [/alias.*already exists|服务器别名.*已存在/i, '这个服务器别名已经存在，请换一个名称。'],
    [/invalid password action/i, '密码保存状态无效，请关闭窗口后重新编辑。'],
    [/no valid host|whitespace in host/i, '主机地址不能为空，也不能包含空格。'],
    [/no valid user|whitespace or @ in user/i, '用户名不能为空，且不能包含空格或 @。'],
    [/port must be between|端口/i, '端口必须是 1 到 65535 之间的整数。'],
    [/connecttimeoutseconds|连接超时/i, '连接超时必须是大于 0 的整数。'],
    [/serveraliveintervalseconds|保活间隔/i, '保活间隔必须是大于或等于 0 的整数。'],
    [/key file does not exist|key file is missing|密钥.*不存在/i, '找不到指定密钥，请重新选择密钥文件或检查路径。'],
    [/key content is not valid base64/i, '密钥文件内容无法读取，请重新选择文件。'],
    [/key file must be between/i, '密钥文件大小必须在 1 字节到 512 KB 之间。'],
    [/openssh client is not installed|openssh client is unavailable/i, 'OpenSSH 运行时不可用，请重新安装 SSH Space。'],
    [/remote command timed out/i, '远程命令执行超过 120 秒，已停止等待。'],
    [/server .* was not found/i, '找不到该服务器，它可能已被删除或重命名。'],
    [/no server\.json packages were found/i, '没有找到可导入的 server.json 配置包。'],
    [/invalid package json/i, '导入包中的 server.json 格式无效。'],
    [/unsupported package version/i, '导入包版本不受支持。'],
    [/imported files exceed 10 mb/i, '导入文件总大小不能超过 10 MB。'],
    [/select between 1 and 200 package files/i, '一次请选择 1 到 200 个导入文件。'],
    [/folder path is outside this workspace/i, '只能打开 SSH Space 工作区内的目录。']
  ];
  return translations.find(([pattern]) => pattern.test(message))?.[1] || message || '操作未完成，请稍后重试。';
}

function dismissToast(element) {
  clearTimeout(element._dismissTimer);
  element.remove();
}

function toast(message, type = 'ok', action) {
  const region = $('#toast-region');
  const normalizedType = type === 'error' ? 'error' : (type === 'info' ? 'info' : 'ok');
  const cleanMessage = String(message || '').trim();
  const key = `${normalizedType}:${cleanMessage}`;
  const existing = [...region.children].find(element => element.dataset.toastKey === key);
  const duration = action ? 9000 : (normalizedType === 'error' ? 7000 : 4200);

  if (existing) {
    existing._count = (existing._count || 1) + 1;
    const badge = $('.toast-count', existing);
    badge.textContent = `×${existing._count}`;
    badge.classList.remove('hidden');
    clearTimeout(existing._dismissTimer);
    existing._dismissTimer = setTimeout(() => dismissToast(existing), duration);
    existing.animate([{ transform: 'translateX(0)' }, { transform: 'translateX(-5px)' }, { transform: 'translateX(0)' }], { duration: 180 });
    return existing;
  }

  while (region.children.length >= 3) dismissToast(region.firstElementChild);
  const element = document.createElement('div');
  element.className = `toast ${normalizedType === 'ok' ? '' : normalizedType}`;
  element.dataset.toastKey = key;
  element._count = 1;

  const icon = document.createElement('span');
  icon.className = 'toast-icon';
  icon.textContent = normalizedType === 'error' ? '!' : (normalizedType === 'info' ? 'i' : '✓');
  const copy = document.createElement('div');
  copy.className = 'toast-copy';
  const title = document.createElement('strong');
  title.append(document.createTextNode(normalizedType === 'error' ? '操作失败' : (normalizedType === 'info' ? '请注意' : '操作成功')));
  const count = document.createElement('span');
  count.className = 'toast-count hidden';
  title.append(count);
  const text = document.createElement('p');
  text.textContent = cleanMessage;
  copy.append(title, text);
  const close = document.createElement('button');
  close.className = 'toast-close';
  close.type = 'button';
  close.title = '关闭通知';
  close.setAttribute('aria-label', '关闭通知');
  close.textContent = '×';
  close.addEventListener('click', () => dismissToast(element));
  element.append(icon, copy, close);
  if (action) {
    const button = document.createElement('button');
    button.className = 'command-button toast-action';
    button.type = 'button';
    button.textContent = action.label;
    button.addEventListener('click', async () => {
      try { await action.handler(); } catch (error) { toast(friendlyError(error), 'error'); }
    });
    element.append(button);
  }
  region.append(element);
  element._dismissTimer = setTimeout(() => dismissToast(element), duration);
  return element;
}

function setBusy(button, busy, label) {
  if (!button) return;
  button.disabled = busy;
  button.classList.toggle('busy', busy);
  button.setAttribute('aria-busy', String(busy));
  const target = $('.button-label', button);
  if (target && label) {
    if (!button.dataset.idleLabel) button.dataset.idleLabel = target.textContent;
    target.textContent = busy ? label : button.dataset.idleLabel;
  }
}

function setFieldError(id, message = '') {
  const field = $(`#${id}`);
  const error = $(`#${id}-error`);
  if (field) message ? field.setAttribute('aria-invalid', 'true') : field.removeAttribute('aria-invalid');
  if (error) error.textContent = message;
}

function clearServerErrors() {
  ['field-alias', 'field-host', 'field-user', 'field-port', 'field-key', 'field-password', 'field-timeout', 'field-alive'].forEach(id => setFieldError(id));
  const alert = $('#server-form-error');
  alert.classList.add('hidden');
  $('p', alert).textContent = '';
}

function showFormError(message) {
  const alert = $('#server-form-error');
  $('p', alert).textContent = message;
  alert.classList.remove('hidden');
  alert.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}

function validateServerForm(existing) {
  clearServerErrors();
  const alias = $('#field-alias').value.trim();
  const host = $('#field-host').value.trim();
  const user = $('#field-user').value.trim();
  const port = Number($('#field-port').value);
  const timeout = Number($('#field-timeout').value);
  const alive = Number($('#field-alive').value);
  const errors = [];
  const add = (id, message) => { setFieldError(id, message); errors.push(id); };

  if (!alias) add('field-alias', '请输入服务器别名。');
  else if (!/^[\p{L}\p{N}][\p{L}\p{N}._-]{0,63}$/u.test(alias)) add('field-alias', '仅支持中文、字母、数字、点、下划线或连字符，最多 64 个字符。');
  else if (state.servers.some(server => server.alias.toLocaleLowerCase() === alias.toLocaleLowerCase() && server.alias !== existing?.alias)) add('field-alias', '这个别名已经存在。');
  if (!host || /\s/.test(host)) add('field-host', '请输入不含空格的主机名或 IP 地址。');
  if (!user || /[\s@]/.test(user)) add('field-user', '请输入不含空格和 @ 的用户名。');
  if (!Number.isInteger(port) || port < 1 || port > 65535) add('field-port', '请输入 1 到 65535 之间的整数。');
  if (state.authMode === 'key' && !$('#field-key').value.trim()) add('field-key', '请选择密钥文件或填写密钥路径。');
  if (state.authMode === 'password' && !existing?.hasPassword && !$('#field-password').value) add('field-password', '新建密码节点时需要输入登录密码。');
  if (!Number.isInteger(timeout) || timeout < 1) add('field-timeout', '请输入大于 0 的整数。');
  if (!Number.isInteger(alive) || alive < 0) add('field-alive', '请输入大于或等于 0 的整数。');

  if (errors.some(id => id === 'field-timeout' || id === 'field-alive')) $('.advanced-settings').open = true;
  if (errors.length) {
    const first = $(`#${errors[0]}`);
    first.scrollIntoView({ block: 'center', behavior: 'smooth' });
    setTimeout(() => first.focus(), 180);
    return false;
  }
  return true;
}

function attachServerError(error) {
  const message = friendlyError(error);
  const raw = String(error?.message || '');
  const mappings = [
    [/alias|别名/i, 'field-alias'], [/host|主机/i, 'field-host'], [/user|用户名/i, 'field-user'],
    [/port|端口/i, 'field-port'], [/connecttimeout|连接超时/i, 'field-timeout'],
    [/serveralive|保活间隔/i, 'field-alive'], [/key|密钥/i, 'field-key'], [/password|密码/i, 'field-password']
  ];
  const fieldId = mappings.find(([pattern]) => pattern.test(raw))?.[1];
  if (fieldId) {
    setFieldError(fieldId, message);
    if (fieldId === 'field-timeout' || fieldId === 'field-alive') $('.advanced-settings').open = true;
    const field = $(`#${fieldId}`);
    field.scrollIntoView({ block: 'center', behavior: 'smooth' });
    setTimeout(() => field.focus(), 180);
  } else showFormError(message);
}

async function loadState(preferredAlias) {
  const data = await api('/api/state');
  state.servers = data.servers || [];
  state.runtime = data.runtime || null;
  state.configError = data.configError || '';
  state.checked = new Set([...state.checked].filter(alias => state.servers.some(server => server.alias === alias)));
  if (preferredAlias && state.servers.some(server => server.alias === preferredAlias)) state.selectedAlias = preferredAlias;
  if (!state.servers.some(server => server.alias === state.selectedAlias)) state.selectedAlias = state.servers[0]?.alias || null;
  render();
  if (state.configError) toast(`配置文件损坏：${state.configError}`, 'error');
}

function render() {
  const filtered = state.servers.filter(server => `${server.alias} ${server.host} ${server.user}`.toLowerCase().includes(state.query.toLowerCase()));
  $('#server-count').textContent = state.servers.length;
  $('#selection-count').textContent = `${state.checked.size} 已选择`;
  $('#select-all-button').textContent = state.checked.size === state.servers.length && state.servers.length ? '取消全选' : '全选';
  $('#server-list').innerHTML = filtered.length ? filtered.map((server, index) => `
    <button class="server-row ${server.alias === state.selectedAlias ? 'active' : ''} ${server.status === 'invalid' ? 'invalid' : ''}" data-alias="${escapeHtml(server.alias)}" style="animation-delay:${index * 35}ms">
      <input class="server-check" type="checkbox" ${state.checked.has(server.alias) ? 'checked' : ''} aria-label="选择 ${escapeHtml(server.alias)}">
      <span class="node-avatar">${escapeHtml(initials(server.alias))}</span>
      <span class="server-copy"><strong>${escapeHtml(server.alias)}</strong><span>${escapeHtml(server.user || '—')}@${escapeHtml(server.host || '—')}:${server.port}</span></span>
      <span class="auth-tag">${escapeHtml(server.auth)}</span>
    </button>`).join('') : '<div class="empty-list">NO MATCHING NODES</div>';

  $$('.server-row').forEach(row => {
    row.addEventListener('click', event => {
      if (event.target.matches('.server-check')) return;
      state.selectedAlias = row.dataset.alias;
      render();
    });
    $('.server-check', row).addEventListener('change', event => {
      event.target.checked ? state.checked.add(row.dataset.alias) : state.checked.delete(row.dataset.alias);
      render();
    });
  });

  const server = state.servers.find(item => item.alias === state.selectedAlias);
  const live = $('.live-indicator');
  const runtimeSource = state.runtime?.source === 'bundled' ? 'BUILT-IN' : 'SYSTEM';
  live.innerHTML = `<i></i>${state.runtime?.sshAvailable ? `OPENSSH / ${runtimeSource}` : 'SSH MISSING'}`;
  live.classList.toggle('runtime-error', state.runtime && !state.runtime.sshAvailable);
  $('#empty-state').classList.toggle('hidden', Boolean(server));
  $('#node-workspace').classList.toggle('hidden', !server);
  $('#active-alias').textContent = server?.alias || 'NO NODE';
  const sshVersion = String(state.runtime?.version || '').match(/OpenSSH(?:_for_Windows)?_([^\s,]+)/i)?.[1] || 'READY';
  const powerShellVersion = String(state.runtime?.powerShellVersion || '').split('.').slice(0, 2).join('.') || '?';
  $('#footer-runtime').textContent = state.runtime?.sshAvailable
    ? `PS ${powerShellVersion} / SSH ${sshVersion}`
    : `PS ${powerShellVersion} / OPENSSH REQUIRED`;
  if (!server) return;
  $('#node-title').textContent = server.alias;
  $('#node-address').textContent = `${server.user}@${server.host}:${server.port}`;
  $('#node-status').textContent = server.status === 'ready' ? 'READY' : 'CHECK CONFIG';
  $('#node-status-dot').style.background = server.status === 'ready' ? 'var(--green)' : 'var(--amber)';
  $('#node-auth').textContent = server.auth.toUpperCase();
  $('#metric-port').textContent = server.port;
  $('#metric-auth').textContent = server.auth.toUpperCase();
  $('#metric-timeout').textContent = `${server.connectTimeoutSeconds}S`;
  $('#metric-alive').textContent = `${server.serverAliveIntervalSeconds}S`;
  $('#topology-initials').textContent = initials(server.alias);
  $('#topology-remote').textContent = `REMOTE / ${server.port}`;
  $('#topology-index').textContent = String(state.servers.findIndex(item => item.alias === server.alias) + 1).padStart(2, '0');
  $('#terminal-label').textContent = `${server.alias.toUpperCase()} / REMOTE EXEC`;
  $('#terminal-exit').textContent = 'IDLE';
  $('#open-terminal').disabled = state.runtime && !state.runtime.sshAvailable;
}

function openServerDialog(server) {
  const editing = Boolean(server);
  clearServerErrors();
  state.saving = false;
  setBusy($('#server-submit'), false, '保存中');
  $('#server-dialog-title').textContent = editing ? '编辑服务器' : '新建服务器';
  $('#original-alias').value = server?.alias || '';
  $('#field-alias').value = server?.alias || '';
  $('#field-host').value = server?.host === 'CHANGE_ME' ? '' : server?.host || '';
  $('#field-user').value = server?.user === 'CHANGE_ME' ? '' : server?.user || '';
  $('#field-port').value = server?.port || 22;
  $('#field-key').value = server?.identityFile || '';
  $('#field-password').value = '';
  $('#field-password').placeholder = server?.hasPassword ? '保持现有密码' : '输入登录密码';
  $('#field-timeout').value = server?.connectTimeoutSeconds || 10;
  $('#field-alive').value = server?.serverAliveIntervalSeconds ?? 30;
  $('#field-strict').value = server?.strictHostKeyChecking || 'accept-new';
  setAuthMode(server?.auth || 'key');
  $('#server-dialog').showModal();
  setTimeout(() => $('#field-alias').focus(), 80);
}

function setAuthMode(mode) {
  state.authMode = mode;
  $$('.auth-tab').forEach(tab => tab.classList.toggle('active', tab.dataset.authMode === mode));
  $('#key-fields').classList.toggle('hidden', mode !== 'key');
  $('#password-fields').classList.toggle('hidden', mode !== 'password');
  $('#interactive-fields').classList.toggle('hidden', mode !== 'interactive');
  setFieldError('field-key');
  setFieldError('field-password');
}

async function saveServer(event) {
  event.preventDefault();
  if (state.saving) return;
  const originalAlias = $('#original-alias').value;
  const existing = state.servers.find(server => server.alias === originalAlias);
  if (!validateServerForm(existing)) return;
  let passwordAction = 'keep';
  let password = '';
  let identityFile = '';
  if (state.authMode === 'password') {
    password = $('#field-password').value;
    passwordAction = password ? 'set' : (existing?.hasPassword ? 'keep' : 'set');
  } else {
    passwordAction = existing?.hasPassword ? 'clear' : 'keep';
    if (state.authMode === 'key') identityFile = $('#field-key').value.trim();
  }
  const body = {
    originalAlias,
    alias: $('#field-alias').value.trim(),
    host: $('#field-host').value.trim(),
    user: $('#field-user').value.trim(),
    port: Number($('#field-port').value),
    identityFile,
    password,
    passwordAction,
    connectTimeoutSeconds: Number($('#field-timeout').value),
    serverAliveIntervalSeconds: Number($('#field-alive').value),
    strictHostKeyChecking: $('#field-strict').value
  };
  state.saving = true;
  setBusy($('#server-submit'), true, '保存中');
  clearServerErrors();
  try {
    const result = await api('/api/server/save', { method: 'POST', body: JSON.stringify(body) });
    $('#server-dialog').close();
    await loadState(result.alias);
    toast(`节点 ${result.alias} 已保存`);
  } catch (error) {
    if ($('#server-dialog').open) attachServerError(error);
    else toast(friendlyError(error), 'error');
  } finally {
    state.saving = false;
    setBusy($('#server-submit'), false, '保存中');
  }
}

async function uploadKey(file) {
  if (!file || state.uploading) return;
  const alias = $('#field-alias').value.trim();
  if (!/^[\p{L}\p{N}][\p{L}\p{N}._-]{0,63}$/u.test(alias)) {
    setFieldError('field-alias', '请先填写有效的服务器别名，再选择密钥。');
    $('#field-alias').focus();
    $('#key-upload').value = '';
    return;
  }
  state.uploading = true;
  const uploadButton = $('.upload-key-button');
  uploadButton.setAttribute('aria-busy', 'true');
  try {
    const content = await fileToBase64(file);
    const result = await api('/api/key/upload', { method: 'POST', body: JSON.stringify({ alias, name: file.name, content }) });
    $('#field-key').value = result.path;
    setFieldError('field-key');
    setAuthMode('key');
    toast('密钥已存入隔离目录');
  } catch (error) {
    const message = friendlyError(error);
    if (/alias|别名/i.test(String(error?.message || ''))) {
      setFieldError('field-alias', message);
      $('#field-alias').focus();
    } else if (/key|file|base64|密钥/i.test(String(error?.message || ''))) {
      setFieldError('field-key', message);
    } else showFormError(message);
  } finally {
    state.uploading = false;
    uploadButton.removeAttribute('aria-busy');
    $('#key-upload').value = '';
  }
}

function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1] || '');
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

async function exportServers(aliases) {
  if (state.exporting) return;
  const selection = aliases?.length ? aliases : (state.checked.size ? [...state.checked] : (state.selectedAlias ? [state.selectedAlias] : []));
  if (!selection.length) return toast('没有可导出的服务器', 'error');
  state.exporting = true;
  const buttons = [...$$('[data-action="export"]'), $('#export-server')].filter(Boolean);
  buttons.forEach(button => setBusy(button, true));
  try {
    const result = await api('/api/export', { method: 'POST', body: JSON.stringify({ aliases: selection }) });
    toast(`已导出 ${result.count} 台服务器`, 'ok', {
      label: '打开目录',
      handler: () => api('/api/folder/open', { method: 'POST', body: JSON.stringify({ path: result.directory }) })
    });
  } catch (error) { toast(friendlyError(error), 'error'); }
  finally {
    state.exporting = false;
    buttons.forEach(button => setBusy(button, false));
  }
}

async function importFiles(files) {
  const list = [...files];
  if (!list.length || state.importing) return;
  const log = $('#transfer-log');
  state.importing = true;
  $$('.import-actions input').forEach(input => { input.disabled = true; });
  log.textContent = `正在读取 ${list.length} 个文件…`;
  try {
    const payload = [];
    for (const file of list) payload.push({ name: file.name, relativePath: file.webkitRelativePath || file.name, content: await fileToBase64(file) });
    log.textContent = '正在校验并导入…';
    const result = await api('/api/import', { method: 'POST', body: JSON.stringify({ files: payload }) });
    const aliases = result.imported.map(item => item.Alias || item.alias);
    log.textContent = aliases.map(alias => `已导入  ${alias}`).join('\n');
    await loadState(aliases[0]);
    toast(`已导入 ${aliases.length} 台服务器`);
  } catch (error) {
    const message = friendlyError(error);
    log.textContent = `导入失败  ${message}`;
    toast(message, 'error');
  } finally {
    state.importing = false;
    $$('.import-actions input').forEach(input => { input.disabled = false; input.value = ''; });
  }
}

async function runCommand(event) {
  event.preventDefault();
  const command = $('#command-input').value.trim();
  if (!command || !state.selectedAlias) return;
  const output = $('#terminal-output');
  const startedAt = performance.now();
  output.insertAdjacentHTML('beforeend', `<div class="output-line command">❯ ${escapeHtml(command)}</div><div class="output-line system pending"><span>RUN</span><p>Dispatching encrypted remote command...</p></div>`);
  output.scrollTop = output.scrollHeight;
  state.history.push(command);
  state.historyIndex = state.history.length;
  $('#command-input').value = '';
  $('.run-button').disabled = true;
  $('#terminal-exit').textContent = 'RUNNING';
  try {
    const result = await api('/api/command/run', { method: 'POST', body: JSON.stringify({ alias: state.selectedAlias, command }) });
    output.lastElementChild.remove();
    output.insertAdjacentHTML('beforeend', `<div class="output-line ${result.exitCode ? 'error' : 'result'}">${escapeHtml(result.output || '[no output]')}</div>`);
    const elapsed = ((performance.now() - startedAt) / 1000).toFixed(2);
    output.insertAdjacentHTML('beforeend', `<div class="output-line system"><span>EXIT</span><p>Code ${result.exitCode} / ${elapsed}s</p></div>`);
    $('#terminal-exit').textContent = `EXIT ${result.exitCode}`;
  } catch (error) {
    output.lastElementChild.remove();
    output.insertAdjacentHTML('beforeend', `<div class="output-line error">${escapeHtml(friendlyError(error))}</div>`);
    $('#terminal-exit').textContent = 'FAILED';
  } finally {
    $('.run-button').disabled = false;
    output.scrollTop = output.scrollHeight;
    $('#command-input').focus();
  }
}

function bindEvents() {
  $('#server-search').addEventListener('input', event => { state.query = event.target.value; render(); });
  $('#select-all-button').addEventListener('click', () => {
    state.checked = state.checked.size === state.servers.length ? new Set() : new Set(state.servers.map(server => server.alias));
    render();
  });
  $$('[data-action="new"]').forEach(button => button.addEventListener('click', () => openServerDialog(null)));
  $$('[data-action="import"]').forEach(button => button.addEventListener('click', () => $('#transfer-dialog').showModal()));
  $$('[data-action="export"]').forEach(button => button.addEventListener('click', () => exportServers()));
  $$('[data-action="reset"]').forEach(button => button.addEventListener('click', () => {
    $('#reset-confirmation').value = '';
    $('#reset-submit').disabled = true;
    $('#reset-dialog').showModal();
    setTimeout(() => $('#reset-confirmation').focus(), 80);
  }));
  $$('[data-close-dialog]').forEach(button => button.addEventListener('click', () => button.closest('dialog').close()));
  $$('.auth-tab').forEach(button => button.addEventListener('click', () => setAuthMode(button.dataset.authMode)));
  $('#server-form').addEventListener('submit', saveServer);
  $$('#server-form input, #server-form select').forEach(field => field.addEventListener('input', () => {
    if (field.id) setFieldError(field.id);
    $('#server-form-error').classList.add('hidden');
  }));
  $('#key-upload').addEventListener('change', event => uploadKey(event.target.files[0]));
  $('#refresh-button').addEventListener('click', async event => {
    if (state.refreshing) return;
    state.refreshing = true;
    setBusy(event.currentTarget, true);
    try {
      await loadState(state.selectedAlias);
      toast('服务器列表已刷新');
    } catch (error) { toast(friendlyError(error), 'error'); }
    finally { state.refreshing = false; setBusy(event.currentTarget, false); }
  });
  $('#edit-server').addEventListener('click', () => openServerDialog(state.servers.find(server => server.alias === state.selectedAlias)));
  $('#export-server').addEventListener('click', () => exportServers([state.selectedAlias]));
  $('#open-terminal').addEventListener('click', async event => {
    if (state.openingTerminal || !state.selectedAlias) return;
    state.openingTerminal = true;
    setBusy(event.currentTarget, true);
    try { await api('/api/terminal/open', { method: 'POST', body: JSON.stringify({ alias: state.selectedAlias }) }); toast('终端已打开'); }
    catch (error) { toast(friendlyError(error), 'error'); }
    finally { state.openingTerminal = false; setBusy(event.currentTarget, false); render(); }
  });
  $('#delete-server').addEventListener('click', () => {
    if (!state.selectedAlias) return;
    $('#delete-alias').textContent = state.selectedAlias;
    $('#delete-dialog').showModal();
  });
  $('#delete-form').addEventListener('submit', async event => {
    event.preventDefault();
    if (state.deleting || !state.selectedAlias) return;
    const alias = state.selectedAlias;
    state.deleting = true;
    setBusy($('#delete-submit'), true, '删除中');
    try {
      await api('/api/server/delete', { method: 'POST', body: JSON.stringify({ alias }) });
      $('#delete-dialog').close();
      state.selectedAlias = null;
      await loadState();
      toast(`服务器 ${alias} 已删除`);
    } catch (error) { toast(friendlyError(error), 'error'); }
    finally { state.deleting = false; setBusy($('#delete-submit'), false, '删除中'); }
  });
  $('#command-form').addEventListener('submit', runCommand);
  $('#clear-output').addEventListener('click', () => {
    $('#terminal-output').innerHTML = '<div class="output-line system"><span>SYS</span><p>Secure execution channel initialized.</p></div>';
    $('#terminal-exit').textContent = 'IDLE';
  });
  $('#command-input').addEventListener('keydown', event => {
    if (event.key === 'ArrowUp' && state.history.length) { event.preventDefault(); state.historyIndex = Math.max(0, state.historyIndex - 1); event.target.value = state.history[state.historyIndex]; }
    if (event.key === 'ArrowDown' && state.history.length) { event.preventDefault(); state.historyIndex = Math.min(state.history.length, state.historyIndex + 1); event.target.value = state.history[state.historyIndex] || ''; }
  });
  $('#import-files').addEventListener('change', event => importFiles(event.target.files));
  $('#import-folder').addEventListener('change', event => importFiles(event.target.files));
  $('#reset-confirmation').addEventListener('input', event => { $('#reset-submit').disabled = event.target.value !== 'RESET SSH SPACE'; });
  $('#reset-form').addEventListener('submit', async event => {
    event.preventDefault();
    const confirmation = $('#reset-confirmation').value;
    if (confirmation !== 'RESET SSH SPACE' || state.resetting) return;
    state.resetting = true;
    setBusy($('#reset-submit'), true);
    try {
      const result = await api('/api/factory-reset', { method: 'POST', body: JSON.stringify({ confirmation }) });
      $('#reset-dialog').close();
      state.selectedAlias = null;
      state.checked.clear();
      await loadState();
      toast('已恢复默认配置', 'ok', { label: '打开备份目录', handler: () => api('/api/folder/open', { method: 'POST', body: JSON.stringify({ path: result.backup }) }) });
    } catch (error) { toast(friendlyError(error), 'error'); }
    finally {
      state.resetting = false;
      setBusy($('#reset-submit'), false);
      $('#reset-submit').disabled = $('#reset-confirmation').value !== 'RESET SSH SPACE';
    }
  });
  const dropZone = $('#drop-zone');
  ['dragenter', 'dragover'].forEach(type => dropZone.addEventListener(type, event => { event.preventDefault(); dropZone.classList.add('dragging'); }));
  ['dragleave', 'drop'].forEach(type => dropZone.addEventListener(type, event => { event.preventDefault(); dropZone.classList.remove('dragging'); }));
  dropZone.addEventListener('drop', event => importFiles(event.dataTransfer.files));
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') $$('dialog[open]').forEach(dialog => dialog.close());
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); $('#server-search').focus(); }
  });
}

function startClock() {
  const update = () => { $('#clock').textContent = new Date().toLocaleTimeString('en-GB', { hour12: false }); };
  update();
  setInterval(update, 1000);
}

function startNetworkCanvas() {
  const canvas = $('#network-canvas');
  const context = canvas.getContext('2d');
  if (!context || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  let width = 0, height = 0, frame = 0, pointer = { x: -1000, y: -1000 };
  const points = Array.from({ length: 54 }, (_, index) => ({
    x: Math.random(),
    y: Math.random(),
    vx: (Math.random() - .5) * .00016,
    vy: (Math.random() - .5) * .00016,
    phase: index * .83
  }));
  const resize = () => { const dpr = Math.min(devicePixelRatio || 1, 2); width = innerWidth; height = innerHeight; canvas.width = width * dpr; canvas.height = height * dpr; canvas.style.width = `${width}px`; canvas.style.height = `${height}px`; context.setTransform(dpr, 0, 0, dpr, 0, 0); };
  addEventListener('resize', resize); resize();
  addEventListener('pointermove', event => { pointer = { x: event.clientX, y: event.clientY }; });
  const draw = () => {
    frame += .008;
    context.clearRect(0, 0, width, height);
    points.forEach(point => { point.x = (point.x + point.vx + 1) % 1; point.y = (point.y + point.vy + 1) % 1; });
    for (let i = 0; i < points.length; i++) for (let j = i + 1; j < points.length; j++) {
      const ax = points[i].x * width, ay = points[i].y * height, bx = points[j].x * width, by = points[j].y * height;
      const distance = Math.hypot(ax - bx, ay - by);
      if (distance < 165) {
        context.strokeStyle = `rgba(111, 178, 145, ${.12 * (1 - distance / 165)})`;
        context.lineWidth = .6;
        context.beginPath();
        context.moveTo(ax, ay);
        context.lineTo(bx, by);
        context.stroke();
      }
    }
    points.forEach(point => {
      const x = point.x * width, y = point.y * height;
      const pointerDistance = Math.hypot(x - pointer.x, y - pointer.y);
      const pulse = (Math.sin(frame + point.phase) + 1) * .35;
      const size = pointerDistance < 150 ? 2.4 + pulse : .8 + pulse;
      context.fillStyle = pointerDistance < 130 ? 'rgba(159,247,200,.82)' : 'rgba(180,195,187,.32)';
      context.beginPath();
      context.arc(x, y, size, 0, Math.PI * 2);
      context.fill();
    });
    requestAnimationFrame(draw);
  };
  draw();
}

function bindMotion() {
  const halo = $('#cursor-halo');
  const coordinates = $('#pointer-coordinates');
  let haloFrame = 0;
  addEventListener('pointermove', event => {
    coordinates.textContent = `X ${String(Math.round(event.clientX)).padStart(4, '0')} / Y ${String(Math.round(event.clientY)).padStart(4, '0')}`;
    if (matchMedia('(pointer: coarse)').matches) return;
    cancelAnimationFrame(haloFrame);
    haloFrame = requestAnimationFrame(() => {
      halo.style.left = `${event.clientX}px`;
      halo.style.top = `${event.clientY}px`;
      halo.style.opacity = '1';
    });
  });
  document.documentElement.addEventListener('mouseleave', () => { halo.style.opacity = '0'; });
  $$('.magnetic').forEach(button => {
    button.addEventListener('pointermove', event => { const box = button.getBoundingClientRect(); button.style.transform = `translate(${(event.clientX - box.left - box.width / 2) * .08}px, ${(event.clientY - box.top - box.height / 2) * .08}px)`; });
    button.addEventListener('pointerleave', () => { button.style.transform = ''; });
  });
  const panel = $('#terminal-panel');
  panel.addEventListener('pointermove', event => { const box = panel.getBoundingClientRect(); const rx = ((event.clientY - box.top) / box.height - .5) * -1.1; const ry = ((event.clientX - box.left) / box.width - .5) * 1.1; panel.style.transform = `perspective(1200px) rotateX(${rx}deg) rotateY(${ry}deg)`; });
  panel.addEventListener('pointerleave', () => { panel.style.transform = ''; });
}

bindEvents();
startClock();
startNetworkCanvas();
bindMotion();
loadState().catch(error => toast(friendlyError(error), 'error'));
