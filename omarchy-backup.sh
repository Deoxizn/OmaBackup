#!/bin/bash
# =============================================================================
# omarchy-backup.sh
#
# Compare an Omarchy install (3.8.x or quattro / 4.0.x) against the upstream
# repository (https://github.com/basecamp/omarchy) and back up every local
# difference in dotfiles / config files. Legacy Hyprland .conf files are also
# converted to the quattro .lua format where a .lua equivalent exists, so your
# customizations survive the 3.8.x -> quattro upgrade.
#
# The upstream repo has two branches:
#   master   -> Omarchy 3.8.x (stable, legacy .conf Hyprland layout)
#   quattro  -> Omarchy 4.0.0 / quattro (package-backed, Hyprland in Lua)
#
# The branch is auto-detected from the installed version. Nothing on the
# system is modified; this script only reads and copies files.
# =============================================================================

set -euo pipefail

REPO_URL="${OMARCHY_REPO_URL:-https://github.com/basecamp/omarchy}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
BASE_DIR="${OMABACKUP_DIR:-$HOME/Downloads/Omabackup}"
CACHE_ROOT="$BASE_DIR/.cache"
BACKUPS_ROOT="$BASE_DIR/backups"

BRANCH=""
REPO_DIR=""
OUT_DIR=""
EXTRA_DIRS="fish fastfetch quickshell"
NO_CONVERT=0
DRY_RUN=0
CONVERT_ONLY=""

usage() {
  cat <<'USAGE'
Usage: omarchy-backup.sh [options]

Options:
  --branch <master|quattro|auto>   Repo branch to compare against.
                                   (default: auto, detected from installed version)
  --repo-dir <path>                Use an existing checkout instead of cloning
                                   (e.g. --repo-dir /usr/share/omarchy)
  --out-dir <path>                 Where to write backups
                                   (default: ~/Downloads/Omabackup/backups/<stamp>-<branch>)
  --extra <"dir1 dir2 ...">        Extra ~/.config dirs to scan for local-only files.
                                   (default: "fish fastfetch quickshell")
  --no-convert                     Back up differences but skip .conf -> .lua conversion.
  --dry-run                        Compare and report only; write nothing.
  --convert <file.conf>            Run only the .conf -> .lua converter on one file,
                                   print result to stdout, and exit.
  -h, --help                       Show this help.
USAGE
}

log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWarning:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --branch)
      BRANCH="${2:-}"; shift 2 ;;
    --repo-dir)
      REPO_DIR="${2:-}"; shift 2 ;;
    --out-dir)
      OUT_DIR="${2:-}"; shift 2 ;;
    --extra)
      EXTRA_DIRS="${2:-}"; shift 2 ;;
    --no-convert) NO_CONVERT=1; shift ;;
    --dry-run)    DRY_RUN=1;    shift ;;
    --convert)    CONVERT_ONLY="${2:-}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) fail "Unknown option: $1 (see --help)" ;;
  esac
