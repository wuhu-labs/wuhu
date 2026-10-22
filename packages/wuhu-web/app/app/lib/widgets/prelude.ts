// What a sidebar or widget script sees besides its own module: the JSX
// primitives, `query` and the proxied `fetch`. It runs in every fresh QuickJS
// context before the script, so the same file runs unchanged on native
// QuickJS. The host provides `__wuhu_query(sql, paramsJSON)` and
// `__wuhu_fetch(requestJSON)`, each a promise of a JSON string.
export const elementNames = [
  'Sidebar',
  'PageCard',
  'Widget',
  'Subject',
  'Agent',
  'Figure',
  'Doc',
  'List',
  'Pattern',
  'Progress',
  'Calendar',
  'Entity',
  'Row',
  'Tag',
  'Chip',
  'Avatar',
  'LeadIcon',
  'Button',
] as const

export type ElementName = typeof elementNames[number]

export const prelude = `
(() => {
  const names = ${JSON.stringify(elementNames)};
  for (const name of names) globalThis[name] = name;
  globalThis.Fragment = '#fragment';
  const flat = (items, out) => {
    for (const item of items) {
      if (Array.isArray(item)) flat(item, out);
      else if (item != null && item !== false && item !== true && item !== '') out.push(item);
    }
    return out;
  };
  globalThis.h = (type, props, ...children) => {
    const given = props == null ? {} : { ...props };
    if (children.length > 0) given.children = flat(children, []);
    if (typeof type === 'function') return type(given);
    if (type === '#fragment') return given.children ?? [];
    return { $element: type, props: given };
  };
  const host = (call, ...args) => call(...args).then((text) => JSON.parse(text));
  const query = __wuhu_query, fetchRaw = __wuhu_fetch;
  delete globalThis.__wuhu_query;
  delete globalThis.__wuhu_fetch;
  globalThis.query = (strings, ...values) => {
    if (typeof strings === 'string') return host(query, strings, JSON.stringify(values[0] ?? []));
    return host(query, strings.join('?'), JSON.stringify(values));
  };
  class Headers {
    constructor(entries) { this.entries = (entries ?? []).map(([k, v]) => [String(k).toLowerCase(), String(v)]); }
    get(name) { const hit = this.entries.find(([k]) => k === String(name).toLowerCase()); return hit ? hit[1] : null; }
    has(name) { return this.get(name) != null; }
    forEach(each) { for (const [k, v] of this.entries) each(v, k, this); }
  }
  class Response {
    constructor(answer) {
      this.status = answer.status;
      this.statusText = answer.statusText;
      this.ok = answer.status >= 200 && answer.status < 300;
      this.headers = new Headers(answer.headers);
      this.body = answer.body;
    }
    async text() { return this.body; }
    async json() { return JSON.parse(this.body); }
  }
  globalThis.fetch = (input, init) => {
    const options = init ?? {};
    const headers = options.headers == null ? {} : Array.isArray(options.headers)
      ? Object.fromEntries(options.headers) : { ...options.headers };
    const request = {
      url: String(input),
      method: options.method ?? 'GET',
      headers,
      body: options.body == null ? null : String(options.body),
      every: options.every ?? null,
    };
    return fetchRaw(JSON.stringify(request)).then((text) => {
      const answer = JSON.parse(text);
      if (answer.error != null) throw new Error(answer.error);
      return new Response(answer);
    });
  };
})();
`

// The script's result as JSON. A function anywhere in it is refused: a
// widget has no handlers, only links.
export const serialize = `
(value) => JSON.stringify(value === undefined ? null : value, (key, item) =>
  typeof item === 'function' ? { $function: key || 'value' } : item)
`
