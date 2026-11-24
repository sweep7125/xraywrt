'use strict';
'require baseclass';
'require ui';
'require xraywrt.api as api';

const text = api.text;

const configNotice = action => action === 'unchanged' ? _('Configuration is unchanged.')
	: action === 'restarted' ? _('Configuration checked and applied; Xray restarted.')
	: action === 'hot_reloaded' ? _('Configuration checked and applied without restarting Xray.') : _('Configuration checked and saved.');
const CONFIG_MAX_BYTES = 8388608;
// One-line JSON is hard to edit. Pretty-print it unless that could change meaning:
// 16+ digit integers lose precision in JSON.parse. Anything else is shown as stored.
const prettyIfSafe = stored => {
	if (/[\r\n]|\d{16}/.test(stored))
		return stored;
	try {
		return JSON.stringify(JSON.parse(stored), null, 2);
	}
	catch (_) { return stored; }
};

// Error state with a way forward; the region is busy while it loads.
const loadError = (e, retry) => {
	const again = E('button', { class: 'cbi-button', type: 'button' }, text(_('Try again')));
	again.addEventListener('click', retry);
	return E('div', { class: 'alert-message error', role: 'alert' }, [
		E('p', text(_('Cannot load the configuration: %s').format(api.errorText(e)))), again ]);
};
const loadingState = box => {
	box.setAttribute('aria-busy', 'true');
	box.replaceChildren(E('p', { class: 'spinning' }, text(_('Loading…'))));
};
const readConfig = async cmd => {
	const reply = await (cmd === 'runtime-config' ? api.runtimeConfig() : api.readLarge(cmd));
	if (typeof reply?.content !== 'string')
		throw new Error(_('Unexpected response from the router.'));
	// The editor formats only compact text that JSON.parse cannot damage; see prettyIfSafe.
	if (cmd === 'runtime-config')
		try {
			reply.content = JSON.stringify(JSON.parse(reply.content), null, 2);
		}
		catch (_) { /* Show the text as it is. */ }
	return reply;
};