done
# --- The .conf -> .lua converter (embedded Python) -------------------------
converter_python() {
  cat <<'PYEOF'
import sys, re, json

CONFIG_SECTIONS = {'general','decoration','group','animations','input','misc',
                   'cursor','binds','dwindle','master','xwayland','ecosystem',
                   'scrolling','gestures','layout'}

def lua_string(s): return json.dumps(s, ensure_ascii=False)

def lua_value(v):
    v = v.strip()
    if re.fullmatch(r'-?\d+', v): return v
    if re.fullmatch(r'-?\d*\.\d+', v): return v
    if v in ('true','yes','on'): return 'true'
    if v in ('false','no','off'): return 'false'
    return lua_string(v)

def strip_comment(line):
    out=[]; i=0; in_q=False
    while i < len(line):
        c=line[i]
        if c == '"':
            in_q = not in_q
        elif not in_q and c in '#;' and (i == 0 or line[i-1].isspace()):
            return ''.join(out)
        out.append(c); i += 1
    return ''.join(out)

def tokenize(text):
    tokens=[]
    for raw in text.splitlines():
        line = strip_comment(raw).strip()
        if not line:
            tokens.append({'type':'blank'}); continue
        if line.startswith('#') or line.startswith(';') or line.startswith('--'):
            tokens.append({'type':'comment','text':line.lstrip('#; ').strip()}); continue
        m = re.match(r'\$(\w+)\s*=\s*(.*)$', line)
        if m:
            tokens.append({'type':'var','name':m.group(1),'value':m.group(2).strip()}); continue
        if line == '}':
            tokens.append({'type':'close'}); continue
        if line.endswith('{'):
            tokens.append({'type':'open','name':line[:-1].strip()}); continue
        tokens.append({'type':'line','text':line})
    return tokens

def build(tokens, i):
    nodes=[]
    while i < len(tokens):
        t = tokens[i]
        if t['type'] == 'close': return nodes, i+1
        if t['type'] == 'open':
            children, i = build(tokens, i+1)
            nodes.append({'type':'block','name':t['name'],'children':children}); continue
        nodes.append(t); i += 1
    return nodes, i

def split_kv(line):
    m = re.match(r'([\w.]+)\s*=\s*(.*)$', line)
    if m: return m.group(1), m.group(2).strip()
    return None

def serialize_table(d, indent):
    lines=[]
    for k, v in d.items():
        pad = '  '*indent
        if isinstance(v, dict):
            lines.append(pad + k + ' = {')
            lines.append(serialize_table(v, indent+1))
            lines.append(pad + '}')
        else:
            lines.append(pad + k + ' = ' + v)
    return '\n'.join(lines)

def config_dict(children):
    d={}
    for child in children:
        if child['type'] == 'block':
            d[child['name']] = config_dict(child['children'])
        elif child['type'] == 'line':
            kv = split_kv(child['text'])
            if kv:
                key, value = kv
                lv = lua_value(value)
                parts = key.split('.')
                cur = d
                for p in parts[:-1]:
                    cur = cur.setdefault(p, {})
                cur[parts[-1]] = lv
    return d

def render_config_section(name, children, out, indent=0):
    d = config_dict(children)
    pad = '  '*indent
    if not d:
        out.append(pad + '-- (empty ' + name + ' block)')
        return
    wrapped = {name: d}
    out.append(pad + 'hl.config({')
    out.append(serialize_table(wrapped, indent+1))
    out.append(pad + '})')

def format_keys(mods, key):
    parts=[]
    for m in mods.split():
        parts.append(m)
    if key:
        parts.append(key)
    return ' + '.join(parts)

def render_bind(argstr, has_desc, out):
    fields=[f.strip() for f in argstr.split(',')]
    if len(fields) < 2:
        out.append('-- TODO review bind: ' + argstr); return
    mods, key = fields[0], fields[1]
    if has_desc:
        desc = fields[2] if len(fields) > 2 else ''
        disp = fields[3].lower() if len(fields) > 3 else ''
        rest = fields[4:]
    else:
        desc = None
        disp = fields[2].lower() if len(fields) > 2 else ''
        rest = fields[3:]
    keys = format_keys(mods, key)
    ds = lua_string(desc) if desc else 'nil'
    if disp == 'exec':
        cmd = ','.join(rest).strip()
        out.append('o.bind(' + lua_string(keys) + ', ' + ds + ', ' + lua_string(cmd) + ')')
    else:
        args = ','.join(rest).strip()
        cmd = 'hyprctl dispatch ' + disp + ((' ' + args) if args else '')
        out.append('-- TODO review: original dispatcher was "' + disp + '"')
        out.append('o.bind(' + lua_string(keys) + ', ' + ds + ', ' + lua_string(cmd) + ')')

def render_unbind(argstr, out):
    fields=[f.strip() for f in argstr.split(',')]
    if len(fields) < 2:
        out.append('-- TODO review unbind: ' + argstr); return
    out.append('hl.unbind(' + lua_string(format_keys(fields[0], fields[1])) + ')')

def find_top_comma(s):
    depth=0; in_q=False
    for i, c in enumerate(s):
        if c == '"': in_q = not in_q
        elif in_q: continue
        elif c in '([': depth += 1
        elif c in ')]': depth -= 1
        elif c == ',' and depth == 0: return i
    return -1

def parse_window_rule(rule):
    # returns (lua_key, lua_value, needs_todo)
    toks = rule.split()
    head = toks[0] if toks else ''
    rest = ' '.join(toks[1:]) if len(toks) > 1 else ''
    booleans = {'float':'float','fullscreen':'fullscreen','nofocus':'no_focus',
                'no_focus':'no_focus','noinitialfocus':'no_initial_focus',
                'center':'center','nomaxsize':'no_max_size','pin':'pin',
                'maximize':'maximize','unbordered':'unbordered','forcergbx':'force_rgba'}
    if head in booleans:
        if rest in ('on','1','yes','true',''):
            return booleans[head], 'true', False
        if rest in ('off','0','no','false'):
            return booleans[head], 'false', False
    if head == 'size' and rest:
        return 'size', '{ ' + rest.replace(' ', ', ') + ' }', False
    if head == 'workspace' and rest:
        return 'workspace', lua_string(rest), False
    if head == 'opacity' and rest:
        return 'opacity', lua_string(rest), False
    if head == 'scroll_touchpad' and rest:
        return 'scroll_touchpad', lua_value(rest), False
    if head == 'idleinhibit' and rest:
        return 'idle_inhibit', lua_string(rest), False
    if head == 'suppressevent' and rest:
        return 'suppress_event', lua_string(rest), False
    if head == 'suppress_event' and rest:
        return 'suppress_event', lua_string(rest), False
    if head == 'tag' and rest:
        return 'tag', lua_string(rest), False
    if head == 'workspace':
        return 'workspace', lua_string(''), True
    return None, None, True

def split_match_fields(s):
    # "class .*, title ^$, xwayland 1" -> {"class": ".*", "title": "^$", "xwayland": "1"}
    d = {}
    i = 0
    toks = s.split()
    while i < len(toks):
        if toks[i].startswith('match:') or toks[i] in ('class','title','xwayland','float','fullscreen','pin','tag','initialclass','initialtitle'):
            key = toks[i].split(':', 1)[-1]
            val = (toks[i+1] if i + 1 < len(toks) else '').rstrip(',')
            d[key] = val
            i += 2
        else:
            i += 1
    return d

def render_windowrule(text, out):
    text = text.strip()
    m = re.match(r'match:(\w+)\s+(.+?)\s*,\s*(.*)$', text)
    if m:
        mtype, mval, rule = m.group(1), m.group(2).strip(), m.group(3).strip()
        if mval.startswith('(') and mval.endswith(')'):
            mval = mval[1:-1]
        key, lv, todo = parse_window_rule(rule)
        if key is None:
            out.append('-- TODO review windowrule: ' + text); return
        if mtype == 'class':
            if todo: out.append('-- TODO review window rule')
            out.append('o.window(' + lua_string(mval) + ', { ' + key + ' = ' + lv + ' })')
        else:
            out.append('hl.window_rule({ match = { ' + mtype + ' = ' + lua_string(mval) + ' }, ' + key + ' = ' + lv + ' })')
        return
    idx = find_top_comma(text)
    if idx == -1:
        out.append('-- TODO review windowrule: ' + text); return
    rule = text[:idx].strip()
    match = text[idx+1:].strip()
    key, lv, todo = parse_window_rule(rule)
    if key is None:
        out.append('-- TODO review windowrule: ' + text); return
    m = re.match(r'class\((.+)\)$', match)
    if m:
        if todo: out.append('-- TODO review window rule')
        out.append('o.window(' + lua_string(m.group(1)) + ', { ' + key + ' = ' + lv + ' })')
        return
    m = re.match(r'title\((.+)\)$', match)
    if m:
        out.append('hl.window_rule({ match = { title = ' + lua_string(m.group(1)) + ' }, ' + key + ' = ' + lv + ' })')
        return
    m = re.match(r'\((.+)\)$', match)
    if m:
        out.append('hl.window_rule({ match = { raw = ' + lua_string(m.group(1)) + ' }, ' + key + ' = ' + lv + ' })')
        return
    if match.startswith('match:') or re.match(r'\w+ ', match):
        fields = split_match_fields(match)
        if fields:
            pairs = ', '.join(k + ' = ' + lua_string(v) for k, v in fields.items())
            out.append('hl.window_rule({ match = { ' + pairs + ' }, ' + key + ' = ' + lv + ' })')
            return
    out.append('-- TODO review windowrule: ' + text)

def render_monitor(argstr, out):
    fields=[f.strip() for f in argstr.split(',')]
    name = fields[0]
    if len(fields) == 2 and fields[1] == 'disable':
        out.append('-- TODO review: monitor disabled below')
        out.append('hl.monitor({ output = ' + lua_string(name) + ', disabled = true })')
        return
    mode = fields[1] if len(fields) > 1 and fields[1] else 'preferred'
    position = fields[2] if len(fields) > 2 and fields[2] else 'auto'
    scale = fields[3] if len(fields) > 3 and fields[3] else 'auto'
    parts = ['output = ' + lua_string(name), 'mode = ' + lua_string(mode),
             'position = ' + lua_string(position), 'scale = ' + lua_value(scale)]
    i = 4
    while i + 1 < len(fields):
        k, v = fields[i].strip(), fields[i+1].strip()
        if k == 'transform':
            parts.append('transform = ' + lua_value(v))
        else:
            parts.append(k + ' = ' + lua_value(v))
        i += 2
    out.append('hl.monitor({ ' + ', '.join(parts) + ' })')

def render_gesture(argstr, out):
    fields=[f.strip() for f in argstr.split(',')]
    if len(fields) < 3:
        out.append('-- TODO review gesture: ' + argstr); return
    fingers = lua_value(fields[0])
    direction = lua_string(fields[1].lower())
    action = fields[2]
    if action == 'dispatcher' and len(fields) >= 4:
        d = fields[3]
        arg = fields[4] if len(fields) > 4 else ''
        if d == 'movefocus' and arg:
            dirs = {'l':'left','r':'right','u':'up','d':'down'}
            out.append('hl.gesture({ fingers = ' + fingers + ', direction = ' + direction
                       + ', action = function() hl.dsp.focus({ direction = '
                       + lua_string(dirs.get(arg, arg)) + ' }) end })')
        else:
            out.append('-- TODO review gesture: ' + argstr)
    elif action == 'workspace':
        out.append('hl.gesture({ fingers = ' + fingers + ', direction = ' + direction
                   + ', action = "workspace" })')
    else:
        out.append('-- TODO review gesture: ' + argstr)

def run_converter(src, dst_stream):
    try:
        with open(src, encoding='utf-8', errors='replace') as fh:
            text = fh.read()
    except OSError as e:
        dst_stream.write('-- Could not read source: %s\n' % e)
        return
    tokens = tokenize(text)
    nodes, _ = build(tokens, 0)
    out = []
    out.append('-- Auto-converted from %s by omarchy-backup.sh.' % src)
    out.append('-- Review before use: not every construct can be translated 1:1.')
    out.append('-- The original .conf is preserved in the modified/ backup tree.')
    out.append('')
    execs = []
    for node in nodes:
        t = node['type']
        if t == 'comment':
            out.append('-- ' + node['text'])
        elif t == 'blank':
            out.append('')
        elif t == 'var':
            out.append('local ' + node['name'] + ' = ' + lua_value(node['value']))
        elif t == 'line':
            text = node['text']
            m = re.match(r'(bindd|bind|unbind|windowrule|windowrulev2|gesture|exec-once|env|monitor)\s*=\s*(.*)$', text)
            if m:
                kw, rest = m.group(1), m.group(2).strip()
                if kw == 'bindd':            render_bind(rest, True, out)
                elif kw == 'bind':           render_bind(rest, False, out)
                elif kw == 'unbind':         render_unbind(rest, out)
                elif kw == 'windowrule':     render_windowrule(rest, out)
                elif kw == 'windowrulev2':   render_windowrule(rest, out)
                elif kw == 'gesture':        render_gesture(rest, out)
                elif kw == 'exec-once':      execs.append(rest)
                elif kw == 'env':
                    mm = re.match(r'([^,]+)\s*,\s*(.*)$', rest)
                    if mm:
                        out.append('hl.env(' + lua_string(mm.group(1).strip()) + ', '
                                   + lua_string(mm.group(2).strip()) + ')')
                    else:
                        out.append('-- TODO review: ' + text)
                elif kw == 'monitor':        render_monitor(rest, out)
            elif text.startswith('source'):
                out.append('-- (source directive omitted: ' + text + ')')
            elif text.startswith('exec '):
                out.append('-- (exec directive: ' + text + ')')
            else:
                out.append('-- TODO review: ' + text)
        elif t == 'block':
            if node['name'] in CONFIG_SECTIONS:
                render_config_section(node['name'], node['children'], out)
            else:
                out.append('-- TODO review block: ' + node['name'] + ' {')
                render_config_section(node['name'], node['children'], out, 1)
    if execs:
        if out and out[-1] != '': out.append('')
        out.append('hl.on("hyprland.start", function()')
        for e in execs:
            out.append('  hl.exec_cmd(' + lua_string(e) + ')')
        out.append('end)')
    dst_stream.write('\n'.join(out) + '\n')

run_converter(sys.argv[1], sys.stdout)
PYEOF
}

