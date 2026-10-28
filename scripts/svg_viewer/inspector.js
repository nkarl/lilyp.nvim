import {renderGroup} from './group.js';

// All supported variants have an explicit renderer. This module consumes the
// validated inspection contract; legacy shapes are normalized by Neovim.
const unsupportedMessage = 'Unsupported symbol';
const view = (label, fields = [], reason = '') => ({label, fields, reason});
const optional = (label, value) => value === undefined ? [] : [[label, value]];
const tuplets = symbol => ['Tuplets', symbol.tuplets.length ? symbol.tuplets.map(t => `${t.command} ${t.ratio}`).join(' → ') : 'None'];
function duration(value) {
  const names = {1: 'Whole', 2: 'Half', 4: 'Quarter', 8: 'Eighth', 16: 'Sixteenth', 32: 'Thirty-second'};
  return ['Notated duration', `${names[value.denominator] || 'Note'} (${value.notation})`
    + (value.dots === 1 ? ', dotted' : value.dots > 1 ? `, ${value.dots} dots` : '')
    + (value.inherited ? ' · implicit duration' : ' · explicit duration')];
}
const labelledNotation = symbol => view(symbol.name, [[symbol.notation.startsWith('\\') ? 'Marking' : 'Notation', symbol.notation], ...optional('Direction', symbol.direction)]);
const renderers = {
  note: symbol => view(symbol.grace ? 'Grace note' : 'Note', [
    ['Written pitch', symbol.written_pitch],
    ['Source pitch', `${symbol.pitch} · ${symbol.absolute_pitch} · MIDI ${symbol.midi}`],
    ['Pitch context', symbol.mode === 'relative' ? `Relative to ${symbol.anchor}` : symbol.mode === 'fixed' ? `Fixed octave at ${symbol.anchor}` : 'Absolute'],
    duration(symbol.duration), ['Chord', symbol.chord_size > 1 ? `Note ${symbol.chord_member} of ${symbol.chord_size}` : 'Single note'], tuplets(symbol),
  ]),
  rest: symbol => view('Rest', [duration(symbol.duration), tuplets(symbol)]),
  skip: symbol => view('Skip', [duration(symbol.duration), tuplets(symbol)]),
  lyric: symbol => view(({syllable: 'Lyric syllable', extender: 'Lyric extender', hyphen: 'Lyric hyphen', skip: 'Lyric alignment skip', stanza: 'Stanza label'})[symbol.form], [
    [symbol.form === 'stanza' ? 'Label' : 'Text', symbol.text], ...optional('Definition', symbol.definition), ...optional('Stanza', symbol.stanza),
  ]),
  chord: symbol => view(({name: 'Chord name', skip: 'Chord skip', rest: 'Chord rest'})[symbol.form], [
    ['Written chord', symbol.written], ['Notated duration', `${symbol.duration.notation} · ${symbol.duration.inherited ? 'implicit duration' : 'explicit duration'}`],
    ...optional('Root', symbol.root), ...optional('Modifier', symbol.modifier), ...optional('Bass', symbol.bass),
  ]),
  dynamic: symbol => view(symbol.name, [[symbol.meaning === undefined ? 'Notation' : 'Marking', symbol.notation], ...optional('Meaning', symbol.meaning)]),
  articulation: labelledNotation,
  beam: labelledNotation,
  slur: labelledNotation,
  tie: labelledNotation,
  key: symbol => view('Key signature', [...optional('Key', symbol.key), ...optional('Written key', symbol.written), ...optional('Alias', symbol.alias)]),
  meter: symbol => view('Time signature', [['Meter', symbol.meter], ['Command', symbol.command]]),
  tuplet: symbol => view('Tuplet', [['Ratio', symbol.ratio], ['Command', symbol.command]]),
  tempo: symbol => view('Tempo', [...optional('Text', symbol.text), ...optional('Beat unit', symbol.beat_unit), ...optional('Beats per minute', symbol.bpm)]),
  repeat: symbol => view('Repeat', [['Type', symbol.repeat_type], ['Count', symbol.count]]),
  alternative: symbol => view(symbol.ending === undefined ? 'Alternative endings' : 'Alternative ending', optional('Ending', symbol.ending)),
  grace: symbol => view('Grace music', [['Command', symbol.command]]),
  pitch_context: symbol => view('Pitch context', [['Mode', symbol.mode], ...optional('Anchor', symbol.anchor)]),
  barline: symbol => view('Barline', [['Style', symbol.style]]),
  clef: symbol => view('Clef', [['Clef', symbol.clef]]),
  pickup: symbol => view('Pickup', [['Notated duration', symbol.duration]]),
  mark: symbol => view(symbol.form === 'end' ? 'End mark' : 'Score mark', [['Mark', symbol.mark], ...optional('Glyph', symbol.glyph)]),
  layout: symbol => view('Layout instruction', [['Command', symbol.command]]),
};
export const supportedSymbolKinds = Object.freeze(Object.keys(renderers).sort());
export function describeInspection(inspection) {
  switch (inspection.tag) {
    case 'unsupported': return view(null, [], unsupportedMessage);
    case 'supported': {
      const render = Object.hasOwn(renderers, inspection.symbol.kind) ? renderers[inspection.symbol.kind] : null;
      if (!render) throw new Error(`Missing renderer for supported symbol: ${inspection.symbol.kind}`);
      return render(inspection.symbol);
    }
    default: throw new Error('Invalid inspection result');
  }
}

