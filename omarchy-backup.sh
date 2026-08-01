#!/bin/bash
# =============================================================================
# omarchy-backup.sh
#
# Compare an Omarchy install (3.8.x or quattro / 4.0.x) against the upstream
# repository (https://github.com/basecamp/omarchy) and back up every local
# difference in dotfiles / config files. Legacy Hyprland .conf files are also
# converted to the quattro .lua format where a .lua equivalent exists.
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

# Temporary files & cleanup trap
MANIFEST="$(mktemp)"
DRY_DIR=""

cleanup() {
  rm -f "$MANIFEST"
  if [[ -n "$DRY_DIR" && -d "$DRY_DIR" ]]; then
    rm -rf "$DRY_DIR"
  fi
}
trap cleanup EXIT INT TERM

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
    --branch)    BRANCH="${2:-}"; shift 2 ;;
    --repo-dir)  REPO_DIR="${2:-}"; shift 2 ;;
    --out-dir)   OUT_DIR="${2:-}"; shift 2 ;;
    --extra)     EXTRA_DIRS="${2:-}"; shift 2 ;;
    --no-convert) NO_CONVERT=1; shift ;;
    --dry-run)    DRY_RUN=1;    shift ;;
    --convert)    CONVERT_ONLY="${2:-}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) fail "Unknown option: $1 (see --help)" ;;
  esac
done

# --- Python Converter Script ----------------------------------------------
run_converter() { # $1 source conf
  python3 - "$1" <<'PYEOF'
import sys, re, json

CONFIG_SECTIONS = {'general','decoration','group','animations','input','misc',
                   'cursor','binds','dwindle','master','xwayland','ecosystem',
                   'scrolling','gestures','layout'}

def lua_string(s): return json.dumps(s, ensure_ascii=False)

def lua_value(v):
    v = v.strip()
    if re.fullmatch(r'-?\d+', v): return v
    if re.fullmatch(r'-?\d*\.\d+', v): return v
    if v.lower() in ('true','yes','on'): return 'true'
    if v.lower() in ('false','no','off'): return 'false'
    return lua_string(v)

def strip_comment(line):
    out=[]; i=0; in_q=False
    while i < len(line):
        c=line[i]
        if c == '"':
            in_q = not in_q
        elif not in_q:
            if c in '#;':
                return ''.join(out)
            if c == '/' and i + 1 < len(line) and line[i+1] == '/':
                return ''.join(out)
        out.append(c); i += 1
    return ''.join(out)

def tokenize(text):
    tokens=[]
    for raw in text.splitlines():
        line = strip_comment(raw).strip()
        if not line:
            tokens.append({'type':'blank'}); continue
        if line.startswith('#') or line.startswith(';') or line.startswith('//') or line.startswith('--'):
            tokens.append({'type':'comment','text':line.lstrip('#;/ ').strip()}); continue
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
    pad = '  '*indent
    for k, v in d.items():
        if isinstance(v, dict):
            lines.append(pad + k + ' = {')
            lines.append(serialize_table(v, indent+1))
            lines.append(pad + '}')
        else:
            lines.append(pad + k + ' = ' + str(v))
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
    parts = mods.split()
    if key: parts.append(key)
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

def parse_window_rule(rule):
    toks = rule.split()
    head = toks[0] if toks else ''
    rest = ' '.join(toks[1:]) if len(toks) > 1 else ''
    booleans = {'float':'float','fullscreen':'fullscreen','nofocus':'no_focus',
                'no_focus':'no_focus','noinitialfocus':'no_initial_focus',
                'center':'center','nomaxsize':'no_max_size','pin':'pin',
                'maximize':'maximize','unbordered':'unbordered','forcergbx':'force_rgba'}
    if head in booleans:
        if rest.lower() in ('on','1','yes','true',''):
            return booleans[head], 'true', False
        if rest.lower() in ('off','0','no','false'):
            return booleans[head], 'false', False
    if head == 'size' and rest:
        return 'size', '{ ' + rest.replace(' ', ', ') + ' }', False
    if head in ('workspace', 'opacity', 'idleinhibit', 'suppressevent', 'suppress_event', 'tag') and rest:
        key_map = {'idleinhibit':'idle_inhibit', 'suppressevent':'suppress_event'}
        return key_map.get(head, head), lua_string(rest), False
    return None, None, True

def render_windowrule(text, out):
    text = text.strip()
    # Check windowrulev2 rule, match pattern
    m_v2 = re.match(r'([^,]+)\s*,\s*(class|title):(.*)$', text)
    if m_v2:
        rule, mtype, mval = m_v2.group(1).strip(), m_v2.group(2).strip(), m_v2.group(3).strip()
        key, lv, todo = parse_window_rule(rule)
        if key:
            if mtype == 'class':
                out.append('o.window(' + lua_string(mval) + ', { ' + key + ' = ' + lv + ' })')
            else:
                out.append('hl.window_rule({ match = { ' + mtype + ' = ' + lua_string(mval) + ' }, ' + key + ' = ' + lv + ' })')
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
        parts.append(('transform = ' if k == 'transform' else k + ' = ') + lua_value(v))
        i += 2
    out.append('hl.monitor({ ' + ', '.join(parts) + ' })')

def run_converter(src_path):
    try:
        with open(src_path, encoding='utf-8', errors='replace') as fh:
            text = fh.read()
    except OSError as e:
        sys.stdout.write('-- Could not read source: %s\n' % e)
        return
    tokens = tokenize(text)
    nodes, _ = build(tokens, 0)
    out = [
        f'-- Auto-converted from {src_path} by omarchy-backup.sh.',
        '-- Review before use: not every construct can be translated 1:1.',
        '-- The original .conf is preserved in the modified/ backup tree.',
        ''
    ]
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
                elif kw in ('windowrule','windowrulev2'): render_windowrule(rest, out)
                elif kw == 'exec-once':      execs.append(rest)
                elif kw == 'env':
                    mm = re.match(r'([^,]+)\s*,\s*(.*)$', rest)
                    if mm:
                        out.append('hl.env(' + lua_string(mm.group(1).strip()) + ', ' + lua_string(mm.group(2).strip()) + ')')
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
    sys.stdout.write('\n'.join(out) + '\n')

run_converter(sys.argv[1])
PYEOF
}

