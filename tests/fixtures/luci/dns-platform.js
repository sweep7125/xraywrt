'use strict';

// Unmodified helper bodies from OpenWrt LuCI openwrt-25.12 (Apache-2.0).
// Source: modules/luci-base/htdocs/luci-static/resources/{form,ui,validation}.js
// Captured for DNS regressions: ordinary choice objects and permissive IPv4 parsing
// are platform behavior, not substitutes using Node's stricter net.isIP().
module.exports = {
	renderFrame(E, dom, L, _, section_id, in_table, option_index, nodes) {
		const config_name = this.uciconfig ?? this.section.uciconfig ?? this.map.config;
		const depend_list = this.transformDepList(section_id);
		let optionEl;

		if (in_table) {
			const title = this.stripTags(this.title).trim();
			optionEl = E('td', {
				'class': 'td cbi-value-field',
				'data-title': (title != '') ? title : null,
				'data-description': this.stripTags(this.description).trim(),
				'data-name': this.option,
				'data-widget': this.typename || (this.template ? this.template.replace(/^.+\//, '') : null) || this.__name__
			}, E('div', {
				'id': 'cbi-%s-%s-%s'.format(config_name, section_id, this.option),
				'data-index': option_index,
				'data-depends': depend_list,
				'data-field': this.cbid(section_id)
			}));
		}
		else {
			optionEl = E('div', {
				'class': 'cbi-value',
				'id': 'cbi-%s-%s-%s'.format(config_name, section_id, this.option),
				'data-index': option_index,
				'data-depends': depend_list,
				'data-field': this.cbid(section_id),
				'data-name': this.option,
				'data-widget': this.typename || (this.template ? this.template.replace(/^.+\//, '') : null) || this.__name__
			});

			if (this.last_child)
				optionEl.classList.add('cbi-value-last');

			if (typeof(this.title) === 'string' && this.title !== '') {
				optionEl.appendChild(E('label', {
					'class': 'cbi-value-title',
					'for': 'widget.cbid.%s.%s.%s'.format(config_name, section_id, this.option),
					'click': (ev) => {
						const node = ev.currentTarget;
						const elem = node.nextElementSibling.querySelector(`#${node.getAttribute('for')}`) ?? node.nextElementSibling.querySelector(`[data-widget-id="${node.getAttribute('for')}"]`);

						if (elem) {
							elem.click();
							elem.focus();
						}
					}
				},
				this.titleref ? E('a', {
					'class': 'cbi-title-ref',
					'href': this.titleref,
					'title': this.titledesc ?? _('Go to relevant configuration page')
				}, this.title) : this.title));

				optionEl.appendChild(E('div', { 'class': 'cbi-value-field' }));
			}
		}

		if (nodes)
			(optionEl.lastChild ?? optionEl).appendChild(nodes);

		if (!in_table && typeof(this.description) === 'string' && this.description !== '')
			dom.append(optionEl.lastChild ?? optionEl,
				E('div', { 'class': 'cbi-value-description' }, this.description.trim()));

		if (depend_list && depend_list.length)
			if (in_table)
				optionEl.firstChild.classList.add('hidden');
			else
				optionEl.classList.add('hidden');

		optionEl.addEventListener('widget-change',
			L.bind(this.map.checkDepends, this.map));

		optionEl.addEventListener('widget-change',
			L.bind(this.handleValueChange, this, section_id, {}));

		dom.bindClassInstance(optionEl, this);

		return optionEl;
	},
	transformChoices() {
		if (!Array.isArray(this.keylist) || this.keylist.length == 0)
			return null;

		const choices = {};

		for (let i = 0; i < this.keylist.length; i++)
			choices[this.keylist[i]] = this.vallist[i];

		return choices;
	},
	selectInit(L, value, choices, options) {
		if (!L.isObject(choices))
			choices = {};

		if (!Array.isArray(value))
			value = (value != null && value != '') ? [ value ] : [];

		if (!options.multiple && value.length > 1)
			value.length = 1;

		this.values = value;
		this.choices = choices;
		this.options = Object.assign({
			multiple: false,
			widget: 'select',
			orientation: 'horizontal'
		}, options);

		if (this.choices.hasOwnProperty(''))
			this.options.optional = true;
	},
	parseIPv4(x) {
		if (!x.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/))
			return null;

		if (RegExp.$1 > 255 || RegExp.$2 > 255 || RegExp.$3 > 255 || RegExp.$4 > 255)
			return null;

		return [ +RegExp.$1, +RegExp.$2, +RegExp.$3, +RegExp.$4 ];
	},
	parseIPv6(x) {
		if (x.match(/^([a-fA-F0-9:]+):(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/)) {
			const v6 = RegExp.$1;
			const v4 = this.parseIPv4(RegExp.$2);

			if (!v4)
				return null;

			x = `${v6}:${(v4[0] * 256 + v4[1]).toString(16)}:${(v4[2] * 256 + v4[3]).toString(16)}`;
		}

		if (!x.match(/^[a-fA-F0-9:]+$/))
			return null;

		const prefix_suffix = x.split(/::/);

		if (prefix_suffix.length > 2)
			return null;

		const prefix = (prefix_suffix[0] || '0').split(/:/);
		const suffix = prefix_suffix.length > 1 ? (prefix_suffix[1] || '0').split(/:/) : [];

		if (suffix.length ? (prefix.length + suffix.length > 7)
			              : ((prefix_suffix.length < 2 && prefix.length < 8) || prefix.length > 8))
			return null;

		let i;
		let word;
		const words = [];

		for (i = 0, word = parseInt(prefix[0], 16); i < prefix.length; word = parseInt(prefix[++i], 16))
			if (prefix[i].length <= 4 && !isNaN(word) && word <= 0xFFFF)
				words.push(word);
			else
				return null;

		for (i = 0; i < (8 - prefix.length - suffix.length); i++)
			words.push(0);

		for (i = 0, word = parseInt(suffix[0], 16); i < suffix.length; word = parseInt(suffix[++i], 16))
			if (suffix[i].length <= 4 && !isNaN(word) && word <= 0xFFFF)
				words.push(word);
			else
				return null;

		return words;
	},
};
