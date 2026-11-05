// The hover layer of the charts, which are drawn on the server. Without this script
// they stay readable, and every value remains in the table under each of them.

function nearestIndex(points, x) {
  let best = 0;
  points.forEach((point, index) => {
    if (Math.abs(point.x - x) < Math.abs(points[best].x - x)) best = index;
  });
  return best;
}

// Names come from outside this app: text nodes only, never markup.
function fillTooltip(tooltip, point) {
  const title = document.createElement("p");
  title.className = "tooltip-title";
  title.textContent = point.title;

  const rows = point.rows.map((row) => {
    const line = document.createElement("p");
    line.className = "tooltip-row";

    const key = document.createElement("span");
    key.className = `key key-line ${row.css_class}`;

    const value = document.createElement("strong");
    value.textContent = row.value;

    const name = document.createElement("span");
    name.className = "tooltip-name";
    name.textContent = row.name;

    line.append(key, value, name);
    return line;
  });

  tooltip.replaceChildren(title, ...rows);
}

function setUpChart(figure) {
  const svg = figure.querySelector("svg");
  const tooltip = figure.querySelector(".chart-tooltip");
  if (!svg || !tooltip) return;

  const points = JSON.parse(figure.dataset.points);
  const width = Number(figure.dataset.width);
  const crosshair = figure.querySelector(".crosshair");
  const marks = figure.querySelectorAll("[data-index]");
  let active = null;

  function show(index) {
    active = index;
    const point = points[index];
    fillTooltip(tooltip, point);
    tooltip.hidden = false;

    if (crosshair) {
      crosshair.setAttribute("x1", point.x);
      crosshair.setAttribute("x2", point.x);
      crosshair.setAttribute("visibility", "visible");
    }
    marks.forEach((mark) => {
      mark.classList.toggle("is-active", Number(mark.dataset.index) === index);
    });

    const scale = svg.getBoundingClientRect().width / width;
    const left = point.x * scale;
    const flip = left + tooltip.offsetWidth + 16 > svg.getBoundingClientRect().width;
    tooltip.style.left = `${flip ? left - tooltip.offsetWidth - 12 : left + 12}px`;
  }

  function hide() {
    tooltip.hidden = true;
    if (crosshair) crosshair.setAttribute("visibility", "hidden");
    marks.forEach((mark) => mark.classList.remove("is-active"));
  }

  svg.addEventListener("pointermove", (event) => {
    const box = svg.getBoundingClientRect();
    show(nearestIndex(points, ((event.clientX - box.left) / box.width) * width));
  });
  svg.addEventListener("pointerleave", hide);

  svg.addEventListener("focus", () => show(active ?? points.length - 1));
  svg.addEventListener("blur", hide);
  svg.addEventListener("keydown", (event) => {
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
}

document.querySelectorAll("[data-chart]").forEach(setUpChart);
