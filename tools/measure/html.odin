package measure

// The app's memory snapshots (src/app/snapshot.odin) as a page: a stacked
// bar per snapshot split into the groups, each group's items on hover, and
// a table of every item. The page is one file with the numbers in it, so
// it opens from disk.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Snapshot is one snapshot file.
Snapshot :: struct {
	snapshot:       string, // its UTC time, which names the file
	commit:         string,
	build:          string,
	uptime_s:       f64,
	window:         string, // points, then the scale
	footprint:      f64,
	footprint_peak: f64,
	items:          []Snapshot_Item,
}

// Snapshot_Item is one part of the footprint: its group, the pool of
// memory the OS counts it in, and its bytes.
Snapshot_Item :: struct {
	group: string,
	pool:  string,
	name:  string,
	bytes: f64,
}

// snapshots_html writes the page for the snapshots in dir to path.
snapshots_html :: proc(dir, path: string) -> int {
	snaps := load_snapshots(dir)
	if len(snaps) == 0 {
		fmt.eprintfln("measure: no snapshots in %s; the app menu's Take Memory Snapshot or SIGUSR1 takes one", dir)
		return 1
	}
	m := machine()
	page := snapshots_page(snaps, fmt.tprintf("%s, %s, %s%s", m.model, m.cpu, OS_LABEL, m.os), dir)
	if err := os.write_entire_file(path, transmute([]u8)page); err != nil {
		fmt.eprintfln("measure: can't write %s: %v", path, err)
		return 1
	}
	for snap in snaps {
		fmt.printfln("%s  %s, up %s, footprint %.1f MB, peak %.1f MB", snap.snapshot, snap.build, uptime(snap.uptime_s), snap.footprint / MB, snap.footprint_peak / MB)
	}
	fmt.printfln("%d snapshot%s from %s in %s", len(snaps), "" if len(snaps) == 1 else "s", dir, path)
	return 0
}

// load_snapshots reads the snapshots in dir, oldest first. Files that
// aren't snapshots are left out.
load_snapshots :: proc(dir: string, allocator := context.allocator) -> []Snapshot {
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	out := make([dynamic]Snapshot, allocator)
	for e in entries {
		if !strings.has_suffix(e.name, ".json") {
			continue
		}
		data, err := os.read_entire_file(e.fullpath, context.temp_allocator)
		snap: Snapshot
		if err == nil && json.unmarshal(data, &snap, allocator = allocator) == nil && snap.snapshot != "" {
			append(&out, snap)
		}
	}
	slice.sort_by(out[:], proc(a, b: Snapshot) -> bool {
		return a.snapshot < b.snapshot
	})
	return out[:]
}

// snapshots_page is the page for snaps.
snapshots_page :: proc(snaps: []Snapshot, machine, dir: string, allocator := context.allocator) -> string {
	data := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&data, `{{"machine":%q,"folder":%q,"snapshots":[`, machine, dir)
	for snap, i in snaps {
		fmt.sbprintf(&data, `%s{{"name":%q,"build":%q,"uptime":%q,"window":%q,"footprint":%.1f,"peak":%.1f,"items":[`,
			"," if i > 0 else "", snap.snapshot, fmt.tprintf("%s %s", snap.build, short_commit(snap.commit)), uptime(snap.uptime_s), snap.window, snap.footprint / MB, snap.footprint_peak / MB)
		for item, j in snap.items {
			fmt.sbprintf(&data, `%s{{"group":%q,"name":%q,"mb":%.2f}}`, "," if j > 0 else "", item.group, item.name, item.bytes / MB)
		}
		strings.write_string(&data, "]}")
	}
	strings.write_string(&data, "]}")
	// Nothing in the data is the app's text, but keep it from closing the
	// script anyway.
	json, _ := strings.replace_all(strings.to_string(data), "</", `<\/`, context.temp_allocator)
	page, _ := strings.replace(HTML_PAGE, "/*DATA*/null", json, 1, allocator)
	return page
}

@(private = "file")
short_commit :: proc(commit: string) -> string {
	dirty := strings.has_suffix(commit, "-dirty")
	if len(commit) < 7 {
		return commit if commit != "" else "?"
	}
	return strings.concatenate({commit[:7], "-dirty" if dirty else ""}, context.temp_allocator)
}

