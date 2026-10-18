// Minimal local runtime for the mockup files (.dc.html format) so they open in a plain browser.
// Supports {{holes}}, <sc-if>, <sc-for>, event bindings and setState re-render. Mockup only.
(function () {
  class DCLogic {
    constructor(props) { this.props = props || {}; this.state = null; }
    setState(p) { this.state = Object.assign({}, this.state || {}, typeof p === 'function' ? p(this.state) : p); window.__dcRender && window.__dcRender(); }
    forceUpdate() { window.__dcRender && window.__dcRender(); }
  }
  window.DCLogic = DCLogic;
  const WHOLE = /^\s*\{\{([^}]+)\}\}\s*$/;
  function lookup(path, scope) {
    path = path.trim();
    if (path === 'true') return true; if (path === 'false') return false; if (path === 'null') return null;
    if (/^-?\d+(\.\d+)?$/.test(path)) return +path;
    return path.split('.').reduce(function (o, k) { return o == null ? undefined : o[k]; }, scope);
  }
  function interp(str, scope) { return str.replace(/\{\{([^}]+)\}\}/g, function (m, p) { const v = lookup(p, scope); return v == null ? '' : String(v); }); }
  function build(node, scope, out) {
    if (node.nodeType === 3) { out.push(document.createTextNode(interp(node.nodeValue, scope))); return; }
    if (node.nodeType !== 1) return;
    const tag = node.tagName.toLowerCase();
    if (tag === 'sc-if') {
      const m = (node.getAttribute('value') || '').match(WHOLE);
      if (m ? lookup(m[1], scope) : node.getAttribute('value')) node.childNodes.forEach(function (c) { build(c, scope, out); });
      return;
    }
    if (tag === 'sc-for') {
      const m = node.getAttribute('list').match(WHOLE);
      const list = (m && lookup(m[1], scope)) || [];
      const as = node.getAttribute('as') || 'item';
      list.forEach(function (it, i) { const s = Object.create(scope); s[as] = it; s.$index = i; node.childNodes.forEach(function (c) { build(c, s, out); }); });
      return;
    }
    const svg = node.namespaceURI && node.namespaceURI.indexOf('svg') >= 0;
    const el = svg ? document.createElementNS(node.namespaceURI, tag) : document.createElement(tag);
    let pending;
    for (const a of Array.from(node.attributes)) {
      const name = a.name, m = a.value.match(WHOLE);
      if (name.indexOf('hint-') === 0) continue;
      if (name.indexOf('on') === 0 && m) {
        const fn = lookup(m[1], scope); let ev = name.slice(2);
        if (ev === 'change' && tag === 'input' && node.getAttribute('type') === 'range') ev = 'input';
        if (typeof fn === 'function') el.addEventListener(ev, fn);
        continue;
      }
      if (name === 'checked' && m) { el.checked = !!lookup(m[1], scope); continue; }
      if (name === 'value' && m) { pending = lookup(m[1], scope); continue; }
      el.setAttribute(name, interp(a.value, scope));
    }
    node.childNodes.forEach(function (c) { const k = []; build(c, scope, k); k.forEach(function (n) { el.appendChild(n); }); });
    if (pending !== undefined) el.value = pending;
    out.push(el);
  }
  document.addEventListener('DOMContentLoaded', function () {
    const xdc = document.querySelector('x-dc');
    const helmet = xdc.querySelector('helmet');
    if (helmet) { Array.from(helmet.children).forEach(function (c) { document.head.appendChild(c); }); helmet.remove(); }
    const tpl = document.createElement('template'); tpl.innerHTML = xdc.innerHTML; xdc.innerHTML = '';
    const sc = document.querySelector('script[data-dc-script]');
    const decl = JSON.parse(sc.getAttribute('data-props') || '{}'), props = {};
    for (const k in decl) if (k[0] !== '$' && decl[k] && 'default' in decl[k]) props[k] = decl[k].default;
    Object.assign(props, window.__dcProps || {});
    const Component = new Function('DCLogic', sc.textContent + '\nreturn Component;')(DCLogic);
    const inst = new Component(props);
    window.__dc = inst;
    window.__dcRender = function () {
      const vals = inst.renderVals(), out = [];
      tpl.content.childNodes.forEach(function (c) { build(c, vals, out); });
      xdc.replaceChildren.apply(xdc, out);
    };
    window.__dcRender();
  });
})();