# Reads a Hyprland-style .conf and writes quattro-flavoured Lua to stdout.
run_converter() {  # $1 source conf  $2 output lua
  converter_python | python3 - "$1" "$2"
}

# --- Single-file conversion mode -------------------------------------------
if [[ -n $CONVERT_ONLY ]]; then
  [[ -f $CONVERT_ONLY ]] || fail "Cannot read $CONVERT_ONLY"
  converter_python | python3 - "$CONVERT_ONLY" -
  exit 0
fi


# --- Branch detection -------------------------------------------------------
detect_branch() {
  local v=""
  if [[ -r /usr/share/omarchy/version ]]; then
    v="$(tr -d '[:space:]' < /usr/share/omarchy/version)"
  elif command -v omarchy >/dev/null 2>&1; then
    v="$(omarchy version 2>/dev/null | awk '{print $1}')"
  fi
  case "$v" in
    3.*) echo master ;;
    4.*|*alpha*|*quattro*) echo quattro ;;
    *) echo quattro ;;
  esac
}

if [[ -z $BRANCH ]]; then
  BRANCH="$(detect_branch)"
fi
case "$BRANCH" in
  master|quattro) ;;
  *) fail "Invalid --branch '$BRANCH' (expected master or quattro)" ;;
esac

# --- Locate the upstream checkout ------------------------------------------
if [[ -z $REPO_DIR ]]; then
  REPO_DIR="$CACHE_ROOT/$BRANCH"
  if [[ -d $REPO_DIR/.git ]]; then
    log "Updating cached checkout ($BRANCH)"
    git -C "$REPO_DIR" fetch --quiet --depth 1 origin "$BRANCH" 2>/dev/null \
      && git -C "$REPO_DIR" reset --quiet --hard FETCH_HEAD 2>/dev/null \
      || warn "Could not update cached checkout; using what is present."
  else
    log "Cloning upstream $BRANCH branch"
    mkdir -p "$CACHE_ROOT"
    if ! git clone --quiet --depth 1 --branch "$BRANCH" --single-branch "$REPO_URL" "$REPO_DIR" 2>/dev/null; then
      warn "Could not clone $REPO_URL ($BRANCH). Falling back to installed defaults in /usr/share/omarchy."
      REPO_DIR=/usr/share/omarchy
    fi
  fi
