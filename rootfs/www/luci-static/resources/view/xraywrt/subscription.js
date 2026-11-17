'use strict';
'require view';
'require xraywrt.api as api';
'require xraywrt.configuration as configuration';

// No LuCI form here: the page saves only through its own buttons.
return view.extend({
 load: () => configuration.load(),
 render: sub => E('div', { class: 'mw-page' }, [
  E('h2', api.text(_('Subscription'))), api.jobNotice(), configuration.render(sub, 'subscription')
 ]),

 handleSave: null,
 handleSaveApply: null,
 handleReset: null
});
