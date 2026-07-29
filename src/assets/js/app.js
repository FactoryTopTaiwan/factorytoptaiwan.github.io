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

  /* ---- Header hairline on scroll ---------------------------------------- */
  var header = document.getElementById('site-header');
  if (header) {
    var setStuck = function () {
      header.setAttribute('data-stuck', window.scrollY > 8 ? 'true' : 'false');
    };
    setStuck();
    window.addEventListener('scroll', setStuck, { passive: true });
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
