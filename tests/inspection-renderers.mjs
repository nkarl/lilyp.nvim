import assert from 'node:assert/strict';
import {readFile, writeFile} from 'node:fs/promises';
import {describeInspection, summarizeInspection, supportedSymbolKinds} from '../scripts/svg_viewer/inspector.js';
const fixture = JSON.parse(await readFile(process.argv[2], 'utf8'));
assert.deepEqual(supportedSymbolKinds, fixture.kinds, 'Lua variants and card renderers differ');
const legacy = [];
for (const result of fixture.results) {
  const description = describeInspection(result);
  assert.equal(typeof description.label, 'string');
  assert.equal(typeof description.reason, 'string');
  for (const [label, value] of description.fields) {
    assert.equal(typeof label, 'string');
    assert(value !== undefined && value !== null, `Missing ${label} for ${result.symbol.kind}`);
    assert(!String(value).includes('undefined'));
  }
  const summary = summarizeInspection(result);
  assert.equal(typeof summary.title, 'string');
  assert.equal(typeof summary.summary, 'string');
  assert.equal(typeof summary.qualification, 'string');
  assert(!Object.values(summary).some(value => value.includes('undefined')));
  if (result.symbol.kind === 'note') {
    assert(summary.title.includes(result.symbol.pitch));
    assert.equal(summary.qualification, '');
  }
  const symbol = result.symbol;
  if (['note', 'rest', 'skip'].includes(symbol.kind)) {
    const {kind, ...detail} = symbol;
    legacy.push({music: {status: 'resolved', read_only: true, event_type: kind, ...detail}});
  } else {
    legacy.push({symbol: {status: 'resolved', read_only: true, kind: symbol.kind, label: description.label,
      fields: description.fields.map(([label, value]) => ({label, value: String(value).replace('implicit duration', 'inherited').replace('explicit duration', 'explicit')})), reason: description.reason}});
  }
}
assert.deepEqual(describeInspection({tag: 'unsupported'}), {
  label: null, fields: [], reason: 'Unsupported symbol',
});
assert.deepEqual(summarizeInspection({tag: 'unsupported'}), {title: 'Unsupported symbol', summary: '', qualification: ''});
for (const [dots, inherited, expected] of [
  [0, false, 'Quarter rest · explicit duration'],
  [1, false, 'Quarter rest, dotted · explicit duration'],
  [2, true, 'Quarter rest, 2 dots · implicit duration'],
]) {
  const result = summarizeInspection({tag: 'supported', symbol: {kind: 'rest', duration: {denominator: 4, notation: '4' + '.'.repeat(dots), dots, inherited}, tuplets: []}});
  assert.equal(result.summary, expected);
  assert.equal(result.qualification, '');
}
assert.throws(() => describeInspection({tag: 'supported', symbol: {kind: 'future'}}), /Missing renderer/);
assert.throws(() => describeInspection({tag: 'future'}), /Invalid inspection/);
assert.throws(() => describeInspection({tag: 'supported', symbol: {kind: 'toString'}}), /Missing renderer/);
await writeFile(process.argv[3], JSON.stringify(legacy));
console.log(`PASS: exhaustive card renderers for ${supportedSymbolKinds.length} variants and one unsupported message`);