function renderEditor(sub) {
	const readOnly = api.readOnly();
	const apply = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-apply' }, text(_('Save config')));
	const validate = E('button', { class: 'cbi-button', type: 'button' }, text(_('Validate')));
	// Xray's own answer to Validate; announced, kept until the next check.
	const checkResult = E('div', { 'aria-live': 'polite' });
	// The config (up to 8 MiB) loads on the first opening of the editor.
	const editorBody = E('div', {});
	const editor = E('div', {}, [
		(sub.configured ?? !!sub.url) ? E('div', { class: 'alert-message warning' }, text(_('Subscription updates, including automatic ones, replace your edits.'))) : '',
		E('p', { class: 'mw-muted' }, text(_('Use Xray JSON with outbounds. For several profiles, use an array and choose by remarks on Home. XrayWRT adds router rules. Put router settings under xraywrt.'))),
		editorBody
	]);
	let configArea = null, original = null, loading = null;

	const onBeforeUnload = e => {
		if (configArea && configArea.value !== original) {
			e.preventDefault();
			e.returnValue = '';
		}
	};
	if (typeof window !== 'undefined' && window.addEventListener)
		window.addEventListener('beforeunload', onBeforeUnload);
	const dropGuard = () => {
		if (typeof window !== 'undefined' && window.removeEventListener)
			window.removeEventListener('beforeunload', onBeforeUnload);
	};
	const uploadEdited = async () => {
		if (new Blob([configArea.value]).size > CONFIG_MAX_BYTES)
			throw new Error(_('The configuration is larger than 8 MiB.'));
		return api.upload('xraywrt-config', configArea.value);
	};
	apply.addEventListener('click', () => api.busy(apply, async () => {
		if (configArea.value === original)
			return api.notify(configNotice('unchanged'));
		const res = await api.job('save-config', await uploadEdited());
		dropGuard();
		api.reloadResult(res, configNotice(res.action));
	}));
	// config-check tests the edited config; missing geodata may be installed.
	validate.addEventListener('click', () => api.busy(validate, async () => {
		checkResult.replaceChildren(E('p', { class: 'spinning' }, text(_('Checking…'))));
		let res;
		try {
			res = await api.configCheck(await uploadEdited());
		}
		catch (e) {
			checkResult.replaceChildren();
			throw e;
		}
		const output = api.coreError(res.output || '');
		checkResult.replaceChildren(res.ok
			? E('div', { class: 'alert-message success' }, text(_('The configuration is valid: Xray accepts it.')))
			: E('div', { class: 'alert-message error', role: 'alert' }, [
				E('p', text(api.errorText(res.error || _('The configuration is invalid.')))),
				...(output ? [ E('pre', { class: 'mw-log' }, text(output)) ] : [])
			]));
	}));

	const restore = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null,
		class: 'cbi-button cbi-button-reset' }, text(_('Restore previous config')));
	restore.addEventListener('click', async () => {
		if (restore.disabled || api.jobRunning)
			return;
		if (!await api.confirm(_('Restore previous config'), _('Restore the previous config?'), _('Restore previous config'), { danger: true }))
			return;
		return api.busy(restore, async () => {
			const res = await api.job('restore-config');
			dropGuard();
			api.reloadResult(res, configNotice(res.action));
		});
	});
	const restoreNote = E('div', { class: 'cbi-value-description' },
		text(_('Automatic updates will replace the restored configuration again.')));
	restoreNote.hidden = sub.auto_update === false;
	const openEditor = () => {
		if (configArea || loading)
			return;
		loadingState(editorBody);
		loading = readConfig('read-config').then(config => {
			// LuCI's own monospace textarea (as for code fields on stock pages).
			const widget = new ui.Textarea(prettyIfSafe(config.content), { id: 'mw-config', monospace: true, wrap: false, rows: 24 }).render();
			configArea = widget.querySelector('textarea');
			configArea.classList.add('mw-code');
			configArea.setAttribute('spellcheck', 'false');
			// The textarea normalises CRLF; compare against what it holds, not the stored bytes.
			original = configArea.value;
			editorBody.replaceChildren(
				E('label', { class: 'cbi-value-title mw-label', for: 'widget.mw-config' }, text(_('config.json'))),
				widget,
				...(readOnly ? [] : [ E('div', { class: 'mw-row' }, [ validate, apply, ...(sub.config_backup ? [ restore ] : []) ]), checkResult ]),
				...(sub.config_backup && !readOnly ? [ restoreNote ] : []));
		}).catch(e => {
			editorBody.replaceChildren(loadError(e, openEditor));
		}).finally(() => {
			editorBody.removeAttribute('aria-busy');
			loading = null;
		});
	};


	return E('div', { class: 'mw-page' }, [ api.style(), E('div', { class: 'cbi-section' }, [
		...(!readOnly ? [ E('h3', text(_('Xray config'))),
			E('p', { class: 'cbi-value-description' }, text(_('Use “Save config” below to apply editor changes.'))),
			api.toggle(_('Show config editor'), _('Hide config editor'), editor, openEditor) ] : [])
	]) ]);
}