# --- Single-file conversion mode -------------------------------------------
if [[ -n $CONVERT_ONLY ]]; then
  [[ -f $CONVERT_ONLY ]] || fail "Cannot read $CONVERT_ONLY"
  run_converter "$CONVERT_ONLY"
  exit 0
fi

# --- Branch detection -------------------------------------------------------
detect_branch() {
  local v=""
  if [[ -r /usr/share/omarchy/version ]]; then
    v="$(tr -d '[:space:]' < /usr/share/omarchy/version)"
  elif command -v omarchy >/dev/null 2>&1; then
    v="$(omarchy version 2>/dev/null)"
    v="${v%% *}"
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
  DRY_DIR="$(mktemp -d /tmp/omarchy-backup-dryrun.XXXXXX)"
  OUT_DIR="$DRY_DIR"
fi
mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/report.txt"
NOTES="$OUT_DIR/NOTES.md"

backup_modified()   { mkdir -p "$OUT_DIR/modified/$(dirname "$1")";    cp -a "$2" "$OUT_DIR/modified/$1";    echo "mod:$1"    >> "$MANIFEST"; }
backup_local_only() { mkdir -p "$OUT_DIR/local-only/$(dirname "$1")"; cp -a "$2" "$OUT_DIR/local-only/$1"; echo "local:$1" >> "$MANIFEST"; }

# --- Exclusions -------------------------------------------------------------
exclude_file() {
  case "$1" in
    hypr/.luarc.json|chromium/Default/Preferences|*omarchy-upgrade-to-quattro.*) return 0 ;;
    */node_modules/*|*/__pycache__/*|*/.git/*) return 0 ;;
  esac
  return 1
}

compare_file() {
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

# 1) Compare files present in repo
while IFS= read -r -d '' f; do
  rel="${f#$REPO_DIR/config/}"
  repo="$REPO_DIR/config/$rel"
  local="$CONFIG_HOME/$rel"

  if [[ ! -e $local ]]; then
    echo "missing    $rel" >> "$REPORT"
    ((MISSING += 1))
    continue
  fi
  exclude_file "$rel" && continue
  if [[ -f $local ]] && compare_file "$local" "$repo"; then
    echo "same       $rel" >> "$REPORT"
    ((UNCHANGED += 1))
  else
    if (( ! DRY_RUN )); then backup_modified "$rel" "$local"; fi
    echo "modified   $rel" >> "$REPORT"
    ((MODIFIED += 1))
  fi
done < <(find "$REPO_DIR/config" -type f -print0)

# 2) Scan local-only files
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
while IFS= read -r -d '' top; do
  rel="${top#$REPO_DIR/config/}"
  if [[ -n "$rel" ]]; then
    SCAN_DIRS+=("$rel")
  fi
done < <(find "$REPO_DIR/config" -mindepth 1 -maxdepth 1 -type d -print0)

for d in $EXTRA_DIRS; do SCAN_DIRS+=("$d"); done

declare -A _seen
for d in "${SCAN_DIRS[@]}"; do
  [[ -n $d && -z ${_seen[$d]+x} ]] || continue
  _seen[$d]=1
  scan_dir_local_only "$d"
done
unset _seen

# 3) Conversion for backed-up Hyprland configs
if (( ! NO_CONVERT )); then
  hypr_lua_map() {
    case "$1" in
      hypr/hyprland.conf)  echo hypr/hyprland.lua ;;
      hypr/monitors.conf)  echo hypr/monitors.lua ;;
      hypr/input.conf)     echo hypr/input.lua ;;
      hypr/looknfeel.conf) echo hypr/looknfeel.lua ;;
      hypr/bindings.conf)  echo hypr/bindings.lua ;;
      hypr/autostart.conf) echo hypr/autostart.lua ;;
      hypr/windows.conf)   echo hypr/windows.lua ;;
      hypr/envs.conf)      echo hypr/envs.lua ;;
    esac
  }
  special_conf() {
    case "$1" in
      hypr/hypridle.conf|hypr/hyprlock.conf|hypr/hyprpaper.conf|hypr/hyprsunset.conf|hypr/xdph.conf) return 0 ;;
    esac
    return 1
  }

  CONVERTED=0
  if [[ -f $MANIFEST ]]; then
    while IFS=: read -r status rel; do
      [[ $rel == hypr/*.conf ]] || continue
      src="$OUT_DIR/$status/$rel"
      [[ -f $src ]] || continue
      target="$(hypr_lua_map "$rel")"
      if [[ -n $target ]]; then
        mkdir -p "$OUT_DIR/converted/$(dirname "$target")"
        if run_converter "$src" > "$OUT_DIR/converted/$target"; then
          echo "converted  $rel -> $target" >> "$REPORT"
          ((CONVERTED += 1))
        fi
      elif special_conf "$rel"; then
        mkdir -p "$OUT_DIR/converted/$(dirname "$rel")"
        cp -a "$src" "$OUT_DIR/converted/$rel"
        echo "converted  $rel -> (kept as $rel)" >> "$REPORT"
        ((CONVERTED += 1))
      fi
    done < "$MANIFEST"
  fi
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

log "Done."
if (( DRY_RUN )); then
  echo "Dry run report written to $REPORT"
else
  echo "Backup written to $OUT_DIR"
  echo "Report: $REPORT"
fi
