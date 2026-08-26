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

  /* ---- Mobile product carousel + immersive media viewer -----------------
     Two connected pieces:
     1. .pgal is the mobile-only swipe carousel inside .prod__media.
        Native scroll-snap does the finger-following; we render pagination
        dots and open the viewer on tap.
     2. .lightbox is the immersive viewer. Single scroll-snap track holds
        every image plus the YouTube video as media items. Pinch, double-
        tap and pan zoom images; when zoomed, horizontal swipe locks so
        the pan stays on the current image. Desktop keeps the sidebar
        thumb rail (client's confirmed layout); mobile becomes full-screen
        with a dark background and pagination dots. */

  // ----- Mobile carousel ---------------------------------------------------
  var pgals = document.querySelectorAll('[data-pgal]');
  for (var pg = 0; pg < pgals.length; pg++) {
    (function (pgal) {
      var track  = pgal.querySelector('[data-pgal-track]');
      var slides = pgal.querySelectorAll('[data-pgal-slide]');
      var dotsEl = pgal.querySelector('[data-pgal-dots]');
      if (!track || !slides.length || !dotsEl) return;

      // Build dots
      var dots = [];
      for (var i = 0; i < slides.length; i++) {
        (function (i) {
          var d = document.createElement('button');
          d.type = 'button';
          d.className = 'pgal__dot';
          d.setAttribute('aria-label', 'Go to media ' + (i + 1) + ' of ' + slides.length);
          d.addEventListener('click', function () {
            slides[i].scrollIntoView({ behavior: 'smooth', inline: 'center', block: 'nearest' });
          });
          dotsEl.appendChild(d);
          dots.push(d);
        })(i);
      }
      dots[0].classList.add('is-active');

      // Active index tracking via IntersectionObserver
      var active = 0;
      if ('IntersectionObserver' in window) {
        var io = new IntersectionObserver(function (entries) {
          entries.forEach(function (e) {
            if (e.isIntersecting && e.intersectionRatio > 0.6) {
              var idx = Array.prototype.indexOf.call(slides, e.target);
              if (idx >= 0 && idx !== active) {
                dots[active] && dots[active].classList.remove('is-active');
                dots[idx].classList.add('is-active');
                active = idx;
              }
            }
          });
        }, { root: track, threshold: [0.6, 0.9] });
        for (var s = 0; s < slides.length; s++) io.observe(slides[s]);
      }

      // Tap-to-open. Use a small drag-threshold so a swipe does not
      // accidentally open the viewer.
      var startX = 0, startY = 0, dragged = false;
      track.addEventListener('pointerdown', function (e) {
        startX = e.clientX; startY = e.clientY; dragged = false;
      }, { passive: true });
      track.addEventListener('pointermove', function (e) {
        if (Math.abs(e.clientX - startX) > 8 || Math.abs(e.clientY - startY) > 8) {
          dragged = true;
        }
      }, { passive: true });

      for (var t2 = 0; t2 < slides.length; t2++) {
        (function (t2) {
          slides[t2].addEventListener('click', function () {
            if (dragged) return;
            openViewer(t2);
          });
        })(t2);
      }
    })(pgals[pg]);
  }

  // ----- Immersive viewer --------------------------------------------------
  var lightbox = document.querySelector('[data-lightbox]');
  var slides = [];
  var mediaIdx = 0;
  var trackEl = null;
  var stage = null;
  var count = null;
  var dots = [];
  var openViewer = function () {};
  var closeViewer = function () {};

  if (lightbox && typeof HTMLDialogElement !== 'undefined') {
    var lbClose  = lightbox.querySelector('[data-lightbox-close]');
    var lbPrev   = lightbox.querySelector('[data-lightbox-prev]');
    var lbNext   = lightbox.querySelector('[data-lightbox-next]');
    trackEl      = lightbox.querySelector('[data-lightbox-track]');
    stage        = lightbox.querySelector('[data-lightbox-stage]');
    count        = lightbox.querySelector('[data-lightbox-count]');
    var dotsEl   = lightbox.querySelector('[data-lightbox-dots]');
    var thumbs   = lightbox.querySelectorAll('[data-lightbox-thumb]');
    slides = trackEl ? trackEl.querySelectorAll('[data-lightbox-slide]') : [];

    // Declare these upfront so closures below and above can reference them.
    // Function declarations inside blocks are strictly block-scoped in strict
    // mode and did not resolve reliably here, so use assigned expressions.
    var loadImg, preloadAdjacent, renderState, lbGoto, updateActive;

    openViewer = function (idx) {
      mediaIdx = Math.max(0, Math.min(idx || 0, slides.length - 1));
      document.body.dataset.lbScroll = String(window.scrollY);
      document.body.classList.add('lb-open');
      try { lightbox.showModal(); } catch (e) { lightbox.setAttribute('open', ''); }
      // Snap and preload synchronously so state is consistent even if the
      // browser throttles rAF while the dialog is animating in.
      lbGoto(mediaIdx, false);
      preloadAdjacent(mediaIdx);
      // Backup rAF in case layout wasn't ready above.
      requestAnimationFrame(function () { lbGoto(mediaIdx, false); });
    };
    closeViewer = function () {
      var iframe = lightbox.querySelector('iframe');
      if (iframe && iframe.parentNode) iframe.parentNode.removeChild(iframe);
      var vplay = lightbox.querySelector('[data-lightbox-vplay]');
      if (vplay) vplay.hidden = false;
      var zs = lightbox.querySelectorAll('[data-lightbox-zoomer]');
      for (var z = 0; z < zs.length; z++) resetZoom(zs[z]);
      try { lightbox.close(); } catch (e) { lightbox.removeAttribute('open'); }
      document.body.classList.remove('lb-open');
      var y = parseInt(document.body.dataset.lbScroll || '0', 10);
      if (!isNaN(y)) window.scrollTo(0, y);
    };

    // Build dots
    if (dotsEl) {
      for (var d = 0; d < slides.length; d++) {
        (function (d) {
          var dot = document.createElement('button');
          dot.type = 'button';
          dot.className = 'lightbox__dot';
          dot.setAttribute('aria-label', 'Show media ' + (d + 1) + ' of ' + slides.length);
          dot.addEventListener('click', function () { lbGoto(d, true); });
          dotsEl.appendChild(dot);
          dots.push(dot);
        })(d);
      }
      if (dots[0]) dots[0].classList.add('is-active');
    }

    // Load full-size images lazily as they scroll into view
    var imgs = trackEl.querySelectorAll('[data-lightbox-img]');
    loadImg = function (img) {
      if (img.dataset.loaded === '1') return;
      var src = img.getAttribute('data-src');
      var ss  = img.getAttribute('data-srcset');
      if (src) img.src = src;
      if (ss)  img.srcset = ss;
      img.dataset.loaded = '1';
    };

    preloadAdjacent = function (i) {
      var list = [i, i - 1, i + 1];
      for (var k = 0; k < list.length; k++) {
        var t = slides[list[k]];
        if (!t) continue;
        var im = t.querySelector('[data-lightbox-img]');
        if (im) loadImg(im);
      }
    };

    // Track-scroll → index update
    var scrollTimer = null;
    updateActive = function () {
      if (!trackEl || !slides.length) return;
      var w = trackEl.clientWidth || 1;
      var idx = Math.round(trackEl.scrollLeft / w);
      idx = Math.max(0, Math.min(idx, slides.length - 1));
      if (idx !== mediaIdx) {
        // leaving previous slide - reset its zoom, and stop video if it was the video slide
        var prev = slides[mediaIdx];
        if (prev) {
          var pz = prev.querySelector('[data-lightbox-zoomer]');
          if (pz) resetZoom(pz);
          if (prev.getAttribute('data-lightbox-slide') === 'video') {
            var iframe = prev.querySelector('iframe');
            if (iframe && iframe.parentNode) iframe.parentNode.removeChild(iframe);
            var vplay = prev.querySelector('[data-lightbox-vplay]');
            if (vplay) vplay.hidden = false;
          }
        }
      }
      mediaIdx = idx;
      renderState();
      preloadAdjacent(idx);
    };
    if (trackEl) {
      trackEl.addEventListener('scroll', function () {
        if (scrollTimer) clearTimeout(scrollTimer);
        scrollTimer = setTimeout(updateActive, 60);
      }, { passive: true });
    }

    // Locate the video slide once so we can flip the VIDEO / IMAGES tabs
    // based on which media the reader is looking at.
    var lbTabs   = lightbox.querySelectorAll('[data-lightbox-tab]');
    var videoSlideIdx = -1;
    for (var s = 0; s < slides.length; s++) {
      if (slides[s].getAttribute('data-lightbox-slide') === 'video') { videoSlideIdx = s; break; }
    }

    renderState = function () {
      if (count) count.textContent = (mediaIdx + 1) + ' / ' + slides.length;
      for (var i = 0; i < dots.length; i++) {
        dots[i].classList.toggle('is-active', i === mediaIdx);
      }
      for (var j = 0; j < thumbs.length; j++) {
        thumbs[j].setAttribute('aria-selected', j === mediaIdx ? 'true' : 'false');
      }
      // Tab active state: current slide is the video slide -> VIDEO tab,
      // otherwise IMAGES tab.
      var currentKind = slides[mediaIdx] &&
        slides[mediaIdx].getAttribute('data-lightbox-slide') === 'video' ? 'video' : 'images';
      for (var t = 0; t < lbTabs.length; t++) {
        var k = lbTabs[t].getAttribute('data-lightbox-tab');
        lbTabs[t].setAttribute('aria-selected', k === currentKind ? 'true' : 'false');
      }
      if (lbPrev) lbPrev.hidden = mediaIdx <= 0;
      if (lbNext) lbNext.hidden = mediaIdx >= slides.length - 1;
    };

    lbGoto = function (i, smooth) {
      if (!trackEl || !slides.length) return;
      i = Math.max(0, Math.min(i, slides.length - 1));
      mediaIdx = i;
      var w = trackEl.clientWidth;
      var behavior = smooth ? 'smooth' : 'auto';
      var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      if (reduced) behavior = 'auto';
      trackEl.scrollTo({ left: i * w, top: 0, behavior: behavior });
      renderState();
      preloadAdjacent(i);
    };

    // Thumb clicks (desktop rail). Thumbs are in track order, so their
    // index maps 1:1 to slide index.
    for (var th = 0; th < thumbs.length; th++) {
      (function (th) {
        thumbs[th].addEventListener('click', function () { lbGoto(th, true); });
      })(th);
    }

    // Tab clicks: VIDEO -> jump to the video slide; IMAGES -> jump to
    // the first image slide.
    for (var tt = 0; tt < lbTabs.length; tt++) {
      (function (tab) {
        tab.addEventListener('click', function () {
          var kind = tab.getAttribute('data-lightbox-tab');
          if (kind === 'video' && videoSlideIdx >= 0) {
            lbGoto(videoSlideIdx, true);
          } else if (kind === 'images') {
            // First slide whose kind is image
            for (var q = 0; q < slides.length; q++) {
              if (slides[q].getAttribute('data-lightbox-slide') === 'image') {
                lbGoto(q, true); break;
              }
            }
          }
        });
      })(lbTabs[tt]);
    }

    // Nav buttons (desktop)
    if (lbPrev) lbPrev.addEventListener('click', function () { lbGoto(mediaIdx - 1, true); });
    if (lbNext) lbNext.addEventListener('click', function () { lbGoto(mediaIdx + 1, true); });

    // Close controls
    if (lbClose) lbClose.addEventListener('click', closeViewer);
    lightbox.addEventListener('click', function (e) {
      if (e.target === lightbox) closeViewer();
    });
    lightbox.addEventListener('cancel', function (e) {
      // Esc key - let it close naturally via dialog behavior, but we
      // still need to run our teardown.
      e.preventDefault();
      closeViewer();
    });

    // Keyboard nav (desktop)
    document.addEventListener('keydown', function (e) {
      if (!lightbox.open) return;
      if (e.key === 'ArrowRight') lbGoto(mediaIdx + 1, true);
      else if (e.key === 'ArrowLeft') lbGoto(mediaIdx - 1, true);
      else if (e.key === 'Escape') closeViewer();
    });

    // Wire the hero + thumbs on the product page. Clicking the hero opens
    // on the video (if the product has one) so the buyer sees the machine
    // running first, matching Amazon's default VIDEO tab; clicking a
    // specific image thumb opens on that image.
    var firstImageSlide = 0;
    for (var qq = 0; qq < slides.length; qq++) {
      if (slides[qq].getAttribute('data-lightbox-slide') === 'image') { firstImageSlide = qq; break; }
    }
    var heroBtn = document.querySelector('[data-prod-zoom]');
    if (heroBtn) heroBtn.addEventListener('click', function () {
      openViewer(videoSlideIdx >= 0 ? videoSlideIdx : 0);
    });
    var prodThumbs = document.querySelectorAll('[data-prod-thumb]');
    for (var pt = 0; pt < prodThumbs.length; pt++) {
      (function (pt) {
        prodThumbs[pt].addEventListener('click', function () {
          openViewer(firstImageSlide + pt);
        });
      })(pt);
    }

    // Video slide: start the facade on click
    var vplayBtns = lightbox.querySelectorAll('[data-lightbox-vplay]');
    for (var vp = 0; vp < vplayBtns.length; vp++) {
      vplayBtns[vp].addEventListener('click', function (e) {
        e.stopPropagation();
        var wrap = this.parentNode;
        if (wrap.querySelector('iframe')) return;
        var vid = wrap.getAttribute('data-lightbox-video-id');
        if (!vid) return;
        var f = document.createElement('iframe');
        f.src = 'https://www.youtube-nocookie.com/embed/' + encodeURIComponent(vid) +
                '?autoplay=1&rel=0&modestbranding=1';
        f.title = wrap.getAttribute('data-lightbox-video-title') || 'Video';
        f.allow = 'autoplay; accelerometer; encrypted-media; picture-in-picture; web-share';
        f.setAttribute('allowfullscreen', '');
        wrap.appendChild(f);
        this.hidden = true;
      });
    }

    // Recompute snap position on viewport resize
    var resizeTimer = null;
    window.addEventListener('resize', function () {
      if (!lightbox.open) return;
      if (resizeTimer) clearTimeout(resizeTimer);
      resizeTimer = setTimeout(function () { lbGoto(mediaIdx, false); }, 100);
    });

    // ----- Zoom + pan on image slides -------------------------------------
    var zoomers = lightbox.querySelectorAll('[data-lightbox-zoomer]');
    for (var zi = 0; zi < zoomers.length; zi++) attachZoom(zoomers[zi]);
  }

  function resetZoom(z) {
    z.classList.remove('is-zoomed');
    z.classList.remove('is-panning');
    var img = z.querySelector('.lightbox__img');
    if (img) {
      img.style.transform = '';
      img.dataset.scale = '1';
      img.dataset.tx = '0';
      img.dataset.ty = '0';
    }
    if (stage) stage.classList.remove('is-zoomed');
  }

  function attachZoom(z) {
    var img = z.querySelector('.lightbox__img');
    if (!img) return;

    // Two zoom modes coexist on the same image element:
    //  * Touch (pinch / double-tap / pan) uses translate + scale.
    //  * Mouse (hover-follow, Amazon-style) uses transform-origin +
    //    scale — cheaper and always stays inside the rigid frame.
    // The image is transformed inside the .lightbox__zoomer, which is
    // overflow:hidden, so nothing bleeds beyond the stage bounds.
    var state = {
      scale: 1, tx: 0, ty: 0,
      startDist: 0, startScale: 1,
      panStartX: 0, panStartY: 0, panning: false,
      pointers: {},
      pointerCount: 0,
      lastTap: 0,
      isHoverMode: false
    };

    var HOVER_SCALE = 2.4;

    function applyTouch() {
      img.style.transformOrigin = '50% 50%';
      img.style.transform = 'translate(' + state.tx + 'px,' + state.ty + 'px) scale(' + state.scale + ')';
      var isZoomed = state.scale > 1.02;
      z.classList.toggle('is-zoomed', isZoomed);
      if (stage) stage.classList.toggle('is-zoomed', isZoomed);
    }

    function applyHover(clientX, clientY) {
      var rect = img.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) return;
      var px = Math.min(Math.max((clientX - rect.left) / rect.width, 0), 1) * 100;
      var py = Math.min(Math.max((clientY - rect.top) / rect.height, 0), 1) * 100;
      img.style.transformOrigin = px + '% ' + py + '%';
      img.style.transform = 'scale(' + HOVER_SCALE + ')';
    }
    function resetHover() {
      state.isHoverMode = false;
      z.classList.remove('is-hover-zoom');
      img.style.transform = '';
      img.style.transformOrigin = '50% 50%';
      if (stage) stage.classList.remove('is-zoomed');
    }

    function clampPan() {
      var rect = z.getBoundingClientRect();
      var iw = img.naturalWidth || img.clientWidth;
      var ih = img.naturalHeight || img.clientHeight;
      var displayScale = Math.min(rect.width / iw, rect.height / ih) || 1;
      var sw = iw * displayScale * state.scale;
      var sh = ih * displayScale * state.scale;
      var maxX = Math.max(0, (sw - rect.width) / 2);
      var maxY = Math.max(0, (sh - rect.height) / 2);
      state.tx = Math.min(maxX, Math.max(-maxX, state.tx));
      state.ty = Math.min(maxY, Math.max(-maxY, state.ty));
    }

    function distance(p1, p2) {
      var dx = p1.x - p2.x, dy = p1.y - p2.y;
      return Math.sqrt(dx * dx + dy * dy);
    }
    function pointerList() {
      var list = [];
      for (var k in state.pointers) if (state.pointers.hasOwnProperty(k)) list.push(state.pointers[k]);
      return list;
    }

    // ---- Mouse click-to-zoom, then pan-follow (Amazon-style) --------------
    // Hover shows a zoom-in cursor as an indication (CSS handles the cursor).
    // Click activates zoom at the click point; while zoomed, mousemove pans
    // the image (transform-origin follows the cursor). Click again exits.
    // The container is overflow:hidden so nothing ever bleeds outside the
    // rigid frame regardless of scale.
    var hoverCapable = window.matchMedia('(hover: hover) and (pointer: fine)').matches;

    z.addEventListener('mousemove', function (e) {
      if (!hoverCapable || !state.isHoverMode) return;
      applyHover(e.clientX, e.clientY);
    });
    z.addEventListener('mouseleave', function () {
      // Keep the zoom-in cursor state when the mouse briefly leaves the
      // image but stays inside the modal - only reset when it actually
      // leaves the zoomer. resetHover pulls the transform.
      if (!state.isHoverMode) return;
      resetHover();
    });

    // ---- Touch: pinch + pan + double-tap zoom ----------------------------
    z.addEventListener('pointerdown', function (e) {
      if (e.pointerType !== 'touch') return;
      state.pointers[e.pointerId] = { x: e.clientX, y: e.clientY };
      state.pointerCount = pointerList().length;
      try { z.setPointerCapture(e.pointerId); } catch (err) {}

      if (state.pointerCount === 2) {
        var pts = pointerList();
        state.startDist = distance(pts[0], pts[1]);
        state.startScale = state.scale;
        z.classList.add('is-panning');
      } else if (state.pointerCount === 1) {
        state.panStartX = e.clientX;
        state.panStartY = e.clientY;
        state.panning = state.scale > 1.02;
        if (state.panning) z.classList.add('is-panning');
      }
    });

    z.addEventListener('pointermove', function (e) {
      if (e.pointerType !== 'touch') return;
      if (!state.pointers[e.pointerId]) return;
      state.pointers[e.pointerId] = { x: e.clientX, y: e.clientY };

      if (state.pointerCount === 2) {
        var pts = pointerList();
        var d = distance(pts[0], pts[1]);
        if (state.startDist > 0) {
          var ratio = d / state.startDist;
          state.scale = Math.min(4, Math.max(1, state.startScale * ratio));
          clampPan();
          applyTouch();
        }
        e.preventDefault();
      } else if (state.pointerCount === 1 && state.panning) {
        var only = pointerList()[0];
        state.tx += (only.x - state.panStartX);
        state.ty += (only.y - state.panStartY);
        state.panStartX = only.x;
        state.panStartY = only.y;
        clampPan();
        applyTouch();
        e.preventDefault();
      }
    });

    function endPointer(e) {
      if (e.pointerType !== 'touch') return;
      if (state.pointers[e.pointerId]) delete state.pointers[e.pointerId];
      state.pointerCount = pointerList().length;
      if (state.pointerCount < 2) state.startDist = 0;
      if (state.pointerCount === 0) {
        z.classList.remove('is-panning');
        if (state.scale <= 1.02) {
          state.scale = 1; state.tx = 0; state.ty = 0; applyTouch();
        }
      }
      try { z.releasePointerCapture(e.pointerId); } catch (err) {}
    }
    z.addEventListener('pointerup', endPointer);
    z.addEventListener('pointercancel', endPointer);

    // Click behaviour: on mouse pointers this is the primary zoom trigger
    // (click to enter zoom-follow mode, click again to exit). On touch it
    // becomes the double-tap toggle.
    z.addEventListener('click', function (e) {
      var isMouse = hoverCapable;
      if (isMouse) {
        e.preventDefault();
        e.stopPropagation();
        if (state.isHoverMode) {
          resetHover();
        } else {
          state.isHoverMode = true;
          z.classList.add('is-hover-zoom');
          if (stage) stage.classList.add('is-zoomed');
          applyHover(e.clientX, e.clientY);
        }
        return;
      }
      // Touch: double-tap toggles a scale-2.2 zoom around the tap point.
      var moved = Math.abs(e.clientX - state.panStartX) > 8 ||
                  Math.abs(e.clientY - state.panStartY) > 8;
      if (moved) return;
      var now = Date.now();
      if (now - state.lastTap < 350) {
        e.preventDefault();
        e.stopPropagation();
        if (state.scale > 1.02) {
          state.scale = 1; state.tx = 0; state.ty = 0;
        } else {
          state.scale = 2.2;
          var rect = z.getBoundingClientRect();
          var cx = e.clientX - rect.left - rect.width / 2;
          var cy = e.clientY - rect.top - rect.height / 2;
          state.tx = -cx * (state.scale - 1);
          state.ty = -cy * (state.scale - 1);
          clampPan();
        }
        applyTouch();
        state.lastTap = 0;
      } else {
        state.lastTap = now;
      }
    });

    // Track slide changes so any lingering hover-zoom on a non-active
    // slide is reset (transform stays cheap in the compositor otherwise).
    z.addEventListener('lightbox:leave', function () {
      if (state.isHoverMode) resetHover();
    });
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

      // Scrim for the mobile bottom-sheet variant.
      var scrim = null;
      function ensureScrim() {
        if (scrim) return scrim;
        scrim = document.createElement('div');
        scrim.className = 'share-scrim';
        document.body.appendChild(scrim);
        scrim.addEventListener('click', closeMenu);
        return scrim;
      }
      function closeMenu() {
        menu.hidden = true;
        toggle.setAttribute('aria-expanded', 'false');
        if (scrim) scrim.classList.remove('is-open');
      }
      function openMenu() {
        menu.hidden = false;
        toggle.setAttribute('aria-expanded', 'true');
        if (window.matchMedia('(max-width: 63.99rem)').matches) {
          ensureScrim().classList.add('is-open');
        }
      }
      toggle.addEventListener('click', function () {
        // Native share sheet where available (mobile) - preferred UX
        if (navigator.share) {
          navigator.share({ title: title, url: url }).catch(function(){});
          return;
        }
        if (menu.hidden) openMenu(); else closeMenu();
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
        if (menu.hidden) return;
        if (scrim && scrim.contains(e.target)) return;
        if (!box.contains(e.target)) closeMenu();
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