return baseclass.extend({
	load: () => api.read('subscription-json').catch(e => ({ error: e })),

	render: function(sub, section) {
		if (sub?.error) {
			const again = E('button', { class: 'cbi-button', type: 'button' }, text(_('Try again')));
			again.addEventListener('click', () => location.reload());
			return E('div', { class: 'mw-page' }, [
				api.style(),

					E('div', { class: 'alert-message error', role: 'alert' }, [
					E('p', text(_('Cannot load subscription settings: %s').format(api.errorText(sub.error)))),
					again
				])
			]);
		}
		if (section === 'editor')
			return renderEditor(sub);
		if (section === 'runtime') {
			// Read-only: what Xray actually runs with, re-read on every opening.
			// The backend hides secrets (spec 15).
			const runtime = E('div', {});
			let runtimeRequest = 0;
			const openRuntime = () => {
				// Only the latest opening may fill the view.
				const request = ++runtimeRequest;
				loadingState(runtime);
				readConfig('runtime-config').then(config => {
					if (request !== runtimeRequest)
						return;
					runtime.removeAttribute('aria-busy');
					const widget = new ui.Textarea(config.content, { id: 'mw-runtime', monospace: true, wrap: false, rows: 24, readonly: true }).render();
					const area = widget.querySelector('textarea');
					area.classList.add('mw-code');
					area.setAttribute('spellcheck', 'false');
					area.setAttribute('aria-label', _('Configuration passed to Xray'));
					runtime.replaceChildren(
						E('p', { class: 'mw-muted' }, text(_('Config passed to Xray, with router rules added. Secrets are masked with ***.'))),
						...(config.generated === true ? [ E('p', { class: 'mw-muted' }, text(_('XrayWRT is not running; this is what it would pass at start.'))) ] : []),
						widget);
				}).catch(e => {
					if (request !== runtimeRequest)
						return;
					runtime.removeAttribute('aria-busy');
					runtime.replaceChildren(loadError(e, openRuntime));
				});
			};

			return E('div', { class: 'mw-page' }, [ api.style(),
				E('div', { class: 'cbi-section mw-page' }, [ api.toggle(_('Show running config'), _('Hide running config'), runtime, openRuntime) ]) ]);
		}
		const readOnly = api.readOnly();
		// Saved subscriptions; without any, the page is the one-link form.
		const items = Array.isArray(sub.subscriptions) ? sub.subscriptions : [];
		// type=text: some themes (openwrt-2020) style only text inputs.
		const url = E('input', { id: 'mw-url', type: 'text', inputmode: 'url', autocomplete: 'off', spellcheck: 'false',
			class: 'cbi-input-text', style: 'width: 100%',
			value: sub.url || '', placeholder: 'https://provider.example/sub/…' });
		const urlForm = E('form', { action: '', style: 'width: 100%' }, [ url ]);
		urlForm.addEventListener('submit', e => {
			e.preventDefault();
			if (readOnly)
				return;
			(url.value.trim() ? update : save).click();
		});
		const auto = E('input', { id: 'mw-auto', type: 'checkbox', class: 'cbi-input-checkbox',
			disabled: readOnly || !sub.url || api.jobRunning || null, checked: sub.auto_update !== false ? '' : null });
		const autoWidget = E('div', { class: 'cbi-checkbox' }, [ auto, E('label', { for: 'mw-auto' }, [ E('i', {}) ]) ]);
		const autoHint = E('div', { class: 'cbi-value-description' });
		// The header period also counts while auto-update is still off.
		const header = Number(sub.header_interval);
		const period = header >= 1 && header <= 8760 ? header : 0;
		let savedAuto = sub.auto_update !== false;
		const describeAuto = () => {
			autoHint.textContent = (!auto.checked ? _('Only when you press Update now.')
				: _('Update interval from the subscription: every %d h.').format(period));
		};
		describeAuto();
		const save = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-save' }, text(sub.url ? _('Save') : _('Connect')));
		const update = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-action important' }, text(_('Update now')));

		const saveSettings = () => api.write('set-subscription', url.value.trim(), auto.checked ? '1' : '0');


		const updateSubscription = async link => {
			const changed = link !== (sub.url || '');
			let res;
			if (!changed)
				await saveSettings();
			// A new link is saved only after it downloads and passes the check.
			try {
				res = await api.job('update-subscription', ...(changed ? [ link ] : []));
			}
			catch (e) {
				throw new Error(e.message + (changed && sub.url ? ' ' + _('The previous link is kept.') : ''));
			}
			api.reloadResult(res, api.actionNotice(res.action));
		};

		save.addEventListener('click', async () => {
			if (save.disabled || api.jobRunning)
				return;
			const link = url.value.trim();
			// No link saved yet: the same job as Connect on Home (download, check, enable and start).
			if (!sub.url)
				return api.busy(save, async () => {
					await api.connect(link);
				});
			const changed = link && link !== (sub.url || '');
			if (!link && sub.url && !await api.confirm(_('Stop using the subscription?'), _('XrayWRT keeps the current configuration, but it will no longer be updated.'), _('Disable'), { danger: true }))
				return;
			return api.busy(save, async () => {
				if (changed)
					return updateSubscription(link);
				await saveSettings();
				sub.url = link;
				auto.disabled = readOnly || !link;
				api.notify(_('Subscription settings saved.'));
			});
		});
		update.addEventListener('click', async () => {
			if (update.disabled || api.jobRunning)
				return;
			const link = url.value.trim();
			return api.busy(update, async () => {
				if (!link)
					throw new Error(_('Enter the subscription link, or press Save to stop using a subscription.'));
				return updateSubscription(link);
			});
		});

		auto.addEventListener('change', () => {
			if (readOnly || !sub.url || auto.disabled || api.jobRunning)
				return;
			return api.busy(auto, async () => {
				try {
					await api.write('set-subscription', sub.url, auto.checked ? '1' : '0');
					savedAuto = auto.checked;
					api.notify(_('Subscription settings saved.'));
				}
				finally {
					auto.checked = savedAuto;
					describeAuto();
				}
			});
		});

		// A row's job; the page reloads with its notice.
		const rowButton = (label, cls, run) => {
			const button = E('button', { 'data-mw-job': '', type: 'button', disabled: api.jobRunning || null, class: 'cbi-button ' + cls }, text(label));
			button.addEventListener('click', () => button.disabled || api.jobRunning ? null : run(button));
			return button;
		};
		const subscriptionRow = item => {
			const data = item.meta || {};
			const cell = value => E('td', { class: 'td' }, text(value));
			const actions = [];
			if (!item.active)
				actions.push(rowButton(_('Use'), 'cbi-button-action', button => api.busy(button, async () => {
					const res = await api.job('use-subscription', item.id);
					api.reloadResult(res, _('Subscription "%s" is now in use.').format(item.name));
				})));
			if (!item.active || items.length === 1)
				actions.push(rowButton(_('Delete'), 'cbi-button-remove', async button => {
					if (!await api.confirm(_('Delete the subscription?'), _('"%s" is removed from the router with its saved configuration and rule databases.').format(item.name), _('Delete'), { danger: true }))
						return;
					return api.busy(button, async () => {
						const res = await api.job('delete-subscription', item.id);
						api.reloadResult(res, _('Subscription deleted.'));
					});
				}));
			return E('tr', { class: 'tr' }, [
				cell(item.name),
				cell(item.active ? _('Active') : ''),
				cell(data.upload != null || data.download != null || data.total != null ? api.trafficSummary(data) : '—'),
				cell(data.expire != null ? (Number(data.expire) === 0 ? _('Never') : api.formatDate(data.expire)) : '—'),
				cell(item.updated ? api.formatDate(item.updated) : '—'),
				E('td', { class: 'td' }, readOnly ? [] : actions)
			]);
		};
		const subscriptionTable = E('table', { class: 'table cbi-section-table' }, [
			E('tr', { class: 'tr table-titles' }, [ _('Name'), _('Status'), _('Data used'), _('Expires'), _('Last update'), _('Actions') ]
				.map(label => E('th', { class: 'th', scope: 'col' }, text(label)))),
			...items.map(subscriptionRow)
		]);
		const addUrl = E('input', { id: 'mw-add-url', type: 'text', inputmode: 'url', autocomplete: 'off', spellcheck: 'false',
			class: 'cbi-input-text', style: 'width: 100%', placeholder: 'https://provider.example/sub/…' });
		const addButton = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-add' }, text(_('Add subscription')));
		const addForm = E('form', { action: '', style: 'width: 100%' }, [ addUrl ]);
		addForm.addEventListener('submit', e => {
			e.preventDefault();
			if (!readOnly)
				addButton.click();
		});
		addButton.addEventListener('click', () => {
			if (addButton.disabled || api.jobRunning)
				return;
			return api.busy(addButton, async () => {
				const link = addUrl.value.trim();
				if (!link)
					throw new Error(_('Enter the subscription link.'));
				const res = await api.job('add-subscription', link);
				api.reloadResult(res, res.action === 'exists' ? _('This subscription is already in the list.')
					: res.action === 'added' ? _('Subscription added. Press "Use" to switch to it.') : api.actionNotice(res.action));
			});
		});


		return E('div', { class: 'mw-page' }, [
			api.style(),

			E('div', { class: 'cbi-section' }, [
				...(items.length ? [ subscriptionTable,
					...(readOnly ? [] : [ E('div', { class: 'cbi-value' }, [
						E('label', { class: 'cbi-value-title', for: 'mw-add-url' }, text(_('Add subscription'))),
						E('div', { class: 'cbi-value-field' }, [ addForm, E('div', { class: 'mw-row' }, [ addButton ]),
							E('div', { class: 'cbi-value-description' }, text(_('Add a subscription link, then press "Use" to switch to it.'))) ])
					]) ]) ] : [ E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title', for: 'mw-url' }, text(_('Subscription URL'))),
					E('div', { class: 'cbi-value-field' }, [ urlForm,
						E('div', { class: 'cbi-value-description' }, text(_('Subscription link. Leave empty to use your own configuration.'))) ])
				]) ]),
				...(period > 0 ? [ E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title', for: 'mw-auto' }, text(_('Update automatically'))),
					E('div', { class: 'cbi-value-field' }, [ autoWidget, autoHint ])
				]) ] : sub.url ? [ E('p', { class: 'mw-muted' }, text(_('No automatic update schedule. Press "Update now" to update manually.'))) ] : []),
				...(readOnly ? [] : [ E('div', { class: 'cbi-value' }, [ E('label', { class: 'cbi-value-title' }, []),
					E('div', { class: 'cbi-value-field' }, [ E('div', { class: 'mw-row' }, items.length ? [ update ] : sub.url ? [ save, update ] : [ save ]) ]) ]) ])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
