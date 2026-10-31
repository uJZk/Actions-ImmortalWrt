#!/usr/bin/env python3
"""Expose miniupnpd's optional STUN filtering override in UCI and LuCI."""
from pathlib import Path
import sys

init = Path('feeds/packages/net/miniupnpd/files/miniupnpd.init')
ui = Path('feeds/luci/applications/luci-app-upnp/htdocs/luci-static/resources/view/upnp/upnp.js')

def replace_once(text, old, new, path):
    if new in text:
        return text
    if text.count(old) != 1:
        raise SystemExit(f'{path}: expected exactly one upstream anchor; refusing to patch')
    return text.replace(old, new, 1)

init_text = init.read_text()
init_text = replace_once(init_text,
    '\t\tupnpd_write_bool use_stun 0 ext_perform_stun\n',
    '\t\tlocal stun_allow_filtered\n'
    '\t\tconfig_get_bool stun_allow_filtered config stun_allow_filtered 0\n'
    '\t\tif [ "$use_stun" = 1 ] && [ "$stun_allow_filtered" = 1 ]; then\n'
    '\t\t\techo "ext_perform_stun=allow-filtered"\n'
    '\t\telse\n'
    '\t\t\tupnpd_write_bool use_stun 0 ext_perform_stun\n'
    '\t\tfi\n', init)
ui_text = ui.read_text()
ui_text = replace_once(ui_text,
    "\t\to = s.taboption('advanced', form.Value, 'stun_host', _('STUN host'));\n",
    "\t\to = s.taboption('advanced', form.Flag, 'stun_allow_filtered', _('Allow mappings when STUN detects filtering'),\n"
    "\t\t\t_('Continue accepting mappings even when STUN detects filtering. Upstream NAT may still block incoming connections.'));\n"
    "\t\to.default = '0';\n"
    "\t\to.depends('use_stun', '1');\n\n"
    "\t\to = s.taboption('advanced', form.Value, 'stun_host', _('STUN host'));\n", ui)
# Validate both inputs before writing either one.
init.write_text(init_text)
ui.write_text(ui_text)
