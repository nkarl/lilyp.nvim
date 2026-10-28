// Read-only harmonic interpretations. Octave and duplicated pitches do not
// change a pitch-class match; bass, key and playback are not inferred.
const qualities = [
  ['major', [0, 4, 7]], ['minor', [0, 3, 7]], ['diminished', [0, 3, 6]],
  ['augmented', [0, 4, 8]], ['suspended second', [0, 2, 7]], ['suspended fourth', [0, 5, 7]],
  ['dominant seventh', [0, 4, 7, 10]], ['major seventh', [0, 4, 7, 11]],
  ['minor seventh', [0, 3, 7, 10]], ['half-diminished seventh', [0, 3, 6, 10]],
  ['diminished seventh', [0, 3, 6, 9]], ['minor major seventh', [0, 3, 7, 11]],
];
const names = ['C', 'C♯/D♭', 'D', 'D♯/E♭', 'E', 'F', 'F♯/G♭', 'G', 'G♯/A♭', 'A', 'A♯/B♭', 'B'];
const pc = pitch => ((pitch % 12) + 12) % 12;
export function pitchLabel(pitch) {
  if (!Number.isInteger(pitch)) return 'Pitch unavailable';
  const octave = Math.floor(pitch / 12) - 1;
  return names[pc(pitch)].split('/').map(name => `${name}${octave}`).join('/');
}
export function possibleChords(pitches) {
  if (!pitches.length || pitches.some(pitch => !Number.isInteger(pitch))) return [];
  const selected = [...new Set(pitches.map(pc))].sort((a, b) => a - b);
  const candidates = [];
  for (let root = 0; root < 12; root++) qualities.forEach(([quality, intervals], order) => {
    const tones = intervals.map(interval => (root + interval) % 12);
    const matched = selected.filter(tone => tones.includes(tone));
    const missing = tones.filter(tone => !selected.includes(tone));
    const outside = selected.filter(tone => !tones.includes(tone));
    // At least two observed tones and at most one omitted/extra tone keeps
    // the extended list bounded without inventing arbitrary harmonies.
    if (matched.length < 2 || missing.length > 1 || outside.length > 1) return;
    candidates.push({root, order, name: `${names[root]} ${quality}`, matched, missing, outside,
      complete: !missing.length && !outside.length});
  });
  return candidates.sort((a, b) => Number(b.complete) - Number(a.complete)
    || (a.missing.length + a.outside.length) - (b.missing.length + b.outside.length)
    || b.matched.length - a.matched.length || a.order - b.order || a.root - b.root);
}
export function containsCenter(rectangle, bounds) {
  const x = bounds.left + bounds.width / 2, y = bounds.top + bounds.height / 2;
  return x > rectangle.left && x < rectangle.right && y > rectangle.top && y < rectangle.bottom;
}
const element = (tag, text, className) => {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
};
export function renderGroup(container, group, describe, summarize) {
  const open = new Set([...container.querySelectorAll('details[open][data-disclosure]')].map(node => node.dataset.disclosure));
  const active = container.contains(document.activeElement) ? document.activeElement : null;
  const focusedDisclosure = active?.closest('[data-disclosure]')?.dataset.disclosure;
  container.replaceChildren();
  container.append(element('h3', 'Possible chords'));
  const {notes} = group;
  const spellings = new Map();
  notes.forEach(note => {
    const inspection = group.origins.get(group.keyOf(note))?.inspection;
    if (inspection?.tag !== 'supported' || inspection.symbol.kind !== 'note') return;
    const tone = pc(Number(note.dataset.pitch));
    if (!spellings.has(tone)) spellings.set(tone, new Set());
    spellings.get(tone).add(inspection.symbol.written_pitch);
  });
  const written = tone => spellings.has(tone) ? [...spellings.get(tone)].join('/') : names[tone];
  let candidates;
  switch (group.analysis.tag) {
    case 'supported': candidates = group.analysis.candidates; break;
    case 'unsupported': candidates = []; break;
    default: throw new Error('Invalid chord analysis result');
  }
  const explanation = candidate => `${candidate.matched.map(written).join(', ')} present`
    + (candidate.missing.length ? `; missing ${candidate.missing.map(tone => tone === candidate.root ? `${names[tone]} (root)` : names[tone]).join(', ')}` : '; all chord tones present')
    + (candidate.outside.length ? `; outside chord: ${candidate.outside.map(written).join(', ')}` : '');
  const list = entries => {
    const ul = element('ul');
    for (const candidate of entries) {
      const li = element('li'); li.append(element('strong', candidate.name), element('div', explanation(candidate), 'group-explanation')); ul.append(li);
    }
    return ul;
  };
  const complete = candidates.filter(candidate => candidate.complete);
  container.append(complete.length ? list(complete) : element('p', 'No complete chord matches.'));
  const others = candidates.filter(candidate => !candidate.complete);
  if (others.length) {
    const more = element('details'); more.id = 'more-chords'; more.dataset.disclosure = 'more'; more.append(element('summary', 'More possibilities'), list(others)); container.append(more);
  }
  if (group.analysis.tag === 'unsupported') container.append(element('p', 'Chord suggestions require twelve-tone pitches.'));
  container.append(element('p', 'Possible harmonies suggested by the selected notes.', 'group-explanation'));
  container.append(element('h3', 'Selected notes'));
  for (const note of notes) {
    const key = group.keyOf(note), origin = group.origins.get(key);
    const disclosure = element('details'); disclosure.className = 'group-note'; disclosure.dataset.disclosure = `note-${key}`;
    const known = origin?.inspection.tag === 'supported' && origin.inspection.symbol.kind === 'note';
    const headline = known ? summarize(origin.inspection) : null;
    disclosure.append(element('summary', headline ? `${headline.title} · ${headline.summary}` : `Note · ${pitchLabel(Number(note.dataset.pitch))} · details unavailable`));
    if (origin) {
      disclosure.append(element('p', `${origin.path}:${origin.line}:${origin.column}`, 'group-location'));
      const source = element('pre', origin.available ? `${origin.truncated_left ? '…' : ''}${origin.before}${origin.focus}${origin.after}${origin.truncated_right ? '…' : ''}` : 'Source preview unavailable. Press F5 in Neovim to rebuild.');
      source.tabIndex = 0; source.setAttribute('aria-label', 'Source at last build'); disclosure.append(source);
      const technical = element('details'); technical.dataset.disclosure = `technical-${key}`; technical.append(element('summary', 'Technical details'));
      const dl = element('dl'); dl.className = 'detail-group';
      for (const [label, value] of describe(origin.inspection).fields) dl.append(element('dt', label), element('dd', String(value)));
      if (origin.linked_objects > 1) dl.append(element('dt', 'Shared source'), element('dd', `Symbol ${origin.occurrence} of ${origin.linked_objects} at this source location`));
      technical.append(dl); disclosure.append(technical);
    } else disclosure.append(element('p', group.errors.get(key) || 'Loading note details…'));
    container.append(disclosure);
  }
  for (const node of container.querySelectorAll('details[data-disclosure]')) {
    node.open = open.has(node.dataset.disclosure);
    if (node.dataset.disclosure === focusedDisclosure) {
      node.querySelector(`:scope > ${active.tagName.toLowerCase()}`)?.focus({preventScroll: true});
    }
  }
}
