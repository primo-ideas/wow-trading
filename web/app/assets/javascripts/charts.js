// The hover layer of the charts, which are drawn on the server. Without this script
// they stay readable, and every value remains in the table under each of them.
(() => {
  const ready = new WeakSet();

  function nearestIndex(points, key, target) {
    let best = 0;
    points.forEach((point, index) => {
      if (Math.abs(point[key] - target) < Math.abs(points[best][key] - target)) best = index;
    });
    return best;
  }

  // Only ever text nodes and fixed class names: nothing here is parsed as markup.
  function valueNode(parts) {
    const value = document.createElement("strong");
    parts.forEach(([text, unit]) => {
      value.append(text);
      if (unit) {
        const coin = document.createElement("i");
        coin.className = `coin coin-${unit}`;
        value.append(coin);
      }
      value.append(" ");
    });
    return value;
  }

  function fillTooltip(tooltip, point) {
    const title = document.createElement("p");
    title.className = "tooltip-title";
    title.textContent = point.title;

    const rows = point.rows.map((row) => {
      const line = document.createElement("p");
      line.className = "tooltip-row";

      const key = document.createElement("span");
      key.className = `key key-line ${row.css_class}`;

      const name = document.createElement("span");
      name.className = "tooltip-name";
      name.textContent = row.name;

      line.append(key, valueNode(row.parts), name);
      return line;
    });

    tooltip.replaceChildren(title, ...rows);
  }

  function setUpChart(figure, group) {
    const area = figure.querySelector("[data-plot-area]");
    if (!area) return null;

    const plot = figure.querySelector(".plot");
    const tooltip = area.querySelector(".chart-tooltip");
    const crosshair = area.querySelector(".crosshair");
    const slots = area.querySelectorAll("[data-index]");
    const points = JSON.parse(figure.dataset.points);
    const markers = (figure.dataset.markers ? JSON.parse(figure.dataset.markers) : []).map((css) => {
      const marker = document.createElement("i");
      marker.className = `hover-dot ${css}`;
      marker.hidden = true;
      area.append(marker);
      return marker;
    });
    let active = null;

    function highlight(index) {
      active = index;
      const point = points[index];
      if (crosshair) {
        crosshair.hidden = false;
        crosshair.style.left = `${point.x}%`;
      }
      markers.forEach((marker, position) => {
        marker.hidden = false;
        marker.style.left = `${point.x}%`;
        marker.style.top = `${point.y[position]}%`;
      });
      slots.forEach((slot) => {
        slot.classList.toggle("is-active", Number(slot.dataset.index) === index);
      });
    }

    function clear() {
      tooltip.hidden = true;
      if (crosshair) crosshair.hidden = true;
      markers.forEach((marker) => { marker.hidden = true; });
      slots.forEach((slot) => slot.classList.remove("is-active"));
    }

    function placeTooltip(point) {
      fillTooltip(tooltip, point);
      tooltip.hidden = false;
      const width = area.getBoundingClientRect().width;
      const left = (point.x / 100) * width;
      const flip = left + tooltip.offsetWidth + 16 > width;
      tooltip.style.left = `${flip ? Math.max(left - tooltip.offsetWidth - 12, 0) : left + 12}px`;
    }

    function show(index) {
      highlight(index);
      placeTooltip(points[index]);
      group.forEach((other) => {
        if (other !== chart) other.follow(points[index].t);
      });
    }

    function leave() {
      clear();
      group.forEach((other) => {
        if (other !== chart) other.clear();
      });
    }

    area.addEventListener("pointermove", (event) => {
      const box = area.getBoundingClientRect();
      show(nearestIndex(points, "x", ((event.clientX - box.left) / box.width) * 100));
    });
    area.addEventListener("pointerleave", leave);

    plot.addEventListener("focus", () => show(active ?? points.length - 1));
    plot.addEventListener("blur", leave);
    plot.addEventListener("keydown", (event) => {
      const moves = {
        ArrowLeft: (active ?? points.length) - 1,
        ArrowRight: (active ?? -1) + 1,
        Home: 0,
        End: points.length - 1,
      };
      if (!(event.key in moves)) return;

      event.preventDefault();
      show(Math.min(Math.max(moves[event.key], 0), points.length - 1));
    });

    const chart = {
      clear,
      // Another chart of the page is being read: show the same moment here.
      follow(time) {
        if (points.length) highlight(nearestIndex(points, "t", time));
      },
    };
    return chart;
  }

  // Charts of one group show the same moment together; a chart of hours of the day has
  // nothing to show for a date, so it keeps to its own group.
  function setUpCharts() {
    const figures = [...document.querySelectorAll("[data-chart]")].filter((figure) => !ready.has(figure));
    const groups = new Map();
    figures.forEach((figure) => {
      ready.add(figure);
      const key = figure.dataset.chartGroup || "time";
      if (!groups.has(key)) groups.set(key, []);
      const group = groups.get(key);
      const chart = setUpChart(figure, group);
      if (chart) group.push(chart);
    });
  }

  setUpCharts();
  document.addEventListener("turbo:load", setUpCharts);
  document.addEventListener("turbo:frame-load", setUpCharts);
})();
