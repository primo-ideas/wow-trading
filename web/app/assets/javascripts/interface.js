// Comforts on top of plain links and forms, which all work without this script.
(() => {
  const SEARCH_DELAY = 180;
  const FILTER_DELAY = 250;

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

  // Search box: suggestions as you type, driven by the keyboard.
  function setUpSearch() {
    const form = document.querySelector("[data-search]");
    if (!form || form.dataset.ready) return;
    form.dataset.ready = "true";

    const input = form.querySelector("input[type=search]");
    const results = form.querySelector(".search-results");
    let active = -1;
    let latestRequest = 0;

    const options = () => [...results.querySelectorAll(".result")];

    function close() {
      results.hidden = true;
      input.setAttribute("aria-expanded", "false");
      active = -1;
    }

    function setActive(index) {
      const all = options();
      if (!all.length) return;
      active = (index + all.length) % all.length;
      all.forEach((option, position) => option.classList.toggle("is-active", position === active));
      all[active].scrollIntoView({ block: "nearest" });
    }

    const suggest = debounce(async () => {
      const query = input.value.trim();
      if (query.length < 2) return close();

      const request = ++latestRequest;
      const response = await fetch(`${form.action}?q=${encodeURIComponent(query)}&fragment=1`);
      // A slower, older answer must not replace a newer one.
      if (request !== latestRequest || !response.ok) return;

      // Rendered and escaped by the server, like any other page.
      results.innerHTML = await response.text();
      results.hidden = false;
      input.setAttribute("aria-expanded", "true");
      active = -1;
    }, SEARCH_DELAY);

    input.addEventListener("input", suggest);
    input.addEventListener("focus", () => {
      if (results.children.length && input.value.trim().length >= 2) results.hidden = false;
    });
    input.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") {
        event.preventDefault();
        setActive(active + 1);
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        setActive(active - 1);
      } else if (event.key === "Enter" && active >= 0) {
        event.preventDefault();
        visit(options()[active].href);
      } else if (event.key === "Escape") {
        close();
        input.blur();
      }
    });
    document.addEventListener("click", (event) => {
      if (!form.contains(event.target)) close();
    });
  }

  // The one shortcut every search box has.
  document.addEventListener("keydown", (event) => {
    const shortcut = (event.key === "/" && !isTyping(event.target)) ||
      (event.key.toLowerCase() === "k" && (event.ctrlKey || event.metaKey));
    if (!shortcut) return;

    const input = document.querySelector("[data-search] input[type=search]");
    if (input) {
      event.preventDefault();
      input.focus();
      input.select();
    }
  });

  // Dropdowns: close on a click elsewhere or Escape, and filter long lists.
  function setUpMenus() {
    document.querySelectorAll("[data-menu-filter]").forEach((filter) => {
      if (filter.dataset.ready) return;
      filter.dataset.ready = "true";

      filter.addEventListener("input", () => {
        const text = filter.value.trim().toLowerCase();
        filter.closest("[data-menu]").querySelectorAll("[data-menu-item]").forEach((item) => {
          item.hidden = !item.dataset.menuItem.includes(text);
        });
      });
    });
  }

  document.addEventListener("click", (event) => {
    document.querySelectorAll("[data-menu][open]").forEach((menu) => {
      if (!menu.contains(event.target)) menu.open = false;
    });
  });
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    document.querySelectorAll("[data-menu][open]").forEach((menu) => { menu.open = false; });
  });
  document.addEventListener("toggle", (event) => {
    if (event.target.matches?.("[data-menu][open]")) {
      event.target.querySelector("[data-menu-filter]")?.focus();
    }
  }, true);

  // Filters above a listing: the table follows what is typed, without losing the focus.
  function setUpLiveFilters() {
    document.querySelectorAll("[data-live-filters]").forEach((form) => {
      if (form.dataset.ready) return;
      form.dataset.ready = "true";

      const submit = () => form.requestSubmit();
      form.addEventListener("input", debounce((event) => {
        if (event.target.matches("input[type=search]")) submit();
      }, FILTER_DELAY));
      form.addEventListener("change", (event) => {
        if (event.target.matches("select")) submit();
      });
    });
  }

  function setUp() {
    setUpSearch();
    setUpMenus();
    setUpLiveFilters();
  }

  setUp();
  document.addEventListener("turbo:load", setUp);
})();
