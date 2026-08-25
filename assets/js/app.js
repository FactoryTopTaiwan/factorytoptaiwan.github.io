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

  /* ---- Video facades -----------------------------------------------------
     The page ships a poster and a button. YouTube is not contacted at all
     until someone presses play, so a reader who never watches pays no
     third-party request and collects no cookie.

     No autoplay - client instruction. The reader clicks our facade to load
     the embed, then clicks YouTube's own play control to start playback. Two
     clicks, but that is the behaviour the client asked for after review.

     Placed above the reveal-on-scroll block on purpose: that block returns
     early under prefers-reduced-motion. */
  var facades = document.querySelectorAll('[data-video]');
  for (var v = 0; v < facades.length; v++) {
    (function (box) {
      var btn = box.querySelector('.vid__play');
      if (!btn) return;
      btn.addEventListener('click', function () {
        var id = box.getAttribute('data-video');
        if (!id) return;
        var frame = document.createElement('iframe');
        frame.src = 'https://www.youtube-nocookie.com/embed/' + encodeURIComponent(id) +
                    '?rel=0&modestbranding=1';
        frame.title = box.getAttribute('data-video-title') || 'Video';
        frame.allow = 'accelerometer; encrypted-media; picture-in-picture; web-share';
        frame.referrerPolicy = 'strict-origin-when-cross-origin';
        frame.setAttribute('allowfullscreen', '');
        frame.className = 'vid__frame';
        box.textContent = '';
        box.appendChild(frame);
        frame.focus();
      });
    })(facades[v]);
  }

  /* ---- Product lightbox --------------------------------------------------
     Clicking the main hero (or any thumbnail button) opens a native <dialog>
     with a large view, a thumb strip, and a tab for the machine's YouTube
     video. YouTube is only contacted when the reader switches to the Video
     tab, keeping the no-autoplay / no-third-party-until-clicked contract. */
  var lightbox = document.querySelector('[data-lightbox]');
  if (lightbox && typeof HTMLDialogElement !== 'undefined') {
    var lbMain   = lightbox.querySelector('[data-lightbox-main]');
    var lbThumbs = lightbox.querySelectorAll('[data-lightbox-src]');
    var lbTabs   = lightbox.querySelectorAll('[data-lightbox-tab]');
    var lbPanes  = lightbox.querySelectorAll('[data-lightbox-pane]');
    var lbClose  = lightbox.querySelector('[data-lightbox-close]');
    var lbVideo  = lightbox.querySelector('[data-lightbox-video-id]');

    function lbShow(idx) {
      if (!lbThumbs.length) return;
      idx = (idx + lbThumbs.length) % lbThumbs.length;
      var t = lbThumbs[idx];
      lbMain.src    = t.getAttribute('data-lightbox-src')    || '';
      lbMain.srcset = t.getAttribute('data-lightbox-srcset') || '';
      lbMain.width  = t.getAttribute('data-lightbox-w')      || '';
      lbMain.height = t.getAttribute('data-lightbox-h')      || '';
      lbMain.alt    = t.getAttribute('data-lightbox-alt')    || '';
      for (var i = 0; i < lbThumbs.length; i++) {
        lbThumbs[i].setAttribute('aria-selected', i === idx ? 'true' : 'false');
      }
      lbMain.dataset.idx = idx;
    }

    for (var t = 0; t < lbThumbs.length; t++) {
      (function (i) { lbThumbs[i].addEventListener('click', function () { lbShow(i); }); })(t);
    }

    function lbOpenTab(id) {
      for (var i = 0; i < lbTabs.length; i++) {
        var sel = lbTabs[i].getAttribute('data-lightbox-tab') === id;
        lbTabs[i].setAttribute('aria-selected', sel ? 'true' : 'false');
      }
      for (var j = 0; j < lbPanes.length; j++) {
        lbPanes[j].hidden = lbPanes[j].getAttribute('data-lightbox-pane') !== id;
      }
      if (id === 'video' && lbVideo && !lbVideo.querySelector('iframe')) {
        var vid = lbVideo.getAttribute('data-lightbox-video-id');
        var f = document.createElement('iframe');
        f.src = 'https://www.youtube-nocookie.com/embed/' + encodeURIComponent(vid) +
                '?rel=0&modestbranding=1';
        f.title = lbVideo.getAttribute('data-lightbox-video-title') || 'Video';
        f.allow = 'accelerometer; encrypted-media; picture-in-picture; web-share';
        f.setAttribute('allowfullscreen', '');
        lbVideo.appendChild(f);
      }
    }

    for (var k = 0; k < lbTabs.length; k++) {
      (function (tab) {
        tab.addEventListener('click', function () { lbOpenTab(tab.getAttribute('data-lightbox-tab')); });
      })(lbTabs[k]);
    }

    function openLightbox(idx) {
      lbShow(idx || 0);
      lbOpenTab('images');
      try { lightbox.showModal(); } catch (e) { lightbox.setAttribute('open', ''); }
    }
    function closeLightbox() {
      try { lightbox.close(); } catch (e) { lightbox.removeAttribute('open'); }
    }
    if (lbClose) lbClose.addEventListener('click', closeLightbox);
    lightbox.addEventListener('click', function (e) {
      if (e.target === lightbox) closeLightbox();
    });
    document.addEventListener('keydown', function (e) {
      if (!lightbox.open) return;
      if (e.key === 'ArrowRight') lbShow((parseInt(lbMain.dataset.idx || '0', 10) + 1));
      else if (e.key === 'ArrowLeft') lbShow((parseInt(lbMain.dataset.idx || '0', 10) - 1));
    });

    var heroBtn = document.querySelector('[data-prod-zoom]');
    if (heroBtn) heroBtn.addEventListener('click', function () { openLightbox(0); });
  }

  /* ---- Share menu --------------------------------------------------------
     A small share popover on every product page. Opens with the platforms
     that a corporate buyer actually uses to escalate a page: email, LinkedIn,
     X, WhatsApp, plus copy-to-clipboard. Uses the Web Share API on mobile
     where present, so the native sheet appears instead of the popover. */
  var shareEls = document.querySelectorAll('[data-share]');
  for (var s = 0; s < shareEls.length; s++) {
    (function (box) {
      var toggle = box.querySelector('[data-share-toggle]');
      var menu   = box.querySelector('.share__menu');
      var title  = box.getAttribute('data-share-title') || document.title;
      var url    = box.getAttribute('data-share-url') || location.href;
      var enc    = encodeURIComponent;

      // Fill dynamic hrefs (need real url encoding, not template escape)
      var eL = box.querySelector('[data-share-email]');
      if (eL) eL.href = 'mailto:?subject=' + enc(title) + '&body=' + enc(url);
      var iL = box.querySelector('[data-share-linkedin]');
      if (iL) iL.href = 'https://www.linkedin.com/sharing/share-offsite/?url=' + enc(url);
      var xL = box.querySelector('[data-share-x]');
      if (xL) xL.href = 'https://twitter.com/intent/tweet?url=' + enc(url) + '&text=' + enc(title);
      var wL = box.querySelector('[data-share-whatsapp]');
      if (wL) wL.href = 'https://api.whatsapp.com/send?text=' + enc(title + ' ' + url);

      toggle.addEventListener('click', function () {
        // Native share sheet where available (mobile) - preferred UX
        if (navigator.share) {
          navigator.share({ title: title, url: url }).catch(function(){});
          return;
        }
        var open = menu.hidden;
        menu.hidden = !open;
        toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      });

      var copyBtn = box.querySelector('[data-share-copy]');
      var copyLbl = box.querySelector('[data-share-copy-label]');
      if (copyBtn && copyLbl) {
        var origLabel = copyLbl.textContent;
        copyBtn.addEventListener('click', function () {
          if (navigator.clipboard) {
            navigator.clipboard.writeText(url).then(function () {
              copyLbl.textContent = box.getAttribute('data-share-copied-label') || 'Link copied';
              setTimeout(function () { copyLbl.textContent = origLabel; }, 2000);
            });
          }
        });
      }

      document.addEventListener('click', function (e) {
        if (!box.contains(e.target)) {
          menu.hidden = true;
          toggle.setAttribute('aria-expanded', 'false');
        }
      });
    })(shareEls[s]);
  }

  /* ---- Product gallery thumbnails ---------------------------------------
     Click a thumbnail, swap the hero image. The template renders each thumb
     as a <button> with data-src / data-srcset / data-w / data-h / data-alt,
     so the swap is straight attribute copies and no data has to be fetched.
     No visible active state on the thumbs deliberately: the hero above them
     already shows which one is current.

     Above the reveal-on-scroll block on purpose, since that block returns
     early under prefers-reduced-motion. */
  var galleries = document.querySelectorAll('[data-prod-gallery]');
  for (var g = 0; g < galleries.length; g++) {
    (function (root) {
      var hero = root.querySelector('[data-prod-hero]');
      if (!hero) return;
      var thumbs = root.querySelectorAll('[data-prod-thumb]');
      for (var t = 0; t < thumbs.length; t++) {
        thumbs[t].addEventListener('click', function () {
          hero.src    = this.getAttribute('data-src')    || hero.src;
          hero.srcset = this.getAttribute('data-srcset') || hero.srcset;
          hero.width  = this.getAttribute('data-w')      || hero.width;
          hero.height = this.getAttribute('data-h')      || hero.height;
          hero.alt    = this.getAttribute('data-alt')    || hero.alt;
          // Mark the pressed thumb so it can be styled if the visual system
          // ever calls for one; harmless if the CSS never uses it.
          for (var j = 0; j < thumbs.length; j++) thumbs[j].removeAttribute('data-current');
          this.setAttribute('data-current', 'true');
        });
      }
    })(galleries[g]);
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
