#!/usr/bin/env python3
"""Verify coordinated feed patches and nftables mapping parsing."""
import itertools
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENTRY = ROOT / 'scripts/apply-upnp-patches.sh'
STATUS = 'feeds/luci/applications/luci-app-upnp/root/usr/share/rpcd/ucode/luci.upnp'
OLD_PATTERN = r'/^\t\tiif ".+" @nh,72,8 (0x6|0x11) th dport ([0-9]+) dnat ip to ([0-9.]+):([0-9]+)/'


class UpnpPatches(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tree = Path(self.tmp.name)
        self.write('feeds/packages/net/miniupnpd/files/miniupnpd.init',
                   '\t\tupnpd_write_bool use_stun 0 ext_perform_stun\n')
        self.write('feeds/packages/net/miniupnpd/Makefile', '# fixture\n')
        self.write('feeds/packages/net/miniupnpd/files/nftables.d/chain-post/dstnat/20-miniupnpd.nft',
                   'jump upnp_prerouting comment "miniupnpd"\n')
        self.write('feeds/luci/applications/luci-app-upnp/htdocs/luci-static/resources/view/upnp/upnp.js',
                   "\t\to = s.taboption('advanced', form.Value, 'stun_host', _('STUN host'));\n")
        self.write(STATUS, 'let m = match(line, ' + OLD_PATTERN + ');\n'
                   "proto: (m[1] == '0x6') ? 'TCP' : 'UDP',\n")

    def write(self, name, text):
        path = self.tree / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def apply(self):
        return subprocess.run(['bash', str(ENTRY)], cwd=self.tree, capture_output=True, text=True)

    def test_idempotent_and_restores_source_patch(self):
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ('100-nat-loopback.patch', '110-stun-input.patch',
                     '120-internal-client-fallback.patch', '130-ipv6-pinhole-client-fallback.patch'):
            self.assertEqual((self.tree / 'feeds/packages/net/miniupnpd/patches' / name).read_bytes(),
                             (ROOT / 'patches' / name).read_bytes())
        before = {str(p.relative_to(self.tree)): p.read_bytes()
                  for p in self.tree.rglob('*') if p.is_file()}
        (self.tree / 'feeds/packages/net/miniupnpd/patches/100-nat-loopback.patch').unlink()
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        after = {str(p.relative_to(self.tree)): p.read_bytes()
                 for p in self.tree.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_missing_guard_refuses_source_patch(self):
        self.write('feeds/packages/net/miniupnpd/files/nftables.d/chain-post/dstnat/20-miniupnpd.nft',
                   'unexpected upstream content\n')
        self.assertNotEqual(self.apply().returncode, 0)
        self.assertFalse((self.tree / 'feeds/packages/net/miniupnpd/patches/100-nat-loopback.patch').exists())

    def test_changed_parser_anchor_does_not_write_inputs(self):
        self.write(STATUS, '// changed upstream\n')
        init = self.tree / 'feeds/packages/net/miniupnpd/files/miniupnpd.init'
        before = init.read_bytes()
        self.assertNotEqual(self.apply().returncode, 0)
        self.assertEqual(init.read_bytes(), before)

    def test_mapping_variants(self):
        self.assertEqual(self.apply().returncode, 0)
        text = (self.tree / STATUS).read_text()
        pattern = re.search(r'match\(line, /(.*)/\);', text)[1]
        # The expression uses the common ECMAScript/ucode regex subset.
        pattern = re.compile(pattern)
        for interface, counter, (proto, port_expr) in itertools.product(
                ['', 'iif "pppoe-wan" ', 'iifname "eth0" '],
                ['', 'counter packets 12 bytes 1024 '],
                [('@nh,72,8 0x6', 'th'), ('@nh,72,8 0x11', 'th'),
                 ('ip protocol tcp', 'tcp'), ('meta l4proto udp', 'udp')]):
            line = f'\t\t{interface}{proto} {port_expr} dport 12345 {counter}dnat ip to 192.168.0.2:54321 comment "test" # handle 8'
            with self.subTest(line=line):
                match = pattern.match(line)
                self.assertIsNotNone(match)
                self.assertEqual(match.groups()[1:], ('12345', '192.168.0.2', '54321'))
        for line in ['chain upnp_prerouting {', 'counter packets 1 bytes 2 accept',
                     '@nh,72,8 0x1 th dport 12345 dnat ip to 192.168.0.2:54321']:
            self.assertIsNone(pattern.match(line))


if __name__ == '__main__':
    unittest.main()
