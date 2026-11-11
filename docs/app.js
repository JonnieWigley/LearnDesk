'use strict';

// LearnDesk for the phone. Everything is kept on this device and synced with
// your own Supabase project. There are no API keys here: the Mac app writes the
// quiz questions, and answers on the phone are self-graded.

// ---------- storage ----------

const KEYS = { data: 'learndesk.data', config: 'learndesk.config', session: 'learndesk.session' };
const ARRAYS = { idea: 'ideas', entry: 'entries', card: 'cards', todo: 'todos' };
const COLORS = ['red', 'orange', 'yellow', 'green', 'blue', 'purple', 'pink'];
const GRADES = ['Again', 'Hard', 'Good', 'Easy'];

function read(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw === null ? fallback : JSON.parse(raw);
  } catch {
    return fallback;
  }
}

function write(key, value) {
  try {
    if (value === null || value === undefined) localStorage.removeItem(key);
    else localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch {
    return false;
  }
}

const data = Object.assign({ ideas: [], entries: [], cards: [], todos: [], tombstones: [] }, read(KEYS.data, {}));
let config = Object.assign({ url: '', anonKey: '', email: '' }, read(KEYS.config, {}));
let session = read(KEYS.session, null);

function saveData() {
  if (!write(KEYS.data, data)) ui.notice = "Couldn't save on this device. Storage may be full or blocked.";
}

// ---------- helpers ----------

const nowISO = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z'); // the Mac app reads dates without milliseconds
const newID = () => crypto.randomUUID();
const byCreated = (a, b) => (a.created < b.created ? 1 : a.created > b.created ? -1 : 0);
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const dateText = (iso) => new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });

