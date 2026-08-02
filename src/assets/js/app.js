/* fatop-global.com — progressive enhancement only.
   Nothing here is required for the page to be readable or navigable. */
(function () {
  'use strict';

  /* ---- Theme toggle ----------------------------------------------------- */
  var root = document.documentElement;
  var toggle = document.getElementById('theme-toggle');

  /* Three states: auto, light, dark. Auto is the absence of data-theme, which
     lets the CSS fall through to prefers-color-scheme — so the page follows
     whatever the device is doing, including a sunset schedule. Without it there
     is no way back to the device setting once the button has been pressed. */
  var MODES = ['auto', 'light', 'dark'];
  var LABELS = {
    auto:  'Appearance: follow device',
    light: 'Appearance: light',
    dark:  'Appearance: dark'
  };

  function storedMode() {
    var m = root.getAttribute('data-theme');
    return (m === 'light' || m === 'dark') ? m : 'auto';
  }

  function applyMode(mode) {
    if (mode === 'auto') {
      root.removeAttribute('data-theme');
      try { localStorage.removeItem('theme'); } catch (e) {}
    } else {
      root.setAttribute('data-theme', mode);
      try { localStorage.setItem('theme', mode); } catch (e) {}
    }
    if (toggle) {
      toggle.setAttribute('aria-label', LABELS[mode]);
      toggle.setAttribute('title', LABELS[mode]);
    }
  }

  if (toggle) {
    applyMode(storedMode());
    toggle.addEventListener('click', function () {
      var next = MODES[(MODES.indexOf(storedMode()) + 1) % MODES.length];
      applyMode(next);
    });
  }

  /* ---- Language menu ----------------------------------------------------
     The menu opens, closes and takes keyboard focus without any of this —
     details/summary does that natively. All this adds is dismissing on Escape
     or an outside click, which a native details element does not do. */
  var langMenu = document.getElementById('lang-menu');
  if (langMenu) {
    document.addEventListener('click', function (e) {
      if (langMenu.open && !langMenu.contains(e.target)) langMenu.open = false;
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && langMenu.open) {
        langMenu.open = false;
        var s = langMenu.querySelector('summary');
        if (s) s.focus();
      }
    });
  }

  /* ---- Mobile navigation -------------------------------------------------
     The button shipped without this, so below 64rem the entire navigation was
     unreachable — the control was there, announced itself as a menu, and did
     nothing. */
  var navToggle = document.querySelector('.nav-toggle');
  var nav = document.querySelector('.nav');
  if (navToggle && nav) {
    var setNav = function (open) {
      navToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      document.body.classList.toggle('nav-open', open);
    };
    navToggle.addEventListener('click', function () {
      setNav(navToggle.getAttribute('aria-expanded') !== 'true');
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && navToggle.getAttribute('aria-expanded') === 'true') {
        setNav(false);
        navToggle.focus();
      }
    });
    // A link inside the panel should close it on the way out
    nav.addEventListener('click', function (e) {
      if (e.target.closest('a')) setNav(false);
    });
  }

  /* ---- Header hairline on scroll ---------------------------------------- */
  var header = document.getElementById('site-header');
  if (header) {
    var setStuck = function () {
      header.setAttribute('data-stuck', window.scrollY > 8 ? 'true' : 'false');
    };
    setStuck();
    window.addEventListener('scroll', setStuck, { passive: true });
  }

  /* ---- Site search -------------------------------------------------------
     A static host cannot run a query, so the whole index is one small JSON
     written at build time and fetched the first time search is opened. It is
     around sixty entries, so a linear scan is faster than loading a search
     library would be.

     This block sits ABOVE the reveal-on-scroll code on purpose: that block
     returns out of this function early under prefers-reduced-motion, so
     anything placed after it would never run for those readers. */
  var searchBox = document.querySelector('[data-search]');
  if (searchBox) {
    var searchBtn  = searchBox.querySelector('.search__open');
    var searchPane = searchBox.querySelector('.search__panel');
    var searchIn   = searchBox.querySelector('.search__input');
    var searchList = searchBox.querySelector('.search__results');
    var searchNone = searchBox.querySelector('[data-search-empty]');
    var searchHint = searchBox.querySelector('[data-search-hint]');
    var rows = null, fetching = false, active = -1, shown = [];

    /* The control ships hidden so it never sits there looking usable while
       doing nothing. Script is running, so it can be honest now. */
    searchBox.hidden = false;

    var bare = function (s) { return (s || '').toLowerCase().replace(/[^a-z0-9]/g, ''); };

    function loadIndex() {
      if (rows || fetching) return;
      fetching = true;
      fetch(searchBox.getAttribute('data-src'))
        .then(function (r) { return r.ok ? r.json() : []; })
        .then(function (data) {
          rows = data || [];
          fetching = false;
          if (searchIn.value) render();
        })
        .catch(function () { rows = []; fetching = false; });
    }

    /* A buyer arriving with a model number is the case that must never miss,
       so an exact or leading model match outranks everything. TWM929, twm-929
       and TWM 929 all have to reach the same machine. */
    function rank(row, q) {
      var m = (row.m || '').toLowerCase(), t = (row.t || '').toLowerCase();
      var qb = bare(q), mb = bare(row.m);
      if (m && m === q) return 100;
      if (mb && qb && mb === qb) return 98;
      if (mb && qb && mb.indexOf(qb) === 0) return 90;
      if (t.indexOf(q) === 0) return 70;
      if (t.indexOf(q) > -1) return 55;
      if ((row.f || '').toLowerCase().indexOf(q) > -1) return 35;
      return 20;
    }

    function match(q) {
      var terms = q.split(/\s+/).filter(Boolean);
      var out = [];
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        var hay = ((row.t || '') + ' ' + (row.m || '') + ' ' +
                   (row.f || '') + ' ' + (row.k || '')).toLowerCase();
        var hayBare = bare(hay);
        var ok = true;
        for (var j = 0; j < terms.length; j++) {
          if (hay.indexOf(terms[j]) === -1 && hayBare.indexOf(bare(terms[j])) === -1) {
            ok = false; break;
          }
        }
        if (ok) out.push({ row: row, score: rank(row, q) });
      }
      out.sort(function (a, b) {
        if (b.score !== a.score) return b.score - a.score;
        return (a.row.t || '').length - (b.row.t || '').length;
      });
      return out.slice(0, 8).map(function (x) { return x.row; });
    }

    function setActive(n) {
      var items = searchList.children;
      if (!items.length) { active = -1; return; }
      if (n < 0) n = items.length - 1;
      if (n >= items.length) n = 0;
      for (var i = 0; i < items.length; i++) {
        items[i].firstChild.setAttribute('aria-selected', i === n ? 'true' : 'false');
      }
      active = n;
      items[n].firstChild.scrollIntoView({ block: 'nearest' });
    }

    function render() {
      var q = searchIn.value.trim().toLowerCase();
      searchList.textContent = '';
      active = -1;

      if (!q) {
        shown = [];
        searchNone.hidden = true;
        searchHint.hidden = false;
        searchIn.setAttribute('aria-expanded', 'false');
        return;
      }
      searchHint.hidden = true;
      if (!rows) { return; }

      shown = match(q);
      searchNone.hidden = shown.length > 0;
      searchIn.setAttribute('aria-expanded', shown.length ? 'true' : 'false');

      for (var i = 0; i < shown.length; i++) {
        var row = shown[i];
        var li = document.createElement('li');
        var a = document.createElement('a');
        a.href = row.u;
        a.setAttribute('role', 'option');
        a.setAttribute('aria-selected', 'false');
        if (row.m) {
          var model = document.createElement('span');
          model.className = 'search__model model';
          model.textContent = row.m;
          a.appendChild(model);
        }
        var title = document.createElement('span');
        title.className = 'search__title';
        title.textContent = row.t;
        a.appendChild(title);
        if (row.f) {
          var fam = document.createElement('span');
          fam.className = 'search__fam';
          fam.textContent = row.f;
          a.appendChild(fam);
        }
        li.appendChild(a);
        searchList.appendChild(li);
      }
    }

    function openSearch(open) {
      searchPane.hidden = !open;
      searchBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
      searchBox.classList.toggle('is-open', open);
      if (open) { loadIndex(); searchIn.focus(); }
    }

    searchBtn.addEventListener('click', function () {
      openSearch(searchPane.hidden);
    });

    searchIn.addEventListener('input', render);

    searchIn.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown') { e.preventDefault(); setActive(active + 1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); setActive(active - 1); }
      else if (e.key === 'Enter' && active > -1) {
        e.preventDefault();
        searchList.children[active].firstChild.click();
      }
    });

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !searchPane.hidden) {
        openSearch(false);
        searchBtn.focus();
      }
    });

    document.addEventListener('click', function (e) {
      if (!searchPane.hidden && !searchBox.contains(e.target)) openSearch(false);
    });
  }

  /* ---- Reveal on scroll ------------------------------------------------- */
  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var targets = document.querySelectorAll('[data-reveal]');

  if (reduced || !('IntersectionObserver' in window)) {
    for (var i = 0; i < targets.length; i++) targets[i].classList.add('is-revealed');
    return;
  }

  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry, n) {
      if (!entry.isIntersecting) return;
      var el = entry.target;
      // Stagger siblings slightly so a grid resolves as a sequence, not a pop
      var delay = Math.min(n * 55, 220);
      setTimeout(function () { el.classList.add('is-revealed'); }, delay);
      io.unobserve(el);
    });
  }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });

  for (var j = 0; j < targets.length; j++) io.observe(targets[j]);
})();