fi

if [[ ! -d $REPO_DIR/config ]]; then
  fail "$REPO_DIR does not contain an Omarchy config/ tree"
fi
REPO_COMMIT="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo n/a)"

# --- Output layout ----------------------------------------------------------
if [[ -z $OUT_DIR ]]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  OUT_DIR="$BACKUPS_ROOT/$STAMP-$BRANCH"
fi
if (( DRY_RUN )); then
  OUT_DIR="$(mktemp -d /tmp/omarchy-backup-dryrun.XXXXXX)"
fi
mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/report.txt"
NOTES="$OUT_DIR/NOTES.md"
MANIFEST="$(mktemp)"

backup_modified()  { mkdir -p "$OUT_DIR/modified/$(dirname "$1")";    cp -a "$2" "$OUT_DIR/modified/$1";    echo "mod:$1"    >> "$MANIFEST"; }
backup_local_only() { mkdir -p "$OUT_DIR/local-only/$(dirname "$1")"; cp -a "$2" "$OUT_DIR/local-only/$1"; echo "local:$1" >> "$MANIFEST"; }

# --- Exclusions: runtime / churn / upgrade-tool artifacts ------------------
exclude_file() {
  case "$1" in
    hypr/.luarc.json)                    return 0 ;;
    chromium/Default/Preferences)        return 0 ;;
    *omarchy-upgrade-to-quattro.*)       return 0 ;;
    */node_modules/*)                  return 0 ;;
    */__pycache__/*)                   return 0 ;;
    */.git/*)                          return 0 ;;
  esac
  return 1
}

compare_file() {  # $1 local  $2 repo -> exit 0 if identical
  if [[ $1 == *.json ]]; then
    jq -S . "$1" 2>/dev/null | diff -q - <(jq -S . "$2" 2>/dev/null) >/dev/null 2>&1
  else
    diff -q "$1" "$2" >/dev/null 2>&1
  fi
}

# --- Comparison -------------------------------------------------------------
{
  printf 'Omarchy backup report\n'
  printf '  generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '  upstream:  %s\n' "$REPO_URL"
  printf '  branch:    %s\n' "$BRANCH"
  printf '  commit:    %s\n' "$REPO_COMMIT"
  printf '  local:     %s\n\n' "$CONFIG_HOME"
} > "$REPORT"

log "Comparing $CONFIG_HOME against $REPO_DIR/config ($BRANCH@$REPO_COMMIT)"

if (( DRY_RUN )); then
  echo "DRY RUN: nothing will be written."
fi

MODIFIED=0
LOCAL_ONLY=0
UNCHANGED=0
MISSING=0

# 1) Files the repo ships: report modified / missing.
while IFS= read -r rel; do
  repo="$REPO_DIR/config/$rel"
  local="$CONFIG_HOME/$rel"
  [[ -f $repo ]] || continue
  if [[ ! -e $local ]]; then
    echo "missing    $rel" >> "$REPORT"
    ((MISSING += 1))
    continue
  fi
  if exclude_file "$rel"; then continue; fi
  if [[ -f $local ]] && compare_file "$local" "$repo"; then
    echo "same       $rel" >> "$REPORT"
    ((UNCHANGED += 1))
  else
    if (( ! DRY_RUN )); then backup_modified "$rel" "$local"; fi
    echo "modified   $rel" >> "$REPORT"
    ((MODIFIED += 1))
  fi
done < <(cd "$REPO_DIR/config" && find . -type f | sed 's|^\./||' | sort)

# 2) Local files with no stock counterpart in omarchy-managed areas.
scan_dir_local_only() {
  local d="$1"
  [[ -d $CONFIG_HOME/$d ]] || return 0
  while IFS= read -r -d '' f; do
    rel="${f#$CONFIG_HOME/}"
    exclude_file "$rel" && continue
    [[ -e $REPO_DIR/config/$rel ]] && continue
    if (( DRY_RUN )); then
      echo "local-only $rel" >> "$REPORT"
    else
      backup_local_only "$rel" "$f"
      echo "local-only $rel" >> "$REPORT"
    fi
    ((LOCAL_ONLY += 1))
  done < <(find "$CONFIG_HOME/$d" -type f -print0 2>/dev/null)
}

SCAN_DIRS=(hypr omarchy)
while IFS= read -r top; do
  if [[ -d $REPO_DIR/config/$top ]]; then
    SCAN_DIRS+=("$top")
  fi
done < <(cd "$REPO_DIR/config" && find . -mindepth 1 -maxdepth 1 -type d | sed 's|^\./||')
for d in $EXTRA_DIRS; do
  SCAN_DIRS+=("$d")
done

declare -A _seen
for d in "${SCAN_DIRS[@]}"; do
  [[ -n $d ]] || continue
  if [[ -n ${_seen[$d]+x} ]]; then
    continue
  fi
  _seen[$d]=1
  scan_dir_local_only "$d"
done
unset _seen

# 3) .conf -> .lua conversion for backed-up Hyprland configs.
if (( ! NO_CONVERT )); then
  hypr_lua_map() {
    case "$1" in
      hypr/hyprland.conf) echo hypr/hyprland.lua ;;
      hypr/monitors.conf) echo hypr/monitors.lua ;;
      hypr/input.conf)    echo hypr/input.lua ;;
      hypr/looknfeel.conf) echo hypr/looknfeel.lua ;;
      hypr/bindings.conf) echo hypr/bindings.lua ;;
      hypr/autostart.conf) echo hypr/autostart.lua ;;
      hypr/windows.conf)  echo hypr/windows.lua ;;
      hypr/envs.conf)     echo hypr/envs.lua ;;
    esac
  }
  special_conf() {
    case "$1" in
      hypr/hypridle.conf|hypr/hyprlock.conf|hypr/hyprpaper.conf|hypr/hyprsunset.conf|hypr/xdph.conf) return 0 ;;
    esac
    return 1
  }
  note_special() {
    local rel="$1"
    {
      echo
      echo "## $rel"
      case "$rel" in
        hypr/hypridle.conf)
          echo "In quattro, idle timing moved to ~/.config/omarchy/shell.json."
          echo "Port your listener timeouts there:"
          echo "  \"idle\": { \"screensaver\": <screensaver_timeout_s>, \"lock\": <lock_timeout_s> }"
          echo "The original file was kept as-is for reference."
          ;;
        hypr/hyprlock.conf)
          echo "In quattro the lock screen is a Quickshell plugin, not hyprlock."
          echo "This config was kept as-is; port any wanted visuals to the lock plugin."
          echo "Note: hyprlock may be uninstalled after the upgrade."
          ;;
        hypr/hyprpaper.conf)
          echo "hyprpaper is still supported in quattro; keep launching it from"
          echo "hypr/autostart.lua (e.g. hl.exec_cmd(\"uwsm-app -- hyprpaper\"))."
          echo "The original file was kept as-is."
          ;;
        hypr/hyprsunset.conf|hypr/xdph.conf)
          echo "These stay .conf files in quattro too. Copy them back in place."
          ;;
      esac
    } >> "$NOTES"
  }

  CONVERTED=0
  while IFS=: read -r status rel; do
    [[ $rel == hypr/*.conf ]] || continue
    src="$OUT_DIR/$status/$rel"
    [[ -f $src ]] || continue
    target="$(hypr_lua_map "$rel")"
    if [[ -n $target ]]; then
      mkdir -p "$OUT_DIR/converted/$(dirname "$target")"
      if run_converter "$src" "$OUT_DIR/converted/$target"; then
        echo "converted  $rel -> $target" >> "$REPORT"
        ((CONVERTED += 1))
      fi
    elif special_conf "$rel"; then
      mkdir -p "$OUT_DIR/converted/$(dirname "$rel")"
      cp -a "$src" "$OUT_DIR/converted/$rel"
      note_special "$rel"
      echo "converted  $rel -> (kept as $rel)" >> "$REPORT"
      ((CONVERTED += 1))
    fi
  done < "$MANIFEST"
fi

# --- Wrap-up ----------------------------------------------------------------
cat >> "$REPORT" <<EOF

Summary:
  unchanged: $UNCHANGED
  modified:  $MODIFIED
  local-only:$LOCAL_ONLY
  missing:   $MISSING
  converted: ${CONVERTED:-0}
EOF

if (( ! DRY_RUN )); then
  cat > "$OUT_DIR/README.txt" <<EOF
Omarchy backup - $(date '+%Y-%m-%d %H:%M:%S')
================================================
Upstream:  $REPO_URL
Branch:    $BRANCH ($REPO_COMMIT)
Compared:  $CONFIG_HOME vs the repo's config/ templates

Layout:
  modified/   local files that differ from the stock Omarchy template
  local-only/ local files that have no stock counterpart (your additions)
  converted/  Hyprland .conf files translated toward the quattro .lua layout
  report.txt  per-file status and conversion notes
  NOTES.md    notes about .conf files without a .lua equivalent

Re-applying after a quattro upgrade:
  * hypr/*.lua, monitors.lua, input.lua, bindings.lua, looknfeel.lua,
    autostart.lua, hyprland.lua   -> copy into ~/.config/hypr/
  * envs.lua                      -> merge into ~/.config/hypr/envs.lua (or as-is)
  * hyprsunset.conf, xdph.conf    -> copy into ~/.config/hypr/ (still .conf)
  * hypridle.conf / hyprlock.conf -> port settings per NOTES.md
  * omarchy/shell.json            -> merge into ~/.config/omarchy/shell.json
  * omarchy/hooks/*               -> reinstall via 'omarchy hook install <name> <script>'
  * omarchy/themes/*              -> copy into ~/.config/omarchy/themes/

Converted .lua files are best-effort: review them before use.
EOF
fi

rm -f "$MANIFEST"

log "Done."
if (( DRY_RUN )); then
  echo "Dry run report written to $REPORT"
else
  echo "Backup written to $OUT_DIR"
  echo "Report: $REPORT"
fi
