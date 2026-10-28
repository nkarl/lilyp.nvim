import {createInspectorView} from './inspector.js';
import {containsCenter, pitchLabel, possibleChords} from './group.js';

const main = document.querySelector('main');
const status = document.querySelector('#status');
const scoreState = document.querySelector('#score-state');
const pageCount = document.querySelector('#page-count');
const detailsButton = document.querySelector('#show-details');
const help = document.querySelector('#viewer-help');
const inspector = document.querySelector('#source-inspector');
const inspectorView = createInspectorView(inspector);
const state = {
  revision: '', navigationHighlight: null, navigationSequence: -1, revealSequence: 0,
  connection: 'connecting', connectionError: '', feedback: '',
  stale: false, dirty: false, selection: null, inspection: {hover: null, expanded: null},
};
const originCache = new Map();
const requests = {hover: null, expanded: null};
let gesture = null, suppressClick = false, groupSequence = 0, pointerPosition = null;
const selectionArea = document.querySelector('#selection-area');
let hoverTimer = null, navigationTicket = 0, feedbackTimer = null;

function renderStatus() {
  const condition = state.connection === 'disconnected' ? 'disconnected' : !state.revision ? 'loading'
    : state.stale ? 'stale' : state.dirty ? 'dirty' : 'current';
  const labels = {loading: 'Loading score', current: 'Up to date', dirty: 'Unsaved changes', stale: 'Source changed', disconnected: 'Disconnected'};
  scoreState.dataset.state = condition;
  if (scoreState.textContent !== labels[condition]) scoreState.textContent = labels[condition];
  scoreState.title = condition === 'disconnected' ? state.connectionError : '';
  const count = main.children.length;
  const pages = count ? `${count} page${count === 1 ? '' : 's'}` : '';
  if (pageCount.textContent !== pages) pageCount.textContent = pages;
  const messages = {
    loading: 'Connecting to Neovim…', current: 'Click a symbol for details · F7 in Neovim to find a symbol',
    dirty: 'Save, then press F5 in Neovim to update the score',
    stale: 'Press F5 in Neovim to update the score',
    disconnected: state.revision ? 'Reconnecting · showing the last build' : 'Reconnecting to Neovim…',
  };
  const message = condition === 'disconnected' ? messages.disconnected : state.feedback || messages[condition];
  if (status.textContent !== message) status.textContent = message;
}
function feedback(message) {
  clearTimeout(feedbackTimer); state.feedback = message; renderStatus();
  feedbackTimer = setTimeout(() => { state.feedback = ''; renderStatus(); }, 4000);
}

// Transport is shared; action functions decide what each response may change.
async function post(route, revision, key, signal) {
  const response = await fetch(route, {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({revision, key}), signal});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error);
  return result;
}

function cancelInspection(lane) {
  requests[lane]?.abort();
  requests[lane] = null;
  if (lane === 'hover') { clearTimeout(hoverTimer); hoverTimer = null; }
}

function visibleInspection() {
  const group = state.selection;
  if (group?.open) return {key: group.id, note: group.notes[0], anchor: group.anchor,
    group, groupVersion: group.version, expanded: true};
  const hover = state.inspection.hover;
  if (hover?.note.isConnected && (hover.origin || hover.error)) return {...hover, expanded: false};
  const expanded = state.inspection.expanded;
  return expanded?.note.isConnected ? {...expanded, selection: expanded, expanded: true} : null;
}

function renderInspection() {
  const visible = visibleInspection();
  inspectorView.render(visible && {...visible, stale: state.stale, dirty: state.dirty});
  detailsButton.disabled = !state.selection && !state.inspection.expanded?.note.isConnected;
  detailsButton.setAttribute('aria-expanded', String(Boolean(visible?.expanded)));
}

function renderNavigation(scroll = false) {
  highlight(state.inspection.expanded?.key ?? state.navigationHighlight, scroll);
}