// Compact musical summaries are derived from the same exhaustive descriptions.
// No additional interpretation or edit eligibility is inferred here.
function rhythmSummary(value, symbol = 'note') {
  const names = {1: 'whole', 2: 'half', 4: 'quarter', 8: 'eighth', 16: 'sixteenth', 32: 'thirty-second'};
  const dots = value.dots === 1 ? ', dotted' : value.dots > 1 ? `, ${value.dots} dots` : '';
  const label = `${names[value.denominator] ? `${names[value.denominator]} ${symbol}` : `${symbol} (${value.notation})`}${dots}`;
  return `${label[0].toUpperCase()}${label.slice(1)} · ${value.inherited ? 'implicit' : 'explicit'} duration`;
}
export function summarizeInspection(inspection) {
  const description = describeInspection(inspection);
  if (inspection.tag === 'unsupported') return {title: unsupportedMessage, summary: '', qualification: ''};
  const symbol = inspection.symbol;
  if (symbol.kind === 'note') return {
    title: `${description.label} · ${symbol.pitch}`, summary: rhythmSummary(symbol.duration),
    qualification: '',
  };
  if (symbol.kind === 'rest' || symbol.kind === 'skip') return {
    title: description.label, summary: rhythmSummary(symbol.duration, symbol.kind), qualification: '',
  };
  if (symbol.kind === 'lyric') return {title: description.label,
    summary: [symbol.text, symbol.stanza === undefined ? '' : `Stanza ${symbol.stanza}`].filter(Boolean).join(' · '),
    qualification: '',
  };
  if (symbol.kind === 'tempo') return {title: description.label,
    summary: [symbol.text, symbol.bpm === undefined ? '' : `${symbol.beat_unit ? `Beat ${symbol.beat_unit}` : 'Tempo'} = ${symbol.bpm}`].filter(Boolean).join(' · '),
    qualification: '',
  };
  return {title: description.label,
    summary: description.fields.slice(0, 2).map(([label, value]) => label === description.label ? String(value) : `${label}: ${value}`).join(' · '), qualification: ''};
}

