// Tiny runtime localization for the Control Tower UI. No build step, no framework.
// The ENGLISH source string is the lookup key, so a missing translation falls back to English
// automatically and the HTML/JS keep reading naturally. Mirrors the theme toggle's pattern
// (localStorage key + apply on boot). Add a language by dropping a lang/<code>.json file and
// listing it in SUPPORTED below.
//
// Usage:
//   tr('Sea')                      -> translated string (or 'Sea' if no translation)
//   tr('All', 'lens')              -> context-qualified lookup, falls back to context-less, then English
//   <button data-i18n>Sea</button> -> swept + translated by I18N.applyDom()
//   data-i18n-title / data-i18n-placeholder / data-i18n-aria-label -> same for those attributes
//   await I18N.boot(profileLang)   -> resolve language, load its dictionary, sweep the static DOM
//   I18N.setLang('zh-Hans')        -> persist a per-device choice and reload
// This source file is kept ASCII-only (Chinese label written as a \u escape) to avoid any charset risk.
'use strict';
(function () {
  var DICT = {};                       // englishSource -> translation (only for the active non-English language)
  var LANG = 'en';
  var SEP = String.fromCharCode(4);    // gettext-style context separator: tr(en, ctx) looks up "ctx" + SEP + en
  // code -> the label shown for it in the language picker (in its own language)
  var SUPPORTED = { 'en': 'English', 'zh-Hans': '中文', 'ja': '日本語' };   // picker labels in their own language

  function norm(code) {
    if (!code) return '';
    code = ('' + code).trim();
    if (SUPPORTED[code]) return code;
    var lc = code.toLowerCase();
    if (lc === 'zh' || lc.indexOf('zh-hans') === 0 || lc.indexOf('zh-cn') === 0 || lc.indexOf('zh-sg') === 0) return 'zh-Hans';
    if (lc.indexOf('en') === 0) return 'en';
    // generic: match the primary subtag against SUPPORTED ('ja-JP' -> 'ja', 'es-MX' -> 'es') so any
    // newly added language is browser-detectable without editing norm() again.
    var primary = lc.split('-')[0];
    if (SUPPORTED[primary]) return primary;
    return '';
  }
  // Precedence: explicit per-device choice (localStorage) -> profile default -> browser -> English.
  function resolve(profileLang) {
    var ls = '';
    try { ls = localStorage.getItem('lang') || ''; } catch (e) {}
    return norm(ls) || norm(profileLang) || norm(navigator.language) || 'en';
  }
  function tr(en, ctx) {
    if (en == null) return '';
    if (LANG === 'en') return en;
    var v = ctx != null ? DICT[ctx + SEP + en] : undefined;
    if (v == null) v = DICT[en];          // fall back to the context-less translation
    return v != null ? v : en;            // then to the English source
  }
  // Translate static markup in place. Each element remembers its English source in a *-src attribute,
  // so re-running after a language change re-translates from English rather than from the prior language.
  function applyDom(root) {
    root = root || document;
    root.querySelectorAll('[data-i18n]').forEach(function (e) {
      var ctx = e.getAttribute('data-i18n');
      var src = e.getAttribute('data-i18n-src');
      if (src == null) { src = e.textContent; e.setAttribute('data-i18n-src', src); }
      e.textContent = tr(src, ctx || undefined);
    });
    [['data-i18n-title', 'title'], ['data-i18n-placeholder', 'placeholder'], ['data-i18n-aria-label', 'aria-label']]
      .forEach(function (pair) {
        root.querySelectorAll('[' + pair[0] + ']').forEach(function (e) {
          var srcAttr = pair[0] + '-src';
          var src = e.getAttribute(srcAttr);
          if (src == null) { src = e.getAttribute(pair[1]) || ''; e.setAttribute(srcAttr, src); }
          e.setAttribute(pair[1], tr(src));
        });
      });
  }
  function load(lang) {
    if (lang === 'en') { DICT = {}; LANG = 'en'; return Promise.resolve(); }
    return fetch('lang/' + lang + '.json', { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : {}; })
      .then(function (d) { DICT = d || {}; LANG = lang; })
      .catch(function () { DICT = {}; LANG = 'en'; });   // any failure -> stay on English, never blank
  }
  function boot(profileLang) {
    LANG = resolve(profileLang);
    try { document.documentElement.setAttribute('lang', LANG); } catch (e) {}
    return load(LANG).then(function () { applyDom(document); });
  }
  // Persist an explicit per-device choice (including 'en', so a Chinese-default user can force English
  // and have it stick across reloads). Reload re-runs boot() with the dictionary now in localStorage.
  function setLang(code) {
    code = norm(code) || 'en';
    try { localStorage.setItem('lang', code); } catch (e) {}
    location.reload();
  }

  window.I18N = { tr: tr, applyDom: applyDom, boot: boot, setLang: setLang, supported: SUPPORTED,
    current: function () { return LANG; }, resolve: resolve };
  window.tr = tr;   // convenience global used throughout ops.js
})();