async function loadOrigin(entry, lane) {
  const revision = state.revision;
  const controller = new AbortController(); requests[lane] = controller;
  try {
    const result = await post('inspect', revision, entry.key, controller.signal);
    if (state.inspection[lane] !== entry || state.revision !== revision || !entry.note.isConnected) return;
    if (result.revision !== revision || result.key !== entry.key) return;
    if (!originCache.has(entry.key)) originCache.set(entry.key, result.origin);
    entry.origin = originCache.get(entry.key);
    state.stale = Boolean(result.stale); state.dirty = Boolean(result.dirty);
    renderInspection(); renderStatus();
  } catch (error) {
    if (error.name === 'AbortError' || state.inspection[lane] !== entry || state.revision !== revision) return;
    entry.error = error.message;
    renderInspection();
  } finally { if (requests[lane] === controller) requests[lane] = null; }
}

// Named actions keep musical selection, inspection and navigation separate.
const actions = {
  analysis: {
    analyzeSelection(notes) {
      const pitches = notes.map(note => Number(note.dataset.pitch));
      return pitches.some(pitch => !Number.isInteger(pitch)) ? {tag: 'unsupported'}
        : {tag: 'supported', candidates: possibleChords(pitches)};
    },
  },
  inspection: {
    preview(note, anchor) {
      actions.inspection.dismiss();
      const key = Number(note.dataset.note);
      const entry = {key, note, anchor, scrollX: window.scrollX, scrollY: window.scrollY, origin: null, error: null};
      state.inspection.hover = entry;
      outline('data-hover', key, 'var(--color-inspection-hover)', 'var(--inspection-hover-stroke)');
      hoverTimer = setTimeout(() => loadOrigin(entry, 'hover'), 250);
    },
    endPreview() {
      cancelInspection('hover');
      state.inspection.hover = null;
      main.querySelector('[data-hover]')?.remove();
      renderInspection();
    },
    expand(note, anchor) {
      const preview = state.inspection.hover;
      cancelInspection('hover'); cancelInspection('expanded');
      state.inspection.hover = null;
      main.querySelector('[data-hover]')?.remove();
      const key = Number(note.dataset.note);
      const entry = {key, note, scrollX: window.scrollX, scrollY: window.scrollY, anchor: preview?.key === key ? preview.anchor : anchor, origin: (preview?.key === key && preview.origin) || originCache.get(key) || null, error: null};
      state.inspection.expanded = entry;
      renderInspection(); renderNavigation();
      loadOrigin(entry, 'expanded');
    },
    dismiss() {
      const restoreFocus = inspector.contains(document.activeElement);
      if (state.selection) state.selection.open = false;
      cancelInspection('hover'); cancelInspection('expanded');
      state.inspection.hover = state.inspection.expanded = null;
      // Invalidate status effects of a pending click, not its editor operation.
      navigationTicket++;
      main.querySelector('[data-hover]')?.remove();
      renderInspection(); renderNavigation();
      if (restoreFocus) help.querySelector('summary').focus({preventScroll: true});
    },
    reopenSelection() {
      if (!state.selection) return;
      state.selection.open = true;
      actions.inspection.endPreview();
    },
    focus() {
      if (state.selection) actions.inspection.reopenSelection();
      else actions.inspection.endPreview();
      if (state.selection || state.inspection.expanded) inspector.focus({preventScroll: true});
    },
  },
  navigation: {
    async openSource(note) {
      const revision = state.revision, ticket = ++navigationTicket;
      try {
        await post('click', revision, Number(note.dataset.note));
        if (ticket === navigationTicket && revision === state.revision) feedback('Source opened in Neovim');
      } catch (error) {
        if (ticket === navigationTicket && revision === state.revision) feedback(error.message);
      }
    },
    revealInScore(key) {
      const note = main.querySelector(`[data-note="${key}"]`);
      if (!note) return;
      navigationTicket++;
      clearSelection();
      highlight(key, true);
      actions.inspection.expand(note);
    },
  },
};

