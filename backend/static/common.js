// Shared by the payer, ask and safety pages: languages and small helpers.
// Each page adds its own words with I18N.add({ en: {...}, ha: {...}, pcm: {...} }).
var I18N = (function () {
  var words = { en: {}, ha: {}, pcm: {} };
  var names = { en: "English", ha: "Hausa", pcm: "Pidgin" };
  var lang = "en";
  var onChange = function () {};

  function supported(l) { return Object.prototype.hasOwnProperty.call(words, l); }

  // ?lang= wins, then what the person picked before, then the browser's language.
  function detect() {
    var q = new URLSearchParams(location.search).get("lang");
    if (q && supported(q)) return q;
    try { var saved = localStorage.getItem("lang"); if (saved && supported(saved)) return saved; } catch (e) {}
    var prefs = navigator.languages || [navigator.language || "en"];
    for (var i = 0; i < prefs.length; i++) {
      var code = String(prefs[i]).toLowerCase().split("-")[0];
      if (code === "ha" || code === "pcm") return code;
    }
    return "en";
  }

  function t(key, vars) {
    var s = (words[lang] && words[lang][key]);
    if (s === undefined) s = words.en[key];
    if (s === undefined) return key;
    return s.replace(/\{(\w+)\}/g, function (_, k) { return vars && vars[k] !== undefined ? vars[k] : "{" + k + "}"; });
  }

  function apply() {
    document.documentElement.lang = lang === "pcm" ? "en" : lang;
    document.querySelectorAll("[data-i18n]").forEach(function (el) { el.textContent = t(el.getAttribute("data-i18n")); });
    document.querySelectorAll("[data-i18n-ph]").forEach(function (el) { el.setAttribute("placeholder", t(el.getAttribute("data-i18n-ph"))); });
    var select = document.getElementById("lang");
    if (select) select.value = lang;
  }

  return {
    add: function (more) { Object.keys(more).forEach(function (l) { Object.assign(words[l], more[l]); }); },
    t: t,
    get lang() { return lang; },
    // Call once the page's words are added. `changed` runs after the language changes.
    init: function (changed) {
      onChange = changed || onChange;
      lang = detect();
      var select = document.getElementById("lang");
      if (select) {
        Object.keys(names).forEach(function (l) {
          var o = document.createElement("option"); o.value = l; o.textContent = names[l]; select.appendChild(o);
        });
        select.addEventListener("change", function () {
          lang = select.value;
          try { localStorage.setItem("lang", lang); } catch (e) {}
          apply(); onChange();
        });
      }
      apply(); onChange();
    },
  };
})();

var fmt = {
  naira: function (n) { return "₦" + Number(n).toLocaleString("en-NG"); },
  sats: function (n) { return Number(n).toLocaleString("en-NG") + " sats"; },
  usd: function (n) { return "$" + Number(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }); },
  gbp: function (n) { return "£" + Number(n).toLocaleString("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 }); },
};

var icons = {
  ok: '<svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
  err: '<svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M12 7v6M12 17h.01"/></svg>',
  wait: '<div class="spin"></div>',
};

// Copy text; falls back to selecting it when the browser refuses.
function copyText(text) {
  try { return navigator.clipboard.writeText(text).then(function () { return true; }, function () { return false; }); }
  catch (e) { return Promise.resolve(false); }
}