@(private = "file")
uptime :: proc(seconds: f64) -> string {
	s := int(seconds)
	if s < 3600 {
		return fmt.tprintf("%dm %02ds", s / 60, s % 60)
	}
	return fmt.tprintf("%dh %02dm", s / 3600, s / 60 % 60)
}

@(private = "file")
HTML_PAGE :: `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TIDALfast memory snapshots</title>
<style>
:root {
	color-scheme: light;
	--surface: #fcfcfb;
	--raised: #f3f2ef;
	--grid: #e6e5e1;
	--text: #0b0b0b;
	--text-2: #52514e;
	--muted: #75746f;
	--api: #2a78d6;
	--playback: #eb6834;
	--ui: #1baf7a;
	--gpu: #eda100;
	--system: #a9a8a2;
}
@media (prefers-color-scheme: dark) {
	:root:not([data-theme="light"]) {
		color-scheme: dark;
		--surface: #1a1a19;
		--raised: #242422;
		--grid: #33332f;
		--text: #f0efec;
		--text-2: #c3c2b7;
		--muted: #8f8e86;
		--api: #3987e5;
		--playback: #d95926;
		--ui: #199e70;
		--gpu: #c98500;
		--system: #6a6964;
	}
}
:root[data-theme="dark"] {
	color-scheme: dark;
	--surface: #1a1a19;
	--raised: #242422;
	--grid: #33332f;
	--text: #f0efec;
	--text-2: #c3c2b7;
	--muted: #8f8e86;
	--api: #3987e5;
	--playback: #d95926;
	--ui: #199e70;
	--gpu: #c98500;
	--system: #6a6964;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--surface); color: var(--text); font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
main { max-width: 1080px; margin: 0 auto; padding: 28px 16px 56px; }
h1 { font-size: 22px; margin: 0 0 4px; font-weight: 600; }
.sub { color: var(--text-2); margin: 0; }
.note { color: var(--muted); margin: 4px 0 16px; font-size: 13px; }
.legend { display: flex; flex-wrap: wrap; gap: 6px 18px; margin: 16px 0 12px; color: var(--text-2); font-size: 13px; }
.legend span { display: inline-flex; align-items: center; gap: 6px; }
.swatch { width: 10px; height: 10px; border-radius: 3px; flex: none; display: inline-block; }
.plot { position: relative; }
.row { display: grid; grid-template-columns: 104px 1fr; align-items: center; height: 34px; }
.stage { color: var(--text-2); font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; padding-right: 8px; }
.track { position: relative; height: 22px; margin-right: 64px; }
.grid { position: absolute; top: 0; bottom: 0; width: 1px; background: var(--grid); }
.bar { position: absolute; left: 0; top: 0; bottom: 0; display: flex; gap: 2px; }
.seg { height: 100%; min-width: 1px; outline: none; }
.seg:last-child { border-radius: 0 4px 4px 0; }
.seg:hover, .seg:focus-visible { filter: brightness(1.12); }
.total { position: absolute; top: 2px; padding-left: 8px; font-size: 13px; color: var(--text); font-variant-numeric: tabular-nums; white-space: nowrap; }
.axis { display: grid; grid-template-columns: 104px 1fr; height: 20px; }
.ticks { position: relative; margin-right: 64px; }
.tick { position: absolute; transform: translateX(-50%); font-size: 12px; color: var(--muted); font-variant-numeric: tabular-nums; }
.table-wrap { overflow-x: auto; margin-top: 20px; }
table { border-collapse: collapse; width: 100%; font-size: 13px; font-variant-numeric: tabular-nums; }
th, td { padding: 5px 10px; text-align: right; white-space: nowrap; }
th:first-child, td:first-child { text-align: left; }
thead th { color: var(--text-2); font-weight: 500; border-bottom: 1px solid var(--grid); }
tr.group td { font-weight: 600; padding-top: 12px; }
tr.group td:first-child { display: flex; align-items: center; gap: 8px; }
tr.item td:first-child { padding-left: 28px; color: var(--text-2); }
tr.zero td { color: var(--muted); }
tr.sum td { border-top: 1px solid var(--grid); font-weight: 600; }
tr.fp td { color: var(--text-2); }
#tip { position: fixed; pointer-events: none; z-index: 10; background: var(--raised); color: var(--text); border: 1px solid var(--grid); border-radius: 8px; padding: 10px 12px; font-size: 13px; min-width: 220px; max-width: 320px; box-shadow: 0 6px 20px rgba(0,0,0,.18); display: none; }
#tip .head { display: flex; align-items: center; gap: 8px; font-weight: 600; margin-bottom: 6px; }
#tip .line { display: flex; justify-content: space-between; gap: 16px; color: var(--text-2); font-variant-numeric: tabular-nums; }
#tip .line b { color: var(--text); font-weight: 500; }
@media (max-width: 560px) {
	.row, .axis { grid-template-columns: 84px 1fr; }
	.track, .ticks { margin-right: 56px; }
}
</style>
</head>
<body>
<main id="root"></main>
<div id="tip" role="tooltip"></div>
<script>
const DATA = /*DATA*/null;
const GROUPS = ["api", "playback", "ui", "gpu", "system"];
const LABELS = { api: "API", playback: "Playback", ui: "UI", gpu: "GPU", system: "System" };
const NOTES = {
	api: "TIDAL data: lists, the sidebar, artist pages, search, the session and the workers' scratch",
	playback: "the player, its ring buffer, stream windows and track data, and the queue",
	ui: "text caches and font tables, the cover index, the frame arena and app state",
	gpu: "glyph atlas, cover pages, instance buffers, drawables and the driver's own",
	system: "frameworks' malloc, binaries' data, stacks and anything else the app didn't allocate",
};

function el(tag, attrs, ...kids) {
	const e = document.createElement(tag);
	for (const k in attrs || {}) {
		if (k === "style") Object.assign(e.style, attrs[k]);
		else if (k === "class") e.className = attrs[k];
		else e.setAttribute(k, attrs[k]);
	}
	for (const kid of kids) e.append(kid);
	return e;
}
const mb = (v) => v.toFixed(1);
// A snapshot's name is its UTC time, 20261031-101500; show it in local time.
function stageName(name) {
	const m = /^(\d{4})(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)$/.exec(name);
	if (!m) return name;
	const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
	return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" });
}
const swatch = (g) => el("span", { class: "swatch", style: { background: "var(--" + g + ")" } });

function niceStep(max) {
	const raw = max / 5;
	const pow = Math.pow(10, Math.floor(Math.log10(raw)));
	for (const m of [1, 2, 2.5, 5, 10]) if (raw <= m * pow) return m * pow;
	return 10 * pow;
}

function groupTotals(stage) {
	const t = {};
	for (const g of GROUPS) t[g] = 0;
	for (const it of stage.items) t[it.group] += it.mb;
	return t;
}

const tip = document.getElementById("tip");
function showTip(e, stage, group, totals) {
	const sum = GROUPS.reduce((a, g) => a + totals[g], 0);
	const items = stage.items.filter((it) => it.group === group && it.mb >= 0.05).sort((a, b) => b.mb - a.mb);
	tip.replaceChildren(
		el("div", { class: "head" }, swatch(group), LABELS[group] + ", " + stageName(stage.stage)),
		el("div", { class: "line" }, "total", el("b", {}, mb(totals[group]) + " MB, " + Math.round(100 * totals[group] / sum) + "%")),
		...items.slice(0, 8).map((it) => el("div", { class: "line" }, it.name, el("b", {}, mb(it.mb) + " MB"))),
	);
	if (items.length > 8) tip.append(el("div", { class: "line" }, (items.length - 8) + " more in the table"));
	tip.style.display = "block";
	moveTip(e);
}
function moveTip(e) {
	const r = tip.getBoundingClientRect();
	let x = (e.clientX ?? 0) + 14, y = (e.clientY ?? 0) + 14;
	if (e.type === "focus") {
		const b = e.target.getBoundingClientRect();
		x = b.left; y = b.bottom + 8;
	}
	if (x + r.width > innerWidth - 8) x = innerWidth - r.width - 8;
	if (y + r.height > innerHeight - 8) y = y - r.height - 28;
	tip.style.left = Math.max(8, x) + "px";
	tip.style.top = Math.max(8, y) + "px";
}
const hideTip = () => { tip.style.display = "none"; };

function chart(setup) {
	const totals = setup.stages.map(groupTotals);
	const sums = totals.map((t) => GROUPS.reduce((a, g) => a + t[g], 0));
	const step = niceStep(Math.max(...sums, 1));
	const top = Math.ceil(Math.max(...sums, 1) / step) * step;
	const ticks = [];
	for (let v = 0; v <= top + 1e-9; v += step) ticks.push(v);
	const plot = el("div", { class: "plot" });
	setup.stages.forEach((stage, i) => {
		const track = el("div", { class: "track" });
		for (const v of ticks) track.append(el("div", { class: "grid", style: { left: (100 * v / top) + "%" } }));
		const width = 100 * sums[i] / top;
		const bar = el("div", { class: "bar", style: { width: width + "%" } });
		for (const g of GROUPS) {
			const v = totals[i][g];
			if (v <= 0) continue;
			const seg = el("div", {
				class: "seg", tabindex: "0",
				"aria-label": LABELS[g] + " " + mb(v) + " MB",
				style: { background: "var(--" + g + ")", flex: v + " 1 0" },
			});
			seg.addEventListener("mouseenter", (e) => showTip(e, stage, g, totals[i]));
			seg.addEventListener("mousemove", moveTip);
			seg.addEventListener("mouseleave", hideTip);
			seg.addEventListener("focus", (e) => showTip(e, stage, g, totals[i]));
			seg.addEventListener("blur", hideTip);
			bar.append(seg);
		}
		track.append(bar, el("div", { class: "total", style: { left: width + "%" } }, mb(sums[i]) + " MB"));
		const title = stageName(stage.stage) + ", " + stage.build + ", up " + stage.uptime + ", window " + stage.window + " pt";
		plot.append(el("div", { class: "row" }, el("div", { class: "stage", title: title }, stageName(stage.stage)), track));
	});
	const tickRow = el("div", { class: "ticks" });
	for (const v of ticks) tickRow.append(el("div", { class: "tick", style: { left: (100 * v / top) + "%" } }, String(v)));
	plot.append(el("div", { class: "axis" }, el("div", {}), tickRow));
	return plot;
}

function table(setup) {
	const totals = setup.stages.map(groupTotals);
	const head = el("tr", {}, el("th", {}, "MB"), ...setup.stages.map((s) => el("th", {}, stageName(s.stage))));
	const body = el("tbody");
	for (const g of GROUPS) {
		body.append(el("tr", { class: "group" }, el("td", {}, swatch(g), LABELS[g]), ...totals.map((t) => el("td", {}, mb(t[g])))));
		const names = [];
		for (const s of setup.stages) for (const it of s.items) if (it.group === g && !names.includes(it.name)) names.push(it.name);
		for (const name of names) {
			const vals = setup.stages.map((s) => s.items.filter((it) => it.group === g && it.name === name).reduce((a, it) => a + it.mb, 0));
			const zero = vals.every((v) => v < 0.05);
			body.append(el("tr", { class: zero ? "item zero" : "item" }, el("td", {}, name), ...vals.map((v) => el("td", {}, mb(v)))));
		}
	}
	body.append(el("tr", { class: "sum" }, el("td", {}, "Total"), ...totals.map((t) => el("td", {}, mb(GROUPS.reduce((a, g) => a + t[g], 0))))));
	body.append(el("tr", { class: "fp" }, el("td", {}, "Footprint"), ...setup.stages.map((s) => el("td", {}, mb(s.footprint)))));
	body.append(el("tr", { class: "fp" }, el("td", {}, "Peak footprint"), ...setup.stages.map((s) => el("td", {}, mb(s.peak)))));
	body.append(el("tr", { class: "fp" }, el("td", {}, "Uptime"), ...setup.stages.map((s) => el("td", {}, s.uptime))));
	body.append(el("tr", { class: "fp" }, el("td", {}, "Window, pt"), ...setup.stages.map((s) => el("td", {}, s.window))));
	body.append(el("tr", { class: "fp" }, el("td", {}, "Build"), ...setup.stages.map((s) => el("td", {}, s.build))));
	return el("div", { class: "table-wrap" }, el("table", {}, el("thead", {}, head), body));
}

const root = document.getElementById("root");
const setup = { stages: DATA.snapshots.map((s) => Object.assign({ stage: s.name }, s)) };
root.append(
	el("h1", {}, "Memory snapshots"),
	el("p", { class: "sub" }, DATA.machine + " · " + DATA.folder),
	el("p", { class: "note" }, "What the OS counts against the app (the footprint on macOS) at each snapshot, in MB. Hover a bar for the items in it, or a time for the build, uptime and window size."),
	el("div", { class: "legend" }, ...GROUPS.map((g) => el("span", { title: NOTES[g] }, swatch(g), LABELS[g]))),
	chart(setup),
	table(setup),
);
</script>
</body>
</html>
`