// SVG presentation: decorations do not participate in source-object geometry.
function outline(attribute, key, color, width) {
  main.querySelector(`[${attribute}]`)?.remove();
  if (key === null) return null;
  const note = main.querySelector(`[data-note="${key}"]`);
  if (!note) return null;
  const decorations = [...note.querySelectorAll('[data-highlight], [data-hover]')];
  decorations.forEach(rect => rect.style.display = 'none');
  let box;
  try { box = note.getBBox(); }
  finally { decorations.forEach(rect => rect.style.removeProperty('display')); }
  const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
  for (const [name, value] of Object.entries({x: box.x - .5, y: box.y - .5,
    width: box.width + 1, height: box.height + 1, fill: 'none', stroke: color,
    'stroke-width': width, 'pointer-events': 'none', [attribute]: 'true'})) rect.setAttribute(name, value);
  note.append(rect);
  return note;
}

function highlight(key, scroll) {
  const note = outline('data-highlight', key, 'var(--color-inspection-active)', 'var(--inspection-active-stroke)');
  if (scroll && note) note.scrollIntoView({block: 'center', inline: 'nearest'});
}

function replacePages(pages) {
  const x = window.scrollX, y = window.scrollY;
  const anchor = [...main.querySelectorAll('[data-note]')].find(note => note.getBoundingClientRect().top >= 40);
  const anchorKey = anchor?.getAttribute('data-source'), offset = anchor?.getBoundingClientRect().top;
  main.replaceChildren(...pages.map(page => new DOMParser().parseFromString(page, 'image/svg+xml').documentElement));
  const replacement = anchorKey && [...main.querySelectorAll('[data-note]')].find(note => note.getAttribute('data-source') === anchorKey);
  window.scrollTo(x, replacement ? y + replacement.getBoundingClientRect().top - offset : y);
}

