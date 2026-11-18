'use strict';
'require view';
'require uci';
'require ui';
'require xraywrt.api as api';

const text = api.text;
const MIB = 1048576;
// Release size is compressed APK size, not installed flash usage.
const RAM_MARGIN = 16 * MIB;

function coreNotice(res) {
	if (!res?.updated)
		return _('Xray core %s is up to date.').format(res?.version || '');
	return (res.restarted ? _('Xray core updated to %s; XrayWRT restarted.') : _('Xray core updated to %s.')).format(res.version || '');
}

function fileInput(id, label) {
	return E('input', { id, type: 'file', class: 'cbi-input-file', 'aria-label': label });
}

// The XrayWRT core is the only production core.
function coreSection(status, diagnostics) {
	const readOnly = api.readOnly();
	const src = status.core_source || {};
	const check = E('button', { 'data-mw-job': '', class: 'cbi-button', type: 'button', disabled: api.jobRunning || null }, text(_('Check for updates')));
	const update = E('button', { 'data-mw-job': '', class: 'cbi-button cbi-button-action', disabled: api.jobRunning || null }, text(_('Update the core')));
	const result = E('div', { 'aria-live': 'polite' });

	const free = (kb) => typeof kb === 'number' && isFinite(kb) ? kb * 1024 : null;
	const ram = free(diagnostics?.ram_available_kb);
	const origin = api.coreOrigin(src);
	// One grid for every fact, so the value column and row gaps are shared.
	const factRows = () => {
		const rows = [
			[ _('Core version'), status.core || _('not installed') ],
			[ _('Core source'), origin ]
		];

		return rows;
	};
	const spaceWarning = size => {
		if (!(size > 0))
			return '';
		if (ram != null && ram < size + RAM_MARGIN)
			return _('Not enough free memory to download this core.');
		return '';
	};
	const factsBox = E('div', {}, [ api.infoGrid(factRows()) ]);

	// Confirms run before api.busy: a modal dismissed from outside must not leave job buttons locked.
	const confirmInstall = () => api.confirm(_('Update the core'), _('XrayWRT restarts after the update; the internet drops for a few seconds.'), _('Update'));
	// Always with a backup copy first. core.sh ends every "cannot make a backup copy" refusal with this text;
	// only then ask whether to install without it. install(noRollback) starts the job.
	const runInstall = async (button, install) => {
		let failure;
		await api.busy(button, async () => {
			try { api.reloadWithNotice(coreNotice(await install(false))); } catch (e) { failure = e; }
		});
		if (!failure)
			return;
		if (!String(failure.message).includes('--no-rollback installs without it')
			|| !await api.confirm(_('Update without a backup copy?'), api.errorText(failure) + ' ' + _('If the new core does not start, there is no working core until you install one again, and traffic goes direct.'), _('Update'), { danger: true }))
			return api.notify(api.errorText(failure), 'error');
		return api.busy(button, async () => { api.reloadWithNotice(coreNotice(await install(true))); });
	};

	check.addEventListener('click', () => api.busy(check, async () => {
		result.replaceChildren();
		const res = await api.coreCheck();
		const size = Number(res.latest?.size) || 0;
		const warning = spaceWarning(size);
		// The package's version is the core version (spec 4.5).
		const latest = String(res.latest?.version || res.latest?.tag || '');
		result.replaceChildren(
			res.error ? E('div', { class: 'alert-message error', role: 'alert' }, text(api.errorText('Core update: ' + res.error)))
				: E('p', text(res.update_available ? _('A new core is available: %s.').format(latest) : _('The core is up to date.'))),
			warning ? E('div', { class: 'alert-message warning' }, text(warning)) : '');
		factsBox.replaceChildren(api.infoGrid(factRows()));
	}));
	// Spec 4.4: Update checks first and installs only a different release.
	update.addEventListener('click', async () => {
		if (update.disabled || api.jobRunning)
			return;
		let res;
		await api.busy(update, async () => { res = await api.coreCheck(); });
		if (!res)
			return;
		if (res.error)
			return api.notify(api.errorText('Core update: ' + res.error), 'error');
		if (!res.update_available)
			return api.notify(_('No update available.'), 'info');
		if (!await confirmInstall())
			return;
		return runInstall(update, noRollback => api.coreUpdate({ noRollback }));
	});

	return E('div', { class: 'cbi-section' }, [
		E('h3', text(_('Xray core'))),
		factsBox,
		...(readOnly ? [] : [
			E('div', { class: 'mw-row mw-actions' }, [ check, update ]),
			result,
			...(src.source === 'package'
				? [ E('p', { class: 'cbi-value-description' }, text(_('The core is installed as the XrayWRT core package. "Update the core" updates that package.'))) ] : [])
		])
	]);
}