function h(tag, props, ...children) {
  const el = document.createElement(tag);
  for (const [name, value] of Object.entries(props || {})) {
    if (value === undefined || value === null || value === false) continue;
    if (name === 'class') el.className = value;
    else if (name.startsWith('on')) el.addEventListener(name.slice(2), value);
    else if (name in el && name !== 'list') el[name] = value;
    else el.setAttribute(name, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

// ---------- local changes ----------

function touch(item) {
  item.modified = Date.now();
  saveData();
  scheduleSync();
}

function add(kind, item) {
  item.modified = Date.now();
  data[ARRAYS[kind]].unshift(item);
  saveData();
  scheduleSync();
  return item;
}

function remove(kind, id) {
  const list = data[ARRAYS[kind]];
  const index = list.findIndex((item) => item.id === id);
  if (index < 0) return;
  list.splice(index, 1);
  data.tombstones.push({ id, kind, modified: Date.now() });
  saveData();
  scheduleSync();
}

function removeEntry(id) {
  for (const card of data.cards.filter((c) => c.entryID === id)) remove('card', card.id);
  remove('entry', id);
}

// Same scheme as the Mac app: a simplified SM-2.
function reviewCard(card, grade) {
  const now = Date.now();
  card.lastReviewed = nowISO();
  if (grade === 0) {
    card.reps = 0;
    card.lapses += 1;
    card.ease = Math.max(1.3, card.ease - 0.2);
    card.intervalDays = 0;
    card.due = new Date(now + 10 * 60 * 1000).toISOString().replace(/\.\d+Z$/, 'Z');
  } else {
    if (grade === 1) {
      card.intervalDays = Math.max(1, card.intervalDays * 1.2);
      card.ease = Math.max(1.3, card.ease - 0.15);
    } else if (grade === 2) {
      card.intervalDays = card.reps === 0 ? 1 : card.reps === 1 ? 3 : card.intervalDays * card.ease;
    } else {
      card.intervalDays = card.reps === 0 ? 3 : Math.max(4, card.intervalDays * card.ease * 1.3);
      card.ease += 0.15;
    }
    card.reps += 1;
    card.due = new Date(now + card.intervalDays * 86400000).toISOString().replace(/\.\d+Z$/, 'Z');
  }
  touch(card);
}

const dueCards = () => data.cards.filter((c) => new Date(c.due) <= new Date()).sort((a, b) => (a.due < b.due ? -1 : 1));

// ---------- sync (Supabase) ----------

const sync = { busy: false, again: false, state: 'off', message: '', timer: null };

const supabaseReady = () => Boolean(config.url && config.anonKey && session);

async function supabase(path, options = {}, token) {
  const response = await fetch(config.url + path, {
    ...options,
    headers: {
      apikey: config.anonKey,
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(options.headers || {}),
    },
  });
  if (!response.ok) {
    let detail = `HTTP ${response.status}`;
    try {
      const body = await response.json();
      detail = body.msg || body.message || body.error_description || body.error || detail;
    } catch { /* keep the status */ }
    const error = new Error(detail);
    error.status = response.status;
    throw error;
  }
  return response.status === 204 ? null : response.json().catch(() => null);
}

function storeSession(body) {
  session = {
    accessToken: body.access_token,
    refreshToken: body.refresh_token,
    expiresAt: Date.now() + (body.expires_in || 3600) * 1000,
  };
  write(KEYS.session, session);
}

async function signIn(email, password) {
  const body = await supabase('/auth/v1/token?grant_type=password', { method: 'POST', body: JSON.stringify({ email, password }) });
  storeSession(body);
}

function signOut() {
  session = null;
  write(KEYS.session, null);
  setSync('off', '');
}

async function accessToken() {
  if (session.expiresAt - Date.now() > 60000) return session.accessToken;
  try {
    const body = await supabase('/auth/v1/token?grant_type=refresh_token', {
      method: 'POST',
      body: JSON.stringify({ refresh_token: session.refreshToken }),
    });
    storeSession(body);
    return session.accessToken;
  } catch (error) {
    if (error.status >= 400 && error.status < 500) {
      signOut();
      throw new Error('Signed out. Sign in again in Settings.');
    }
    throw error;
  }
}

async function fetchAllRows(token) {
  const rows = [];
  for (let offset = 0; ; offset += 1000) {
    const page = await supabase(`/rest/v1/items?select=id,kind,data,modified,deleted&order=id.asc&limit=1000&offset=${offset}`, {}, token);
    rows.push(...page);
    if (page.length < 1000) return rows;
  }
}

function localIndex() {
  const index = new Map();
  for (const [kind, name] of Object.entries(ARRAYS)) {
    for (const item of data[name]) index.set(item.id, { kind, modified: item.modified || 0, deleted: false, item });
  }
  for (const stone of data.tombstones) index.set(stone.id, { kind: stone.kind, modified: stone.modified, deleted: true });
  return index;
}

function applyRemote(row) {
  const name = ARRAYS[row.kind];
  if (!name) return; // a kind this version doesn't know about
  data[name] = data[name].filter((item) => item.id !== row.id);
  data.tombstones = data.tombstones.filter((stone) => stone.id !== row.id);
  if (row.deleted) {
    data.tombstones.push({ id: row.id, kind: row.kind, modified: row.modified });
    return;
  }
  const item = { ...row.data, id: row.id, modified: row.modified };
  if (item.entryID) item.entryID = String(item.entryID).toLowerCase();
  data[name].push(item);
}

async function runSync() {
  if (!supabaseReady()) return;
  if (sync.busy) { sync.again = true; return; }
  sync.busy = true;
  setSync('busy', 'Syncing');
  try {
    const token = await accessToken();
    const remote = await fetchAllRows(token);
    const remoteByID = new Map(remote.map((row) => [row.id, row]));

    // Whichever side changed an item most recently wins.
    const before = localIndex();
    let changed = false;
    for (const row of remote) {
      const mine = before.get(row.id);
      if (!mine || row.modified > mine.modified) { applyRemote(row); changed = true; }
    }
    if (changed) {
      data.ideas.sort(byCreated);
      data.entries.sort(byCreated);
      data.todos.sort(byCreated);
      saveData();
    }

    const outgoing = [];
    for (const [id, mine] of localIndex()) {
      const theirs = remoteByID.get(id);
      if (theirs && theirs.modified >= mine.modified) continue;
      outgoing.push({ id, kind: mine.kind, data: mine.deleted ? {} : mine.item, modified: mine.modified, deleted: mine.deleted });
    }
    for (let i = 0; i < outgoing.length; i += 500) {
      await supabase('/rest/v1/items?on_conflict=id', {
        method: 'POST',
        headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
        body: JSON.stringify(outgoing.slice(i, i + 500)),
      }, token);
    }
    setSync('ok', 'Synced');
    if (changed) renderWhenIdle();
  } catch (error) {
    setSync('err', navigator.onLine === false ? 'Offline' : 'Sync failed');
    sync.message = error.message;
  } finally {
    sync.busy = false;
    if (sync.again) { sync.again = false; scheduleSync(); }
  }
}

function scheduleSync() {
  clearTimeout(sync.timer);
  sync.timer = setTimeout(runSync, 1500);
}

function setSync(state, text) {
  sync.state = state;
  sync.message = '';
  document.getElementById('sync-dot').className = state;
  document.getElementById('sync-text').textContent = text;
}

// ---------- interface state ----------

const TABS = [['ideas', 'Ideas'], ['journal', 'Journal'], ['quiz', 'Quiz'], ['todo', 'To Do'], ['settings', 'Settings']];

const ui = {
  tab: 'ideas',
  notice: '',
  ideaFilter: 'create',
  todoFilter: 'open',
  expanded: new Set(),
  editing: null, // id of the journal entry loaded into the form
  setAside: null,
  drafts: { idea: '', todo: '', topic: '', journal: '' },
  quiz: { queue: [], phase: 'answering', answer: '', answered: 0 },
  settingsMessage: '',
  pendingRender: false,
};

function renderWhenIdle() {
  const active = document.activeElement;
  if (active && ['INPUT', 'TEXTAREA', 'SELECT'].includes(active.tagName)) ui.pendingRender = true;
  else render();
}

document.addEventListener('focusout', () => {
  setTimeout(() => {
    if (!ui.pendingRender) return;
    const active = document.activeElement;
    if (active && ['INPUT', 'TEXTAREA', 'SELECT'].includes(active.tagName)) return;
    render();
  }, 0);
});

function toggleExpanded(id) {
  if (ui.expanded.has(id)) ui.expanded.delete(id);
  else ui.expanded.add(id);
  render();
}

function segmented(options, current, onPick) {
  return h('div', { class: 'seg' }, options.map(([value, label]) =>
    h('button', { type: 'button', 'aria-pressed': String(value === current), onclick: () => onPick(value) }, label)));
}

function checkButton(done, onToggle) {
  return h('button', {
    type: 'button', class: `check${done ? ' on' : ''}`,
    'aria-label': done ? 'Mark as open' : 'Mark as complete', onclick: onToggle,
  }, done ? '✓' : '');
}

// Wraps a list card so that swiping it left deletes it. A short swipe springs back;
// the card has to be dragged past the threshold (the red strip turns solid) to delete.
function swipeToDelete(card, onDelete) {
  const wrap = h('div', { class: 'swipe' }, h('div', { class: 'swipe-under', 'aria-hidden': 'true' }, 'Delete'), card);
  let pointer = null;
  let mode = null; // null: undecided, 'swipe': ours, 'ignore': a scroll or a rightward drag
  let startX = 0;
  let startY = 0;
  let dx = 0;
  let justSwiped = false;
  const threshold = () => Math.min(140, wrap.offsetWidth * 0.4);

  card.addEventListener('pointerdown', (e) => {
    if (e.pointerType === 'mouse' || e.target.closest('input, textarea, select')) return;
    pointer = e.pointerId;
    mode = null;
    startX = e.clientX;
    startY = e.clientY;
    dx = 0;
  });

  card.addEventListener('pointermove', (e) => {
    if (e.pointerId !== pointer) return;
    const moveX = e.clientX - startX;
    const moveY = e.clientY - startY;
    if (!mode) {
      if (Math.abs(moveX) < 10 && Math.abs(moveY) < 10) return;
      mode = moveX < 0 && Math.abs(moveX) > Math.abs(moveY) ? 'swipe' : 'ignore';
      if (mode === 'swipe') {
        try { card.setPointerCapture(pointer); } catch { /* the pointer already ended */ }
        card.style.transition = '';
        wrap.classList.add('swiping');
      }
    }
    if (mode !== 'swipe') return;
    dx = Math.min(0, moveX);
    card.style.transform = `translateX(${dx}px)`;
    wrap.classList.toggle('armed', -dx >= threshold());
  });

  const finish = (e) => {
    if (e.pointerId !== pointer) return;
    pointer = null;
    if (mode !== 'swipe') return;
    mode = null;
    justSwiped = true;
    setTimeout(() => { justSwiped = false; }, 350);
    card.style.transition = 'transform .18s ease';
    if (e.type === 'pointerup' && -dx >= threshold()) {
      card.style.transform = 'translateX(-110%)';
      setTimeout(() => { onDelete(); render(); }, 180);
    } else {
      card.style.transform = '';
      wrap.classList.remove('armed');
      setTimeout(() => { wrap.classList.remove('swiping'); card.style.transition = ''; }, 180);
    }
  };
  card.addEventListener('pointerup', finish);
  card.addEventListener('pointercancel', finish);

  // The tap that ends a swipe shouldn't also open the card or tick it off.
  wrap.addEventListener('click', (e) => {
    if (!justSwiped) return;
    e.stopPropagation();
    e.preventDefault();
  }, true);

  return wrap;
}

// ---------- Ideas ----------

function addIdea() {
  const title = ui.drafts.idea.trim();
  const kind = IDEA_KINDS[ui.ideaFilter];
  if (!title || !kind) return;
  add('idea', { id: newID(), title, note: '', kind, done: false, created: nowISO() });
  ui.drafts.idea = '';
  render();
}

// The Create and Research headers are also where new ideas get added.
const IDEA_KINDS = { create: 'Create', research: 'Research' };

function viewIdeas() {
  const visible = data.ideas.filter((idea) => {
    if (ui.ideaFilter === 'done') return idea.done;
    if (ui.ideaFilter === 'open') return !idea.done;
    return !idea.done && idea.kind.toLowerCase() === ui.ideaFilter;
  });
  const kind = IDEA_KINDS[ui.ideaFilter];

  return [
    segmented([['create', 'Create'], ['research', 'Research'], ['open', 'Open'], ['done', 'Complete']], ui.ideaFilter,
      (value) => { ui.ideaFilter = value; render(); }),
    kind && h('div', { class: 'row gap-below' },
      h('input', {
        type: 'text', class: 'grow', placeholder: `Add to ${kind}…`, value: ui.drafts.idea, enterKeyHint: 'done', 'aria-label': `New ${kind} idea`,
        oninput: (e) => { ui.drafts.idea = e.target.value; },
        onkeydown: (e) => { if (e.key === 'Enter') addIdea(); },
      }),
      h('button', { type: 'button', class: 'icon', 'aria-label': 'Add idea', onclick: addIdea }, '+')),
    visible.length === 0 && h('p', { class: 'muted center' }, ui.ideaFilter === 'done' ? 'Nothing completed yet.' : 'Nothing added here yet.'),
    visible.map(ideaCard),
  ];
}

function ideaCard(idea) {
  const open = ui.expanded.has(idea.id);
  const card = h('div', { class: `card stack${idea.color ? ' tint' : ''}` },
    h('div', { class: 'row top' },
      checkButton(idea.done, () => { idea.done = !idea.done; touch(idea); render(); }),
      h('div', { class: `grow pre${idea.done ? ' done-text' : ''}`, onclick: () => toggleExpanded(idea.id) }, idea.title),
      h('span', { class: 'tag' }, idea.kind)),
    open && h('textarea', {
      placeholder: 'Notes', value: idea.note || '', 'aria-label': 'Notes',
      onchange: (e) => { idea.note = e.target.value; touch(idea); },
    }),
    open && h('div', { class: 'swatches' },
      [null, ...COLORS].map((color) => {
        const swatch = h('button', {
          type: 'button', class: `swatch${(idea.color || null) === color ? ' on' : ''}`,
          'aria-label': color ? `Colour ${color}` : 'No colour',
          onclick: () => { if (color) idea.color = color; else delete idea.color; touch(idea); render(); },
        }, color ? '' : '×');
        swatch.style.setProperty('--tint', color ? `var(--${color})` : 'transparent');
        return swatch;
      })),
    open && h('div', { class: 'row' },
      h('span', { class: 'muted small' }, `Added ${dateText(idea.created)}`),
      h('button', { type: 'button', class: 'btn sm danger right', onclick: () => { remove('idea', idea.id); render(); } }, 'Delete')),
    !open && idea.note && h('div', { class: 'muted small clamp pre' }, idea.note));
  if (idea.color) card.style.setProperty('--tint', `var(--${idea.color})`);
  return swipeToDelete(card, () => remove('idea', idea.id));
}

// ---------- Journal ----------

function logEntry() {
  const topic = ui.drafts.topic.trim();
  const text = ui.drafts.journal.trim();
  if (!topic || !text) return;
  // needsQuestions asks the Mac app to write quiz questions the next time it syncs.
  add('entry', { id: newID(), topic, text, created: nowISO(), needsQuestions: true });
  ui.drafts.topic = '';
  ui.drafts.journal = '';
  render();
}

// Tapping an entry loads it into the form at the top for editing. Anything half-typed
// there is set aside and put back when the edit is saved or cancelled.
function editEntry(entry) {
  if (ui.editing === entry.id) return;
  if (!ui.editing) ui.setAside = { topic: ui.drafts.topic, journal: ui.drafts.journal };
  ui.editing = entry.id;
  ui.drafts.topic = entry.topic;
  ui.drafts.journal = entry.text;
  render();
  document.getElementById('main').scrollTop = 0;
}

function endEdit() {
  ui.editing = null;
  ui.drafts.topic = ui.setAside ? ui.setAside.topic : '';
  ui.drafts.journal = ui.setAside ? ui.setAside.journal : '';
  ui.setAside = null;
}

function saveEntryEdit() {
  const entry = data.entries.find((e) => e.id === ui.editing);
  const topic = ui.drafts.topic.trim();
  const text = ui.drafts.journal.trim();
  if (!entry || !topic || !text) return;
  if (topic !== entry.topic || text !== entry.text) {
    // Questions already written from this entry are kept; they just follow a renamed topic.
    if (topic !== entry.topic) {
      for (const card of data.cards.filter((c) => c.entryID === entry.id)) { card.topic = topic; touch(card); }
    }
    entry.topic = topic;
    entry.text = text;
    touch(entry);
  }
  endEdit();
  render();
}

function viewJournal() {
  // The entry being edited may have been deleted here or on the Mac in the meantime.
  if (ui.editing && !data.entries.some((e) => e.id === ui.editing)) endEdit();
  const editing = Boolean(ui.editing);
  return [
    h('div', { class: 'stack' },
      editing && h('div', { class: 'label' }, 'Editing an earlier entry'),
      h('input', {
        type: 'text', placeholder: 'Topic, e.g. C#', value: ui.drafts.topic, autocomplete: 'off', 'aria-label': 'Topic',
        oninput: (e) => { ui.drafts.topic = e.target.value; },
      }),
      h('textarea', {
        placeholder: 'What did you learn?', value: ui.drafts.journal, 'aria-label': 'What did you learn?',
        oninput: (e) => { ui.drafts.journal = e.target.value; },
      }),
      editing
        ? h('div', { class: 'row' },
          h('span', { class: 'muted small grow' }, 'Questions already written stay as they are.'),
          h('button', { type: 'button', class: 'btn', onclick: () => { endEdit(); render(); } }, 'Cancel'),
          h('button', { type: 'button', class: 'btn primary', onclick: saveEntryEdit }, 'Save'))
        : h('div', { class: 'row' },
          h('span', { class: 'muted small grow' }, 'Your Mac writes the quiz questions when it next syncs.'),
          h('button', { type: 'button', class: 'btn primary right', onclick: logEntry }, 'Log'))),
    data.entries.length === 0 && h('p', { class: 'muted center' }, 'No entries yet.'),
    data.entries.map(entryCard),
  ];
}

function entryCard(entry) {
  const open = ui.expanded.has(entry.id);
  const count = data.cards.filter((c) => c.entryID === entry.id).length;
  const status = count ? plural(count, 'question') : entry.needsQuestions ? 'Waiting for your Mac' : '';
  return swipeToDelete(h('div', {
    class: `card stack${ui.editing === entry.id ? ' editing' : ''}`,
    // Tap anywhere on the entry to edit it; the buttons inside keep their own jobs.
    onclick: (e) => { if (!e.target.closest('button')) editEntry(entry); },
  },
    h('div', { class: 'row' },
      h('span', { class: 'tag' }, entry.topic),
      h('span', { class: 'muted small' }, dateText(entry.created)),
      h('span', { class: 'muted small right' }, status)),
    h('div', { class: `pre${open ? '' : ' clamp'}` }, entry.text),
    h('div', { class: 'row' },
      h('button', { type: 'button', class: 'link', onclick: () => toggleExpanded(entry.id) }, open ? 'Less' : 'More'),
      open && h('button', { type: 'button', class: 'btn sm danger right', onclick: () => { removeEntry(entry.id); render(); } }, 'Delete'))),
  () => removeEntry(entry.id));
}

// ---------- Quiz ----------

const quiz = ui.quiz;

function quizCurrent() {
  while (quiz.queue.length && !data.cards.some((c) => c.id === quiz.queue[0])) quiz.queue.shift();
  return data.cards.find((c) => c.id === quiz.queue[0]) || null;
}

function quizReset() {
  Object.assign(quiz, { phase: 'answering', answer: '' });
}

function quizStart(ids) {
  quiz.queue = ids;
  quiz.answered = 0;
  quizReset();
  render();
}

function quizRate(card, grade) {
  reviewCard(card, grade);
  quiz.queue.shift();
  if (grade === 0) quiz.queue.push(card.id); // ask it again before the session ends
  else quiz.answered += 1;
  quizReset();
  render();
}

function viewQuiz() {
  const card = quizCurrent();
  if (!card) {
    const due = dueCards().length;
    const total = data.cards.length;
    if (total === 0) {
      return h('div', { class: 'center stack' },
        h('h2', null, 'No questions yet'),
        h('p', { class: 'muted' }, 'Log something in the Journal and questions will be written from it.'));
    }
    return h('div', { class: 'center stack' },
      quiz.answered > 0 && h('p', { class: 'muted' }, `${plural(quiz.answered, 'question')} answered.`),
      h('h2', null, due === 0 ? 'Nothing due right now' : `${plural(due, 'question')} due`),
      h('div', { class: 'row' },
        h('button', { type: 'button', class: 'btn primary grow', disabled: due === 0, onclick: () => quizStart(dueCards().map((c) => c.id)) }, 'Start due'),
        h('button', {
          type: 'button', class: 'btn grow',
          onclick: () => quizStart([...data.cards].sort(() => Math.random() - 0.5).slice(0, 5).map((c) => c.id)),
        }, '5 at random')),
      h('p', { class: 'muted small' }, `${plural(total, 'question')} in total`));
  }

  return [
    h('div', { class: 'row' },
      h('span', { class: 'tag' }, card.topic),
      h('span', { class: 'muted small right' }, `${quiz.queue.length} left`),
      h('button', { type: 'button', class: 'btn sm', onclick: () => quizStart([]) }, 'End')),
    h('div', { class: 'card pre' }, card.question),
    h('textarea', {
      placeholder: 'Your answer (for your own comparison)', value: quiz.answer, disabled: quiz.phase !== 'answering', 'aria-label': 'Your answer',
      oninput: (e) => { quiz.answer = e.target.value; },
    }),
    quiz.phase === 'answering' && h('div', { class: 'row' },
      h('button', { type: 'button', class: 'btn primary', onclick: () => { quiz.phase = 'reviewed'; render(); } }, 'Show answer'),
      h('button', { type: 'button', class: 'link right', onclick: () => { quiz.queue.shift(); quizReset(); render(); } }, 'Skip')),
    quiz.phase === 'reviewed' && [
      h('div', { class: 'card' }, h('div', { class: 'label' }, 'Model answer'), h('div', { class: 'pre' }, card.answer)),
      h('p', { class: 'muted small' }, 'How well did you know it?'),
      h('div', { class: 'row' }, GRADES.map((label, grade) =>
        h('button', { type: 'button', class: 'btn grow', onclick: () => quizRate(card, grade) }, label))),
      h('button', {
        type: 'button', class: 'link',
        onclick: () => { remove('card', card.id); quizReset(); render(); },
      }, 'Delete this question'),
    ],
  ];
}

// ---------- To Do ----------

function addTodo() {
  const title = ui.drafts.todo.trim();
  if (!title) return;
  add('todo', { id: newID(), title, done: false, created: nowISO() });
  ui.drafts.todo = '';
  ui.todoFilter = 'open';
  render();
}

function viewTodo() {
  let visible = data.todos.filter((todo) => todo.done === (ui.todoFilter === 'done'));
  if (ui.todoFilter === 'open') {
    // Dated items first, soonest at the top.
    visible = [...visible].sort((a, b) => {
      if (a.due && b.due) return a.due < b.due ? -1 : 1;
      if (a.due) return -1;
      if (b.due) return 1;
      return byCreated(a, b);
    });
  }
  const startOfToday = new Date(new Date().toDateString());

  return [
    h('div', { class: 'row' },
      h('input', {
        type: 'text', class: 'grow', placeholder: 'Add a to-do…', value: ui.drafts.todo, enterKeyHint: 'done', 'aria-label': 'New to-do',
        oninput: (e) => { ui.drafts.todo = e.target.value; },
        onkeydown: (e) => { if (e.key === 'Enter') addTodo(); },
      }),
      h('button', { type: 'button', class: 'icon', 'aria-label': 'Add to-do', onclick: addTodo }, '+')),
    segmented([['open', 'Open'], ['done', 'Complete']], ui.todoFilter, (value) => { ui.todoFilter = value; render(); }),
    visible.length === 0 && h('p', { class: 'muted center' }, ui.todoFilter === 'done' ? 'Nothing completed yet.' : 'Nothing to do.'),
    visible.map((todo) => {
      const open = ui.expanded.has(todo.id);
      const overdue = todo.due && !todo.done && new Date(todo.due) < startOfToday;
      const dueValue = todo.due ? new Date(new Date(todo.due).getTime() - new Date(todo.due).getTimezoneOffset() * 60000).toISOString().slice(0, 10) : '';
      return swipeToDelete(h('div', { class: 'card stack' },
        h('div', { class: 'row top' },
          checkButton(todo.done, () => { todo.done = !todo.done; touch(todo); render(); }),
          h('div', { class: `grow pre${todo.done ? ' done-text' : ''}`, onclick: () => toggleExpanded(todo.id) }, todo.title),
          todo.due && h('span', { class: `small ${overdue ? 'overdue' : 'muted'}` }, dateText(todo.due))),
        open && h('div', { class: 'row' },
          h('input', {
            type: 'date', class: 'grow', value: dueValue, 'aria-label': 'Due date',
            onchange: (e) => {
              if (e.target.value) todo.due = new Date(`${e.target.value}T12:00:00`).toISOString().replace(/\.\d+Z$/, 'Z');
              else delete todo.due;
              touch(todo);
              ui.pendingRender = true;
            },
          }),
          h('button', { type: 'button', class: 'btn sm danger', onclick: () => { remove('todo', todo.id); render(); } }, 'Delete'))),
      () => remove('todo', todo.id));
    }),
  ];
}

// ---------- Settings ----------

function viewSettings() {
  const fields = { url: config.url, anonKey: config.anonKey, email: config.email, password: '' };

  async function connect() {
    const url = fields.url.trim().replace(/\/+$/, '');
    if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(url)) {
      ui.settingsMessage = 'The project URL should look like https://abcdefgh.supabase.co';
      return render();
    }
    config = { ...config, url, anonKey: fields.anonKey.trim(), email: fields.email.trim() };
    write(KEYS.config, config);
    ui.settingsMessage = 'Signing in…';
    render();
    try {
      await signIn(config.email, fields.password);
      ui.settingsMessage = '';
      render();
      runSync();
    } catch (error) {
      ui.settingsMessage = `Couldn't sign in: ${error.message}`;
      render();
    }
  }

  return [
    h('div', { class: 'card stack' },
      h('h2', null, 'Sync'),
      session
        ? [
          h('p', null, `Signed in as ${config.email}.`),
          sync.message && h('p', { class: 'error' }, sync.message),
          h('div', { class: 'row' },
            h('button', { type: 'button', class: 'btn', onclick: runSync }, 'Sync now'),
            h('button', { type: 'button', class: 'btn', onclick: () => { signOut(); render(); } }, 'Sign out')),
        ]
        : [
          h('p', { class: 'muted small' }, 'Connect to your Supabase project to share ideas, journal, questions and to-dos with your Mac. Until then everything stays on this phone.'),
          h('input', { type: 'url', placeholder: 'Project URL (https://….supabase.co)', value: fields.url, 'aria-label': 'Project URL', autocomplete: 'off', oninput: (e) => { fields.url = e.target.value; } }),
          h('input', { type: 'text', placeholder: 'Publishable (anon) key', value: fields.anonKey, 'aria-label': 'Publishable key', autocomplete: 'off', autocapitalize: 'off', oninput: (e) => { fields.anonKey = e.target.value; } }),
          h('input', { type: 'email', placeholder: 'Email', value: fields.email, 'aria-label': 'Email', autocomplete: 'username', oninput: (e) => { fields.email = e.target.value; } }),
          h('input', { type: 'password', placeholder: 'Password', 'aria-label': 'Password', autocomplete: 'current-password', oninput: (e) => { fields.password = e.target.value; } }),
          h('button', { type: 'button', class: 'btn primary', onclick: connect }, 'Sign in'),
        ],
      ui.settingsMessage && h('p', { class: 'small' }, ui.settingsMessage)),

    h('div', { class: 'card stack' },
      h('h2', null, 'Quizzes'),
      h('p', { class: 'muted small' }, 'Questions are written by the Mac app using your Claude subscription, then synced here. On the phone you reveal the model answer and rate yourself. No API key is stored on this phone.')),
  ];
}

// ---------- shell ----------

const VIEWS = { ideas: viewIdeas, journal: viewJournal, quiz: viewQuiz, todo: viewTodo, settings: viewSettings };

function render() {
  ui.pendingRender = false;
  const due = dueCards().length;
  document.getElementById('nav').replaceChildren(...TABS.map(([id, label]) =>
    h('button', {
      type: 'button', 'aria-current': ui.tab === id ? 'page' : null,
      onclick: () => { ui.tab = id; render(); document.getElementById('main').scrollTop = 0; },
    }, id === 'quiz' && due ? `${label} (${due})` : label)));

  const main = document.getElementById('main');
  const scroll = main.scrollTop;
  const content = [].concat(VIEWS[ui.tab]()).flat(Infinity).filter(Boolean);
  if (ui.notice) content.unshift(h('p', { class: 'error' }, ui.notice));
  main.replaceChildren(...content);
  main.scrollTop = scroll;
}

document.getElementById('sync').addEventListener('click', () => {
  if (supabaseReady()) runSync();
  else { ui.tab = 'settings'; render(); }
});
document.addEventListener('visibilitychange', () => { if (!document.hidden) { runSync(); renderWhenIdle(); } });
window.addEventListener('online', runSync);
setInterval(runSync, 60000);

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});

setSync(supabaseReady() ? 'ok' : 'off', supabaseReady() ? '' : 'Not synced');
render();
runSync();
