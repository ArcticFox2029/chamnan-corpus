const fs = require('fs');

// The JavaScript form of the same thing. `new RegExp(string)` where the string came from
// disk is what neither literal-extraction nor a worker fired at literals can reach.
const patterns = fs.readFileSync('patterns.txt', 'utf8').split('\n')
  .filter(l => l && !l.startsWith('#'));
const matchers = patterns.map(p => new RegExp(p));
