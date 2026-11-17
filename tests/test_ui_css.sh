#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs'), path = require('path'), assert = require('assert');
const root = process.argv[2];
const api = fs.readFileSync(path.join(root, 'rootfs/www/luci-static/resources/xraywrt/api.js'), 'utf8');
const css = api.match(/const CSS = `([\s\S]*?)`;/)[1].replace(/\.mw-sr\s*\{[^}]*\}/g, '');
assert(!/(?:font(?:-[\w-]+)?|opacity|color|background(?:-[\w-]+)?|border(?:-[\w-]+)?|outline(?:-[\w-]+)?)\s*:/.test(css), 'XrayWRT CSS must leave visual styles to the theme');
console.log('ok - layout-only XrayWRT CSS');
// Material gives the LuCI page tabs negative margins; cap their width so the
// XrayWRT menu cannot extend beyond a 390px viewport (398px before this cap).
assert(/#tabmenu\s*>\s*\.tabs\s*\{[^}]*max-width:\s*100%/.test(css), 'page tabs must fit the viewport despite theme negative margins');
console.log('ok - bounded page tab layout');
assert(/\.mw-page\s+\[hidden\],\s*\.mw-row\[hidden\]\s*\{\s*display:\s*none;?\s*\}/.test(css), 'hidden toggle content must override grid and theme display rules');
console.log('ok - hidden toggle content layout');
// Spacing and alignment keep blocks consistent with stock LuCI pages in every theme.
assert(/\.mw-toggle\s*>\s*\.mw-row\s*\+\s*\*\s*\{[^}]*margin-top:\s*12px/.test(css), 'opened toggle content keeps a gap under its button');
assert(/\.mw-page\s*>\s*h2\s*\{\s*margin-bottom:\s*0;?\s*\}/.test(css) && !/\.mw-page\s*>\s*h2[^{]*\{[^}]*margin:\s*0/.test(css), 'page title keeps the theme top margin');
assert(/\.mw-announce\s*\+\s*\.mw-grid\s*\{[^}]*margin-top:\s*12px/.test(css), 'announce text is separated from the subscription grid');
assert(/\.mw-status\s*\{[^}]*flex-direction:\s*column/.test(css), 'status facts are stacked');
// Phone: equal-width columns, so a lone third button (Website) is not stretched to the full row.
assert(/\.mw-actions\s*\{[^}]*display:\s*grid;[^}]*grid-template-columns:\s*repeat\(auto-fill,\s*minmax\(min\(100%,\s*10em\),\s*1fr\)\)/.test(css), 'phone action buttons in equal columns');
assert(!/\.mw-actions\s*>\s*\.cbi-button\s*\{[^}]*flex:\s*1 1 auto/.test(css), 'no stretching flex rule for action buttons');
assert(/\.mw-actions\s*\{[^}]*align-items:\s*stretch/.test(css) && /\.mw-actions\s*>\s*\.cbi-button\s*\{\s*margin:\s*0;?\s*\}/.test(css), 'grid cells align: same row height, no theme margins (openwrt-2020)');
const overview = fs.readFileSync(path.join(root, 'rootfs/www/luci-static/resources/view/xraywrt/overview.js'), 'utf8');
assert(/class: 'mw-toggle'/.test(api), 'toggle wrapper marked for spacing');
assert(/function linkButton/.test(api) && /api\.linkButton\(sub\./.test(overview) && !/safeLink\(sub\./.test(overview), 'provider links are theme buttons, not unstyled links');
assert(/\.mw-job:empty\s*\{[^}]*position:\s*absolute/.test(css) && /class: 'mw-job'/.test(api), 'empty job notice takes no flex gap');
assert(/\.mw-picker\s*>\s*select\s*\{\s*flex:\s*1 1 12em;\s*min-width:\s*0;\s*max-width:\s*100%;\s*\}/.test(css), 'picker selects share the row and shrink on a phone');
console.log('ok - layout review spacing and alignment');
// Settings selects (Traffic mode) fit their longest option instead of the theme's fixed width.
const settings = fs.readFileSync(path.join(root, 'rootfs/www/luci-static/resources/view/xraywrt/advanced.js'), 'utf8');
assert(/\.mw-settings\s+\.cbi-value-field\s+select\s*\{[^}]*width:\s*auto;[^}]*min-width:\s*min-content;[^}]*max-width:\s*100%/.test(css), 'settings selects size to their longest option and still fit a phone');
assert(/E\('div',\s*\{\s*class:\s*'mw-settings'\s*\}/.test(settings), 'settings page carries the mw-settings scope class');
console.log('ok - settings select width');

NODE
