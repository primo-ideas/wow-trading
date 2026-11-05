// Comforts on top of plain links and forms, which all work without this script.
(() => {
  const SEARCH_DELAY = 180;
  const FILTER_DELAY = 250;
  const REALM_SUGGESTIONS = 8;
  const CARD_DELAY = 200;
  const TIP_DELAY = 350;

  function debounce(action, delay) {
    let timer;
    return (...args) => {
      clearTimeout(timer);
      timer = setTimeout(() => action(...args), delay);
    };
  }

  function isTyping(target) {
    return target.closest("input, textarea, select") !== null;
  }

  function visit(url) {
    if (window.Turbo) window.Turbo.visit(url);
    else window.location.assign(url);
  }

  // A text box and the list of suggestions under it, driven by the keyboard.
  function combobox(input, list, { onEnter } = {}) {
    let active = -1;
    const options = () => [...list.querySelectorAll("[role=option]")];

    function open() {
      list.hidden = false;
      input.setAttribute("aria-expanded", "true");
    }

    function close() {
      list.hidden = true;
      input.setAttribute("aria-expanded", "false");
      input.removeAttribute("aria-activedescendant");
      active = -1;
      hideTip();
    }

    function reset() {
      active = -1;
      input.removeAttribute("aria-activedescendant");
      options().forEach((option, position) => {
        option.id = `${list.id}-option-${position}`;
        option.setAttribute("aria-selected", "false");
      });
    }

    function setActive(index) {
      const all = options();
      if (!all.length) return;
      active = (index + all.length) % all.length;
      all.forEach((option, position) => {
        option.classList.toggle("is-active", position === active);
        option.setAttribute("aria-selected", String(position === active));
      });
      input.setAttribute("aria-activedescendant", all[active].id);
      all[active].scrollIntoView({ block: "nearest" });
      if (all[active].dataset.tooltip) showTipBeside(all[active], list);
    }

    input.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") {
        event.preventDefault();
        if (list.hidden && options().length) open();
        setActive(active + 1);
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        setActive(active - 1);
      } else if (event.key === "Enter") {
        const chosen = options()[active] || (onEnter && onEnter());
        if (chosen) {
          event.preventDefault();
          visit(chosen.href);
        }
      } else if (event.key === "Escape") {
        if (!list.hidden) {
          event.stopPropagation();
          close();
        } else {
          input.blur();
        }
      }
    });
    input.addEventListener("focus", () => {
      if (list.children.length && input.value.trim()) open();
    });
    document.addEventListener("click", (event) => {
      if (input.isConnected && event.target !== input && !list.contains(event.target)) close();
    });

    return { open, close, reset, options };
  }

  // Item search: suggestions as you type, from what is for sale on the realm.
  function setUpSearch(form) {
    if (form.dataset.ready) return;
    form.dataset.ready = "true";

    const input = form.querySelector("input[type=search]");
    const results = form.querySelector(".search-results");
    const box = combobox(input, results);
    let latestRequest = 0;

    const suggest = debounce(async () => {
      const query = input.value.trim();
      if (query.length < 2) return box.close();

      const request = ++latestRequest;
      const response = await fetch(`${form.action}?q=${encodeURIComponent(query)}&fragment=1`);
      // A slower, older answer must not replace a newer one.
      if (request !== latestRequest || !response.ok) return;

      // Rendered and escaped by the server, like any other page.
      results.innerHTML = await response.text();
      box.reset();
      if (document.activeElement === input) box.open();
    }, SEARCH_DELAY);

    input.addEventListener("input", suggest);
  }

  // The one shortcut every search box has.
  document.addEventListener("keydown", (event) => {
    const shortcut = (event.key === "/" && !isTyping(event.target)) ||
      (event.key.toLowerCase() === "k" && (event.ctrlKey || event.metaKey));
    if (!shortcut) return;

    const input = document.querySelector("[data-search] input[type=search], [data-realm-picker] input[type=search]");
    if (input) {
      event.preventDefault();
      input.focus();
      input.select();
    }
  });

  // Realm picker: matches as you type, without case, accents or punctuation, among the
  // realms listed further down the page.
  function simplify(text) {
    return text.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9 ]/g, "");
  }

  // The simplified name, and where each of its letters comes from in the real one.
  function indexName(name) {
    let plain = "";
    const origins = [];
    [...name].forEach((character, position) => {
      const simple = simplify(character);
      for (const letter of simple) {
        plain += letter;
        origins.push(position);
      }
    });
    return { plain, origins, characters: [...name] };
  }

  function highlighted(realm, start, length) {
    const fragment = document.createDocumentFragment();
    const from = realm.index.origins[start];
    const to = realm.index.origins[start + length - 1] + 1;
    const characters = realm.index.characters;
    const mark = document.createElement("mark");
    mark.textContent = characters.slice(from, to).join("");
    fragment.append(characters.slice(0, from).join(""), mark, characters.slice(to).join(""));
    return fragment;
  }

  function setUpRealmPicker(form) {
    if (form.dataset.ready) return;
    form.dataset.ready = "true";

    const input = form.querySelector("input[type=search]");
    const list = form.querySelector("[role=listbox]");
    const realms = [...document.querySelectorAll("[data-realm-directory] a[data-realm]")].map((link) => ({
      name: link.dataset.realm,
      region: link.dataset.region,
      regionName: link.closest("section").querySelector("h2").textContent,
      href: link.href,
      index: indexName(link.dataset.realm)
    }));
    const box = combobox(input, list, { onEnter: () => box.options()[0] });

    function render() {
      const query = simplify(input.value).replace(/\s+/g, " ").trim();
      if (!query) return box.close();

      const matches = realms
        .map((realm) => {
          const at = realm.index.plain.indexOf(query);
          if (at < 0) return null;
          const wordStart = at === 0 ? 0 : (realm.index.plain[at - 1] === " " ? 1 : 2);
          return { realm, at, rank: wordStart };
        })
        .filter(Boolean)
        .sort((a, b) => a.rank - b.rank || a.realm.name.localeCompare(b.realm.name) || a.realm.region.localeCompare(b.realm.region))
        .slice(0, REALM_SUGGESTIONS);

      if (!matches.length) {
        const hint = document.createElement("li");
        hint.className = "search-hint";
        hint.textContent = "No realm by that name. Check the spelling, or browse them all below.";
        list.replaceChildren(hint);
      } else {
        list.replaceChildren(...matches.map(({ realm, at }) => {
          const item = document.createElement("li");
          const link = document.createElement("a");
          link.className = "result realm-result";
          link.href = realm.href;
          link.setAttribute("role", "option");

          const region = document.createElement("span");
          region.className = "region";
          region.textContent = realm.region.toUpperCase();

          const name = document.createElement("span");
          name.className = "result-name";
          name.append(highlighted(realm, at, query.length));

          const where = document.createElement("span");
          where.className = "result-kind";
          where.textContent = realm.regionName;

          link.append(region, name, where);
          item.append(link);
          return item;
        }));
      }
      box.reset();
      box.open();
      if (matches.length) list.querySelector("[role=option]").classList.add("is-first");
    }

    input.addEventListener("input", render);
    if (input.value.trim() && document.activeElement === input) render();
  }

  // Dropdowns: close on a click elsewhere or Escape.
  document.addEventListener("click", (event) => {
    document.querySelectorAll("[data-menu][open]").forEach((menu) => {
      if (!menu.contains(event.target)) menu.open = false;
    });
  });
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    document.querySelectorAll("[data-menu][open]").forEach((menu) => { menu.open = false; });
    hideTip();
  });

  // Filters above a listing: the table follows what is typed, without losing the focus.
  function setUpLiveFilters(form) {
    if (form.dataset.ready) return;
    form.dataset.ready = "true";

    const submit = () => form.requestSubmit();
    form.addEventListener("input", debounce((event) => {
      if (event.target.matches("input[type=search]")) submit();
    }, FILTER_DELAY));
    form.addEventListener("change", (event) => {
      if (event.target.matches("select")) submit();
    });
  }

  // Tooltips: a product's card on hovering its link, and a line of explanation on the
  // labels of figures. The card comes from the server, once per product and page view.
  const cards = new Map();
  let tipAnchor = null;
  let tipTimer = null;
  let pointer = null;

  function tipElement() {
    let tip = document.getElementById("tip");
    if (!tip) {
      tip = document.createElement("div");
      tip.id = "tip";
      tip.className = "tip";
      tip.setAttribute("role", "tooltip");
      tip.hidden = true;
      document.body.append(tip);
    }
    return tip;
  }

  function loadCard(url) {
    if (!cards.has(url)) {
      cards.set(url, fetch(url)
        .then((response) => (response.ok ? response.text() : null))
        .catch(() => null)
        .then((html) => {
          if (html === null) cards.delete(url);
          return html;
        }));
    }
    return cards.get(url);
  }

  function clamp(value, low, high) {
    return Math.max(low, Math.min(value, high));
  }

  // Next to the pointer when it is what asked, else beside what has the focus.
  function place(tip, beside) {
    const margin = 10;
    const { width, height } = tip.getBoundingClientRect();
    let x;
    let y;
    if (pointer) {
      x = pointer.x + 16;
      y = pointer.y + 20;
      if (x + width > innerWidth - margin) x = pointer.x - width - 16;
      if (y + height > innerHeight - margin) y = pointer.y - height - 14;
    } else {
      const rect = (beside || tipAnchor).getBoundingClientRect();
      const anchor = tipAnchor.getBoundingClientRect();
      if (beside && rect.right + 8 + width <= innerWidth - margin) {
        x = rect.right + 8;
        y = anchor.top;
      } else if (beside && rect.left - 8 - width >= margin) {
        x = rect.left - 8 - width;
        y = anchor.top;
      } else {
        // Under or over the whole list when beside one, so as not to hide it.
        x = rect.left;
        y = rect.bottom + 8;
        if (y + height > innerHeight - margin) y = rect.top - height - 8;
      }
    }
    x = clamp(x, margin, innerWidth - width - margin);
    y = clamp(y, margin, innerHeight - height - margin);
    tip.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
  }

  async function showTip(anchor, beside) {
    const tip = tipElement();
    if (anchor.dataset.tooltip) {
      const html = await loadCard(anchor.dataset.tooltip);
      if (tipAnchor !== anchor || html === null) return;
      // Rendered and escaped by the server, like any other page.
      tip.innerHTML = html;
      tip.classList.add("tip-card");
    } else {
      tip.textContent = anchor.dataset.tip;
      tip.classList.remove("tip-card");
    }
    tip.hidden = false;
    anchor.setAttribute("aria-describedby", "tip");
    place(tip, beside);
  }

  function hideTip() {
    clearTimeout(tipTimer);
    if (tipAnchor) tipAnchor.removeAttribute("aria-describedby");
    tipAnchor = null;
    const tip = document.getElementById("tip");
    if (tip) tip.hidden = true;
  }

  function anchorOf(target) {
    return target.closest?.("[data-tooltip], [data-tip]") || null;
  }

  function delayOf(anchor) {
    return anchor.dataset.tooltip ? CARD_DELAY : TIP_DELAY;
  }

  // For a suggestion chosen with the keyboard: its card beside the list.
  function showTipBeside(anchor, list) {
    hideTip();
    tipAnchor = anchor;
    pointer = null;
    tipTimer = setTimeout(() => showTip(anchor, list), CARD_DELAY);
  }

  document.addEventListener("pointerover", (event) => {
    if (event.pointerType !== "mouse") return;
    const anchor = anchorOf(event.target);
    if (!anchor || anchor === tipAnchor) return;
    hideTip();
    tipAnchor = anchor;
    pointer = { x: event.clientX, y: event.clientY };
    tipTimer = setTimeout(() => showTip(anchor), delayOf(anchor));
  });
  document.addEventListener("pointermove", (event) => {
    if (!tipAnchor || event.pointerType !== "mouse") return;
    pointer = { x: event.clientX, y: event.clientY };
    const tip = document.getElementById("tip");
    if (tip && !tip.hidden) place(tip);
  }, { passive: true });
  document.addEventListener("pointerout", (event) => {
    if (!tipAnchor || !pointer) return;
    if (event.relatedTarget && tipAnchor.contains(event.relatedTarget)) return;
    if (tipAnchor.contains(event.target)) hideTip();
  });
  document.addEventListener("focusin", (event) => {
    const anchor = anchorOf(event.target);
    if (!anchor || anchor !== event.target || !anchor.matches(":focus-visible")) return;
    hideTip();
    tipAnchor = anchor;
    pointer = null;
    tipTimer = setTimeout(() => showTip(anchor), CARD_DELAY);
  });
  document.addEventListener("focusout", (event) => {
    if (tipAnchor && tipAnchor === event.target && !pointer) hideTip();
  });
  document.addEventListener("pointerdown", hideTip);
  document.addEventListener("scroll", () => { if (tipAnchor && pointer) hideTip(); }, { passive: true, capture: true });
  document.addEventListener("turbo:before-visit", hideTip);
  document.addEventListener("turbo:before-render", hideTip);

  function setUp() {
    document.querySelectorAll("[data-search]").forEach(setUpSearch);
    document.querySelectorAll("[data-realm-picker]").forEach(setUpRealmPicker);
    document.querySelectorAll("[data-live-filters]").forEach(setUpLiveFilters);
  }

  setUp();
  document.addEventListener("turbo:load", setUp);
  document.addEventListener("turbo:frame-load", setUp);
})();