// Selection uses only compiler-tagged noteheads, never source-link geometry.
function noteheads() { return [...main.querySelectorAll('[data-measure]')]; }
function keyOf(note) {
  const source = note.querySelector('[data-note]');
  return source ? Number(source.dataset.note) : -Number(note.dataset.selectionIndex) - 1;
}
function decorateSelection(notes, geometry = noteheads().map(note => ({note}))) {
  main.querySelectorAll('[data-selection-region]').forEach(rect => rect.remove());
  const chosen = new Set(notes), pages = new Map();
  for (const {note, bounds} of geometry) {
    const selected = chosen.has(note);
    note.setAttribute('aria-pressed', String(selected));
    note.toggleAttribute('data-musical-selection', selected);
    if (!selected) continue;
    const page = note.closest('svg');
    if (!pages.has(page)) pages.set(page, []);
    pages.get(page).push(bounds || note.getBoundingClientRect());
  }
  const padding = parseFloat(getComputedStyle(main).getPropertyValue('--selection-padding'));
  for (const [page, bounds] of pages) {
    // Place the shared fill behind the music in the page's own coordinates.
    // It follows scrolling/zoom without covering ink or altering hit testing.
    const inverse = page.getScreenCTM().inverse();
    const topLeft = new DOMPoint(Math.min(...bounds.map(box => box.left)) - padding,
      Math.min(...bounds.map(box => box.top)) - padding).matrixTransform(inverse);
    const bottomRight = new DOMPoint(Math.max(...bounds.map(box => box.right)) + padding,
      Math.max(...bounds.map(box => box.bottom)) + padding).matrixTransform(inverse);
    const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    for (const [name, value] of Object.entries({x: topLeft.x, y: topLeft.y,
      width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y,
      'aria-hidden': 'true', 'data-selection-region': 'true'})) rect.setAttribute(name, value);
    page.prepend(rect);
  }
}
function cancelGesture() {
  gesture = null; selectionArea.hidden = true;
  decorateSelection(state.selection?.notes || []);
}
function clearSelection() {
  state.selection?.controller.abort(); state.selection = null;
  cancelGesture(); renderInspection();
}
async function loadGroup(group) {
  const keys = [...new Set(group.notes.map(keyOf).filter(key => Number.isInteger(key) && key >= 0))];
  // Fetch only selected notes, with bounded concurrency and a generation cache.
  let index = 0;
  await Promise.all(Array.from({length: Math.min(4, keys.length)}, async () => {
    while (index < keys.length && state.selection === group && !group.controller.signal.aborted) {
      const key = keys[index++];
      try {
        let origin = originCache.get(key);
        if (!origin) {
          const result = await post('inspect', group.revision, key, group.controller.signal);
          if (state.selection !== group || result.revision !== group.revision || result.key !== key) continue;
          origin = result.origin; originCache.set(key, origin);
          state.stale = Boolean(result.stale); state.dirty = Boolean(result.dirty);
        }
        if (state.selection === group) group.origins.set(key, origin);
      } catch (error) {
        if (error.name !== 'AbortError' && state.selection === group) group.errors.set(key, error.message);
      }
    }
  }));
  if (state.selection === group) { group.version++; renderInspection(); renderStatus(); }
}
function selectNotes(notes) {
  state.selection?.controller.abort(); state.selection = null;
  actions.inspection.dismiss();
  if (!notes.length) { decorateSelection([]); return; }
  // Printed order, then vertical position, rather than compiler emission order.
  const pages = [...main.children];
  notes.sort((a, b) => {
    const ar = a.getBoundingClientRect(), br = b.getBoundingClientRect();
    return pages.indexOf(a.closest('svg')) - pages.indexOf(b.closest('svg')) || ar.left - br.left || ar.top - br.top;
  });
  decorateSelection(notes);
  const areas = [...main.querySelectorAll('[data-selection-region]')].map(region => region.getBoundingClientRect());
  const anchor = {x: Math.min(...areas.map(area => area.left)), y: Math.max(...areas.map(area => area.bottom))};
  const group = {id: `group-${++groupSequence}`, revision: state.revision,
    notes, analysis: actions.analysis.analyzeSelection(notes), anchor, open: true, origins: new Map(), errors: new Map(),
    controller: new AbortController(), version: 0, keyOf};
  for (const note of notes) if (keyOf(note) < 0) group.errors.set(keyOf(note), 'Source preview unavailable. Press F5 in Neovim to rebuild.');
  state.selection = group;
  renderInspection(); loadGroup(group);
}
function prepareNoteheads() {
  for (const [index, note] of noteheads().entries()) {
    note.dataset.selectionIndex = index;
    note.tabIndex = 0; note.setAttribute('role', 'button'); note.setAttribute('aria-pressed', 'false');
    note.setAttribute('aria-label', `${pitchLabel(Number(note.dataset.pitch))}, measure ${note.dataset.measureNumber}. Press Space to select.`);
  }
}
function notehead(target) { const note = target?.closest?.('[data-measure]'); return note && main.contains(note) ? note : null; }
function updateGesture(event) {
  if (!gesture || gesture.pointerId !== event.pointerId) return;
  const threshold = parseFloat(getComputedStyle(main).getPropertyValue('--drag-threshold'));
  if (!gesture.dragging && Math.hypot(event.clientX - gesture.x, event.clientY - gesture.y) < threshold) return;
  if (!gesture.dragging) {
    gesture.dragging = true; suppressClick = true;
    main.setPointerCapture(event.pointerId);
    actions.inspection.dismiss();
  }
  const rectangle = {left: Math.min(gesture.x, event.clientX), right: Math.max(gesture.x, event.clientX),
    top: Math.min(gesture.y, event.clientY), bottom: Math.max(gesture.y, event.clientY)};
  selectionArea.hidden = false;
  Object.assign(selectionArea.style, {left: `${rectangle.left}px`, top: `${rectangle.top}px`,
    width: `${rectangle.right - rectangle.left}px`, height: `${rectangle.bottom - rectangle.top}px`});
  const geometry = noteheads().map(note => ({note, bounds: note.getBoundingClientRect()}));
  const enclosed = geometry.filter(({bounds}) => containsCenter(rectangle, bounds));
  if (!gesture.measure && enclosed.length) {
    // Empty-space starts acquire compiler measure identity from the first
    // enclosed note. When several enter at once, use the closest center.
    const distance = ({bounds}) => Math.hypot(bounds.left + bounds.width / 2 - gesture.x,
      bounds.top + bounds.height / 2 - gesture.y);
    const nearest = enclosed.reduce((best, target) => distance(target) < distance(best) ? target : best);
    gesture.measure = nearest.note.dataset.measure;
  }
  gesture.notes = enclosed.filter(({note}) => note.dataset.measure === gesture.measure).map(({note}) => note);
  decorateSelection(gesture.notes, geometry);
}
// Pointer capture keeps release/cancellation deterministic outside the score.
main.addEventListener('pointerdown', event => {
  if (event.button !== 0 || !event.isPrimary) return;
  if (suppressClick) suppressClick = false;
  event.preventDefault();
  gesture = {pointerId: event.pointerId, measure: notehead(event.target)?.dataset.measure, sourceStarted: Boolean(scoreObject(event.target)), x: event.clientX, y: event.clientY, dragging: false, notes: []};
});
document.addEventListener('pointerup', event => {
  if (!gesture || gesture.pointerId !== event.pointerId) return;
  updateGesture(event);
  const completed = gesture;
  pointerPosition = {x: event.clientX, y: event.clientY};
  gesture = null; selectionArea.hidden = true;
  if (main.hasPointerCapture(event.pointerId)) main.releasePointerCapture(event.pointerId);
  if (completed.dragging) {
    if (!completed.measure && (completed.sourceStarted || !noteheads().length)) {
      feedback('Measure information unavailable. Press F5 in Neovim to rebuild.');
      decorateSelection(state.selection?.notes || []);
    } else selectNotes(completed.notes);
  } else decorateSelection(state.selection?.notes || []);
  if (completed.dragging) setTimeout(() => { suppressClick = false; }, 0);
});
document.addEventListener('pointercancel', () => { cancelGesture(); suppressClick = false; });
main.addEventListener('lostpointercapture', () => { if (gesture) cancelGesture(); });
window.addEventListener('blur', cancelGesture);