// Presentation only: the controller supplies the visible object and card mode.
export function createInspectorView(card) {
  const groupContent = card.querySelector('#group-content');
  const sourceBlock = card.querySelector('.source-block');
  const kind = card.querySelector('#origin-kind');
  const location = card.querySelector('#origin-location');
  const sourcePath = card.querySelector('#source-path');
  const fullPath = card.querySelector('#origin-full-path');
  const durationOrigin = card.querySelector('#duration-origin');
  const before = card.querySelector('#origin-before');
  const focus = card.querySelector('#origin-focus');
  const after = card.querySelector('#origin-after');
  const hint = card.querySelector('#origin-hint');
  const details = card.querySelector('#origin-details');
  const context = card.querySelector('#origin-context');
  const reason = card.querySelector('#origin-reason');
  const close = card.querySelector('#inspector-close');
  const summary = card.querySelector('#origin-summary');
  const qualification = card.querySelector('#origin-qualification');
  const technical = card.querySelector('#technical-details');
  const excerpt = card.querySelector('pre');
  const announcement = document.querySelector('#inspection-announcement');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let presented = null, cardMotion = null, detailsMotion = null, announcedKey = null, placement = null, groupPlacement = null, layoutBox = null;

  function settle() { cardMotion?.cancel(); detailsMotion?.cancel(); }
  reducedMotion.addEventListener('change', () => { if (reducedMotion.matches) settle(); });

  function place(model) {
    if (model.group) {
      if (groupPlacement?.key !== model.key) {
        const gap = parseFloat(getComputedStyle(card).getPropertyValue('--inspection-gap'));
        groupPlacement = {key: model.key, style: {
          left: `${model.anchor.x + window.scrollX}px`, top: `${model.anchor.y + gap + window.scrollY}px`,
          maxWidth: 'none', maxHeight: 'none'}};
      }
      card.style.position = 'absolute';
      Object.assign(card.style, groupPlacement.style);
      card.dataset.placement = 'score';
      return;
    }
    card.style.position = 'absolute';
    if (placement?.key !== model.key) {
      const gap = parseFloat(getComputedStyle(card).getPropertyValue('--inspection-gap'));
      const target = model.note.getBoundingClientRect();
      const anchor = model.anchor || {x: target.left, y: target.bottom};
      const scrollX = model.anchor ? model.scrollX : window.scrollX;
      const scrollY = model.anchor ? model.scrollY : window.scrollY;
      placement = {key: model.key, style: {
        left: `${anchor.x + scrollX}px`, top: `${anchor.y + gap + scrollY}px`,
        maxWidth: 'none', maxHeight: 'none'}};
    }
    Object.assign(card.style, placement.style);
    card.dataset.placement = 'score';
  }

  function animate(previous, model, before) {
    const box = card.getBoundingClientRect();
    layoutBox = box;
    if (reducedMotion.matches) return;
    const style = getComputedStyle(card);
    const easing = style.getPropertyValue('--motion-easing').trim();
    if (!previous) {
      const offset = style.getPropertyValue('--motion-open-offset').trim();
      cardMotion = card.animate([{opacity: 0, transform: `translateY(${offset})`}, {opacity: 1, transform: 'translateY(0)'}], {duration: parseFloat(style.getPropertyValue('--motion-open-duration')), easing});
    } else if (previous.key === model.key && before && (Math.abs(before.width - box.width) > 1 || Math.abs(before.height - box.height) > 1)) {
      const frame = rect => ({width: `${rect.width}px`, height: `${rect.height}px`, overflow: 'hidden'});
      cardMotion = card.animate([frame(before), frame(box)], {duration: parseFloat(style.getPropertyValue('--motion-resize-duration')), easing});
    } else if (previous.key !== model.key) {
      detailsMotion = details.animate([{opacity: .4}, {opacity: 1}], {duration: parseFloat(style.getPropertyValue('--motion-change-duration')), easing});
    }
  }
  function reposition() {
    if (!presented || card.hidden) return;
    requestAnimationFrame(() => {
      if (!presented || card.hidden) return;
      const before = cardMotion?.playState === 'running' ? card.getBoundingClientRect() : layoutBox;
      settle(); place(presented); animate(presented, presented, before);
    });
  }
  card.addEventListener('toggle', reposition, true);

  function renderDetails(origin) {
    context.replaceChildren();
    const description = describeInspection(origin.inspection);
    function group(label, fields) {
      if (!fields.length) return;
      const section = document.createElement('div'); section.className = 'detail-group';
      section.setAttribute('role', 'group'); section.setAttribute('aria-label', label);
      for (const [label, value] of fields) {
        const term = document.createElement('dt'), valueNode = document.createElement('dd');
        term.textContent = label; valueNode.textContent = value;
        section.append(term, valueNode);
      }
      context.append(section);
    }
    if (origin.inspection.tag === 'supported') {
      if (origin.inspection.symbol.kind === 'note') {
        const pitchLabels = ['Written pitch', 'Source pitch', 'Pitch context', 'Chord'];
        group('Pitch', description.fields.filter(([label]) => pitchLabels.includes(label)));
        group('Rhythm', description.fields.filter(([label]) => !pitchLabels.includes(label)));
      } else group('Notation', description.fields);
    }
    if (origin.linked_objects > 1) group('Source', [['Shared source', `Symbol ${origin.occurrence} of ${origin.linked_objects} at this source location`]]);
    reason.textContent = origin.inspection.tag === 'supported' ? description.reason : '';
    technical.hidden = !context.children.length && !reason.textContent;
  }

  function renderHint(model) {
    const origin = model.origin;
    if (model.group) hint.textContent = model.dirty ? 'Unsaved edits. Save and press F5 in Neovim to update the score.' : model.stale ? 'Source changed. Press F5 in Neovim to update the score.' : '';
    else if (model.error) hint.textContent = model.error;
    else if (!origin) hint.textContent = '';
    else if (!origin.available) hint.textContent = 'No source preview. Press F5 in Neovim to rebuild.';
    else if (model.dirty) hint.textContent = 'Unsaved edits. Save and press F5 in Neovim to update the score and source links.';
    else if (model.stale) hint.textContent = 'Source changed. Press F5 in Neovim to update the score and source links.';
    else hint.textContent = '';
  }

  return {render(model) {
    if (!model) {
      settle(); presented = null; placement = null; layoutBox = null; card.hidden = true;
      card.removeAttribute('data-key'); technical.open = false; sourcePath.open = false; announcement.textContent = ''; announcedKey = null;
      return;
    }
    const previous = presented;
    groupContent.hidden = !model.group; sourceBlock.hidden = Boolean(model.group);
    if (model.group) {
      renderHint(model);
      if (presented?.group === model.group && presented.groupVersion === model.groupVersion) {
        presented = model; place(model); return;
      }
      settle();
      card.dataset.key = model.key; card.dataset.mode = 'expanded'; card.dataset.symbol = 'group';
      delete card.dataset.mapping; delete card.dataset.kind;
      card.setAttribute('role', 'region'); card.setAttribute('aria-label', 'Selected notes');
      kind.textContent = `${model.group.notes.length} note${model.group.notes.length === 1 ? '' : 's'} selected`;
      summary.textContent = `Measure ${model.note.dataset.measureNumber}`;
      details.hidden = false; qualification.hidden = true; technical.hidden = true;
      close.hidden = false; close.style.visibility = 'visible'; close.tabIndex = 0;
      renderGroup(groupContent, model.group, describeInspection, summarizeInspection);
      if (announcedKey !== model.key) { announcement.textContent = `${kind.textContent}. ${summary.textContent}`; announcedKey = model.key; }
      card.hidden = false; place(model); animate(previous, model, layoutBox); presented = model; return;
    }

    const beforeBox = cardMotion?.playState === 'running' ? card.getBoundingClientRect() : layoutBox;
    renderHint(model);
    if (presented && presented.key === model.key && presented.expanded === model.expanded
      && presented.origin === model.origin && presented.error === model.error && presented.selection === model.selection) {
      presented = model;
      if (cardMotion?.playState !== 'running') { settle(); place(model); animate(previous, model, beforeBox); }
      return;
    }
    settle();
    card.dataset.key = String(model.key);
    card.dataset.mode = model.expanded ? 'expanded' : 'compact';
    card.setAttribute('role', model.expanded ? 'region' : 'tooltip');
    card.setAttribute('aria-label', model.expanded ? 'Selected symbol' : 'Symbol preview');
    details.hidden = false;
    close.hidden = false;
    close.style.visibility = model.expanded ? 'visible' : 'hidden';
    close.tabIndex = model.expanded ? 0 : -1;
    excerpt.tabIndex = model.expanded ? 0 : -1;
    const origin = model.origin;
    const headline = origin ? summarizeInspection(origin.inspection) : {title: model.error ? 'Unavailable' : 'Loading…', summary: '', qualification: ''};
    kind.textContent = headline.title;
    const durationParts = origin?.inspection.tag === 'supported' && ['note', 'rest', 'skip'].includes(origin.inspection.symbol.kind) ? headline.summary.split(' · ') : null;
    summary.textContent = durationParts ? durationParts[0] : headline.summary;
    durationOrigin.textContent = durationParts ? ` · ${durationParts[1]}` : '';
    if (durationParts) summary.append(durationOrigin);
    qualification.textContent = headline.qualification; qualification.hidden = !headline.qualification;
    technical.hidden = !origin;
    const spoken = model.expanded && origin ? `${headline.title}. ${headline.summary}` : '';
    if (spoken && announcedKey !== model.key) { announcement.textContent = spoken; announcedKey = model.key; }
    location.textContent = origin ? `${origin.path.split(/[\\/]/).at(-1)}:${origin.line}:${origin.column}` : '';
    fullPath.textContent = origin ? `${origin.path}:${origin.line}:${origin.column}` : '';
    sourcePath.hidden = !origin;
    if (!previous || previous.key !== model.key) sourcePath.open = false;
    // Source excerpts remain literal text in both card modes.
    before.textContent = origin ? (origin.truncated_left ? '…' : '') + origin.before : '';
    focus.textContent = origin?.focus || '';
    after.textContent = origin ? origin.after + (origin.truncated_right ? '…' : '') : '';
    if (origin) {
      card.dataset.kind = origin.kind;
      card.dataset.mapping = origin.inspection.tag === 'supported' ? 'resolved' : 'unavailable';
      card.dataset.symbol = origin.inspection.tag === 'supported' ? origin.inspection.symbol.kind : 'unknown';
    } else {
      delete card.dataset.kind; delete card.dataset.mapping; delete card.dataset.symbol;
    }
    if (origin) renderDetails(origin);
    else { context.replaceChildren(); reason.textContent = ''; }
    if (!model.expanded) technical.open = false;
    else if (!previous?.expanded || previous.selection !== model.selection || (!previous.origin && origin)) technical.open = !technical.hidden;
    card.hidden = false;
    place(model);
    animate(previous, model, beforeBox);
    presented = model;
    requestAnimationFrame(() => {
      if (presented !== model || card.hidden) return;
      const selected = focus.getBoundingClientRect(), visible = excerpt.getBoundingClientRect();
      if (selected.top < visible.top || selected.bottom > visible.bottom) excerpt.scrollTop += selected.top - visible.top - parseFloat(getComputedStyle(card).getPropertyValue('--source-scroll-inset'));
    });
  }};
}
