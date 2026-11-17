'use strict';
import * as fs from 'fs';
let path = getenv('MOCK_STATE'), s = json(fs.readfile(path)), a = ARGV, c = s.containers;
let tags = s.tags ??= {};
function ident(name) { let p = fs.popen(`printf %s '${name}' | sha256sum`); let v = split(p.read('all'), ' ')[0]; p.close(); return v; }
function resolve(name) { for (let k in c) if (k == name || ident(k) == name) return k; return name; }
function save() { fs.writefile(path, sprintf('%J', s)); }
function fail(message) { warn(message + '\n'); exit(1); }
if (a[0] == 'container' && a[1] == 'exists') exit(c[a[2]] ? 0 : 1);
if (a[0] == 'image' && a[1] == 'inspect') {
 let ref = a[-1];
 if (ref == 'example:latest') print((s.next_image ?? 'new') + '\n');
 else if (index(a[3], 'RepoTags') >= 0) { for (let tag, id in tags) if (id == ref) print(tag + '\n'); }
 else print((tags[ref] ?? ref) + '\n');
 exit(0);
}
if (a[0] == 'tag') { tags[a[2]] = a[1]; save(); exit(0); }
if (a[0] == 'untag') { if (tags[a[2]] != a[1]) fail('tag mismatch'); delete tags[a[2]]; save(); exit(0); }
if (a[0] == 'image' && a[1] == 'rm') {
 for (let name, container in c) if (container.image == a[2]) fail('image in use');
 push(s.removed_images ??= [], a[2]); save(); exit(0);
}
if (a[0] == 'pull') exit(0);
if (a[0] == 'inspect') {
 let fmt = a[2], name = resolve(a[3]), x = c[name];
 if (!x) fail('missing container');
 if (index(fmt, '.Id') >= 0) print(ident(name));
 else if (index(fmt, 'StoppedByUser') >= 0) print(s.unknown_stopped ? 'unknown' : (x.stopped_by_user ? 'true' : 'false'));
 else if (index(fmt, 'RestartPolicy') >= 0) print(x.policy ?? 'no');
 else if (index(fmt, 'AutoRemove') >= 0) print('false');
 else if (index(fmt, '.Image') >= 0) print(x.image);
 else if (index(fmt, '.State.Running') >= 0) print(x.running ? 'true' : 'false');
 else if (index(fmt, '.State.Status') >= 0) print(x.status ?? (x.running ? 'running' : 'exited'));
 else if (index(fmt, '.Config.Healthcheck') >= 0) print(x.health ? 'yes' : '');
 else if (index(fmt, '.State.Health.Status') >= 0) print('unhealthy');
 print('\n'); exit(0);
}
if (a[0] == 'ps') { for (let k, v in c) if (index(a, '-a') >= 0 || v.running) print(k + ' '); print('\n'); exit(0); }
if (a[0] == 'healthcheck') exit(1);
if (a[0] == 'create') { if (s.fail_create) fail('create diagnostic'); c[a[1]] = { image: s.next_image ?? 'new', running: false }; save(); exit(0); }
if (a[0] == 'stop') {
 if (index(a, '--service') >= 0 && s.fail_service_stop) fail('unsupported service stop');
 let name = resolve(a[-1]); c[name].running = false;
 if (index(a, '--service') < 0) c[name].stopped_by_user = true;
}
else if (a[0] == 'rename') { c[a[2]] = c[a[1]]; delete c[a[1]]; }
else if (a[0] == 'start') {
 let name = resolve(a[1]);
 if (s.fail_start || (s.fail_new_start && c[name].image == 'new')) fail('start diagnostic');
 c[name].running = true; if ('stopped_by_user' in c[name]) c[name].stopped_by_user = false;
}
else if (a[0] == 'restart') {
 if (s.fail_restart) { c[a[1]].running = false; save(); fail('restart diagnostic'); }
 c[a[1]].running = true;
}
else if (a[0] == 'rm') delete c[a[-1]];
else fail('unexpected command: ' + sprintf('%J', a));
save();