function geodataLinks(saved) {
	const rows = [];
	const body = E('tbody');
	const table = E('table', { class: 'table cbi-section-table' }, [
		E('thead', {}, [E('tr', { class: 'tr table-titles' }, [_('File name'), _('File URL'), _('Actions')].map(label => E('th', { class: 'th', scope: 'col' }, text(label))))]), body
	]);
	// Without rows the table would show only its header.
	const tableBox = E('div', {});
	const showTable = () => tableBox.replaceChildren(...(rows.length ? [ table ] : []));
	const addRow = (entry = '') => {
		const split = entry.indexOf('=');
		const name = E('input', { type: 'text', class: 'cbi-input-text', 'aria-label': _('File name'), value: split < 0 ? entry : entry.slice(0, split), placeholder: 'own.dat', spellcheck: 'false' });
		const url = E('input', { type: 'url', class: 'cbi-input-text', 'aria-label': _('File URL'), value: split < 0 ? '' : entry.slice(split + 1), placeholder: 'https://example.com/own.dat', spellcheck: 'false' });
		const remove = E('button', { type: 'button', class: 'cbi-button cbi-button-remove' }, text(_('Remove')));
		const node = E('tr', { class: 'tr' }, [name, url, remove].map(input => E('td', { class: 'td' }, [input])));
		const row = { name, url, node };
		remove.addEventListener('click', () => { rows.splice(rows.indexOf(row), 1); body.removeChild(node); showTable(); });
		rows.push(row);
		body.appendChild(node);
		showTable();
	};
	for (const entry of saved) addRow(entry);
	const add = E('button', { type: 'button', class: 'cbi-button' }, text(_('Add file')));
	add.addEventListener('click', () => addRow());
	// Always at 05:00: nobody notices the reload at night. A schedule typed by hand earlier stays as its own option.
	const savedCron = uci.get('xraywrt', 'settings', 'geodata_cron') || '0 5 * * *';
	const schedules = [ [ '0 5 * * *', _('Every day at 05:00') ], [ '0 5 */3 * *', _('Every 3 days at 05:00') ], [ '0 5 * * 0', _('Every week at 05:00') ] ];
	if (!schedules.some(([ value ]) => value === savedCron))
		schedules.push([ savedCron, _('Own schedule (%s)').format(savedCron) ]);
	const cron = E('select', { id: 'mw-geodata-cron', class: 'cbi-input-select' },
		schedules.map(([ value, label ]) => E('option', { value, selected: value === savedCron ? '' : null }, text(label))));
	cron.value = savedCron;
	const save = E('button', { type: 'button', 'data-mw-job': '', class: 'cbi-button cbi-button-apply', disabled: api.jobRunning || null }, text(_('Save links')));
	save.addEventListener('click', () => api.busy(save, async () => {
		const entries = rows.map(row => {
			const name = row.name.value, url = row.url.value;
			if (!api.GEODATA_NAME.test(name)) throw new Error(_('The name must end with .dat and contain only letters, digits, dot, dash and underscore.'));
			if (!/^https:\/\/[^\s\x00-\x1f\x7f/?#]+[^\s\x00-\x1f\x7f]*$/.test(url)) throw new Error(_('Use an HTTPS URL without spaces.'));
			return name + '=' + url;
		});
		if (entries.length) uci.set('xraywrt', 'settings', 'geodata_asset', entries);
		else uci.unset('xraywrt', 'settings', 'geodata_asset');
		uci.set('xraywrt', 'settings', 'geodata_cron', cron.value);
		await uci.save();
		return ui.changes.apply(true);
	}));
	return E('div', {}, [
		E('h4', text(_('By link'))),
		E('p', { class: 'cbi-value-description' }, text(_('Use a unique .dat name. If the subscription has a file with the same name, the subscription\'s file wins.'))),
		tableBox,
		E('div', { class: 'mw-row' }, [ add ]),
		E('div', { class: 'cbi-value' }, [
			E('label', { class: 'cbi-value-title', for: 'mw-geodata-cron' }, text(_('Geodata update schedule'))),
			E('div', { class: 'cbi-value-field' }, [cron, E('p', { class: 'cbi-value-description' }, text(_('Applies only when the subscription sets no schedule of its own.')))])
		]), save
	]);
}

function geodataSection(status) {
	const readOnly = api.readOnly();
	const files = status.geodata || [];
	const saved = [].concat(uci.get('xraywrt', 'settings', 'geodata_asset') || []);
	const cell = (value) => E('td', { class: 'td' }, text(value));
	const table = files.length ? E('table', { class: 'table cbi-section-table' }, [
		E('tr', { class: 'tr table-titles' }, [ _('File'), _('Source'), _('Present'), _('Size'), _('Date') ]
			.map(label => E('th', { class: 'th' }, text(label)))),
		...files.map(f => E('tr', { class: 'tr' }, [
			cell(f.file),
			cell(f.asset ? _('linked file') : _('uploaded or missing')),
			cell(f.present ? _('yes') : _('no')),
			cell(f.present ? api.formatBytes(f.size) : '—'),
			cell(f.present ? api.formatDate(f.mtime) : '—')
		]))
	]) : E('p', { class: 'mw-muted' }, text(_('The configuration uses no rule database files.')));

	const refresh = E('button', { 'data-mw-job': '', class: 'cbi-button cbi-button-action', disabled: api.jobRunning || null }, text(_('Update rule databases')));
	refresh.addEventListener('click', () => api.busy(refresh, async () => {
		api.reloadResult(await api.geodataUpdate({ force: true }), _('Rule databases updated.'));
	}));
	const name = E('input', { id: 'mw-geo-name', type: 'text', class: 'cbi-input-text', autocomplete: 'off', spellcheck: 'false', placeholder: 'geosite.dat' });
	const file = fileInput('mw-geo-file', _('Rule database file'));
	const upload = E('button', { 'data-mw-job': '', class: 'cbi-button', disabled: api.jobRunning || null }, text(_('Upload')));
	upload.addEventListener('click', () => api.busy(upload, async () => {
		const chosen = file.files?.[0], target = name.value.trim() || chosen?.name || '';
		if (!chosen)
			throw new Error(_('Choose the .dat file first.'));
		if (!api.GEODATA_NAME.test(target))
			throw new Error(_('The name must end with .dat and contain only letters, digits, dot, dash and underscore.'));
		if (chosen.size > api.CORE_ASSET_MAX_BYTES)
			throw new Error(_('The file is larger than 64 MB.'));
		if (!await api.confirm(_('Upload a file'), _('Files used by your settings are checked before replacement unless another required file is still missing. Unused files cannot be checked now; they will be checked when settings start using them.'), _('Upload'))) return;
		const path = await api.upload('xraywrt-geodata', chosen);
		api.reloadResult(await api.geodataUpdate({ file: path, name: target }), _('Rule databases updated.'));
	}));

	return E('div', { class: 'cbi-section' }, [
		E('h3', text(_('Rule databases'))),
		E('p', { class: 'mw-muted' }, text(_('Rule databases (geodata) are the geosite/geoip files your configuration needs. The subscription lists them and Xray refreshes them on its own schedule; missing files are downloaded before start.'))),
		table,
		...(readOnly ? [] : [
			...(files.length ? [ E('div', { class: 'mw-row' }, [ refresh ]) ] : []),
			// One block for both ways; open when links are already saved.
			api.toggle(_('Add my own rule database'), _('Hide my own rule databases'), E('div', { class: 'mw-page' }, [
				E('p', { class: 'cbi-value-description' }, text(_('For a .dat file the subscription does not supply. Add it by link (it then updates by itself) or upload it once from this computer.'))),
				geodataLinks(saved),
				E('div', {}, [
					E('h4', text(_('From a file'))),
					// Standard rows: the field column keeps the theme's focus outline inside the card.
					E('div', { class: 'cbi-value' }, [
						E('label', { class: 'cbi-value-title', for: 'mw-geo-file' }, text(_('Rule database file'))),
						E('div', { class: 'cbi-value-field' }, [ file ]) ]),
					E('div', { class: 'cbi-value' }, [
						E('label', { class: 'cbi-value-title', for: 'mw-geo-name' }, text(_('File name'))),
						E('div', { class: 'cbi-value-field' }, [ name,
							E('div', { class: 'cbi-value-description' }, text(_('Name: as the configuration refers to it, for example geosite.dat; empty: the file name.'))) ]) ]),
					upload
				])
			]), undefined, saved.length > 0)
		])
	]);
}

return view.extend(api.guardView({
	load: () => Promise.all([
		api.status(),
		api.read('diagnostics-json').catch(() => ({})),
		uci.load('xraywrt')
	]),

	render: ([ status, diagnostics ]) => E('div', { class: 'mw-page' }, [
		api.style(),
		E('h2', text(_('Updates'))),
		api.jobNotice(),
		coreSection(status, diagnostics),
		geodataSection(status)
	]),

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
}, _('Updates')));