// Input dispatch composes actions after drag recognition and click suppression.
function scoreObject(target) {
  const note = target?.closest?.('[data-note]');
  return note && main.contains(note) ? note : null;
}

function insideSelection(event) {
  if (!state.selection || !main.contains(event.target)) return false;
  return [...main.querySelectorAll('[data-selection-region]')].some(region => {
    const bounds = region.getBoundingClientRect();
    return event.clientX >= bounds.left && event.clientX <= bounds.right
      && event.clientY >= bounds.top && event.clientY <= bounds.bottom;
  });
}

document.addEventListener('click', event => {
  if (suppressClick) { suppressClick = false; event.preventDefault(); return; }
  if (event.target.closest('#show-details')) { actions.inspection.focus(); return; }
  if (insideSelection(event)) { event.preventDefault(); actions.inspection.reopenSelection(); return; }
  if (state.selection?.open && !inspector.contains(event.target)) {
    actions.inspection.dismiss();
    if (!scoreObject(event.target)) return;
  }
  if (event.target.closest('header')) return;
  if (event.target.closest('#inspector-close')) { actions.inspection.dismiss(); return; }
  if (inspector.contains(event.target)) return;
  const note = scoreObject(event.target);
  if (note) {
    clearSelection();
    event.preventDefault();
    actions.inspection.expand(note, {x: event.clientX, y: event.clientY});
    actions.navigation.openSource(note);
  } else { clearSelection(); actions.inspection.dismiss(); }
});
// Pointer movement can replace the origin; departure does not dismiss inspection.
document.addEventListener('pointermove', event => {
  const moved = !pointerPosition || pointerPosition.x !== event.clientX || pointerPosition.y !== event.clientY;
  pointerPosition = {x: event.clientX, y: event.clientY};
  if (gesture) { updateGesture(event); return; }
  if (inspector.contains(event.target)) return;
  const note = scoreObject(event.target);
  if (state.selection?.open) {
    const target = notehead(event.target);
    if (moved && target && !state.selection.notes.includes(target)) {
      if (note) actions.inspection.preview(note, {x: event.clientX, y: event.clientY});
      else actions.inspection.dismiss();
    }
    return;
  }
  const current = state.inspection.expanded || state.inspection.hover;
  if (!note || !moved) return;
  if (current?.note === note) {
    if (state.inspection.hover && !current.origin && !current.error) {
      current.anchor = {x: event.clientX, y: event.clientY};
      current.scrollX = window.scrollX; current.scrollY = window.scrollY;
    }
    return;
  }
  actions.inspection.preview(note, {x: event.clientX, y: event.clientY});
});
window.addEventListener('scroll', () => {
  if (gesture) cancelGesture();
}, {passive: true});
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    help.open = false;
    if (gesture) { cancelGesture(); event.preventDefault(); return; }
    if (state.selection && !state.selection.open && !state.inspection.hover && !state.inspection.expanded) clearSelection();
    else actions.inspection.dismiss();
  }
  const note = notehead(event.target);
  if (note && event.key === ' ') {
    event.preventDefault();
    const previous = state.selection?.notes || [];
    const sameMeasure = previous[0]?.dataset.measure === note.dataset.measure;
    const notes = sameMeasure ? previous.includes(note) ? previous.filter(item => item !== note) : [...previous, note] : [note];
    selectNotes(notes);
  } else if (note && event.key === 'Enter') {
    event.preventDefault(); clearSelection();
    const source = note.querySelector('[data-note]');
    if (source) { actions.inspection.expand(source); actions.navigation.openSource(source); }
  }
});

// System updates reconcile the generation and navigation state. Only an explicit
// F7 reveal event expands inspection; a click acknowledgement cannot reopen it.
async function poll() {
  try {
    const response = await fetch(`state?revision=${encodeURIComponent(state.revision)}`);
    const update = await response.json();
    if (!response.ok) throw new Error(update.error);
    const initial = !state.revision;
    const rebuilt = state.revision !== update.revision;
    const navigationChanged = state.navigationSequence !== update.sequence || state.navigationHighlight !== update.selected;
    state.connection = 'connected'; state.connectionError = '';
    if (rebuilt) {
      clearSelection();
      actions.inspection.dismiss();
      originCache.clear();
      replacePages(update.pages);
      prepareNoteheads();
      state.revision = update.revision;
      main.dataset.revision = update.revision;
      feedback(initial ? 'Score loaded' : 'Score updated');
    }
    state.navigationHighlight = update.selected;
    state.navigationSequence = update.sequence;
    state.stale = Boolean(update.stale); state.dirty = Boolean(update.dirty);
    const reveal = update.reveal;
    if (reveal && reveal.sequence !== state.revealSequence && reveal.revision === state.revision) {
      actions.navigation.revealInScore(reveal.key);
    } else if (rebuilt || navigationChanged) renderNavigation();
    state.revealSequence = reveal?.sequence || 0;
    renderInspection(); renderStatus();
  } catch (error) {
    state.connection = 'disconnected'; state.connectionError = error.message;
    renderStatus();
  }
  setTimeout(poll, 500);
}
poll();
